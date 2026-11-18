#!/usr/bin/env node
// Real Chromium/Swift bridge integration with disposable data and loopback pages.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {setTimeout as delay} from 'node:timers/promises';
import {Browser, expectTitle} from './test_chromium_browser.mjs';

const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const resultRoot = path.join(root, 'test-results/chromium-spaces');
fs.mkdirSync(resultRoot, {recursive: true});
const reports = fs.mkdtempSync(path.join(resultRoot, 'run-'));
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'bark-spaces-test-'));
const directory = path.join(profile, '.bark-ui-driver');
fs.mkdirSync(directory);
const checks = [];
const report = {passed: false, checks};
let requestId = 0;
let latest;
async function command(action = 'snapshot', fields = {}) {
  const id = ++requestId;
  fs.writeFileSync(path.join(directory, 'request.tmp'), JSON.stringify({action, ...fields, requestId: id}));
  fs.renameSync(path.join(directory, 'request.tmp'), path.join(directory, 'request.json'));
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    try {
      const response = JSON.parse(fs.readFileSync(path.join(directory, 'response.json'), 'utf8'));
      if (response.requestId === id) { latest = response; return response; }
    } catch (error) { if (error.code !== 'ENOENT' && !(error instanceof SyntaxError)) throw error; }
    await delay(50);
  }
  throw new Error(`Timed out waiting for Bark command ${action}`);
}
async function waitState(predicate, label) {
  for (let attempt = 0; attempt < 100; attempt++) {
    const state = await command();
    if (predicate(state)) return state;
    await delay(100);
  }
  throw new Error(`Timed out: ${label}`);
}
function visible(state) { return state.windows.filter(window => window.visible && !window.incognito); }
async function select(space, windowId) {
  await command('space', {text: space, windowId});
  const state = await waitState(state => visible(state).length === 1 && visible(state)[0].activeSpaceId === space, 'space selection');
  return visible(state)[0];
}
async function sessionFor(browser, url) {
  for (let attempt = 0; attempt < 100; attempt++) {
    const {targetInfos} = await browser.send('Target.getTargets');
    const page = targetInfos.find(target => target.type === 'page' && target.url === url);
    if (page) {
      const {sessionId} = await browser.send('Target.attachToTarget', {targetId: page.targetId, flatten: true});
      await browser.send('Page.enable', {}, sessionId);
      await expectTitle(browser, sessionId, 'Space page');
      return {sessionId, targetId: page.targetId};
    }
    await delay(100);
  }
  throw new Error('No page for ' + url);
}
async function evaluate(browser, session, expression) {
  const result = await browser.send('Runtime.evaluate', {expression, awaitPromise: true, returnByValue: true}, session);
  assert.ok(!result.exceptionDetails, JSON.stringify(result.exceptionDetails));
  return result.result.value;
}
function launch(label, options = {}) {
  for (const name of ['request.json', 'response.json']) fs.rmSync(path.join(directory, name), {force: true});
  return new Browser(profile, path.join(reports, label + '.log'), {
    nativeWindow: true, nativeUI: true, loadFixture: false, testDirectory: directory, ...options,
  });
}

