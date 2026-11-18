#!/usr/bin/env node
// Exercise the compiled browser with disposable profiles and loopback pages.
// Use --all to include every applicable browser suite. Node 18+; no packages.
import assert from 'node:assert/strict';
import {execFileSync, spawn} from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {setTimeout as delay} from 'node:timers/promises';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const target = process.platform === 'darwin' ? 'mac-arm64' : 'linux-x64';
const output = path.join(root, '.deps/chromium-source/src/out', `Bark-${target}`);
const arguments_ = process.argv.slice(2);
const all = arguments_.includes('--all');
const headless = arguments_.includes('--headless');
const headed = arguments_.includes('--headed');
const swiftUI = arguments_.includes('--swift-ui');
if (arguments_.filter(arg => !arg.startsWith('--')).length > 1 ||
    arguments_.some(arg => arg.startsWith('--') && !['--all', '--headless', '--headed', '--swift-ui'].includes(arg))) {
  throw new Error('Usage: test_chromium_browser.mjs [executable] [--all [--headless] | --headed [--swift-ui]]');
}
if (headless && !all) throw new Error('--headless requires --all; the default extension run is already headless');
if (all && (headed || swiftUI)) throw new Error('--all selects native macOS checks automatically; use --headless to skip them');
if (swiftUI && (!headed || process.platform !== 'darwin')) throw new Error('--swift-ui requires --headed on macOS');
const binary = path.resolve(arguments_.find(arg => !arg.startsWith('--')) || path.join(output,
  process.platform === 'darwin' ? 'Bark-dev.app/Contents/MacOS/Bark' : 'chrome'));
const fixture = path.join(root, 'tools/fixtures/extension');
const lock = JSON.parse(fs.readFileSync(path.join(root, 'engine/chromium/chromium.lock.json')));
const resultsRoot = path.join(root, 'test-results/chromium-browser');

export function bundleEnablesSwiftUI() {
  const info = execFileSync('plutil', ['-convert', 'json', '-o', '-',
    path.resolve(path.dirname(binary), '../Info.plist')], {encoding: 'utf8'});
  return JSON.parse(info).BarkEnableSwiftUI === true;
}

export class Browser {
  constructor(profile, logPath, {nativeWindow = false, nativeUI = swiftUI, loadFixture = true, profileDirectory = 'Default', testDirectory, extraFlags = [], initialURL = 'about:blank'} = {}) {
    const flags = ['--remote-debugging-pipe', '--no-first-run',
      '--no-default-browser-check', '--disable-background-networking',
      '--disable-component-update', '--disable-sync',
      `--user-data-dir=${profile}`, initialURL];
    if (!nativeWindow) flags.push('--headless');
    if (profileDirectory) flags.push(`--profile-directory=${profileDirectory}`);
    if (loadFixture) flags.push(`--load-extension=${fixture}`);
    if (testDirectory) flags.push(`--bark-ui-test-directory=${testDirectory}`);
    flags.push(...extraFlags);
    if (nativeWindow) {
      // Chromium 157 exposes extension installer commands to the trusted
      // browser CDP session. This test uses only its private inherited pipe.
      if (nativeUI) flags.push('--bark-swift-ui');
    }
    // These apply only to fresh test profiles. Never use mock key storage for
    // the installed app or claim this test validates production encryption.
    if (process.platform === 'darwin') {
      flags.push('--use-mock-keychain', '--disable-features=DialMediaRouteProvider');
    } else if (process.platform === 'linux') {
      flags.push('--password-store=basic');
    }
    this.pending = new Map();
    this.nextId = 0;
    this.exited = false;
    const log = fs.openSync(logPath, 'w');
    try {
      // Chromium reads commands on descriptor 3, replies on 4. No debugging
      // port is exposed; the browser's sandbox remains enabled.
      this.child = spawn(binary, flags, {stdio: ['ignore', log, log, 'pipe', 'pipe'], detached: true});
    } finally {
      fs.closeSync(log);
    }
    this.exit = new Promise(resolve => {
      this.child.once('error', error => {
        this.fail(error);
        this.exited = true;
        resolve({error});
      });
      this.child.once('exit', (code, signal) => {
        this.exited = true;
        this.fail(new Error(`Browser exited: code=${code}, signal=${signal}`));
        resolve({code, signal});
      });
    });
    let buffer = '';
    this.child.stdio[4].setEncoding('utf8');
    this.child.stdio[4].on('data', chunk => {
      buffer += chunk;
      let end;
      while ((end = buffer.indexOf('\0')) !== -1) {
        const message = buffer.slice(0, end);
        buffer = buffer.slice(end + 1);
        try {
          const reply = JSON.parse(message);
          if (reply.method) { this.onEvent?.(reply); continue; }
          const pending = this.pending.get(reply.id);
          if (!pending) continue;
          this.pending.delete(reply.id);
          clearTimeout(pending.timer);
          if (reply.error) pending.reject(new Error(`${pending.method}: ${JSON.stringify(reply.error)}`));
          else pending.resolve(reply.result);
        } catch (error) { this.fail(error); }
      }
    });
    for (const pipe of [this.child.stdio[3], this.child.stdio[4]]) {
      pipe.on('error', error => this.fail(error));
    }
  }

