#!/usr/bin/env python3
"""Fetch, patch and build Bark's pinned Chromium source foundation.

This builds the browser source with Bark's native Swift sidebar on macOS.
No command publishes artifacts or changes user profiles.
"""
import argparse
import ast
import base64
import hashlib
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ENGINE = ROOT / 'engine/chromium'
LOCK = ENGINE / 'chromium.lock.json'
UPSTREAM = 'https://chromium.googlesource.com/chromium/src.git'
DEPOT = 'https://chromium.googlesource.com/chromium/tools/depot_tools.git'
SOURCE_MIRROR = 'https://github.com/chromium/chromium.git'
DASH = 'https://chromiumdash.appspot.com/fetch_releases?channel=Stable&platform=Mac&num=1'


def read_url(url):
    with urllib.request.urlopen(url, timeout=60) as response:
        return response.read()


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_lock(path=LOCK):
    data = json.loads(path.read_text())
    if data.get('schema') != 1 or data.get('upstream') != UPSTREAM or data.get('depot_tools') != DEPOT:
        raise ValueError('Unsupported lockfile or source repository')
    if not re.fullmatch(r'\d+\.\d+\.\d+\.\d+', data['version']):
        raise ValueError('Invalid Chromium version')
    for name in ('revision', 'depot_tools_revision'):
        if not re.fullmatch(r'[0-9a-f]{40}', data[name]):
            raise ValueError('Invalid pinned revision')
    for entry in data['patches']:
        if not re.fullmatch(r'[a-zA-Z0-9_.-]+\.patch', entry['file']):
            raise ValueError('Invalid patch filename')
        if digest(ENGINE / 'patches' / entry['file']) != entry['sha256']:
            raise ValueError('Patch changed without updating its lockfile digest: ' + entry['file'])
    return data


def run(args, cwd=None, env=None, capture=False):
    return subprocess.run([str(x) for x in args], cwd=cwd, env=env, check=True,
                          text=True, stdout=subprocess.PIPE if capture else None).stdout


def git(src, *args):
    return run(['git', '-C', src, *args], capture=True).strip()


def patch_paths(patches):
    paths = set()
    for patch in patches:
        for line in patch.read_text().splitlines():
            if line.startswith('--- a/') or line.startswith('+++ b/'):
                name = line[6:].split('\t')[0]
                if Path(name).is_absolute() or '..' in Path(name).parts or '\\' in name:
                    raise ValueError('Unsafe patch path')
                paths.add(name)
    return sorted(paths)


def patch_files(lock):
    return [ENGINE / 'patches' / entry['file'] for entry in lock['patches']]


def verify_patches(lock):
    """Check against exact upstream files without downloading a full checkout."""
    patches = patch_files(lock)
    with tempfile.TemporaryDirectory(prefix='bark-patch-check-') as folder:
        tree = Path(folder)
        for name in patch_paths(patches):
            url = f"https://chromium.googlesource.com/chromium/src/+/{lock['revision']}/{name}?format=TEXT"
            dest = tree / name
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(base64.b64decode(read_url(url), validate=True))
        run(['git', 'apply', '--check', *patches], cwd=tree)
    print(f"{len(patches)} patches apply cleanly to Chromium {lock['version']}")


def latest_release():
    releases = json.loads(read_url(DASH))
    if not releases or releases[0].get('channel') != 'Stable' or releases[0].get('platform') != 'Mac':
        raise ValueError('Unexpected Chromium release metadata')
    version, revision = releases[0]['version'], releases[0]['hashes']['chromium']
    if not re.fullmatch(r'\d+\.\d+\.\d+\.\d+', version) or not re.fullmatch(r'[0-9a-f]{40}', revision):
        raise ValueError('Invalid upstream release metadata')
    return version, revision


def nearest_existing(path):
    while not path.exists():
        path = path.parent
    return path


def check_macos_toolchain():
    run(['xcodebuild', '-version'])
    metal = subprocess.run(['xcrun', 'metal', '--version'], capture_output=True, text=True)
    if metal.returncode:
        raise RuntimeError('The Metal compiler is unavailable. Install Apple’s component with: xcodebuild -downloadComponent MetalToolchain\n' + metal.stderr.strip())