const deepFind = `function find(selector, root = document) {
  const found = root.querySelector(selector);
  if (found) return found;
  for (const node of root.querySelectorAll('*')) {
    if (node.shadowRoot) {
      const found = find(selector, node.shadowRoot);
      if (found) return found;
    }
  }
  return null;
}`;
const settingsState = `(async () => {
  const {sendWithPromise} = await import('chrome://resources/js/cr.js');
  return sendWithPromise('getState');
})()`;
async function openWebUI(url) {
  const {targetId} = await browser.send('Target.createTarget', {url});
  const {sessionId} = await browser.send('Target.attachToTarget', {targetId, flatten: true});
  return {targetId, sessionId};
}
async function waitPage(session, expression, label) {
  for (let attempt = 0; attempt < 150; attempt++) {
    try { if (await evaluate(browser, session, expression)) return; }
    catch (error) {
      if (!/Execution context was destroyed|Cannot find context with specified id/.test(error.message)) throw error;
    }
    await delay(100);
  }
  throw new Error('Timed out: ' + label);
}
async function editSettings() {
  const settings = await openWebUI('chrome://settings/');
  const session = settings.sessionId;
  await waitPage(session, `!!(${deepFind})('#barkSpacesLink') && !!(${deepFind})('#barkImportLink')`, 'Bark settings links');
  assert.equal(await evaluate(browser, session, `(${deepFind})('#barkImportLink').getAttribute('href')`), '/importData');
  await evaluate(browser, session, `(${deepFind})('#barkSpacesLink').click()`);
  await waitPage(session, `location.host === 'spaces' && !!document.querySelector('#spaces cr-input.name')`, 'Spaces settings navigation');
  checks.push('Settings exposes the import route and navigates to the registered chrome://spaces page');

  await evaluate(browser, session, `(() => {
    const input = document.querySelector('#spaces cr-input.name');
    input.value = 'E2E renamed space';
    input.dispatchEvent(new Event('change', {bubbles: true}));
  })()`);
  await waitPage(session, `(${settingsState}).then(state => state.spaces.some(space => space.name === 'E2E renamed space'))`, 'saved space name');
  await evaluate(browser, session, `(() => {
    const input = document.querySelector('#newProfile');
    input.value = 'E2E profile';
    input.dispatchEvent(new Event('input', {bubbles: true}));
    document.querySelector('#addProfile').click();
  })()`);
  await waitPage(session, `(${settingsState}).then(state => state.profiles.some(profile => profile.name === 'E2E profile' && profile.spaces === 1))`, 'created profile and space');
  checks.push('Spaces settings rename a space and create a real Chromium profile with its own space');
  await browser.send('Target.closeTarget', {targetId: settings.targetId});

  const appearance = await openWebUI('chrome://settings/appearance');
  await waitPage(appearance.sessionId, `!!(${deepFind})('[pref-key="webkit.webprefs.tabs_to_links"]')`, 'macOS appearance controls');
  assert.equal(await evaluate(browser, appearance.sessionId, `!!(${deepFind})('[pref-key="browser.confirm_to_quit"]')`), false);
  checks.push('Appearance settings omit the removed hold-to-confirm quit preference');
  await browser.send('Target.closeTarget', {targetId: appearance.targetId});
}
async function verifySettingsRestored() {
  const restored = await openWebUI('chrome://spaces/');
  await waitPage(restored.sessionId, `!!document.querySelector('#spaces cr-input.name')`, 'Spaces settings after restart');
  const saved = await evaluate(browser, restored.sessionId, settingsState);
  assert.ok(saved.spaces.some(space => space.name === 'E2E renamed space'));
  assert.ok(saved.profiles.some(profile => profile.name === 'E2E profile' && profile.spaces === 1));
  checks.push('Settings edits and the new profile persist across the same normal browser restart');
  await browser.send('Target.closeTarget', {targetId: restored.targetId});
}