  fail(error) {
    for (const item of this.pending.values()) {
      clearTimeout(item.timer);
      item.reject(error);
    }
    this.pending.clear();
  }

  send(method, params = {}, sessionId) {
    if (this.exited) return Promise.reject(new Error('Browser is no longer running'));
    const id = ++this.nextId;
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Timed out waiting for ${method}`));
      }, 30000);
      this.pending.set(id, {resolve, reject, timer, method});
      this.child.stdio[3].write(JSON.stringify({id, method, params, sessionId}) + '\0');
    });
  }

  async close({signal = false} = {}) {
    if (!this.exited) {
      if (signal) this.child.kill('SIGINT'); // Chromium's normal POSIX quit handler.
      else await this.send('Browser.close').catch(() => {});
    }
    let result = await Promise.race([this.exit, delay(15000, null, {ref: false})]);
    if (!result) {
      // Terminate only this test's own process group on failure.
      try { process.kill(-this.child.pid, 'SIGTERM'); } catch (error) {
        if (error.code !== 'ESRCH') throw error;
      }
      result = await Promise.race([this.exit, delay(5000, null, {ref: false})]);
      if (!result) {
        try { process.kill(-this.child.pid, 'SIGKILL'); } catch (error) {
          if (error.code !== 'ESRCH') throw error;
        }
        await this.exit;
      }
      throw new Error('Browser did not shut down cleanly');
    }
    if (result.error) throw result.error;
    assert.equal(result.code, 0, `Browser must exit cleanly (signal: ${result.signal ?? 'none'})`);
  }
}

export async function expectTitle(browser, sessionId, expected) {
  const deadline = Date.now() + 30000;
  let title;
  while (Date.now() < deadline) {
    try {
      const result = await browser.send('Runtime.evaluate', {
        expression: 'document.title', returnByValue: true,
      }, sessionId);
      title = result.result?.value;
    } catch (error) {
      // Navigation can replace the context between the evaluation request and
      // its execution. Retry only that transient case, preserving real errors.
      if (!/Execution context was destroyed|Cannot find context with specified id/.test(error.message)) throw error;
    }
    if (title === expected) return;
    if (title?.startsWith('EXT-ERROR:')) throw new Error(title);
    await delay(150);
  }
  throw new Error(`Expected ${expected}; got ${JSON.stringify(title)}`);
}

async function runProfile(profile, label, expectedVisits, reload, base, reports, checks, profileDirectory) {
  const browser = new Browser(profile, path.join(reports, `${label}.log`), {profileDirectory});
  try {
    const version = await browser.send('Browser.getVersion');
    assert.ok(version.product.endsWith('/' + lock.version), `Unexpected engine: ${version.product}`);
    const {targetId} = await browser.send('Target.createTarget', {url: 'about:blank'});
    const {sessionId} = await browser.send('Target.attachToTarget', {targetId, flatten: true});
    await browser.send('Page.enable', {}, sessionId);
    const navigation = await browser.send('Page.navigate', {url: `${base}/extensions`}, sessionId);
    assert.ok(!navigation.errorText, navigation.errorText);
    await expectTitle(browser, sessionId, `EXT:${expectedVisits}:filtered:tab`);
    checks.push(`${label}: content script, service worker, storage, tabs API, request filtering`);
    if (reload) {
      await browser.send('Page.reload', {}, sessionId);
      await expectTitle(browser, sessionId, `EXT:${expectedVisits + 1}:filtered:tab`);
      checks.push(`${label}: storage increments after navigation`);
    }
  } finally {
    await browser.close();
  }
  checks.push(`${label}: clean shutdown`);
}

async function nativeExtensionLifecycle(profile, base, reports, checks) {
  let id;
  for (const phase of ['install-action', 'restart-cleanup-uninstall']) {
    const browser = new Browser(profile, path.join(reports, `${phase}.log`), {nativeWindow: true, loadFixture: false});
    try {
      const {targetId} = await browser.send('Target.createTarget', {url: 'about:blank'});
      if (phase !== 'install-action') {
        const restored = await browser.send('Extensions.getExtensions');
        assert.ok(!restored.extensions.some(extension => extension.id === id),
          'Chromium intentionally removes session-only CDP installations on restart');
        checks.push('Restart cleans up the session-only debugging installation');
      }
      ({id} = await browser.send('Extensions.loadUnpacked', {path: fixture}));
      assert.match(id, /^[a-p]{32}$/);
      let enabled = false;
      for (let attempt = 0; attempt < 150 && !enabled; attempt++) {
        const installed = await browser.send('Extensions.getExtensions');
        enabled = installed.extensions.some(extension => extension.id === id && extension.enabled);
        if (!enabled) await delay(200);
      }
      assert.ok(enabled, 'The loaded test extension must be enabled');
      const {sessionId} = await browser.send('Target.attachToTarget', {targetId, flatten: true});
      await browser.send('Page.enable', {}, sessionId);
      if (swiftUI && phase === 'install-action') {
        await browser.send('Page.navigate', {url: 'chrome://newtab/'}, sessionId);
        let blank = false;
        for (let attempt = 0; attempt < 50 && !blank; attempt++) {
          const result = await browser.send('Runtime.evaluate', {
            expression: "location.href === 'about:blank' && document.body?.childElementCount === 0",
            returnByValue: true,
          }, sessionId);
          blank = result.result.value === true;
          if (!blank) await delay(100);
        }
        assert.ok(blank, 'Native new-tab navigation must open a blank Bark page');
        checks.push('Native new-tab navigation opens a blank page');
      }
      // localhost is deliberately outside the manifest's 127.0.0.1 host
      // permission: scripting here must use the user action's activeTab grant.
      const pageURL = phase === 'install-action'
        ? base.replace('127.0.0.1', 'localhost') + '/extension-popup' : base + '/extension-filter';
      await browser.send('Page.navigate', {url: pageURL}, sessionId);
      await expectTitle(browser, sessionId, 'Waiting for extension');
      await browser.send('Target.activateTarget', {targetId});
      if (swiftUI) {
        const {bounds} = await browser.send('Browser.getWindowForTarget', {targetId});
        const metrics = await browser.send('Page.getLayoutMetrics', {}, sessionId);
        assert.ok(bounds.width - metrics.cssLayoutViewport.clientWidth >= 180,
          'The Swift sidebar must reserve real native browser layout space');
        checks.push(`${phase}: Swift sidebar reserves native window layout space`);
        const topInset = bounds.height - metrics.cssLayoutViewport.clientHeight;
        assert.ok(topInset <= 60,
          `The duplicate top toolbar must not consume page height (inset: ${topInset})`);
        checks.push(`${phase}: Page height is reclaimed from the top toolbar`);
      }
      if (phase === 'install-action') {
        // The action API needs a tab target (the page target is a child).
        const {targetInfos} = await browser.send('Target.getTargets', {filter: [{type: 'tab'}, {exclude: true}]});
        const tab = targetInfos.find(info => info.url === pageURL);
        assert.ok(tab, 'Native Chromium tab must have a DevTools tab target');
        await browser.send('Extensions.triggerAction', {id, targetId: tab.targetId});
        await expectTitle(browser, sessionId, 'Extension action passed');
        const targets = await browser.send('Target.getTargets');
        const worker = targets.targetInfos.find(info => info.type === 'service_worker'
          && info.url.startsWith(`chrome-extension://${id}/`));
        assert.ok(worker, 'The installed extension must have a service-worker target');
        const {sessionId: workerSession} = await browser.send('Target.attachToTarget', {targetId: worker.targetId, flatten: true});
        let actionPassed = false;
        for (let attempt = 0; attempt < 30 && !actionPassed; attempt++) {
          const storage = await browser.send('Extensions.getStorageItems', {id, storageArea: 'local', keys: ['actionPassed']}, workerSession);
          actionPassed = storage.data.actionPassed === true;
          if (!actionPassed) await delay(100);
        }
        assert.equal(actionPassed, true);
        checks.push('Native window: install, toolbar action popup, activeTab, and scripting API');
      } else {
        const blocked = await browser.send('Runtime.evaluate', {
          expression: "fetch('/extension-blocked').then(() => false, () => true)", awaitPromise: true, returnByValue: true,
        }, sessionId);
        assert.equal(blocked.result.value, true, 'The installed extension blocks the test request');
        await browser.send('Extensions.uninstall', {id});
        const remaining = await browser.send('Extensions.getExtensions');
        assert.ok(!remaining.extensions.some(extension => extension.id === id));
        await browser.send('Page.reload', {}, sessionId);
        await expectTitle(browser, sessionId, 'Waiting for extension');
        const request = await browser.send('Runtime.evaluate', {
          expression: "fetch('/extension-blocked').then(response => response.ok)", awaitPromise: true, returnByValue: true,
        }, sessionId);
        assert.equal(request.result.value, true, 'Uninstall removes request-blocking rules');
        checks.push('Uninstall removes the extension and its request-filtering rules');
      }
    } finally { await browser.close(); }
    checks.push(`${phase}: clean native-window shutdown`);
  }
}

