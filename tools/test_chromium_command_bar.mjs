#!/usr/bin/env node
// Command availability, origin scoping, and native actions in disposable data.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';
import {Browser, uiDriver, expectTitle} from './test_chromium_browser.mjs';

const root = path.resolve('test-results/chromium-command-bar');
fs.mkdirSync(root, {recursive: true});
const reports = fs.mkdtempSync(path.join(root, 'run-'));
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'bark-command-bar-'));
const driver = path.join(profile, '.bark-ui-driver');
fs.mkdirSync(driver);
const report = {passed: false, checks: []};
let browser;
const visible = state => state.windows.find(window => window.visible && !window.incognito);
const active = state => visible(state)?.tabs.find(tab => tab.active) ?? visible(state)?.favorites?.find(tab => tab.active);
const blanks = state => visible(state).tabs.filter(tab => !tab.pinned && !tab.split && ['about:blank', 'chrome://newtab/'].includes(tab.url));
const ui = uiDriver({directory: () => driver, browser: () => browser});
const {command, waitFor} = ui;
async function suggestions(windowId, text) {
  return visible(await command('testCommandSuggestions', {windowId, text})).commandSuggestions;
}
function fields(item, windowId) {
  assert.ok(item, 'Expected available command');
  return {windowId, id: item.id, text: item.commandID, metadata: {url: item.contextURL,
    space: item.contextSpace, invoker: String(item.invokerID), invokerURL: item.invokerURL}};
}
async function run(item, windowId) { return command('commandBarAction', fields(item, windowId)); }
const server = http.createServer((request, response) => {
  response.writeHead(200, {'Content-Type': 'text/html', 'Cache-Control': 'no-store'});
  response.end(`<title>Page ${new URL(request.url, 'http://localhost').pathname}</title><body>Command bar test</body>`);
});