def doctor(work, minimum=150):
    free = shutil.disk_usage(nearest_existing(work)).free / 1024**3
    print(f'Build host: {platform.system()} {platform.machine()}')
    print(f'Build directory: {work}')
    print(f'Available disk: {free:.1f} GiB; preflight budget: {minimum} GiB')
    if not shutil.which('git'):
        raise RuntimeError('Install Git before preparing Chromium')
    if platform.system() == 'Darwin':
        check_macos_toolchain()
    elif platform.system() != 'Linux':
        raise RuntimeError('The initial build driver supports macOS and Linux; Windows integration is pending')
    if free < minimum:
        raise RuntimeError(f'Insufficient build space. Use --work-dir on a larger volume ({minimum} GiB free recommended).')
    if not shutil.which('git-lfs'):
        raise RuntimeError('Install Git LFS before syncing Chromium dependencies (macOS: brew install git-lfs).')


def build_env(depot):
    env = dict(os.environ)
    env['PATH'] = str(depot) + os.pathsep + env.get('PATH', '')
    env['DEPOT_TOOLS_UPDATE'] = '0'
    env['PYTHONUNBUFFERED'] = '1'
    return env


def bootstrap_tools(work):
    depot = work / 'depot_tools'
    # Pinning depot_tools disables its automatic updater, so explicitly install
    # the pinned bootstrap Python needed by GN and other tool wrappers.
    run([depot / 'ensure_bootstrap'], cwd=work, env=build_env(depot))


def ensure_checkout(src, lock):
    if not (src / '.git').exists() or git(src, 'rev-parse', 'HEAD') != lock['revision']:
        raise RuntimeError('Checkout does not match the pinned revision. Run sync in a clean build directory.')


def verify_dependencies(work):
    """Catch interrupted dependency checkouts even if gclient returns success."""
    path = work / '.gclient_entries'
    if not path.is_file():
        raise RuntimeError('Dependency metadata is missing. Run sync before building.')
    try:
        tree = ast.parse(path.read_text())
        entries = next(ast.literal_eval(node.value) for node in tree.body
                       if isinstance(node, ast.Assign) and any(isinstance(target, ast.Name) and target.id == 'entries' for target in node.targets))
        if not isinstance(entries, dict):
            raise ValueError('entries must be a dictionary')
    except (SyntaxError, ValueError, StopIteration) as error:
        raise RuntimeError('Invalid dependency metadata; run sync again.') from error
    failures, checked = [], 0
    for name, source in entries.items():
        match = re.search(r'@([a-f0-9]{40})$', source) if isinstance(source, str) else None
        if not match:
            continue
        dependency = (work / name).resolve()
        if not dependency.is_relative_to(work.resolve()):
            raise RuntimeError('Dependency path is outside the build directory: ' + name)
        checked += 1
        if not (dependency / '.git').exists():
            failures.append(name + ': missing Git checkout')
            continue
        result = subprocess.run(['git', '-C', dependency, 'rev-parse', '--verify', 'HEAD'], capture_output=True, text=True)
        if result.returncode or result.stdout.strip() != match[1]:
            failures.append(name + ': incomplete checkout or incorrect revision')
    if failures:
        raise RuntimeError('Dependency verification failed; repair or resync before building:\n' + '\n'.join(failures[:10]))
    print(f'Verified {checked} pinned Git dependencies')