async function nativeWindowShutdown(profile, reports, checks) {
  const browser = new Browser(profile, path.join(reports, 'window-shutdown.log'), {nativeWindow: true, loadFixture: false});
  try {
    const lastTab = await browser.send('Target.createTarget', {url: 'about:blank', newWindow: true});
    await browser.send('Target.createTarget', {url: 'chrome://extensions/', newWindow: true});
    assert.equal((await browser.send('Target.closeTarget', {targetId: lastTab.targetId})).success, true);
    // Let the native window's empty-tab notifications and queued Swift
    // snapshots run before verifying that the browser is still responsive.
    await delay(500);
    await browser.send('Browser.getVersion');
    checks.push('Closing a window through its last tab keeps the browser responsive');
    await browser.close({signal: true});
    checks.push('Multiple native windows close cleanly through Chromium’s normal quit handler');
  } finally { await browser.close(); }
}

async function nativeIncognitoLifecycle(profile, base, reports, checks) {
  const browser = new Browser(profile, path.join(reports, 'incognito-sidebar.log'), {nativeWindow: true});
  try {
    const {targetId} = await browser.send('Target.createTarget', {url: 'about:blank'});
    const {sessionId} = await browser.send('Target.attachToTarget', {targetId, flatten: true});
    await browser.send('Page.enable', {}, sessionId);
    await browser.send('Page.navigate', {url: `${base}/extensions`}, sessionId);
    // Prove the fixture and its request rules work in the ordinary profile
    // before asserting that they are excluded from private windows.
    await expectTitle(browser, sessionId, 'EXT:1:filtered:tab');
    const evaluate = async (session, expression) => {
      const result = await browser.send('Runtime.evaluate', {expression, awaitPromise: true, returnByValue: true}, session);
      assert.ok(!result.exceptionDetails, JSON.stringify(result.exceptionDetails));
      return result.result.value;
    };
    const readStorage = "({value: localStorage.getItem('bark-private-test'), cookie: document.cookie})";
    await evaluate(sessionId, "localStorage.setItem('bark-private-test', 'regular'); document.cookie = 'bark_private_test=regular; path=/; SameSite=Lax'");
    const targets = await browser.send('Target.getTargets');
    const worker = targets.targetInfos.find(info => info.type === 'service_worker' && info.url.endsWith('/worker.js'));
    assert.ok(worker, 'The fixture must have an active extension worker');
    const {sessionId: workerSession} = await browser.send('Target.attachToTarget', {targetId: worker.targetId, flatten: true});
    for (const round of [1, 2]) {
      const url = `${base}/private-storage?round=${round}`;
      // Use the normal Chromium windows API: this creates a real primary
      // Incognito profile, not an isolated DevTools browser context.
      const created = await evaluate(workerSession,
        `chrome.windows.create({incognito: true, url: ${JSON.stringify(url)}}).then(window => window === null)`);
      assert.equal(created, true, 'The normal extension must not receive information about the private window it opened');
      let privateTarget;
      for (let attempt = 0; attempt < 100 && !privateTarget; attempt++) {
        const all = await browser.send('Target.getTargets');
        privateTarget = all.targetInfos.find(info => info.type === 'page' && info.url === url);
        if (!privateTarget) await delay(100);
      }
      assert.ok(privateTarget, 'The native Incognito window must have its own page');
      const {sessionId: privateSession} = await browser.send('Target.attachToTarget', {targetId: privateTarget.targetId, flatten: true});
      await browser.send('Page.enable', {}, privateSession);
      await expectTitle(browser, privateSession, 'Waiting for extension');
      if (swiftUI) {
        const {bounds} = await browser.send('Browser.getWindowForTarget', {targetId: privateTarget.targetId});
        const metrics = await browser.send('Page.getLayoutMetrics', {}, privateSession);
        assert.ok(bounds.width - metrics.cssLayoutViewport.clientWidth >= 180,
          'A native Incognito window must reserve space for Bark’s Swift sidebar');
        assert.ok(bounds.height - metrics.cssLayoutViewport.clientHeight <= 60,
          'Incognito must not retain the duplicate top toolbar');
      }
      const empty = await evaluate(privateSession, readStorage);
      assert.equal(empty.value, null, 'A new private session cannot inherit normal or previous private local storage');
      assert.ok(!empty.cookie.includes('bark_private_test='), 'A new private session cannot inherit normal or previous private cookies');
      await evaluate(privateSession, "localStorage.setItem('bark-private-test', 'private'); document.cookie = 'bark_private_test=private; path=/; SameSite=Lax'");
      await browser.send('Page.reload', {}, privateSession);
      await expectTitle(browser, privateSession, 'Waiting for extension');
      const saved = await evaluate(privateSession, readStorage);
      assert.equal(saved.value, 'private');
      assert.ok(saved.cookie.includes('bark_private_test=private'));
      assert.equal(await evaluate(privateSession, "fetch('/extension-blocked').then(response => response.ok, () => false)"), true,
        'An extension without Incognito permission must not filter private requests');
      assert.equal((await browser.send('Target.closeTarget', {targetId: privateTarget.targetId})).success, true);
      await delay(500); // Allow the last private tab/profile to finish teardown.
      const regular = await evaluate(sessionId, readStorage);
      assert.equal(regular.value, 'regular');
      assert.ok(regular.cookie.includes('bark_private_test=regular'));
      checks.push(`Incognito ${round}: native sidebar layout, isolated cookies/local storage, private extension permissions, clean window close`);
    }
    checks.push('Closing the last Incognito window clears private storage before a fresh private session');
  } finally { await browser.close(); }
  checks.push('Incognito and regular windows shut down cleanly');
}