const server = http.createServer((request, response) => {
  response.writeHead(200, {'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store'});
  response.end('<!doctype html><meta charset="utf-8"><title>Space page</title><body>Space test</body>');
});
let browser;
try {
  assert.equal(process.platform, 'darwin', 'The native space host is currently macOS only');
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const urls = {personal: base + '/personal', research: base + '/research', work: base + '/work'};
  browser = launch('spaces');
  let state = await waitState(state => visible(state).length === 1 && visible(state)[0].spaces.length > 0, 'initial space');
  let current = visible(state)[0];
  const firstWindow = current.windowId;
  const firstProfile = current.profileId;
  const personal = current.activeSpaceId;
  const originalBounds = current.bounds;
  assert.equal(current.profiles.length, 1);
  assert.equal(current.spaces.find(space => space.id === personal).emoji, '👤', 'A fresh Personal space uses the person icon');
  await command('navigate', {windowId: firstWindow, text: urls.personal});
  const firstPage = await sessionFor(browser, urls.personal);
  await browser.send('Extensions.loadUnpacked', {path: path.join(root, 'tools/fixtures/extension')});
  assert.equal(await evaluate(browser, firstPage.sessionId, "fetch('/extension-blocked').then(() => false, () => true)"), true);
  await evaluate(browser, firstPage.sessionId, "localStorage.setItem('bark-profile-test', 'personal'); document.cookie = 'bark_profile_test=personal; path=/; SameSite=Lax'");

  await command('createSpace', {windowId: firstWindow, text: 'Research', metadata: {profile: firstProfile, theme: 'ocean', emoji: '🔬'}});
  state = await waitState(state => visible(state).some(window => window.spaces.some(space => space.active && space.name === 'Research')), 'create same-profile space');
  current = visible(state)[0];
  const research = current.activeSpaceId;
  assert.equal(current.windowId, firstWindow);
  assert.equal(state.windows.length, 1, 'Creating a space must not create a browser window');
  assert.equal(current.profiles.length, 1, 'Creating a space must not create a profile');
  assert.ok(!current.tabs.some(tab => tab.url === urls.personal), 'Another space’s tabs must be absent from the sidebar');
  await command('navigate', {windowId: firstWindow, text: urls.research});
  const researchPage = await sessionFor(browser, urls.research);
  assert.equal((await browser.send('Browser.getWindowForTarget', {targetId: firstPage.targetId})).windowId,
    (await browser.send('Browser.getWindowForTarget', {targetId: researchPage.targetId})).windowId);
  assert.equal(await evaluate(browser, researchPage.sessionId, "localStorage.getItem('bark-profile-test')"), 'personal');
  assert.match(await evaluate(browser, researchPage.sessionId, 'document.cookie'), /bark_profile_test=personal/);
  assert.equal(await evaluate(browser, researchPage.sessionId, "fetch('/extension-blocked').then(() => false, () => true)"), true,
    'Spaces assigned to the same profile share its installed extension and request rules');
  state = await command(); current = visible(state)[0];
  const researchTab = current.tabs.find(tab => tab.url === urls.research);
  await command('pin', {windowId: firstWindow, id: researchTab.id});
  await command('customizeSpace', {windowId: firstWindow, metadata: {theme: 'lavender', emoji: '📚'}});
  current = await select(personal, firstWindow);
  assert.ok(current.tabs.some(tab => tab.url === urls.personal));
  assert.ok(!current.tabs.some(tab => tab.url === urls.research));
  checks.push('Two spaces share one profile and the same real browser window while retaining separate tabs and shared sign-ins');

  await command('createProfile', {windowId: firstWindow, text: 'Work Profile'});
  state = await waitState(state => visible(state)[0]?.profiles.some(profile => profile.name === 'Work Profile'), 'create profile');
  current = visible(state)[0];
  const workProfile = current.profiles.find(profile => profile.name === 'Work Profile').id;
  assert.equal(state.windows.length, 1, 'Creating a profile must not immediately open a window');
  await command('createSpace', {windowId: firstWindow, text: 'Work Space', metadata: {profile: workProfile, theme: 'clay', emoji: '💼'}});
  state = await waitState(state => visible(state).length === 1 && visible(state)[0].spaces.some(space => space.active && space.name === 'Work Space'), 'select another profile');
  current = visible(state)[0];
  const workSpace = current.activeSpaceId;
  assert.equal(current.profileId, workProfile);
  assert.equal(state.windows.length, 2, 'Chromium keeps a host for each profile');
  assert.equal(new Set(state.windows.map(window => window.windowGroup)).size, 1);
  assert.deepEqual(current.bounds, originalBounds, 'The visible Bark window keeps its position and size');
  await command('navigate', {windowId: current.windowId, text: urls.work});
  const workPage = await sessionFor(browser, urls.work);
  assert.equal(await evaluate(browser, workPage.sessionId, "localStorage.getItem('bark-profile-test')"), null);
  assert.ok(!(await evaluate(browser, workPage.sessionId, 'document.cookie')).includes('bark_profile_test='));
  assert.equal(await evaluate(browser, workPage.sessionId, "fetch('/extension-blocked').then(() => false, () => true)"), false,
    'An extension installed in the personal profile must not filter another profile’s requests');
  await evaluate(browser, workPage.sessionId, "localStorage.setItem('bark-profile-test', 'work'); document.cookie = 'bark_profile_test=work; path=/; SameSite=Lax'");
  checks.push('Profile creation opens no extra window; a space assigned to another profile uses one visible window with isolated storage');

  for (let round = 0; round < 3; round++) {
    current = await select(research, current.windowId);
    assert.equal(current.windowId, firstWindow, 'Returning to a profile reuses its original host');
    assert.equal(current.profiles.length, 2);
    const selected = current.spaces.find(space => space.active);
    assert.equal(selected.theme, 'lavender'); assert.equal(selected.emoji, '📚');
    assert.ok(current.tabs.some(tab => tab.url === urls.research && tab.pinned));
    assert.equal(await evaluate(browser, researchPage.sessionId, "localStorage.getItem('bark-profile-test')"), 'personal');
    current = await select(workSpace, current.windowId);
    assert.ok(current.tabs.some(tab => tab.url === urls.work));
    assert.equal(await evaluate(browser, workPage.sessionId, "localStorage.getItem('bark-profile-test')"), 'work');
  }
  current = await select(personal, current.windowId);
  checks.push('Repeated switches reuse profile hosts, preserve pins/themes/emoji, and keep exactly one visible window');
  await editSettings();
  fs.writeFileSync(path.join(reports, 'before-restart.json'), JSON.stringify(await command(), null, 2));
  await browser.close(); browser = null;

  // Use normal startup behavior, with no --restore-last-session override.
  browser = launch('restart', {profileDirectory: null});
  state = await waitState(state => state.windows.some(window => window.allTabs.some(tab => tab.url === urls.research)), 'native tab restoration');
  state = await waitState(state => visible(state).length === 1 && visible(state)[0].activeSpaceId === personal &&
    state.windows.length === 2 && new Set(state.windows.map(window => window.windowGroup)).size === 1, 'restore one logical window and last active space');
  const restored = state.windows.find(window => window.allTabs.some(tab => tab.url === urls.research));
  assert.equal(restored.allTabs.find(tab => tab.url === urls.personal).space, personal);
  assert.equal(restored.allTabs.find(tab => tab.url === urls.research).space, research);
  assert.equal(restored.allTabs.find(tab => tab.url === urls.research).pinned, true);
  assert.equal(restored.spaces.find(space => space.id === research).emoji, '📚');
  await verifySettingsRestored();
  current = await select(workSpace, restored.windowId);
  state = await waitState(state => visible(state).length === 1 && visible(state)[0].allTabs.some(tab => tab.url === urls.work), 'second profile restoration');
  assert.equal(visible(state)[0].allTabs.find(tab => tab.url === urls.work).space, workSpace);
  checks.push('Normal restart restores space membership, tabs, pins, appearance, and the assigned profiles');

  // Explicit new windows remain independent, including when they open a
  // profile already present in another logical window.
  const originalGroup = visible(state)[0].windowGroup;
  await browser.send('Target.createTarget', {url: base + '/second-window', newWindow: true});
  state = await waitState(state => visible(state).length === 2 && state.windows.length === 3, 'explicit second window');
  const second = visible(state).find(window => window.windowGroup !== originalGroup);
  assert.ok(second);
  const otherSpace = second.profileId === firstProfile ? workSpace : personal;
  await command('space', {text: otherSpace, windowId: second.windowId});
  state = await waitState(state => state.windows.length === 4 && visible(state).length === 2 &&
    visible(state).some(window => window.windowGroup === second.windowGroup && window.activeSpaceId === otherSpace), 'independent profile switch in second window');
  assert.equal(state.windows.filter(window => window.windowGroup === originalGroup).length, 2);
  await command('testCloseWindow', {windowId: visible(state).find(window => window.windowGroup === second.windowGroup).windowId});
  state = await waitState(state => state.windows.length === 2 && visible(state).length === 1, 'close second window without closing original');
  assert.equal(visible(state)[0].windowGroup, originalGroup);
  checks.push('An explicitly opened second window owns independent profile hosts and closes without affecting the first');

  const dirtyPage = await sessionFor(browser, urls.work);
  await browser.send('Runtime.evaluate', {
    expression: "window.onbeforeunload = event => { event.preventDefault(); event.returnValue = ''; }",
    userGesture: true,
  }, dirtyPage.sessionId);
  current = await select(personal, visible(state)[0].windowId);
  let closeDialog;
  browser.onEvent = event => {
    if (event.method === 'Page.javascriptDialogOpening' && event.sessionId === dirtyPage.sessionId) closeDialog = event;
  };
  await command('testCloseWindow', {windowId: current.windowId});
  for (let attempt = 0; !closeDialog && attempt < 100; attempt++) await delay(100);
  assert.equal(closeDialog?.params.type, 'beforeunload', 'Background profiles must retain normal beforeunload protection');
  state = await command();
  assert.ok(visible(state).some(window => window.profileId === workProfile), 'The confirmation must belong to a visible window');
  await browser.send('Page.handleJavaScriptDialog', {accept: false}, dirtyPage.sessionId);
  state = await waitState(state => visible(state).length === 1 && visible(state)[0].profileId === workProfile, 'cancel background profile close');
  await evaluate(browser, dirtyPage.sessionId, 'window.onbeforeunload = null');
  checks.push('Closing a group exposes a background profile’s beforeunload dialog; cancelling keeps its tabs usable');

  await command('testCloseWindow', {windowId: visible(state)[0].windowId});
  await waitState(state => state.windows.length === 0, 'closing the logical window closes background profile hosts');
  await browser.send('Browser.getVersion');
  checks.push('Closing the Bark window also closes its background profile hosts without crashing');
  await browser.close(); browser = null;

  // Reopen an older stock Personal space, then choose the old icon explicitly.
  // The migration must run once without overriding a later user choice.
  const localStatePath = path.join(profile, 'Local State');
  const localState = JSON.parse(fs.readFileSync(localStatePath, 'utf8'));
  const stockPersonal = localState.bark.spaces.find(space => space.id === personal);
  Object.assign(stockPersonal, {name: 'Personal', theme: 'gray', emoji: '🍃'});
  delete stockPersonal.personalIconMigrated;
  fs.writeFileSync(localStatePath, JSON.stringify(localState));
  browser = launch('personal-icon-migration');
  state = await waitState(state => visible(state)[0]?.spaces.some(space => space.id === personal), 'Personal icon migration');
  assert.equal(visible(state)[0].spaces.find(space => space.id === personal).emoji, '👤');
  assert.equal(visible(state)[0].spaces.find(space => space.id === research).emoji, '📚', 'A custom space icon is preserved');
  checks.push('Fresh and unchanged legacy Personal spaces use the person icon while custom spaces retain their icons');
  await command('customizeSpace', {windowId: visible(state)[0].windowId,
    metadata: {space: personal, name: 'Personal', theme: 'gray', emoji: '🍃'}});
  await browser.close(); browser = null;
  browser = launch('personal-custom-icon');
  state = await waitState(state => visible(state)[0]?.spaces.some(space => space.id === personal), 'custom Personal icon');
  assert.equal(visible(state)[0].spaces.find(space => space.id === personal).emoji, '🍃');
  checks.push('Choosing a different Personal icon after migration survives restart');
  await browser.close(); browser = null;
  report.passed = true;
  console.log(`${checks.length} native space/profile/settings checks passed`);
} catch (error) {
  report.error = error.stack || String(error);
  report.lastState = latest;
  report.preservedProfile = profile;
  console.error(error);
  process.exitCode = 1;
} finally {
  if (browser) await browser.close().catch(error => { report.shutdownError = String(error); });
  server.closeAllConnections();
  await new Promise(resolve => server.close(resolve));
  fs.writeFileSync(path.join(reports, 'report.json'), JSON.stringify(report, null, 2) + '\n');
  if (report.passed) fs.rmSync(profile, {recursive: true, force: true});
  console.log('Reports:', reports);
}
