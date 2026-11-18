#!/usr/bin/env node
// Exercise the native tab detach command used by sidebar drag-out and its menu action.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';
import {Browser} from './test_chromium_browser.mjs';

const root = path.resolve('test-results/chromium-tab-detach');
fs.mkdirSync(root, {recursive: true});
const reports = fs.mkdtempSync(path.join(root, 'run-'));
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'bark-tab-detach-'));
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
  for (let i = 0; i < 150; i++) {
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
    initialURL: base + '/anchor',
  });
}
async function close() { await browser.close(); browser = null; }
const requests = new Map();
const server = http.createServer((request, response) => {
  requests.set(request.url, (requests.get(request.url) || 0) + 1);
  response.writeHead(200, {'Content-Type': 'text/html', 'Cache-Control': 'no-store'});
  response.end('<title>Detach test</title><link rel="icon" href="data:,"><input id="draft"><body>Detach test</body>');
});
let base;
const windowById = (state, id) => state.windows.find(window => window.windowId === id);
const tabIn = (window, name) => window?.allTabs.find(tab => tab.url === base + '/' + name);
const owner = (state, name) => state.windows.find(window => tabIn(window, name));
const emptyPins = window => window.allTabs.every(tab => !tab.pinned) && window.favorites.length === 0;
async function evaluate(sessionId, expression) {
  const result = await browser.send('Runtime.evaluate', {expression, returnByValue: true}, sessionId);
  assert.ok(!result.exceptionDetails, JSON.stringify(result.exceptionDetails));
  return result.result.value;
}
try {
  assert.equal(process.platform, 'darwin');
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  base = `http://127.0.0.1:${server.address().port}`;
  browser = launch('detach');
  let state = await waitFor(state => !!owner(state, 'anchor')?.activeSpaceId, 'initial window');
  const source = owner(state, 'anchor').windowId;
  const originalGroup = owner(state, 'anchor').windowGroup;
  for (const name of ['keep-pin', 'move-pin', 'keep-favorite', 'move-favorite', 'move', 'split-a', 'split-b']) {
    await browser.send('Target.createTarget', {url: base + '/' + name});
    await waitFor(state => windowById(state, source)?.tabs.some(tab => tab.url === base + '/' + name && tab.title === 'Detach test' && !tab.loading), 'load ' + name);
  }
  state = await command();
  const id = name => tabIn(windowById(state, source), name).id;
  for (const name of ['keep-pin', 'move-pin']) await command('pin', {windowId: source, id: id(name)});
  for (const name of ['keep-favorite', 'move-favorite']) {
    await command('moveTab', {windowId: source, id: id(name), metadata: {zone: 'favorites', before: ''}});
  }
  const movingId = id('move');
  const {targetInfos} = await browser.send('Target.getTargets');
  const target = targetInfos.find(target => target.url === base + '/move');
  const {sessionId} = await browser.send('Target.attachToTarget', {targetId: target.targetId, flatten: true});
  await browser.send('Page.enable', {}, sessionId);
  await evaluate(sessionId, "window.moveMarker = 'live page'; document.querySelector('#draft').value = 'unsaved text'; history.pushState({marker: 42}, '', '/live-state')");
  const historyBefore = await browser.send('Page.getNavigationHistory', {}, sessionId);
  const loadsBefore = requests.get('/move');
  await command('select', {windowId: source, id: movingId});
  await command('detachTab', {windowId: source, id: movingId, metadata: {screenX: '400', screenY: '500'}});
  state = await waitFor(state => owner(state, 'live-state')?.windowId !== source &&
    owner(state, 'live-state')?.visible, 'detached live tab');
  const detached = owner(state, 'live-state');
  assert.equal(detached.allTabs.length, 1);
  assert.equal(detached.allTabs[0].id, movingId);
  assert.equal(detached.allTabs[0].sessionWindow, detached.windowId);
  assert.ok(emptyPins(detached));
  assert.equal(detached.profile, windowById(state, source).profile);
  assert.equal(detached.activeSpaceId, windowById(state, source).activeSpaceId);
  assert.notEqual(detached.windowGroup, originalGroup);
  assert.ok(!windowById(state, source).allTabs.some(tab => tab.id === movingId));
  assert.deepEqual(await evaluate(sessionId, '[window.moveMarker, document.querySelector("#draft").value, history.state.marker]'),
    ['live page', 'unsaved text', 42]);
  const historyAfter = await browser.send('Page.getNavigationHistory', {}, sessionId);
  assert.deepEqual(historyAfter, historyBefore);
  assert.equal(requests.get('/move'), loadsBefore, 'Moving the live tab must not reload it');
  assert.equal(requests.get('/live-state') || 0, 0);
  report.checks.push('Drag-out moves the same live tab, draft, JS state and history into an independent unpinned window');
  assert.ok(tabIn(windowById(state, source), 'keep-pin').pinned);
  assert.ok(windowById(state, source).favorites.some(tab => tab.url === base + '/keep-favorite'));
  report.checks.push('The source retains its other pinned tabs and Favorites');

  await command('detachTab', {windowId: source, id: id('move-pin')});
  state = await waitFor(state => !!owner(state, 'move-pin') && owner(state, 'move-pin').windowId !== source, 'detached pin');
  const pinnedDestination = owner(state, 'move-pin');
  assert.equal(pinnedDestination.allTabs.length, 1);
  assert.ok(emptyPins(pinnedDestination));
  assert.ok(tabIn(windowById(state, source), 'keep-pin').pinned);
  report.checks.push('Dragging a pinned tab out converts only that tab to an ordinary tab');

  await command('detachTab', {windowId: source, id: id('move-favorite')});
  state = await waitFor(state => !!owner(state, 'move-favorite') && owner(state, 'move-favorite').windowId !== source, 'detached Favorite');
  assert.equal(owner(state, 'move-favorite').tabs.length, 1);
  assert.ok(emptyPins(owner(state, 'move-favorite')));
  assert.ok(windowById(state, source).favorites.some(tab => tab.url === base + '/keep-favorite'));
  report.checks.push('Dragging a Favorite out makes it an ordinary tab without copying other Favorites');

  await command('select', {windowId: source, id: id('split-a')});
  await command('splitTab', {windowId: source, id: id('split-b'), text: 'bottom'});
  await waitFor(state => tabIn(windowById(state, source), 'split-b')?.splitLayout === 'stacked', 'source split');
  await command('detachTab', {windowId: source, id: id('split-b')});
  state = await waitFor(state => !!owner(state, 'split-b') && owner(state, 'split-b').windowId !== source, 'detached split half');
  assert.equal(owner(state, 'split-b').allTabs.length, 1);
  assert.ok(!tabIn(windowById(state, source), 'split-a').splitLayout);
  assert.ok(!tabIn(owner(state, 'split-b'), 'split-b').splitLayout);
  assert.ok(emptyPins(owner(state, 'split-b')));
  report.checks.push('Dragging one split pane moves only that tab and leaves its partner in the source');

  await command('detachTab', {windowId: detached.windowId, id: movingId});
  state = await waitFor(state => !!owner(state, 'live-state') && owner(state, 'live-state').windowId !== detached.windowId, 'last tab detached');
  const kept = windowById(state, detached.windowId);
  assert.ok(kept.visible && kept.allTabs.length === 1 && kept.allTabs[0].url === 'about:blank');
  assert.ok(emptyPins(kept) && emptyPins(owner(state, 'live-state')));
  const movedGroup = owner(state, 'live-state').windowGroup;
  report.checks.push('Dragging the last open tab leaves a blank source workspace and does not copy pins');

  await command('testCloseWindow', {windowId: pinnedDestination.windowId});
  await waitFor(state => !windowById(state, pinnedDestination.windowId), 'close detached window');
  assert.ok(windowById(latest, source)?.visible && tabIn(windowById(latest, source), 'keep-pin').pinned);
  report.checks.push('Closing a detached window leaves the original workspace open');

  const independentGroups = Object.fromEntries(['live-state', 'move-favorite', 'split-b']
    .map(name => [name, owner(latest, name).windowGroup]));
  assert.equal(new Set([originalGroup, detached.windowGroup, ...Object.values(independentGroups)]).size, 5);
  report.beforeRestart = latest.windows.map(window => ({windowId: window.windowId,
    group: window.windowGroup, urls: window.allTabs.map(tab => tab.url)}));
  await close();
  browser = launch('restore');
  state = await waitFor(state => owner(state, 'keep-pin')?.visible &&
    Object.keys(independentGroups).every(name => owner(state, name)?.visible), 'restore independent windows');
  for (const [name, group] of Object.entries(independentGroups)) {
    assert.equal(owner(state, name).windowGroup, group, name + ' must keep its independent window group');
    assert.ok(emptyPins(owner(state, name)));
  }
  assert.equal(owner(state, 'live-state').windowGroup, movedGroup);
  assert.equal(owner(state, 'keep-pin').windowGroup, originalGroup);
  assert.notEqual(owner(state, 'live-state').windowId, owner(state, 'keep-pin').windowId);
  assert.ok(emptyPins(owner(state, 'live-state')));
  assert.ok(tabIn(owner(state, 'keep-pin'), 'keep-pin').pinned);
  report.checks.push('Independent windows and their separate pinned-tab lists survive restart');
  await close();
  report.passed = true;
  console.log(`${report.checks.length} focused tab-detach checks passed`);
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
