#!/usr/bin/env node
// Composing opens the address panel. A submitted destination creates or reuses a tab.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';
import {Browser, bundleEnablesSwiftUI} from './test_chromium_browser.mjs';

const root = path.resolve('test-results/chromium-new-tab');
fs.mkdirSync(root, {recursive: true});
const reports = fs.mkdtempSync(path.join(root, 'run-'));
const profiles = fs.mkdtempSync(path.join(os.tmpdir(), 'bark-new-tab-'));
const profile = path.join(profiles, 'tabs');
// Finder supplies no developer switch. Use one only for raw developer builds.
const needsDevelopmentSwitch = !bundleEnablesSwiftUI();
let driver = path.join(profile, '.bark-ui-driver');
fs.mkdirSync(driver, {recursive: true});
const report = {passed: false, checks: []};
let browser, latest, sequence = 0, pendingResponse;
let coldFocusReport;
const visible = state => state.windows.find(window => window.visible && !window.incognito);
const active = window => window?.tabs.find(tab => tab.active);
const blanks = window => window.tabs.filter(tab => ['about:blank', 'chrome://newtab/'].includes(tab.url));
async function command(action = 'snapshot', fields = {}) {
  const requestId = ++sequence;
  fs.writeFileSync(path.join(driver, 'request.tmp'), JSON.stringify({action, requestId, ...fields}));
  fs.renameSync(path.join(driver, 'request.tmp'), path.join(driver, 'request.json'));
  for (let i = 0; i < 400; i++) {
    if (browser.exited) throw Error('Test browser exited');
    try {
      const state = JSON.parse(fs.readFileSync(path.join(driver, 'response.json')));
      if (state.requestId === requestId) { latest = state; return state; }
    } catch (error) { if (error.code !== 'ENOENT' && !(error instanceof SyntaxError)) throw error; }
    await delay(50);
  }
  throw Error('Timed out: ' + action);
}
async function waitFor(predicate, label) {
  for (let i = 0; i < 150; i++) {
    const state = await command();
    if (predicate(state)) return state;
    await delay(100);
  }
  throw Error('Timed out: ' + label);
}
async function expectPageFocus(url) {
  const {targetInfos} = await browser.send('Target.getTargets');
  const target = targetInfos.find(target => target.type === 'page' && target.url === url);
  assert.ok(target, 'Expected page target for ' + url);
  const {sessionId} = await browser.send('Target.attachToTarget', {targetId: target.targetId, flatten: true});
  try {
    for (let i = 0; i < 50; i++) {
      const {result} = await browser.send('Runtime.evaluate', {expression: 'document.hasFocus()', returnByValue: true}, sessionId);
      if (result.value === true) return;
      await delay(50);
    }
    assert.fail('Expected keyboard focus in the page at ' + url);
  } finally {
    await browser.send('Target.detachFromTarget', {sessionId});
  }
}
async function checkColdExternalLink(executable, url) {
  const bundle = path.resolve(executable, '../../..');
  assert.equal(path.join(bundle, 'Contents/MacOS', path.basename(executable)), executable);
  const coldProfile = fs.mkdtempSync(path.join(profiles, 'launch-services-'));
  const profileFlag = '--user-data-dir=' + coldProfile;
  try {
    // Deliver a Get URL event at launch. A URL supplied on argv takes a different startup path.
    execFileSync('/usr/bin/open', ['-n', '-a', bundle, '-u', url, '--args', profileFlag,
      ...(needsDevelopmentSwitch ? ['--bark-swift-ui'] : []),
      '--no-first-run', '--no-default-browser-check', '--use-mock-keychain',
      '--disable-background-networking', '--disable-component-update', '--disable-sync'], {timeout: 15000});
    for (let i = 0; !coldFocusReport && i < 250; i++) await delay(100);
    assert.deepEqual(coldFocusReport, [true, true], 'The externally delivered page must keep keyboard focus as startup finishes');
  } finally {
    // LaunchServices owns the child. Identify it independently by the disposable
    // profile lock and its command line before sending it a termination signal.
    const lock = path.join(coldProfile, 'SingletonLock');
    if (fs.lstatSync(lock, {throwIfNoEntry: false})) {
      const pid = Number(fs.readlinkSync(lock).match(/-(\d+)$/)?.[1]);
      assert.ok(Number.isSafeInteger(pid) && pid > 1, 'Expected a browser PID in the test profile lock');
      const line = execFileSync('/bin/ps', ['-ww', '-p', String(pid), '-o', 'command='], {encoding: 'utf8'}).trim();
      assert.ok(line.startsWith(executable + ' ') && (' ' + line + ' ').includes(' ' + profileFlag + ' '),
        'The process must own this executable and disposable profile');
      process.kill(pid, 'SIGTERM');
      for (let i = 0; ; i++) {
        try { process.kill(pid, 0); } catch (error) {
          if (error.code === 'ESRCH') break;
          throw error;
        }
        assert.ok(i < 100, 'LaunchServices test browser must exit');
        await delay(100);
      }
    }
  }
}
const server = http.createServer((request, response) => {
  if (request.url === '/pending') { pendingResponse = response; return; }
  const url = new URL(request.url, 'http://localhost');
  if (url.pathname === '/cold-focus-report') {
    coldFocusReport = url.searchParams.getAll('focused').map(value => value === 'true');
    response.writeHead(204).end();
    return;
  }
  response.writeHead(200, {'Content-Type': 'text/html', 'Cache-Control': 'no-store'});
  if (url.pathname === '/mac-external-link') {
    // Catch a startup window stealing focus after the link first becomes visible.
    response.end(`<title>Cold external link</title><script>
      setTimeout(() => {
        const first = document.hasFocus();
        setTimeout(() => fetch('/cold-focus-report?focused=' + first + '&focused=' + document.hasFocus()), 1500);
      }, 1000);
    </script>`);
    return;
  }
  response.end('<title>New tab test page</title><body>Existing page</body>');
});
try {
  assert.equal(process.platform, 'darwin');
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  browser = new Browser(profile, path.join(reports, 'browser.log'), {
    nativeWindow: true, nativeUI: needsDevelopmentSwitch, loadFixture: false, testDirectory: driver,
  });
  let state = await waitFor(state => !!visible(state)?.activeSpaceId && blanks(visible(state)).length === 1, 'initial blank tab');
  const original = visible(state);
  const windowId = original.windowId;
  const initialBlank = active(original).id;
  assert.equal(active(original).blankPlaceholder, true);
  assert.ok(!original.switcher.some(tab => tab.id === initialBlank));
  const pageReady = (window, url) => active(window)?.url === url && !active(window).loading;
  const page = url => waitFor(state => pageReady(visible(state), url), url);
  for (let i = 0; i < 3; i++) await command('new', {windowId});
  state = await command('testNewTab', {windowId, count: 10});
  assert.equal(visible(state).addressPanelVisible, true);
  assert.deepEqual(visible(state).tabs.filter(tab => !tab.blankPlaceholder), []);
  assert.deepEqual(visible(state).switcher, []);
  assert.equal(visible(state).tabs.length, 1);
  assert.equal(active(visible(state)).id, initialBlank);

  await browser.send('Target.createTarget', {url: base + '/existing'});
  state = await page(base + '/existing');
  const existing = active(visible(state)).id;
  for (const action of ['new', 'testNewTab']) {
    await command(action, {windowId, count: 10});
    for (const text of ['', '   ']) {
      state = await command('navigateNew', {windowId, text});
      assert.equal(active(visible(state)).id, existing);
      assert.deepEqual(new Set(visible(state).tabs.map(tab => tab.id)), new Set([initialBlank, existing]));
      assert.equal(blanks(visible(state)).length, 1);
    }
  }
  report.checks.push('Opening the composer repeatedly and submitting empty text preserves the page and the complete tab list');

  await command('testNewTab', {windowId});
  await command('testOpenAddressSuggestion', {windowId, suggestion: {
    kind: 'history', title: 'Destination', url: base + '/used-blank',
  }});
  state = await page(base + '/used-blank');
  assert.equal(visible(state).addressPanelVisible, false);
  assert.ok(visible(state).switcher.some(tab => tab.id === initialBlank));
  assert.equal(active(visible(state)).id, initialBlank);
  assert.equal(visible(state).canGoBack, false, 'The reused placeholder is not a visited page');
  assert.equal(active(visible(state)).blankPlaceholder, false);
  assert.equal(visible(state).tabs.length, 2);
  assert.ok(visible(state).tabs.some(tab => tab.id === existing && tab.url === base + '/existing'));
  state = await command('testNewTab', {windowId, count: 10});
  assert.equal(active(visible(state)).id, initialBlank);
  assert.equal(visible(state).tabs.length, 2);
  assert.equal(blanks(visible(state)).length, 0);
  report.checks.push('A submission reuses the background placeholder and repeated Cmd+T leaves both real pages intact');

  await command('createSpace', {windowId, text: 'Other space', metadata: {profile: original.profileId, theme: 'ocean', emoji: ''}});
  state = await waitFor(state => visible(state)?.activeSpaceId !== original.activeSpaceId && blanks(visible(state)).length === 1, 'second space');
  const otherSpace = visible(state).activeSpaceId, otherBlank = active(visible(state)).id;
  await command('space', {windowId, text: original.activeSpaceId});
  await waitFor(state => visible(state)?.activeSpaceId === original.activeSpaceId, 'return to original space');
  await command('select', {windowId, id: existing});
  await command('new', {windowId});
  await command('navigateNew', {windowId, text: base + '/new-page'});
  state = await page(base + '/new-page');
  const newPage = active(visible(state)).id;
  assert.ok(![initialBlank, existing, otherBlank].includes(newPage));
  assert.equal(visible(state).tabs.length, 3);
  assert.deepEqual(visible(state).allTabs.filter(tab => tab.space === otherSpace).map(tab => tab.id), [otherBlank]);
  report.checks.push('A submitted URL adds exactly one tab in the current Space and preserves another Space’s placeholder');

  await command('testFocusAddress', {windowId});
  await command('navigate', {windowId, text: 'about:blank'});
  state = await page('about:blank');
  assert.equal(active(visible(state)).id, newPage);
  assert.equal(visible(state).canGoBack, true);
  await command('testNewTab', {windowId});
  await command('navigateNew', {windowId, text: base + '/after-history'});
  state = await page(base + '/after-history');
  assert.notEqual(active(visible(state)).id, newPage);
  await command('select', {windowId, id: newPage});
  await command('back', {windowId});
  state = await page(base + '/new-page');
  assert.equal(active(visible(state)).id, newPage);
  report.checks.push('Cmd+L edits in place and a blank page with Back history survives a new submission');

  // Keep a real navigation pending on a previously unused blank document.
  await command('space', {windowId, text: otherSpace});
  await waitFor(state => visible(state)?.activeSpaceId === otherSpace && active(visible(state))?.id === otherBlank, 'other Space placeholder');
  await command('navigate', {windowId, text: base + '/pending'});
  for (let i = 0; i < 100 && !pendingResponse; i++) await delay(50);
  assert.ok(pendingResponse, 'The real navigation reached the server');
  state = await command('testNewTab', {windowId, count: 5});
  assert.equal(active(visible(state)).id, otherBlank);
  assert.equal(visible(state).tabs.length, 1);
  assert.equal(active(visible(state)).blankPlaceholder, true);
  await command('navigateNew', {windowId, text: base + '/while-pending'});
  state = await page(base + '/while-pending');
  assert.notEqual(active(visible(state)).id, otherBlank);
  assert.equal(visible(state).tabs.length, 2);
  pendingResponse.writeHead(200, {'Content-Type': 'text/html'});
  pendingResponse.end('<title>Pending page finished</title>');
  await waitFor(state => visible(state)?.tabs.some(tab => tab.id === otherBlank && tab.url === base + '/pending' && !tab.loading), 'pending navigation completes');
  report.checks.push('A new destination leaves an in-flight navigation running in its original tab');

  await browser.send('Target.createTarget', {url: 'about:blank'});
  state = await page('about:blank');
  const pinnedBlank = active(visible(state)).id;
  await command('pin', {windowId, id: pinnedBlank});
  await waitFor(state => visible(state).tabs.some(tab => tab.id === pinnedBlank && tab.pinned), 'pinned blank');
  await browser.send('Target.createTarget', {url: 'about:blank'});
  state = await waitFor(state => pageReady(visible(state), 'about:blank') && active(visible(state)).id !== pinnedBlank, 'second blank');
  const splitBlank = active(visible(state)).id;
  await command('select', {windowId, id: otherBlank});
  await command('splitTab', {windowId, id: splitBlank, text: 'right'});
  await waitFor(state => visible(state).tabs.some(tab => tab.id === splitBlank && tab.split), 'split blank');
  const beforeProtectedSubmit = visible(await command()).tabs.length;
  await command('testNewTab', {windowId});
  await command('navigateNew', {windowId, text: base + '/after-protected'});
  state = await page(base + '/after-protected');
  const protectedTabs = visible(state).tabs;
  assert.equal(protectedTabs.length, beforeProtectedSubmit + 1);
  assert.ok(protectedTabs.some(tab => tab.id === pinnedBlank && tab.pinned && tab.url === 'about:blank'));
  assert.ok(protectedTabs.some(tab => tab.id === splitBlank && tab.split && tab.url === 'about:blank'));
  report.checks.push('A submission preserves blank tabs that are pinned or part of a split');

  await command('createProfile', {windowId, text: 'Separate profile'});
  state = await waitFor(state => visible(state)?.spaces.some(space => space.name === 'Separate profile'), 'second profile');
  const profileSpace = visible(state).spaces.find(space => space.name === 'Separate profile').id;
  await command('space', {windowId, text: profileSpace});
  state = await waitFor(state => visible(state)?.activeSpaceId === profileSpace && blanks(visible(state)).length === 1, 'second profile blank');
  const otherWindow = visible(state).windowId, profileBlank = active(visible(state)).id;
  await command('testNewTab', {windowId: otherWindow, count: 10});
  await command('navigateNew', {windowId: otherWindow, text: base + '/profile'});
  state = await page(base + '/profile');
  assert.equal(visible(state).tabs.length, 1);
  assert.equal(active(visible(state)).id, profileBlank);
  report.checks.push('A new tab in another profile uses that profile’s own placeholder');

  await browser.close(); browser = null;
  for (const file of ['request.json', 'response.json']) fs.rmSync(path.join(driver, file), {force: true});
  browser = new Browser(profile, path.join(reports, 'incognito.log'), {
    nativeWindow: true, nativeUI: needsDevelopmentSwitch, loadFixture: false, testDirectory: driver, extraFlags: ['--incognito'],
  });
  state = await waitFor(state => state.windows.some(window => window.visible && window.incognito && blanks(window).length === 1), 'private blank');
  const privateWindow = state.windows.find(window => window.visible && window.incognito);
  const privateBlank = active(privateWindow).id;
  await command('testNewTab', {windowId: privateWindow.windowId, count: 10});
  await command('navigateNew', {windowId: privateWindow.windowId, text: base + '/private'});
  state = await waitFor(state => state.windows.some(window => window.windowId === privateWindow.windowId && pageReady(window, base + '/private')), 'private page');
  const result = state.windows.find(window => window.windowId === privateWindow.windowId);
  assert.equal(result.tabs.length, 1);
  assert.equal(active(result).id, privateBlank);
  report.checks.push('Incognito submits into its private window’s placeholder');
  await browser.close(); browser = null;

  const externalProfile = path.join(profiles, 'external');
  driver = path.join(externalProfile, '.bark-ui-driver');
  fs.mkdirSync(driver, {recursive: true});
  const startupURL = base + '/external-startup';
  browser = new Browser(externalProfile, path.join(reports, 'external-links.log'), {
    nativeWindow: true, nativeUI: needsDevelopmentSwitch, loadFixture: false, testDirectory: driver, initialURL: startupURL,
  });
  state = await page(startupURL);
  const externalWindow = visible(state).windowId;
  const route = (action, fields = {}) => command(action, {windowId: externalWindow, ...fields});
  assert.equal(visible(state).addressPanelVisible, false, 'Launching with a URL leaves its page unobstructed');
  await route('testActivateWindow');
  await route('testRestoreLocationFocus');
  assert.equal(visible(await command()).addressPanelVisible, false, 'Restoring native focus must not open an address panel');
  report.checks.push('A URL supplied at launch displays its page with the address panel closed');

  for (const little of [false, true]) {
    for (const shortcut of [null, little ? 'testFocusAddress' : 'testNewTab']) {
      if (!little && shortcut) {
        await browser.send('Target.createTarget', {url: 'about:blank'});
        await page('about:blank');
      }
      if (shortcut) {
        await route(shortcut);
        await waitFor(state => visible(state)?.addressPanelVisible === true, 'explicit address shortcut');
      }
      const url = base + '/external-' + (little ? 'little' : 'regular') + (shortcut ? '-composing' : '');
      await route('testExternalLinks', {urls: [url], littleWindow: little});
      state = little
        ? await waitFor(state => visible(state)?.popups.some(popup => popup.kind === 'little' && popup.url === url && popup.keyWindow), 'external Little window receives focus')
        : await page(url);
      assert.equal(visible(state).addressPanelVisible, false, 'Delivering an external link dismisses the address panel');
      if (little) {
        await route('testPopupCommand', {kind: 'little', text: 'close'});
        await waitFor(state => visible(state)?.popups.length === 0, 'Little window closed');
      } else {
        await expectPageFocus(url);
      }
    }
  }
  report.checks.push('External links open in regular tabs or Little windows with the address panel closed, including after Cmd+T or Cmd+L');
  const executable = browser.child.spawnfile;
  await browser.close(); browser = null;
  await checkColdExternalLink(executable, base + '/mac-external-link');
  report.checks.push('A real macOS URL event that launches Bark leaves keyboard focus on the delivered page');
  report.passed = true;
  console.log(`${report.checks.length} focused New Tab checks passed`);
} catch (error) {
  report.error = error.stack || String(error);
  report.lastState = latest;
  report.preservedProfiles = profiles;
  console.error(error);
  process.exitCode = 1;
} finally {
  if (browser) await browser.close().catch(error => { report.shutdownError = String(error); });
  server.closeAllConnections();
  await new Promise(resolve => server.close(resolve));
  fs.writeFileSync(path.join(reports, 'report.json'), JSON.stringify(report, null, 2) + '\n');
  if (report.passed) fs.rmSync(profiles, {recursive: true, force: true});
  console.log('Reports:', reports);
}
