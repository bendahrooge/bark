#!/usr/bin/env node
// Remove original sidebar spaces after importing browser data without deleting profiles.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';
import {Browser} from './test_chromium_browser.mjs';

const root = path.resolve('test-results/chromium-space-removal');
fs.mkdirSync(root, {recursive: true});
const reports = fs.mkdtempSync(path.join(root, 'run-'));
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'bark-space-removal-'));
const driver = path.join(profile, '.bark-ui-driver');
fs.mkdirSync(driver);
const report = {passed: false, checks: []};
let browser, latest, sequence = 0;
const visible = state => state.windows.find(window => window.visible && !window.incognito);
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
  for (let i = 0; i < 200; i++) {
    const state = await command();
    if (predicate(state)) return state;
    await delay(100);
  }
  throw Error('Timed out: ' + label);
}
function launch(name) {
  for (const file of ['request.json', 'response.json']) fs.rmSync(path.join(driver, file), {force: true});
  return new Browser(profile, path.join(reports, name + '.log'), {
    nativeWindow: true, nativeUI: true, loadFixture: false, testDirectory: driver, profileDirectory: null,
  });
}
async function close() { await browser.close(); browser = null; }
async function attach(url) {
  const {targetInfos} = await browser.send('Target.getTargets');
  const target = targetInfos.find(target => target.type === 'page' && target.url === url);
  assert.ok(target, 'Target for ' + url);
  const {sessionId} = await browser.send('Target.attachToTarget', {targetId: target.targetId, flatten: true});
  await browser.send('Page.enable', {}, sessionId);
  return sessionId;
}
async function evaluate(session, expression) {
  const result = await browser.send('Runtime.evaluate', {expression, awaitPromise: true, returnByValue: true}, session);
  assert.ok(!result.exceptionDetails, JSON.stringify(result.exceptionDetails));
  return result.result.value;
}
async function waitPage(session, expression) {
  for (let i = 0; i < 100; i++) {
    if (await evaluate(session, expression)) return;
    await delay(100);
  }
  throw Error('Timed out waiting for settings: ' + expression);
}
const server = http.createServer((request, response) => {
  response.writeHead(200, {'Content-Type': 'text/html', 'Cache-Control': 'no-store'});
  response.end('<title>Preserved profile</title><body>Saved profile data</body>');
});
try {
  assert.equal(process.platform, 'darwin');
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  browser = launch('remove-defaults');
  let state = await waitFor(state => !!visible(state)?.activeSpaceId, 'initial window');
  const original = visible(state);
  const originalId = original.profileId, originalSpace = original.activeSpaceId;
  await command('navigate', {windowId: original.windowId, text: base + '/personal'});
  await waitFor(state => visible(state)?.tabs.some(tab => tab.url === base + '/personal' && !tab.loading), 'original page');
  const originalSession = await attach(base + '/personal');
  await evaluate(originalSession, "localStorage.setItem('keep-profile-data', 'yes'); document.cookie = 'keep_profile=yes; path=/; SameSite=Lax'");
  await command('createProfile', {windowId: original.windowId, text: 'Work'});
  state = await waitFor(state => visible(state)?.spaces.some(space => space.name === 'Work'), 'original Work space');
  const workSpace = visible(state).spaces.find(space => space.name === 'Work').id;
  const payload = {request: 'remove-defaults-import', profiles: [{
    source: 'source-imported', name: 'Source profile', extensions: 0,
    spaces: [{id: 'source-imported', name: 'Imported', theme: 'ocean', emoji: '📚',
      tabs: [{id: 'pin', title: 'Imported pin', url: base + '/imported', pinned: true}]}],
    bookmarks: [], history: [],
  }]};
  await command('importBrowserData', {windowId: original.windowId, text: JSON.stringify(payload)});
  state = await waitFor(state => visible(state)?.browserImportResult?.request === payload.request, 'browser import');
  assert.equal(visible(state).browserImportResult.success, true);
  assert.equal(visible(state).profiles.length, 3);

  await command('deleteSpace', {windowId: original.windowId, text: originalSpace});
  state = await waitFor(state => visible(state)?.activeSpaceId === workSpace &&
    visible(state).spaces.length === 2, 'remove Personal and switch to Work');
  assert.equal(visible(state).profiles.length, 3);
  assert.ok(state.windows.find(window => window.profileId === originalId)?.allTabs.some(tab => tab.url === base + '/personal'));
  assert.equal(await evaluate(originalSession, "localStorage.getItem('keep-profile-data')"), 'yes');
  assert.match(await evaluate(originalSession, 'document.cookie'), /keep_profile=yes/);
  report.checks.push('Sidebar removal of the original Personal space switches spaces while preserving its profile, tabs, cookies, and storage');

  await command('manageSpaces', {windowId: visible(state).windowId});
  await waitFor(state => visible(state)?.tabs.some(tab => tab.url === 'chrome://spaces/' && !tab.loading), 'space settings');
  const ui = await attach('chrome://spaces/');
  const remove = `document.querySelector('[data-focus-key="delete-${workSpace}"]')`;
  await waitPage(ui, `${remove} && !${remove}.disabled`);
  await evaluate(ui, `${remove}.click()`);
  await waitPage(ui, "document.querySelector('#deleteDialog').open");
  assert.match(await evaluate(ui, "document.querySelector('#deleteBody').textContent"), /saved data are kept/);
  await evaluate(ui, "document.querySelector('#cancelDelete').click()");
  assert.equal(visible(await command()).spaces.length, 2);
  await evaluate(ui, `${remove}.click()`);
  await waitPage(ui, "document.querySelector('#deleteDialog').open");
  await evaluate(ui, "document.querySelector('#confirmDelete').click()");
  state = await waitFor(state => visible(state)?.activeSpaceId === 'source-imported' &&
    visible(state).spaces.length === 1, 'remove Work from settings and switch to imported space');
  assert.equal(visible(state).profiles.length, 3);
  report.checks.push('Settings allows removing a profile’s last sidebar space and cancelling leaves the sidebar unchanged');

  await command('deleteSpace', {windowId: visible(state).windowId, text: 'source-imported'});
  state = await command();
  assert.equal(visible(state).spaces.length, 1);
  assert.equal(visible(state).activeSpaceId, 'source-imported');
  payload.request = 'retry';
  await command('importBrowserData', {windowId: visible(state).windowId, text: JSON.stringify(payload)});
  state = await waitFor(state => visible(state)?.browserImportResult?.request === payload.request, 'retry import');
  assert.equal(visible(state).browserImportResult.success, true);
  assert.equal(visible(state).spaces.length, 1);
  assert.equal(visible(state).profiles.length, 3);
  report.checks.push('The final visible space stays protected, and retrying the import does not recreate removed defaults');
  await close();
  const local = JSON.parse(fs.readFileSync(path.join(profile, 'Local State')));
  assert.ok(Object.hasOwn(local.profile.info_cache, originalId));
  browser = launch('restart');
  state = await waitFor(state => visible(state)?.activeSpaceId === 'source-imported' &&
    visible(state).spaces.length === 1 && !visible(state).switchingSpace, 'removed spaces stay absent after restart');
  assert.equal(visible(state).profiles.length, 3);
  report.checks.push('Removed default spaces stay out of the sidebar after restart while all profiles remain registered');

  await command('createSpace', {windowId: visible(state).windowId, text: 'Personal again',
    metadata: {profile: originalId, theme: 'gray', emoji: '👤'}});
  state = await waitFor(state => visible(state)?.profileId === originalId &&
    visible(state).spaces.some(space => space.active && space.name === 'Personal again'), 'reuse preserved original profile');
  assert.equal(visible(state).spaces.length, 2, 'Creating a space must not add another default space');
  const savedTab = visible(state).tabs.find(tab => tab.url === base + '/personal');
  assert.ok(savedTab, 'The original tab is retained');
  await command('select', {windowId: visible(state).windowId, id: savedTab.id});
  await waitFor(state => visible(state)?.tabs.some(tab => tab.url === base + '/personal' && tab.active && !tab.loading) &&
    visible(state).allTabs.find(tab => tab.url === base + '/personal')?.needsReload === false, 'restored original page');
  const restored = await attach(base + '/personal');
  assert.equal(await evaluate(restored, "localStorage.getItem('keep-profile-data')"), 'yes');
  assert.match(await evaluate(restored, 'document.cookie'), /keep_profile=yes/);
  report.checks.push('A new space can reuse the original profile and recover its saved tabs and site data');
  await close();
  report.passed = true;
  console.log(`${report.checks.length} focused sidebar-space removal checks passed`);
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