def seed_from_github(work, lock):
    """Seed the exact commit from Chromium's official mirror, retaining origin."""
    src = work / 'src'
    if not (src / '.git').exists():
        run(['git', 'init', src])
    if 'origin' not in git(src, 'remote').splitlines():
        run(['git', '-C', src, 'remote', 'add', 'origin', UPSTREAM])
    elif git(src, 'remote', 'get-url', 'origin') != UPSTREAM:
        raise RuntimeError('Source origin differs from Chromium upstream; use a separate build directory')
    # A previous download can finish before checkout does. Reuse its verified
    # commit instead of transferring the large source pack again on a retry.
    present = subprocess.run(['git', '-C', src, 'cat-file', '-e', lock['revision'] + '^{commit}'],
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    if not present:
        run(['git', '-C', src, 'fetch', '--no-tags', '--depth=1', '--progress', SOURCE_MIRROR, lock['revision']])
    run(['git', '-C', src, 'checkout', '--detach', lock['revision']])
    ensure_checkout(src, lock)


def gclient_config(custom_vars):
    return 'solutions = ' + repr([{'name': 'src', 'url': UPSTREAM, 'managed': False, 'custom_deps': {}, 'custom_vars': custom_vars}]) + '\n'


def write_gclient(work):
    """Write Bark's .gclient; official builds need runhooks to fetch PGO profiles."""
    config = gclient_config({'checkout_pgo_profiles': True})
    gclient = work / '.gclient'
    # Checkouts made before the official-build preset lack the PGO variable.
    if gclient.exists() and gclient.read_text() not in (config, gclient_config({})):
        raise RuntimeError('Existing .gclient differs from Bark configuration; use a separate build directory')
    gclient.write_text(config)


def sync(work, lock, github_mirror=False):
    doctor(work)
    work.mkdir(parents=True, exist_ok=True)
    depot, src = work / 'depot_tools', work / 'src'
    if src.exists() and any(src.iterdir()):
        # Never discard locally applied patches or developer changes on update.
        if not (src / '.git').exists() or git(src, 'status', '--porcelain', '--untracked-files=normal'):
            raise RuntimeError('Source checkout has changes. Preserve it and use a fresh --work-dir for the new pin.')
    if not depot.exists():
        run(['git', 'clone', '--no-checkout', DEPOT, depot])
    elif git(depot, 'status', '--porcelain'):
        raise RuntimeError('depot_tools has local changes; refusing to overwrite them')
    run(['git', '-C', depot, 'fetch', 'origin', lock['depot_tools_revision']])
    run(['git', '-C', depot, 'checkout', '--detach', lock['depot_tools_revision']])
    bootstrap_tools(work)
    write_gclient(work)
    env = build_env(depot)
    if github_mirror:
        seed_from_github(work, lock)
    run([depot / 'gclient', 'sync', '--no-history', '--nohooks', '--revision', 'src@' + lock['revision']], cwd=work, env=env)
    ensure_checkout(src, lock)
    verify_dependencies(work)
    print('Dependencies fetched. On Linux, install the OS dependencies described in engine/chromium/README.md before configure.')


def overlay_files():
    """Map source-owned UI/core files into Chromium without duplicating them."""
    result = {p.relative_to(ENGINE / 'overlay').as_posix(): p
              for p in sorted((ENGINE / 'overlay').rglob('*'))
              if p.is_file() and '__pycache__' not in p.parts and p.name != '.DS_Store'}
    manifest = ENGINE / 'overlay-sources.json'
    if manifest.exists():
        for name, source in json.loads(manifest.read_text()).items():
            destination = Path(name)
            origin = (ROOT / source).resolve()
            if (destination.is_absolute() or '..' in destination.parts or '\\' in name
                    or not origin.is_relative_to(ROOT.resolve()) or not origin.is_file()):
                raise ValueError('Unsafe overlay source: ' + name)
            if name in result:
                raise ValueError('Duplicate overlay destination: ' + name)
            result[name] = origin
    return result


def prepare(work, lock):
    src = work / 'src'
    ensure_checkout(src, lock)
    stamp_path = work / 'bark-prepared.json'
    overlays = overlay_files()
    patches = patch_files(lock)
    inputs = {p.relative_to(ENGINE).as_posix(): digest(p) for p in patches}
    inputs.update({'overlay/' + name: digest(source) for name, source in overlays.items()})
    previous_outputs = {}
    previous_patch_paths = set()
    if stamp_path.exists():
        stamp = json.loads(stamp_path.read_text())
        if stamp.get('revision') != lock['revision']:
            raise RuntimeError('Prepared source has a different revision. Use a clean checkout.')
        previous_outputs = stamp['outputs']
        for name, expected in previous_outputs.items():
            candidate = src / name
            if (not candidate.resolve().is_relative_to(src.resolve()) or candidate.is_symlink()
                    or not candidate.is_file() or digest(candidate) != expected):
                raise RuntimeError('Prepared source changed: ' + name)
        if stamp.get('inputs') == inputs:
            return
        # Rebuild the stack in a staging directory from the exact pinned HEAD.
        # Only files whose previous output hash still matches may be replaced.
        # No checkout-wide reset/clean and no dependency/output deletion.
        previous_patch_paths = {name for name in previous_outputs if not name.startswith('bark/')}
        old_overlay = {name[5:] for name in previous_outputs if name.startswith('bark/')}
        if old_overlay - overlays.keys():
            raise RuntimeError('Overlay removals require a clean checkout')
    elif git(src, 'status', '--porcelain', '--untracked-files=normal'):
        raise RuntimeError('Refusing to patch a dirty Chromium checkout')
    output_paths = sorted(set(patch_paths(patches)) | {'bark/' + name for name in overlays})
    patch_targets = sorted(set(patch_paths(patches)) | previous_patch_paths)
    pristine = {}
    # Validate new patch targets against HEAD, even if unrelated developer files
    # exist elsewhere. Only verified Bark outputs may be overwritten.
    for name in patch_targets:
        if not (src / name).resolve().is_relative_to(src.resolve()):
            raise RuntimeError('Patch target escapes checkout: ' + name)
        pristine[name] = subprocess.check_output(['git', '-C', src, 'show', 'HEAD:' + name])
        if name not in previous_outputs:
            if (src / name).is_symlink() or (src / name).read_bytes() != pristine[name]:
                raise RuntimeError('New patch target has developer changes: ' + name)
    for name in overlays:
        target = src / 'bark' / name
        if not target.resolve().is_relative_to(src.resolve()):
            raise RuntimeError('Overlay target escapes checkout: ' + name)
        if (target.exists() or target.is_symlink()) and 'bark/' + name not in previous_outputs:
            raise RuntimeError('Refusing to overwrite an unowned overlay file: ' + name)
    # Assemble and check the complete delta before changing the build checkout.
    with tempfile.TemporaryDirectory(prefix='bark-prepare-') as directory:
        stage = Path(directory)
        for name in patch_targets:
            target = stage / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(pristine[name])
        if patches:
            run(['git', 'apply', '--check', *patches], cwd=stage)
            run(['git', 'apply', *patches], cwd=stage)
        for name, source in overlays.items():
            target = stage / 'bark' / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        changed_paths = sorted(set(patch_targets) | {'bark/' + name for name in overlays})
        original = {name: (src / name).read_bytes() if (src / name).exists() else None for name in changed_paths}
        modified = []
        try:
            for name in changed_paths:
                replacement = (stage / name).read_bytes()
                if replacement == original[name]:
                    continue  # Preserve timestamps and cached header dependents.
                target = src / name
                target.parent.mkdir(parents=True, exist_ok=True)
                modified.append(name)
                target.write_bytes(replacement)
            temporary_stamp = stamp_path.with_suffix('.tmp')
            temporary_stamp.write_text(json.dumps({'revision': lock['revision'], 'inputs': inputs,
                'outputs': {name: digest(src / name) for name in output_paths}}, indent=2) + '\n')
            temporary_stamp.replace(stamp_path)
        except BaseException:
            for name in reversed(modified):
                data = original[name]
                target = src / name
                if data is None: target.unlink(missing_ok=True)
                else: target.write_bytes(data)
            raise


def configure(work, lock, target):
    expected_host = 'Darwin' if target.startswith('mac-') else 'Linux'
    if platform.system() != expected_host:
        raise RuntimeError('The macOS Swift/AppKit build requires a Mac with Xcode; use a matching build host.')
    if target == 'mac-arm64' and platform.machine() != 'arm64':
        raise RuntimeError('This initial Mac preset targets an Apple Silicon Mac')
    if target == 'linux-x64' and platform.machine() not in ('x86_64', 'AMD64'):
        raise RuntimeError('This initial Linux preset requires an x86-64 build host')
    if expected_host == 'Darwin':
        check_macos_toolchain()
    verify_dependencies(work)
    bootstrap_tools(work)
    prepare(work, lock)
    env = build_env(work / 'depot_tools')
    write_gclient(work)
    run([work / 'depot_tools/gclient', 'runhooks'], cwd=work, env=env)
    out = work / 'src/out' / ('Bark-' + target)
    out.mkdir(parents=True, exist_ok=True)
    args = (ENGINE / 'args' / (target + '.gn')).read_text()
    args_path = out / 'args.gn'
    if args_path.exists() and args_path.read_text() != args:
        raise RuntimeError('Existing args.gn differs from the preset; use a separate output directory')
    args_path.write_text(args)
    run([work / 'depot_tools/gn', 'gen', out, '--fail-on-unused-args'], cwd=work / 'src', env=env)
    return out


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['doctor', 'check', 'update', 'verify-patches', 'verify-deps', 'sync', 'prepare', 'configure', 'build'])
    parser.add_argument('--work-dir', type=Path, default=Path(os.environ.get('BARK_CHROMIUM_WORK_DIR', ROOT / '.deps/chromium-source')))
    parser.add_argument('--target', choices=['mac-arm64', 'linux-x64'])
    parser.add_argument('--github-mirror', action='store_true', help='For sync: seed the pinned source commit from Chromium’s official GitHub mirror')
    parser.add_argument('--jobs', type=int, help='For build: maximum concurrent local compiler jobs')
    args = parser.parse_args()
    if args.github_mirror and args.command != 'sync':
        parser.error('--github-mirror is only supported with sync')
    if args.jobs is not None and (args.command != 'build' or args.jobs < 1):
        parser.error('--jobs requires build and a positive integer')
    lock = load_lock()
    work = args.work_dir.expanduser().resolve()
    if args.command == 'doctor': doctor(work)
    elif args.command in ('check', 'update'):
        version, revision = latest_release()
        print(f"Pinned: {lock['version']} | Latest Mac stable: {version}")
        if (version, revision) != (lock['version'], lock['revision']):
            if args.command == 'check': return 1
            if tuple(map(int, version.split('.'))) < tuple(map(int, lock['version'].split('.'))):
                raise RuntimeError('Refusing an upstream version downgrade')
            candidate = dict(lock, version=version, revision=revision)
            verify_patches(candidate)  # A conflict never changes the working lock.
            temporary = LOCK.with_suffix('.json.tmp')
            temporary.write_text(json.dumps(candidate, indent=2) + '\n')
            temporary.replace(LOCK)
            print('Pin updated. Build, test, and review before release; no artifact was published.')
    elif args.command == 'verify-patches': verify_patches(lock)
    elif args.command == 'verify-deps': verify_dependencies(work)
    elif args.command == 'sync': sync(work, lock, github_mirror=args.github_mirror)
    elif args.command == 'prepare': prepare(work, lock)
    else:
        target = args.target or ('mac-arm64' if platform.system() == 'Darwin' else 'linux-x64')
        out = configure(work, lock, target)
        if args.command == 'build':
            jobs = ['-j', str(args.jobs)] if args.jobs is not None else []
            env = build_env(work / 'depot_tools')
            ninja = [work / 'depot_tools/autoninja', '-C', out, *jobs]
            if target.startswith('mac-'):
                # Catch bridge/API drift early when updating Chromium, before
                # spending hours compiling unrelated browser libraries.
                run([work / 'depot_tools/gn', 'check', out, '//bark:sidebar'], cwd=work / 'src', env=env)
                run([*ninja,
                     'bark_swift_link_check',
                     'obj/bark/sidebar/sidebar_mac.o',
                     'obj/bark/updater/updater_mac.o',
                     'obj/chrome/browser/ui/views/frame/browser_view/browser_view.o',
                     'obj/chrome/browser/ui/views/frame/browser_view_layout_delegate_impl/browser_view_layout_delegate_impl.o'],
                    cwd=work / 'src', env=env)
            run([*ninja, 'chrome'], cwd=work / 'src', env=env)
            print(f'Built Bark browser in {out}; use tools/release_macos.py for signed distribution.')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print('Chromium setup: ' + str(error), file=sys.stderr)
        sys.exit(2)