try {
  assert.equal(process.platform, 'darwin');
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://localhost:${server.address().port}`;
  browser = new Browser(profile, path.join(reports, 'browser.log'), {
    nativeWindow: true, nativeUI: true, loadFixture: false, testDirectory: driver,
  });
  let state = await waitFor(state => !!visible(state)?.activeSpaceId, 'initial window');
  const windowId = visible(state).windowId;
  await command('testActivateWindow', {windowId});
  await waitFor(state => visible(state)?.sidebarPresentation.keyWindow, 'active browser window');
  await command('navigate', {windowId, text: base + '/origin'});
  state = await waitFor(state => active(state)?.url === base + '/origin' && !active(state).loading, 'origin page');
  const origin = active(state).id, sourceSpace = visible(state).activeSpaceId;
  const settings = await suggestions(windowId, 'settings');
  assert.equal(settings[0].commandID, 'settings');
  assert.equal((await suggestions(windowId, '> preferences'))[0].commandID, 'settings');
  assert.equal((await suggestions(windowId, '> archive'))[0].commandID, 'archive');
  assert.deepEqual(await suggestions(windowId, '> no-such-action-9'), []);
  report.checks.push('Commands match titles and aliases, with exact actions ranked first');

  let pin = (await suggestions(windowId, 'pin tab')).find(item => item.commandID === 'pin');
  const bad = fields(pin, windowId);
  await command('commandBarAction', {...bad, metadata: {...bad.metadata, url: base + '/stale'}});
  state = await command();
  assert.equal(active(state).pinned, false);
  await run(pin, windowId);
  state = await waitFor(state => active(state)?.id === origin && active(state).pinned, 'pin action');
  await run(pin, windowId);
  assert.equal(active(await command()).pinned, true, 'A stale Pin row cannot become Unpin');
  await run((await suggestions(windowId, '> undo'))[0], windowId);
  await waitFor(state => active(state)?.id === origin && !active(state).pinned, 'undo pin');
  report.checks.push('Pin and Undo operate on real tabs and reject stale page or toggle state');

  await command('testNewTab', {windowId, count: 10});
  state = await command();
  assert.equal(active(state).id, origin);
  assert.equal(blanks(state).length, 0);
  pin = (await suggestions(windowId, '> pin')).find(item => item.commandID === 'pin');
  assert.equal(pin?.id, origin);
  assert.equal(pin.invokerID, origin);
  await run(pin, windowId);
  state = await waitFor(state => active(state)?.id === origin && active(state).pinned, 'pin originating page');
  assert.equal(visible(state).tabs.length, 1);
  await run((await suggestions(windowId, '> unpin'))[0], windowId);
  await waitFor(state => active(state)?.id === origin && !active(state).pinned, 'unpin origin');
  report.checks.push('A Cmd+T command acts on the current page without allocating a tab');

  await command('testNewTab', {windowId});
  const oldPin = (await suggestions(windowId, '> pin')).find(item => item.commandID === 'pin');
  await command('testFocusAddress', {windowId});
  await command('navigate', {windowId, text: base + '/edited'});
  state = await waitFor(state => active(state)?.url === base + '/edited' && !active(state).loading, 'Cmd+L in-place edit');
  assert.equal(active(state).id, origin);
  await run(oldPin, windowId);
  assert.equal(active(await command()).pinned, false, 'A stale action cannot act on the replacement document');

  await command('testNewTab', {windowId});
  await command('testOpenAddressSuggestion', {windowId, suggestion: {kind: 'history', title: 'Destination', url: base + '/destination'}});
  state = await waitFor(state => active(state)?.url === base + '/destination' && !active(state).loading, 'compose destination');
  assert.notEqual(active(state).id, origin);
  assert.equal(visible(state).tabs.length, 2);
  assert.equal(visible(state).tabs.find(tab => tab.id === origin).url, base + '/edited');
  report.checks.push('Cmd+L edits the current page and selecting a URL suggestion from Cmd+T opens a separate page');

  await command('select', {windowId, id: origin});
  await command('createSpace', {windowId, text: 'Command destination', metadata: {profile: visible(state).profileId}});
  state = await waitFor(state => visible(state)?.activeSpaceId !== sourceSpace, 'destination space');
  const destination = visible(state).activeSpaceId;
  await command('space', {windowId, text: sourceSpace});
  await command('select', {windowId, id: origin});
  const move = (await suggestions(windowId, '> move command destination')).find(item => item.commandID === 'move:' + destination);
  await run(move, windowId);
  await command('space', {windowId, text: destination});
  state = await waitFor(state => visible(state)?.tabs.some(tab => tab.id === origin), 'moved origin');
  report.checks.push('Move to Space acts on the selected destination in the current profile');

  await command('select', {windowId, id: origin});
  const {id} = await browser.send('Extensions.loadUnpacked', {path: path.resolve('tools/fixtures/extension')});
  let extension;
  for (let i = 0; i < 100 && !extension; i++) {
    extension = (await suggestions(windowId, '> bark extension')).find(item => item.commandID === 'extension:' + id);
    if (!extension) await delay(100);
  }
  assert.ok(extension);
  await command('navigate', {windowId, text: base + '/extension'});
  await waitFor(state => active(state)?.url === base + '/extension' && !active(state).loading, 'extension page');
  await run(extension, windowId);
  assert.equal(active(await command()).title, 'Page /extension', 'A stale extension action cannot target the replacement page');
  await command('testActivateWindow', {windowId});
  await command('testFocusAddress', {windowId});
  extension = (await suggestions(windowId, '> bark extension')).find(item => item.commandID === 'extension:' + id);
  assert.ok(extension, 'The current page offers the installed extension action');
  await command('testOpenAddressSuggestion', {windowId, suggestion: extension});
  const targets = await browser.send('Target.getTargets');
  const target = targets.targetInfos.find(target => target.type === 'page' && target.url === base + '/extension');
  const {sessionId} = await browser.send('Target.attachToTarget', {targetId: target.targetId, flatten: true});
  await expectTitle(browser, sessionId, 'Extension action passed');
  report.checks.push('Named extension commands execute real actions and reject stale originating pages');

  await browser.close(); browser = null;
  report.passed = true;
  console.log(`${report.checks.length} command-bar checks passed`);
} catch (error) {
  report.error = error.stack || String(error); report.lastState = ui.latest; report.preservedProfile = profile;
  if (browser && !browser.exited) {
    try {
      const {targetInfos} = await browser.send('Target.getTargets');
      report.targets = targetInfos;
      report.extensionDocuments = [];
      for (const target of targetInfos.filter(target => target.url.startsWith('chrome-extension://') && target.type !== 'service_worker')) {
        const {sessionId} = await browser.send('Target.attachToTarget', {targetId: target.targetId, flatten: true});
        const value = await browser.send('Runtime.evaluate', {expression: 'document.body?.innerText', returnByValue: true}, sessionId);
        report.extensionDocuments.push({url: target.url, body: value.result?.value, exception: value.exceptionDetails});
      }
    } catch (diagnosticError) { report.diagnosticError = String(diagnosticError); }
  }
  console.error(error); process.exitCode = 1;
} finally {
  if (browser) await browser.close().catch(error => { report.shutdownError = String(error); });
  server.closeAllConnections(); await new Promise(resolve => server.close(resolve));
  fs.writeFileSync(path.join(reports, 'report.json'), JSON.stringify(report, null, 2) + '\n');
  if (report.passed) fs.rmSync(profile, {recursive: true, force: true});
  console.log('Reports:', reports);
}
