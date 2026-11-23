#!/usr/bin/env node
// Exercise the AppKit Extensions menu and site controls in disposable profiles.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';
import {Browser, uiDriver, expectTitle} from './test_chromium_browser.mjs';

const root = path.resolve('test-results/chromium-extensions-menu');
fs.mkdirSync(root, {recursive: true});
const reports = fs.mkdtempSync(path.join(root, 'run-'));
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'bark-extensions-menu-'));
const driver = path.join(profile, '.bark-ui-driver');
fs.mkdirSync(driver);
const report = {passed: false, checks: []};
let browser;
const visible = state => state.windows.find(window => window.visible && !window.incognito);
const ui = uiDriver({directory: () => driver, browser: () => browser});
const {command, waitFor} = ui;
async function menu(windowId, text) {
  return (await command('testExtensionsMenu', {windowId, ...(text ? {text} : {})})).extensionsMenu;
}
async function siteControls(windowId) {
  const state = await command('siteControls', {windowId, text: 'open'});
  return state.windows.find(window => window.windowId === windowId).siteControls;
}
const actions = menu => menu.items.filter(item => /^[a-p]{32}$/.test(item.action));
async function waitMenu(windowId, predicate, label) {
  for (let i = 0; i < 100; i++) {
    const value = await menu(windowId);
    if (predicate(value)) return value;
    await delay(100);
  }
  throw Error('Timed out: ' + label);
}
async function evaluate(session, expression) {
  const result = await browser.send('Runtime.evaluate', {expression, awaitPromise: true, returnByValue: true}, session);
  assert.ok(!result.exceptionDetails, JSON.stringify(result.exceptionDetails));
  return result.result.value;
}
const server = http.createServer((request, response) => {
  response.writeHead(200, {'Content-Type': 'text/html', 'Cache-Control': 'no-store'});
  response.end('<title>Waiting for extension</title><body>Extension menu test</body>');
});
try {
  assert.equal(process.platform, 'darwin');
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const url = `http://localhost:${server.address().port}/menu-action`;
  browser = new Browser(profile, path.join(reports, 'browser.log'), {
    nativeWindow: true, nativeUI: true, loadFixture: false, testDirectory: driver,
  });
  let state = await waitFor(state => !!visible(state)?.activeSpaceId, 'initial window');
  const original = visible(state);
  await command('testActivateWindow', {windowId: original.windowId});
  let items = await waitMenu(original.windowId, value => value.items.some(item => item.action === 'bark.manageExtensions' && item.enabled), 'active browser menu');
  assert.equal(items.title, 'Extensions');
  assert.deepEqual(actions(items), []);
  assert.ok(items.items.some(item => item.title === 'No enabled extensions' && !item.enabled));
  await menu(original.windowId, 'bark.manageExtensions');
  await waitFor(state => visible(state)?.tabs.some(tab => tab.url === 'chrome://extensions/' && tab.active), 'Manage Extensions opens the manager');
  report.checks.push('The menu bar has an Extensions menu with an empty state and working Manage Extensions action');
  let controls = await siteControls(original.windowId);
  assert.deepEqual(controls.extensions, []);
  assert.deepEqual(controls.permissions, []);
  assert.equal(controls.canManagePermissions, false, 'Internal pages must not present website permissions');

  const {id} = await browser.send('Extensions.loadUnpacked', {path: path.resolve('tools/fixtures/extension')});
  await command('navigate', {windowId: original.windowId, text: url});
  await waitFor(state => visible(state)?.tabs.some(tab => tab.url === url && !tab.loading), 'test page');
  const {targetInfos} = await browser.send('Target.getTargets');
  const page = targetInfos.find(target => target.type === 'page' && target.url === url);
  assert.ok(page);
  const {sessionId: pageSession} = await browser.send('Target.attachToTarget', {targetId: page.targetId, flatten: true});
  await browser.send('Page.enable', {}, pageSession);
  await expectTitle(browser, pageSession, 'Waiting for extension');
  items = await waitMenu(original.windowId, value => actions(value).some(item => item.action === id && item.enabled), 'installed extension appears');
  assert.equal(actions(items).find(item => item.action === id).title, 'Bark Extension Test');
  await menu(original.windowId, id);
  // localhost is outside the manifest's 127.0.0.1 host permission. This proves
  // menu activation grants activeTab through Chromium's real user-action path.
  await expectTitle(browser, pageSession, 'Extension action passed');
  report.checks.push('Selecting an installed extension opens its real popup and grants activeTab for the current page');
  controls = await siteControls(original.windowId);
  assert.equal(controls.url, url);
  assert.equal(controls.canManagePermissions, true);
  assert.deepEqual(controls.permissions.map(item => item.id), ['clipboard', 'camera', 'microphone', 'autoPictureInPicture']);
  assert.ok(controls.permissions.every(item => ['allow', 'block', 'ask', 'default'].includes(item.setting)));
  const extension = controls.extensions.find(item => item.id === id);
  assert.equal(extension.name, 'Bark Extension Test');
  assert.equal(extension.enabled, true);
  assert.equal(Buffer.from(extension.icon, 'base64').subarray(0, 8).toString('hex'), '89504e470d0a1a0a');
  report.checks.push('Site controls expose real extension icons and current permissions, with no website permissions on internal pages');

  const permission = (value, id = 'clipboard') => value.permissions.find(item => item.id === id);
  assert.equal(permission(controls).editable, true);
  assert.deepEqual(permission(controls).options, ['default', 'ask', 'allow', 'block']);
  const permissionFields = {windowId: original.windowId, id: controls.tabId,
    metadata: {url, permission: 'clipboard'}};
  const originalPermission = permission(controls).setting;
  for (const fields of [
    {id: -1},
    {metadata: {permission: 'clipboard'}},
    {metadata: {url: url + '?stale', permission: 'clipboard'}},
    {metadata: {url, permission: 'not-a-permission'}},
    {text: 'unsupported'},
  ]) {
    await command('setSitePermission', {...permissionFields, text: 'block', ...fields});
  }
  controls = await siteControls(original.windowId);
  assert.equal(permission(controls).setting, originalPermission);
  report.checks.push('Inline permission changes reject wrong tabs, stale or missing URLs, unknown permissions, and invalid settings');

  for (const [setting, expected] of [['block', 'denied'], ['allow', 'granted'], ['ask', 'prompt']]) {
    state = await command('setSitePermission', {...permissionFields, text: setting});
    controls = visible(state).siteControls;
    assert.ok(controls, 'Changing a permission must keep the popover subscription open');
    assert.equal(permission(controls).setting, setting);
    assert.equal(permission(controls).isDefault, false);
    assert.equal(await evaluate(pageSession,
      "navigator.permissions.query({name: 'clipboard-read'}).then(permission => permission.state)"), expected);
  }
  await command('setSitePermission', {...permissionFields, text: 'default'});
  controls = await siteControls(original.windowId);
  assert.equal(permission(controls).isDefault, true);
  assert.equal(permission(controls).setting, originalPermission);
  report.checks.push('Ask, Allow, Block, and Use default update Chromium permissions in place and are visible to the webpage');

  await command('setSitePermission', {...permissionFields, text: 'block'});
  const otherOrigin = url.replace('localhost', '127.0.0.1');
  await command('navigate', {windowId: original.windowId, text: otherOrigin});
  await waitFor(state => visible(state)?.tabs.some(tab => tab.active && tab.url === otherOrigin && !tab.loading), 'second origin');
  controls = await siteControls(original.windowId);
  assert.equal(permission(controls).setting, originalPermission);
  assert.equal(permission(controls).isDefault, true, 'Changing one site must not change the profile default');
  await command('navigate', {windowId: original.windowId, text: url});
  await waitFor(state => visible(state)?.tabs.some(tab => tab.active && tab.url === url && !tab.loading), 'return to permission origin');
  controls = await siteControls(original.windowId);
  assert.equal(permission(controls).setting, 'block', 'Site exceptions survive navigation');
  await command('setSitePermission', {...permissionFields, text: 'default'});
  report.checks.push('Permission exceptions persist for the selected origin without leaking to another origin or changing global defaults');

  const clickFixture = path.join(reports, 'click-fixture');
  fs.mkdirSync(clickFixture);
  fs.writeFileSync(path.join(clickFixture, 'manifest.json'), JSON.stringify({
    manifest_version: 3, name: 'Click Action Test', version: '1.0',
    permissions: ['activeTab', 'scripting'], action: {}, background: {service_worker: 'worker.js'},
  }));
  fs.writeFileSync(path.join(clickFixture, 'worker.js'),
    "chrome.action.onClicked.addListener(tab => chrome.scripting.executeScript({target: {tabId: tab.id}, func: () => { document.title = 'Menu click action passed'; }}));");
  const {id: clickId} = await browser.send('Extensions.loadUnpacked', {path: clickFixture});
  await command('testActivateWindow', {windowId: original.windowId});
  await waitMenu(original.windowId, value => actions(value).some(item => item.action === clickId && item.enabled), 'click action appears');
  await menu(original.windowId, clickId);
  await expectTitle(browser, pageSession, 'Menu click action passed');
  report.checks.push('Extensions with an onClicked action work as well as extensions with popups');
  await evaluate(pageSession, "document.title = 'Waiting for site controls'");
  controls = await siteControls(original.windowId);
  for (const fields of [
    {id: controls.tabId},
    {id: -1, metadata: {url}},
    {id: controls.tabId, metadata: {url: url + '?old-document'}},
  ]) {
    await command('activateExtension', {windowId: original.windowId, text: clickId, ...fields});
  }
  await delay(250);
  await expectTitle(browser, pageSession, 'Waiting for site controls');
  await command('activateExtension', {windowId: original.windowId, id: controls.tabId, text: clickId, metadata: {url}});
  await expectTitle(browser, pageSession, 'Menu click action passed');
  state = await command('siteControls', {windowId: original.windowId, text: 'close'});
  assert.equal(visible(state).siteControls, undefined, 'Closed popovers stop serializing extension icons');
  report.checks.push('Site-control extension actions work for the current page and reject missing, stale, or wrong-tab context');

  const littleURL = url + '?little-window';
  const littleFields = {windowId: original.windowId, kind: 'little'};
  await command('testExternalLinks', {windowId: original.windowId, urls: [littleURL], littleWindow: true});
  await waitFor(state => visible(state)?.popups.some(p => p.url === littleURL && p.keyWindow), 'Little window for extension action');
  const littleTarget = (await browser.send('Target.getTargets')).targetInfos.find(target => target.type === 'page' && target.url === littleURL);
  assert.ok(littleTarget);
  const {sessionId: littleSession} = await browser.send('Target.attachToTarget', {targetId: littleTarget.targetId, flatten: true});
  await browser.send('Page.enable', {}, littleSession);
  await expectTitle(browser, littleSession, 'Waiting for extension');
  await evaluate(pageSession, "document.title = 'Sidebar page'");
  await command('testPopupControl', {...littleFields, text: 'extensions'});
  let pressed = false;
  for (let attempt = 0; attempt < 50 && !pressed; ++attempt) {
    pressed = (await command('testLittleExtensionMenuItem', {windowId: original.windowId, text: 'Click Action Test'})).pressed;
    if (!pressed) await delay(100);
  }
  assert.ok(pressed, 'The puzzle button opens a menu with an enabled extension action attached to the Little window');
  await expectTitle(browser, littleSession, 'Menu click action passed');
  await expectTitle(browser, pageSession, 'Sidebar page');
  await command('testPopupControl', {...littleFields, text: 'close'});
  await waitFor(state => !visible(state)?.popups.length, 'close Little window after using its extension');
  await command('testActivateWindow', {windowId: original.windowId});
  report.checks.push('The Little window puzzle button opens its extensions menu and its action operates on the Little page.');

  const popupFixture = path.join(reports, 'popup-window-fixture');
  fs.mkdirSync(popupFixture);
  fs.writeFileSync(path.join(popupFixture, 'manifest.json'), JSON.stringify({
    manifest_version: 3, name: 'Popup Window Test', version: '1.0', action: {}, background: {service_worker: 'worker.js'},
  }));
  fs.writeFileSync(path.join(popupFixture, 'window.html'), '<title>Extension window</title><body>Extension window</body>');
  fs.writeFileSync(path.join(popupFixture, 'worker.js'),
    "chrome.action.onClicked.addListener(() => chrome.windows.create({type: 'popup', url: 'window.html', width: 360, height: 480}));");
  const {id: popupId} = await browser.send('Extensions.loadUnpacked', {path: popupFixture});
  const popupURL = `chrome-extension://${popupId}/window.html`;
  await command('testActivateWindow', {windowId: original.windowId});
  await waitMenu(original.windowId, value => actions(value).some(item => item.action === popupId && item.enabled), 'popup window action appears');
  await menu(original.windowId, popupId);
  state = await waitFor(state => visible(state)?.popups.some(p => p.url === popupURL), 'extension popup window');
  const extensionWindow = visible(state).popups.find(p => p.url === popupURL);
  assert.equal(extensionWindow.kind, 'little', 'chrome.windows.create popups use the Little window frame');
  assert.ok(extensionWindow.hasControls, 'Extension popup windows show the Little window header');
  assert.equal(extensionWindow.chromiumToolbarVisible, false);
  await command('testPopupControl', {...littleFields, text: 'close'});
  await waitFor(state => !visible(state)?.popups.length, 'close extension popup window');
  await browser.send('Extensions.uninstall', {id: popupId});
  await waitMenu(original.windowId, value => !actions(value).some(item => item.action === popupId), 'popup window fixture removed');
  await command('testActivateWindow', {windowId: original.windowId});
  report.checks.push('Extension popup windows from chrome.windows.create get the Little window header.');

  await command('createProfile', {windowId: original.windowId, text: 'Other profile'});
  state = await waitFor(state => visible(state)?.spaces.some(space => space.name === 'Other profile'), 'second profile');
  const otherSpace = visible(state).spaces.find(space => space.name === 'Other profile').id;
  await command('space', {windowId: original.windowId, text: otherSpace});
  state = await waitFor(state => visible(state)?.activeSpaceId === otherSpace, 'switch profile');
  await command('testActivateWindow', {windowId: visible(state).windowId});
  items = await menu(visible(state).windowId);
  assert.deepEqual(actions(items), [], 'The other profile must not expose the original profile’s extensions');
  assert.deepEqual((await siteControls(visible(state).windowId)).extensions, [], 'Site controls must follow the active profile');
  await command('space', {windowId: visible(state).windowId, text: original.activeSpaceId});
  await waitFor(state => visible(state)?.windowId === original.windowId, 'return to original profile');
  await command('testActivateWindow', {windowId: original.windowId});
  await waitMenu(original.windowId, value => actions(value).length === 2, 'original extensions return');
  report.checks.push('The menu follows the active window’s profile when switching spaces');

  const workers = await browser.send('Target.getTargets');
  const worker = workers.targetInfos.find(target => target.type === 'service_worker' && target.url.startsWith(`chrome-extension://${id}/`));
  assert.ok(worker);
  const {sessionId: workerSession} = await browser.send('Target.attachToTarget', {targetId: worker.targetId, flatten: true});
  const privateURL = url + '?private';
  await evaluate(workerSession, `chrome.windows.create({incognito: true, url: ${JSON.stringify(privateURL)}}).then(() => true)`);
  state = await waitFor(state => state.windows.some(window => window.incognito && window.visible), 'private window');
  const privateWindow = state.windows.find(window => window.incognito && window.visible);
  await command('testActivateWindow', {windowId: privateWindow.windowId});
  items = await menu(privateWindow.windowId);
  assert.deepEqual(actions(items), [], 'Extensions without Incognito permission must stay out of the private menu');
  assert.deepEqual((await siteControls(privateWindow.windowId)).extensions, [], 'Site controls must also respect Incognito access');
  const privateTargets = await browser.send('Target.getTargets');
  const privatePage = privateTargets.targetInfos.find(target => target.type === 'page' && target.url === privateURL);
  assert.ok(privatePage);
  await browser.send('Target.closeTarget', {targetId: privatePage.targetId});
  await waitFor(state => !state.windows.some(window => window.incognito), 'close private window');
  report.checks.push('Private windows only expose extensions allowed in Incognito');

  await command('testActivateWindow', {windowId: original.windowId});
  await browser.send('Extensions.uninstall', {id: clickId});
  await waitMenu(original.windowId, value => actions(value).length === 1 && actions(value)[0].action === id, 'uninstalled extension disappears');
  await browser.send('Extensions.uninstall', {id});
  items = await waitMenu(original.windowId, value => actions(value).length === 0, 'empty menu after uninstall');
  assert.ok(items.items.some(item => item.action === 'bark.manageExtensions' && item.enabled));
  report.checks.push('The menu refreshes after extension installation and removal without restarting Bark');
  controls = await siteControls(original.windowId);
  assert.deepEqual(controls.extensions, [], 'Uninstalled extensions disappear from site controls too');
  await command('siteSettings', {windowId: original.windowId, id: controls.tabId, metadata: {url: controls.url}});
  state = await waitFor(state => visible(state)?.tabs.some(tab => tab.active && tab.url.startsWith('chrome://settings/content/siteDetails')), 'site permission settings');
  const settingsURL = new URL(visible(state).tabs.find(tab => tab.active).url);
  assert.equal(new URL(settingsURL.searchParams.get('site')).origin, new URL(url).origin);
  report.checks.push('The advanced Site settings action opens Chromium settings for the correct website');
  await browser.close(); browser = null;
  report.passed = true;
  console.log(`${report.checks.length} focused Extensions menu checks passed`);
} catch (error) {
  report.error = error.stack || String(error);
  report.lastState = ui.latest;
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