async function main() {
  if (!['darwin', 'linux'].includes(process.platform)) throw new Error('Requires macOS or Linux');
  fs.accessSync(binary, fs.constants.X_OK);
  fs.mkdirSync(resultsRoot, {recursive: true});
  const reports = fs.mkdtempSync(path.join(resultsRoot, 'run-'));
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'bark-chromium-test-'));
  const hits = new Map();
  const checks = [];
  const report = {passed: false, chromium: lock.version, binary, headed, swiftUI, checks};
  // The same deterministic 16px blue icon used by the native preview tests.
  const favicon = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAGUlEQVR4nGMwqrjznxLMMGrAqAGjBgwXAwATQ4UfNQv0XgAAAABJRU5ErkJggg==', 'base64');
  const server = http.createServer((request, response) => {
    const pathname = new URL(request.url, 'http://127.0.0.1').pathname;
    hits.set(pathname, (hits.get(pathname) || 0) + 1);
    if (pathname === '/favicon.png') {
      response.writeHead(200, {'Content-Type': 'image/png', 'Cache-Control': 'no-store'});
      response.end(favicon);
      return;
    }
    response.writeHead(200, {'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store'});
    response.end('<!doctype html><meta charset="utf-8"><link rel="icon" href="/favicon.png"><title>Waiting for extension</title><body>Extension test</body>');
  });
  try {
    await new Promise((resolve, reject) => {
      server.once('error', reject);
      server.listen(0, '127.0.0.1', resolve);
    });
    const base = `http://127.0.0.1:${server.address().port}`;
    const first = path.join(temporary, 'first');
    await runProfile(first, 'first-launch', 1, true, base, reports, checks);
    await runProfile(first, 'restart', 3, false, base, reports, checks);
    await runProfile(first, 'separate-profile', 1, false, base, reports, checks, 'Profile 1');
    assert.equal(hits.get('/extension-blocked') || 0, 0, 'Blocked requests must not reach the server');
    assert.equal(hits.get('/extension-allowed'), 4, 'Allowed requests must reach the server');
    checks.push('Request filtering confirmed at server; storage persists across restarts and is isolated by profile');
    if (headed) {
      await nativeExtensionLifecycle(path.join(temporary, 'native'), base, reports, checks);
      await nativeWindowShutdown(path.join(temporary, 'window-shutdown'), reports, checks);
      await nativeIncognitoLifecycle(path.join(temporary, 'incognito'), base, reports, checks);
    }
    report.passed = true;
    console.log(`${checks.length} Chromium extension checks passed on ${lock.version}`);
  } catch (error) {
    report.error = error.stack || String(error);
    throw error;
  } finally {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
    if (!report.passed) report.preservedProfiles = temporary;
    fs.writeFileSync(path.join(reports, 'report.json'), JSON.stringify(report, null, 2) + '\n');
    if (report.passed) fs.rmSync(temporary, {recursive: true, force: true});
    console.log(`Reports: ${reports}`);
  }
}

