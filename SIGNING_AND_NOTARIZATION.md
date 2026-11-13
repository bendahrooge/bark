# macOS signing and GitHub updates

Bark uses Apple Developer ID signing, Apple notarization, and Sparkle 2.10.1.
The public source and release repository is [bendahrooge/bark](https://github.com/bendahrooge/bark).
Configuration lives in [`packaging/macos/release.json`](packaging/macos/release.json).

## Configured on this Mac

- Apple team: `926NLH6ZVC`.
- Signing identity: `Developer ID Application: Benjamin Dahrooge (926NLH6ZVC)`.
- Notarization Keychain profile: `bark-notary`.
- Sparkle Keychain account: `bark`.
- Release bundle ID: `app.bark.browser`.
- Feed: `https://github.com/bendahrooge/bark/releases/latest/download/appcast.xml`.

The Apple certificate and its private key, the notary password, and the Sparkle
private key stay in the login Keychain. Only the Sparkle **public** key belongs
in the repository. The certificate was issued November 13, 2026 and expires
December 13, 2027. Back up both signing keys securely before moving build hosts;
never commit a `.p12`, `.p8`, exported Sparkle key, or password.

Release builds enable the native sidebar without launch flags. The Bark menu
contains **Check for Updates…** and **Automatically Check for Updates**. Checks
are enabled initially; users can turn them off. Sparkle asks before installing
an update. Both the feed and archive must pass Sparkle signature verification.
Development builds keep their separate bundle identifier and have no updater.

## Release from this Mac

Prerequisites: Python 3.12+, Xcode, GitHub CLI authenticated for this repository,
and a complete Chromium build. `tools/chromium.py` manages the pinned build tools;
do not invoke a different Ninja implementation against the cached Siso output.

The CLI downloaded during setup is in `.tools/gh_2.104.0_macOS_arm64/bin/gh`.
For this checkout, add it to the current terminal's PATH if `gh` is not installed
elsewhere:

```sh
export PATH="$PWD/.tools/gh_2.104.0_macOS_arm64/bin:$PATH"
gh auth status
security find-identity -v -p codesigning
xcrun notarytool history --keychain-profile bark-notary
```

1. Update the code and `docs/releases/VERSION.md`. Commit and push the source to
   `main`. The release publisher refuses dirty, unpushed, or mismatched source.
2. Build and run the relevant regression checks:

   ```sh
   python3 -m unittest discover -s tools/tests
   swift test --scratch-path .build/core
   python3 tools/test_chromium_swift.py
   python3 tools/test_updater_macos.py
   python3 tools/chromium.py build --work-dir .deps/chromium-source --target mac-arm64 --jobs 6
   node tools/test_chromium_browser.mjs --headed --swift-ui
   ```

3. Package, sign every nested executable/framework/helper, notarize, staple,
   verify Gatekeeper, and generate the signed feed:

   ```sh
   python3 tools/release_macos.py --version 0.1.0 --build 1
   ```

   Increase the numeric build for every release, independently of the Chromium
   version. The app uses `BarkChromium` for profiles and `Bark Safe Storage / Bark`
   for encrypted storage, matching the packaged Chromium development app.
   Test encrypted storage across restart before replacing an existing install.

   The packager pins and verifies Sparkle's download checksum. It uses the pinned
   Chromium source's entitlements for the main app and V8 helpers, and preserves
   Sparkle's XPC entitlements. Release signing uses hardened runtime and secure
   timestamps. Rejected or unfinished notarization cannot produce an update feed.

4. Test `release/v0.1.0/Bark.app` with a disposable profile. Then publish:

   ```sh
   python3 tools/publish_release.py --version 0.1.0 --build 1 \
     --notes docs/releases/0.1.0.md --publish
   ```

   Without `--publish`, this creates a draft. All assets upload to the draft
   before it becomes the latest public release. The stable feed URL only changes
   when the complete release is published. The publisher rejects altered
   artifacts, duplicate release versions, and non-increasing build numbers.
   If an upload fails, finish or remove that draft explicitly before retrying;
   published archives must never be overwritten.

The three public assets are `Bark-VERSION-mac-arm64.zip`, `appcast.xml`, and
`SHA256SUMS`. The app, notary report, and source/hash manifest remain local in
`release/vVERSION/`. A first release supplies a feed; testing an actual upgrade
requires a second signed release with a higher build number. Builds made before
Sparkle integration need one manual installation of the signed app.

## Optional GitHub Actions release runner

`.github/workflows/release-macos.yml` provides a manual release workflow. It is
not a hosted-runner build: full Chromium requires a persistent Apple Silicon
Mac, substantial disk space, and access to the signing Keychain. No runner is
registered automatically during this setup.

To use it, register a trusted runner with the `bark-release` label, install
Python 3.12+, Xcode and `gh`, and provision the same Apple identity, `bark-notary`
profile, and Sparkle `bark` key for that runner's macOS user. Set repository
variable `BARK_CHROMIUM_WORK_DIR` to its prepared, absolute Chromium work path.
The runner's login Keychain must be unlocked for signing. Run only trusted source
on this machine; the workflow accepts dispatches from the default branch only.
The workflow uses the job's GitHub token for uploads; Apple and Sparkle keys do
not need to be exported into GitHub secrets.

## Recovery and a new Mac

Export the Developer ID identity **with its private key** as a password-protected
`.p12` using Keychain Access. Export Sparkle's key to a protected location outside
the repository using its `generate_keys --account bark -x /secure/path/key` tool.
Import those keys on the replacement signing Mac, preserving the same public key
in `release.json`. Do not casually regenerate keys for an existing feed.

Store notarization credentials interactively (do not put the password in shell
history):

```sh
xcrun notarytool store-credentials bark-notary \
  --apple-id bendahrooge@gmail.com --team-id 926NLH6ZVC
```

For a rejected or timed-out submission, use the ID in `notarization.json`:

```sh
xcrun notarytool info SUBMISSION_ID --keychain-profile bark-notary
xcrun notarytool log SUBMISSION_ID --keychain-profile bark-notary
```

If a submission times out, confirm its outcome before submitting it again.
Use a new `--output` directory for a retry so prior artifacts remain available.
Never sign or package the app bundle while it is running.

References: [Apple Developer ID](https://developer.apple.com/developer-id/),
[Sparkle setup](https://sparkle-project.org/documentation/),
[Sparkle programmatic integration](https://sparkle-project.org/documentation/programmatic-setup/).
