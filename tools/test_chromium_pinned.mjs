#!/usr/bin/env node
// Focused native regression: pins load on selection and close without removal.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';
import {Browser, uiDriver, bundleEnablesSwiftUI} from './test_chromium_browser.mjs';

const resultRoot = path.resolve('test-results/chromium-pinned');
fs.mkdirSync(resultRoot, {recursive: true});
const reports = fs.mkdtempSync(path.join(resultRoot, 'run-'));
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'bark-pinned-test-'));
const driver = path.join(profile, '.bark-ui-driver');
fs.mkdirSync(driver);
const report = {passed: false, checks: []};
const requests = new Map();
const needsDevelopmentSwitch = !bundleEnablesSwiftUI();
let browser;
const visible = state => state.windows.find(window => window.visible && !window.incognito);
const ui = uiDriver({directory: () => driver, browser: () => browser});
const {command, waitFor} = ui;
function launch(name) {
  for (const file of ['request.json', 'response.json']) fs.rmSync(path.join(driver, file), {force: true});
  return new Browser(profile, path.join(reports, name + '.log'), {
    nativeWindow: true, nativeUI: needsDevelopmentSwitch, loadFixture: false, testDirectory: driver,
    profileDirectory: null, initialURL: null,
  });
}
async function close() { await browser.close(); browser = null; }
function editJSON(file, edit) {
  const value = JSON.parse(fs.readFileSync(file));
  edit(value);
  fs.writeFileSync(file, JSON.stringify(value));
}
const iconColors = new Map([
  ['/pin-a.svg', 'red'], ['/pin-b.svg', 'blue'], ['/favorite.svg', 'green'], ['/revised.svg', 'purple'],
  ['/pending-a.svg', 'orange'], ['/pending-b.svg', 'yellow'],
]);
const server = http.createServer((request, response) => {
  const url = new URL(request.url, 'http://localhost');
  requests.set(url.pathname, (requests.get(url.pathname) ?? 0) + 1);
  if (url.pathname === '/slow-pin' && requests.get(url.pathname) === 1) return;
  const color = iconColors.get(url.pathname);
  if (color) {
    response.writeHead(200, {'Content-Type': 'image/svg+xml', 'Cache-Control': 'no-store'});
    response.end(`<svg xmlns="http://www.w3.org/2000/svg" width="32" height="32"><rect width="32" height="32" fill="${color}"/></svg>`);
    return;
  }
  response.writeHead(200, {'Content-Type': 'text/html', 'Cache-Control': 'no-store'});
  const icon = iconColors.has(url.pathname + '.svg') ? url.pathname + '.svg' : 'data:,';
  response.end(`<title>Saved ${url.pathname}</title><link rel="icon" href="${icon}"><body>Pin loading check</body>`);
});
try {
  assert.equal(process.platform, 'darwin');
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const pins = ['/pin-a', '/pin-b', '/favorite'];
  const tabFor = (state, suffix) => visible(state)?.allTabs.find(tab => tab.url === base + suffix);
  const rowFor = (state, suffix) => {
    const window = visible(state);
    return window && [...window.tabs, ...window.favorites].find(tab => tab.url === base + suffix);
  };
  const savedRows = new Map();
  const assertCachedRows = state => {
    for (const [suffix, saved] of savedRows) {
      const row = rowFor(state, suffix);
      assert.ok(row, `${suffix} appears in the sidebar`);
      assert.equal(row.title, saved.title, `${suffix} shows its last page title`);
      assert.notEqual(row.faviconValid, false, `${suffix} can display its restored favicon`);
      assert.equal(row.favicon, saved.favicon, `${suffix} shows its last favicon`);
    }
    for (const icon of iconColors.keys()) {
      assert.equal(requests.get(icon) ?? 0, 0, `Startup must not fetch ${icon}`);
    }
  };
  const attachPage = async url => {
    const {targetInfos} = await browser.send('Target.getTargets');
    const target = targetInfos.find(target => target.type === 'page' && target.url === url);
    assert.ok(target, 'An open page must exist at ' + url);
    const {sessionId} = await browser.send('Target.attachToTarget', {targetId: target.targetId, flatten: true});
    return sessionId;
  };
  const setStartupPreference = async value => {
    // Chromium protects the startup preference against edits made on disk.
    const url = 'chrome://settings/onStartup';
    const {targetId} = await browser.send('Target.createTarget', {url});
    try {
      await waitFor(state => visible(state)?.tabs.some(tab => tab.url === url && !tab.loading), 'startup settings');
      const sessionId = await attachPage(url);
      const {result} = await browser.send('Runtime.evaluate', {
        expression: `chrome.settingsPrivate.setPref('session.restore_on_startup', ${value})`,
        awaitPromise: true, returnByValue: true,
      }, sessionId);
      assert.equal(result.value, true, 'The browser saved the startup preference');
    } finally {
      await browser.send('Target.closeTarget', {targetId});
    }
  };
  const assertDormant = (state, suffixes) => {
    for (const suffix of suffixes) {
      const tab = tabFor(state, suffix);
      assert.ok(tab?.pinned, `${suffix} retains its pinned state`);
      assert.equal(tab.needsReload, true, `${suffix} waits for selection`);
      assert.equal(requests.get(suffix) ?? 0, 0, `${suffix} must not request its page in the background`);
    }
  };
  const select = async suffix => {
    const state = await command();
    const expectedRequests = (requests.get(suffix) ?? 0) + (tabFor(state, suffix).needsReload ? 1 : 0);
    await command('select', {windowId: visible(state).windowId, id: tabFor(state, suffix).id});
    await waitFor(state => {
      const window = visible(state);
      const selected = [...window.tabs, ...window.favorites].find(tab => tab.url === base + suffix && tab.active);
      return requests.get(suffix) === expectedRequests && tabFor(state, suffix)?.needsReload === false && selected && !selected.loading;
    }, 'load selected ' + suffix);
  };

  browser = launch('seed');
  await waitFor(state => !!visible(state)?.activeSpaceId, 'initial window');
  await setStartupPreference(1);  // Continue where you left off.
  const pending = ['/pending-a', '/pending-b'];
  const historyIcons = new Map();
  for (const suffix of pending) {
    const {targetId} = await browser.send('Target.createTarget', {url: base + suffix});
    const visited = await waitFor(state => {
      const row = rowFor(state, suffix);
      return row?.title === 'Saved ' + suffix && row.faviconValid && row.favicon;
    }, 'seed local history for ' + suffix);
    historyIcons.set(suffix, rowFor(visited, suffix).favicon);
    await browser.send('Target.closeTarget', {targetId});
  }
  for (const suffix of [...pins, '/ordinary']) {
    await browser.send('Target.createTarget', {url: base + suffix});
    const state = await waitFor(state => visible(state)?.tabs.some(tab =>
      tab.url === base + suffix && tab.title === 'Saved ' + suffix && !tab.loading) && requests.get(suffix) === 1,
      'seed ' + suffix);
    if (suffix !== '/ordinary') {
      await command('moveTab', {windowId: visible(state).windowId, id: tabFor(state, suffix).id,
        metadata: {zone: suffix === '/favorite' ? 'favorites' : 'pinned', before: ''}});
      let pinned = await waitFor(state => {
        const row = rowFor(state, suffix);
        return row?.pinned && row.faviconValid && row.favicon;
      }, 'pinned page favicon for ' + suffix);
      if (suffix === '/pin-b') {
        const originalIcon = rowFor(pinned, suffix).favicon;
        const session = await attachPage(base + suffix);
        await browser.send('Runtime.evaluate', {
          expression: `document.title = 'Updated page title'; document.querySelector('link[rel=icon]').href = '/revised.svg'`,
        }, session);
        pinned = await waitFor(state => {
          const row = rowFor(state, suffix);
          return row?.title === 'Updated page title' && row.faviconValid && row.favicon && row.favicon !== originalIcon;
        }, 'updated title and favicon after pinning');
      }
      const {title, favicon} = rowFor(pinned, suffix);
      const png = Buffer.from(favicon, 'base64');
      assert.deepEqual([png.readUInt32BE(16), png.readUInt32BE(20)], [32, 32],
        `${suffix} exports the Retina favicon dimensions in the PNG header`);
      savedRows.set(suffix, {title, favicon});
    }
  }
  await browser.send('Target.createTarget', {url: 'about:blank'});
  await close();
  requests.clear();

  browser = launch('session-restore');
  let state = await waitFor(state => pins.every(suffix => !!rowFor(state, suffix)) && requests.get('/ordinary') === 1,
    'session restoration including an ordinary background tab');
  assertCachedRows(state);
  await delay(1000);
  state = await command();
  assertDormant(state, pins);
  assert.equal(tabFor(state, '/favorite').space, 'bark.favorites');
  await select('/pin-a');
  await select('/favorite');
  assertDormant(await command(), ['/pin-b']);
  report.checks.push('Restored pins and Favorites retain their metadata and make no page requests until selected; ordinary tabs still restore');
  await select('/pin-a');
  await close();
  requests.clear();

  browser = launch('selected-pin-restore');
  await waitFor(state => visible(state)?.tabs.some(tab => tab.url === base + '/pin-a' && tab.active) &&
    pins.every(suffix => !!tabFor(state, suffix)) && requests.get('/pin-a') === 1,
    'restore the selected pinned page');
  assertDormant(await command(), ['/pin-b', '/favorite']);
  report.checks.push('The pinned page selected at shutdown still loads when restored on screen');
  await close();
  requests.clear();

  // Browser imports and profile moves use this same pending-tab representation.
  editJSON(path.join(profile, 'Local State'), local => {
    local.bark.spaces.push({id: 'lazy-pending', name: 'Pending pins', profile: 'Default', theme: 'gray', emoji: '📚',
      pendingTabs: pending.map(suffix => ({url: base + suffix, pinned: true}))});
  });
  browser = launch('pending-pins');
  state = await waitFor(state => {
    const window = visible(state);
    return window?.spaces.some(space => space.id === 'lazy-pending') &&
      pins.every(suffix => !!tabFor(state, suffix)) && requests.get('/ordinary') === 1 &&
      window.allTabs.filter(tab => !tab.pinned).every(tab => !tab.needsReload) &&
      window.tabs.every(tab => !tab.loading);
  }, 'startup restoration before switching to the pending space');
  await command('space', {windowId: visible(state).windowId, text: 'lazy-pending'});
  state = await waitFor(state => visible(state)?.activeSpaceId === 'lazy-pending' &&
    visible(state).tabs.some(tab => tab.active && !tab.loading && tab.url.startsWith(base + '/pending-')), 'open pending space');
  const unopened = visible(state).tabs.find(tab => !tab.active && tab.url.startsWith(base + '/pending-'));
  assert.ok(unopened);
  const suffix = new URL(unopened.url).pathname;
  state = await waitFor(state => {
    const row = rowFor(state, suffix);
    return row?.title === 'Saved ' + suffix && row.faviconValid && row.favicon === historyIcons.get(suffix);
  }, 'URL-only dormant pin recovers its title and icon from local history');
  assert.equal(requests.get(suffix + '.svg') ?? 0, 0, 'Recovering an old icon uses only local history');
  await delay(1000);
  assertDormant(await command(), [suffix]);
  await select(suffix);
  report.checks.push('Opening a space with imported or moved pins loads only the selected pin; other pins wait for selection');

  const initialOrder = visible(await command()).allTabs.filter(tab => pending.some(suffix => tab.url === base + suffix)).map(tab => tab.url);
  const closedPin = async (suffix, action = 'close') => {
    const before = await command();
    const count = requests.get(suffix) ?? 0;
    const tab = tabFor(before, suffix);
    const rowHandle = rowFor(before, suffix).tabHandle;
    assert.ok(Number.isInteger(rowHandle));
    await command(action, {windowId: visible(before).windowId, id: tab.id});
    const after = await waitFor(state => tabFor(state, suffix)?.needsReload &&
      tabFor(state, suffix).discarded, 'unload ' + suffix);
    assert.equal(tabFor(after, suffix).pinned, true);
    assert.equal(tabFor(after, suffix).space, tab.space);
    assert.equal(rowFor(after, suffix).tabHandle, rowHandle, 'Closing keeps the hovered row in place for the next click');
    assert.equal(requests.get(suffix) ?? 0, count, 'Closing must not reload the pin');
    return after;
  };
  const background = pending.find(item => item !== suffix);
  const backgroundSession = await attachPage(base + background);
  await browser.send('Runtime.evaluate', {expression: "setInterval(() => fetch('/background-activity'), 50)"}, backgroundSession);
  await waitFor(() => (requests.get('/background-activity') ?? 0) >= 2, 'background page executing');
  await closedPin(background);
  await delay(200);  // Let in-flight requests settle after the renderer discards the page.
  const activityAfterClose = requests.get('/background-activity');
  await delay(300);
  assert.equal(requests.get('/background-activity'), activityAfterClose, 'Closing stops the page from executing');
  state = await closedPin(suffix, 'testCloseTab');  // The native ⌘W / File → Close Tab command.
  assert.equal(state.windows.length, 1, 'Closing the last loaded pin keeps the browser window');
  assert.ok(visible(state).tabs.some(tab => tab.active && tab.url === 'about:blank'));
  assert.deepEqual(visible(state).allTabs.filter(tab => pending.some(suffix => tab.url === base + suffix)).map(tab => tab.url), initialOrder);
  for (const item of pending) {
    assert.equal(visible(state).tabs.find(tab => tab.url === base + item).title, 'Saved ' + item);
  }
  await closedPin(suffix);  // Closing an already dormant pin is harmless.
  await select(suffix);
  report.checks.push('Sidebar close and the native close-tab command unload pins, retain their names/order/space, and reopen them on selection');

  // Use a real beforeunload dialog, with a user gesture as required by Chromium.
  const sessionId = await attachPage(base + suffix);
  await browser.send('Page.enable', {}, sessionId);
  await browser.send('Runtime.evaluate', {expression: "window.onbeforeunload = event => { event.preventDefault(); event.returnValue = ''; }", userGesture: true}, sessionId);
  let dialog;
  browser.onEvent = event => {
    if (event.method === 'Page.javascriptDialogOpening' && event.sessionId === sessionId) dialog = event;
  };
  const requestDirtyClose = async (action = 'close') => {
    dialog = undefined;
    const state = await command();
    await command(action, {windowId: visible(state).windowId, id: tabFor(state, suffix).id});
    for (let i = 0; !dialog && i < 100; i++) await delay(50);
    assert.equal(dialog?.params.type, 'beforeunload');
  };
  await requestDirtyClose();
  await browser.send('Page.handleJavaScriptDialog', {accept: false}, sessionId);
  state = await command();
  assert.equal(tabFor(state, suffix).needsReload, false, 'Cancelling keeps the pinned page loaded');
  assert.equal(tabFor(state, suffix).hasLiveRenderer, true);

  const dirtyTab = {windowId: visible(state).windowId, id: tabFor(state, suffix).id};
  await browser.send('Runtime.evaluate', {expression: "window.pendingCloseMarker = 'unsaved'", userGesture: true}, sessionId);
  await requestDirtyClose('closePinnedSession');
  await command('pin', dirtyTab);
  await waitFor(state => tabFor(state, suffix)?.pinned === false, 'unpin while the close prompt is open');
  await browser.send('Page.handleJavaScriptDialog', {accept: true}, sessionId);
  const keptState = await browser.send('Runtime.evaluate', {expression: 'window.pendingCloseMarker', returnByValue: true}, sessionId);
  assert.equal(keptState.result.value, 'unsaved', 'A close confirmation for the old pin preserves the ordinary tab session');
  state = await command();
  assert.equal(tabFor(state, suffix)?.id, dirtyTab.id);
  assert.equal(tabFor(state, suffix).pinned, false);
  assert.equal(tabFor(state, suffix).hasLiveRenderer, true);
  await command('pin', dirtyTab);
  await waitFor(state => tabFor(state, suffix)?.pinned, 're-pin the same live tab');
  report.checks.push('Unpinning during the beforeunload prompt preserves the ordinary tab and its live document after confirmation');

  await requestDirtyClose();
  await browser.send('Page.handleJavaScriptDialog', {accept: true}, sessionId);
  await waitFor(state => tabFor(state, suffix)?.needsReload && tabFor(state, suffix).discarded,
    'unload after confirming beforeunload');
  browser.onEvent = undefined;
  report.checks.push('Cancelling an unsaved-changes prompt keeps the page open; confirming unloads it and keeps the pin');

  // Close the session after the user has navigated away from the saved pin.
  await select(suffix);
  state = await command();
  const windowId = visible(state).windowId;
  const pinId = tabFor(state, suffix).id;
  const home = base + suffix;
  const detail = base + '/course-lesson';
  const rowForPin = state => visible(state)?.tabs.find(tab => tab.pinnedURL === home);
  await command('setPinURL', {windowId, id: pinId});
  await command('newFolder', {windowId, id: pinId, text: 'Courses'});
  await command('renameTab', {windowId, id: pinId, text: 'Course home'});
  state = await waitFor(state => rowForPin(state)?.folder && rowForPin(state)?.customTitle === 'Course home', 'organized active pin');
  const folder = rowForPin(state).folder;
  const pinOrder = state => visible(state).tabs.filter(tab => tab.pinned).map(tab => tab.pinnedURL || tab.url);
  const orderBeforeClose = pinOrder(state);
  const liveSession = await attachPage(home);
  await browser.send('Page.navigate', {url: detail}, liveSession);
  await waitFor(state => rowForPin(state)?.url === detail && rowForPin(state)?.active &&
    !rowForPin(state).loading && rowForPin(state).drifted, 'active pin visiting a different page');
  const originalState = await browser.send('Runtime.evaluate', {
    expression: "window.pinSession = 'original'; sessionStorage.setItem('pinSession', 'original'); sessionStorage.getItem('pinSession')",
    returnByValue: true,
  }, liveSession);
  assert.equal(originalState.result.value, 'original');
  const homeLoads = requests.get(suffix);
  await command('closePinnedSession', {windowId, id: pinId});
  state = await waitFor(state => rowForPin(state)?.url === home && !rowForPin(state).active &&
    tabFor(state, suffix)?.needsReload, 'saved pin visible in the sidebar with its session closed');
  assert.equal(rowForPin(state).customTitle, 'Course home');
  assert.equal(rowForPin(state).folder, folder);
  assert.equal(rowForPin(state).sessionClosed, true, 'The pinned row reflects its closed session');
  assert.equal(tabFor(state, suffix).hasLiveRenderer, false, 'The retained pin must not keep a live page session');
  assert.deepEqual(pinOrder(state), orderBeforeClose, 'Closing the session keeps the saved pin in place');
  assert.equal(requests.get(suffix), homeLoads, 'Closing must not navigate the dormant pin home');
  await select(suffix);
  assert.notEqual(rowForPin(await command()).sessionClosed, true, 'Selecting the pin reopens its session');
  const newSession = await attachPage(home);
  const newState = await browser.send('Runtime.evaluate', {
    expression: "[typeof window.pinSession, sessionStorage.getItem('pinSession')]", returnByValue: true,
  }, newSession);
  assert.deepEqual(newState.result.value, ['undefined', null]);
  const {entries} = await browser.send('Page.getNavigationHistory', {}, newSession);
  assert.deepEqual(entries.map(entry => entry.url), [home], 'The reopened pin starts with fresh navigation history');
  await closedPin(suffix, 'closePinnedSession');
  report.checks.push('Closing a drifted pin retains its folder, custom title and order; reopening starts a fresh session at its saved URL');

  state = await command();
  await command('moveTab', {windowId: visible(state).windowId, id: tabFor(state, '/favorite').id,
    metadata: {zone: 'favorites', before: ''}});
  await select('/favorite');
  state = await closedPin('/favorite');
  assert.ok(visible(state).favorites.some(tab => tab.url === base + '/favorite'));
  await command('pin', {windowId: visible(state).windowId, id: tabFor(state, background).id});
  state = await command();
  await command('closePinnedSession', {windowId: visible(state).windowId, id: tabFor(state, background).id});
  state = await command();
  assert.equal(tabFor(state, background)?.pinned, false, 'A stale pinned-row X cannot remove a tab that has been unpinned');
  await command('close', {windowId: visible(state).windowId, id: tabFor(state, background).id});
  await waitFor(state => !tabFor(state, background), 'close an unpinned tab');
  report.checks.push('Favorites also stay in their list when closed; unpinning then closing removes a tab normally');

  await browser.send('Target.createTarget', {url: base + '/slow-pin'});
  state = await waitFor(state => !!tabFor(state, '/slow-pin') && requests.get('/slow-pin') === 1,
    'first navigation still waiting for a response');
  await command('pin', {windowId: visible(state).windowId, id: tabFor(state, '/slow-pin').id});
  await closedPin('/slow-pin');
  await select('/slow-pin');
  state = await command();
  await command('removeClosedPin', {windowId: visible(state).windowId, id: tabFor(state, '/slow-pin').id});
  assert.equal(tabFor(await command(), '/slow-pin')?.needsReload, false,
    'A stale remove action preserves a pin that has reopened');
  state = await closedPin('/slow-pin', 'closePinnedSession');
  report.checks.push('Closing a pin during its first page load preserves its destination and allows reopening');
  const loadsBeforeRemoval = requests.get('/slow-pin');
  await command('removeClosedPin', {windowId: visible(state).windowId, id: tabFor(state, '/slow-pin').id});
  await waitFor(state => !tabFor(state, '/slow-pin'), 'remove the closed pin from the sidebar');
  assert.equal(requests.get('/slow-pin'), loadsBeforeRemoval, 'Removing a closed pin keeps its page unloaded');
  await close();
  requests.clear();
  browser = launch('closed-pins-restart');
  state = await waitFor(state => !!tabFor(state, suffix) && !!tabFor(state, '/favorite'), 'closed pins after restart');
  assertDormant(state, [suffix, '/favorite']);
  assert.equal(tabFor(state, background), undefined);
  assert.equal(tabFor(state, '/slow-pin'), undefined, 'A removed pin stays removed after session restore');
  assert.equal(tabFor(state, suffix).space, 'lazy-pending');
  assert.equal(tabFor(state, suffix).meta.title, 'Course home');
  assert.equal(tabFor(state, suffix).meta.folder, folder);
  assert.ok(visible(state).favorites.some(tab => tab.url === base + '/favorite'));
  report.checks.push('Closed pins and Favorites survive restart without loading; an explicitly unpinned and closed tab stays removed');

  // Closing the last window and reopening from the Dock (an Apple "reopen"
  // event) brings the window back with its Favorites and pins. Stock Chromium
  // opens an empty window here, which dropped Favorites.
  await command('testCloseWindow', {windowId: visible(state).windowId});
  await delay(1500);
  execFileSync('/usr/bin/osascript', ['-l', 'JavaScript', '-e', `
    ObjC.import('Foundation');
    const target = $.NSAppleEventDescriptor.descriptorWithProcessIdentifier(${browser.child.pid});
    const reopen = $.NSAppleEventDescriptor.appleEventWithEventClassEventIDTargetDescriptorReturnIDTransactionID(
      0x61657674, 0x72617070, target, -1, 0);  // 'aevt' / 'rapp'
    reopen.sendEventWithOptionsTimeoutError(1, 10, null);  // kAENoReply
  `], {timeout: 30000});
  state = await waitFor(state => !!visible(state) && !!tabFor(state, suffix) &&
    visible(state).favorites.some(tab => tab.url === base + '/favorite'), 'Favorites and pins after Dock reopen');
  assert.equal(tabFor(state, suffix).meta.title, 'Course home');
  report.checks.push('Reopening from the Dock after closing the last window restores its Favorites and pins');
  await setStartupPreference(5);  // Open the New Tab page.
  await close();
  requests.clear();

  browser = launch('new-tab-startup');
  state = await waitFor(state => pins.every(suffix => !!rowFor(state, suffix)), 'sidebar pins without session restoration');
  assertCachedRows(state);
  await delay(1000);
  state = await command();
  assert.equal(tabFor(state, '/ordinary'), undefined, 'New-tab startup skips the old session');
  assert.equal(tabFor(state, '/slow-pin'), undefined, 'A removed pin stays removed on new-tab startup');
  assertDormant(state, pins);
  await select('/pin-b');
  await waitFor(state => {
    const row = rowFor(state, '/pin-b');
    return row?.title === 'Saved /pin-b' && row.faviconValid && row.favicon && row.favicon !== savedRows.get('/pin-b').favicon;
  }, 'live title and favicon replace cached values after selection');
  assertDormant(await command(), ['/pin-a', '/favorite']);
  report.checks.push('New-tab startup shows saved titles and favicons before selection, and removed pins stay removed');
  await close();
  report.passed = true;
  console.log(`${report.checks.length} focused pinned-tab checks passed`);
} catch (error) {
  report.error = error.stack || String(error);
  report.lastState = ui.latest;
  report.requests = Object.fromEntries(requests);
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