async function runAll() {
  assert.ok(['darwin', 'linux'].includes(process.platform), 'Requires macOS or Linux');
  const native = process.platform === 'darwin' && !headless;
  fs.mkdirSync(resultsRoot, {recursive: true});
  const directory = fs.mkdtempSync(path.join(resultsRoot, 'run-'));
  const report = {passed: false, startedAt: new Date().toISOString(), binary,
    expectedChromium: lock.version, expectedSourceRevision: lock.revision, native, suites: []};
  const save = () => fs.writeFileSync(path.join(directory, 'report.json'), JSON.stringify(report, null, 2) + '\n');
  // The headed browser run already includes every headless extension check.
  const suites = [['browser', 'test_chromium_browser.mjs', native ? ['--headed', '--swift-ui'] : []]];
  if (process.platform === 'darwin') suites.push(['new-tab-default', 'test_chromium_new_tab_default.mjs', []]);
  if (native) suites.push(
    ['spaces-and-settings', 'test_chromium_spaces.mjs', []],
    ['space-canvas', 'test_chromium_space_canvas.mjs', []],
    ['new-tab', 'test_chromium_new_tab.mjs', []],
    ['notification-banners', 'test_chromium_notification_banners.mjs', []],
    ['pinned-tabs', 'test_chromium_pinned.mjs', []],
    ['bark-features', 'test_chromium_bark_features.mjs', []],
    ['organization', 'test_chromium_organization.mjs', []],
    ['preferences', 'test_chromium_preferences.mjs', []],
    ['command-bar', 'test_chromium_command_bar.mjs', []],
    ['space-removal', 'test_chromium_space_removal.mjs', []],
    ['extensions-menu', 'test_chromium_extensions_menu.mjs', []],
    ['split-view', 'test_chromium_splits.mjs', []],
    ['tab-detach', 'test_chromium_tab_detach.mjs', []],
    ['sidebar-hover', 'test_chromium_sidebar_hover.mjs', []],
    ['bark-import', 'test_chromium_bark_import.mjs', []],
    ['about-updates', 'test_chromium_updates.mjs', []],
  );
  try {
    report.actualVersion = execFileSync(binary, ['--version'], {encoding: 'utf8', timeout: 30000}).trim();
    assert.ok(report.actualVersion.split(/\s+/).includes(lock.version),
      `Build the pinned Chromium first: expected ${lock.version}, got ${report.actualVersion}`);
    save();
    for (const [name, script, flags] of suites) {
      console.log(`Running ${name} on ${report.actualVersion}`);
      const log = path.join(directory, name + '.log');
      const descriptor = fs.openSync(log, 'w');
      const started = Date.now();
      let outcome;
      try {
        const child = spawn(process.execPath, [path.join(root, 'tools', script), binary, ...flags], {
          cwd: root, stdio: ['ignore', descriptor, descriptor],
        });
        outcome = await new Promise(resolve => {
          child.once('error', error => resolve({error: String(error)}));
          child.once('exit', (code, signal) => resolve({code, signal}));
        });
      } finally {
        fs.closeSync(descriptor);
      }
      const passed = outcome.code === 0;
      report.suites.push({name, passed, ...outcome, durationMs: Date.now() - started, log});
      save();
      console.log(`${passed ? 'Passed' : 'FAILED'} ${name}: ${log}`);
    }
    report.passed = report.suites.every(suite => suite.passed);
    if (!report.passed) process.exitCode = 1;
  } catch (error) {
    report.error = error.stack || String(error);
    throw error;
  } finally {
    report.finishedAt = new Date().toISOString();
    save();
    console.log(`Browser test report: ${path.join(directory, 'report.json')}`);
  }
}

if (fileURLToPath(import.meta.url) === path.resolve(process.argv[1] ?? '')) {
  (all ? runAll() : main()).catch(error => { console.error(error); process.exitCode = 1; });
}
