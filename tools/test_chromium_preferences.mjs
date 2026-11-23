#!/usr/bin/env node
// Native preferences edit Chromium's real profile settings in a disposable profile.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {Browser, uiDriver} from './test_chromium_browser.mjs';

const root = path.resolve('test-results/chromium-preferences');
fs.mkdirSync(root, {recursive: true});
const reports = fs.mkdtempSync(path.join(root, 'run-'));
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'bark-preferences-'));
const driver = path.join(profile, '.bark-ui-driver');
const downloads = path.join(profile, 'chosen-downloads');
fs.mkdirSync(driver); fs.mkdirSync(downloads);
const report = {passed: false, checks: []};
let browser;
const visible = state => state.windows.find(window => window.visible && !window.incognito);
const ui = uiDriver({directory: () => driver, browser: () => browser});
const {command, waitFor} = ui;
function launch(name) {
  for (const file of ['request.json', 'response.json']) fs.rmSync(path.join(driver, file), {force: true});
  return new Browser(profile, path.join(reports, name + '.log'), {
    nativeWindow: true, nativeUI: true, loadFixture: false, testDirectory: driver,
  });
}
try {
  assert.equal(process.platform, 'darwin');
  browser = launch('first');
  let state = await waitFor(state => !!visible(state)?.activeSpaceId, 'initial window');
  let window = visible(state);
  const count = window.tabs.length;
  await command('settings', {windowId: window.windowId});
  state = await waitFor(state => visible(state)?.preferences?.searchLoaded, 'native preferences');
  window = visible(state);
  assert.equal(window.tabs.length, count, 'Opening native Settings does not create a browser tab');
  assert.ok(window.preferences.searchEngines.length > 1);
  report.checks.push('Settings opens the native preferences surface without adding a tab and exposes the actual profile search engines');
  const initialEngine = window.preferences.searchEngine;
  const initialPath = window.preferences.downloadPath;
  const initialAsk = window.preferences.askDownload;
  const fields = key => ({windowId: window.windowId, metadata: {key, profile: window.profileId}});
  for (const invalid of [
    {...fields('searchEngine'), text: 'missing'},
    {...fields('askDownload'), text: 'yes'},
    {...fields('askDownload'), text: 'on', metadata: {key: 'askDownload', profile: 'different-profile'}},
    {...fields('downloadPath'), text: 'relative/path'},
    {...fields('downloadPath'), text: downloads, metadata: {key: 'downloadPath'}},
  ]) await command('setPreference', invalid);
  state = await command();
  assert.equal(visible(state).preferences.searchEngine, initialEngine);
  assert.equal(visible(state).preferences.downloadPath, initialPath);
  assert.equal(visible(state).preferences.askDownload, initialAsk);
  report.checks.push('Preference edits reject invalid values and missing or stale profile context');
  await command('setPreference', {...fields('downloadPath'), text: downloads});
  await command('setPreference', {...fields('askDownload'), text: initialAsk ? 'off' : 'on'});
  state = await waitFor(state => visible(state)?.preferences?.downloadPath === downloads &&
    visible(state).preferences.askDownload === !initialAsk, 'download preferences changed');
  const knownEngines = [['duckduckgo', 'duckduckgo.com'], ['bing', 'www.bing.com'], ['google', 'www.google.com']];
  const target = knownEngines.map(([name, host]) => ({host, engine: window.preferences.searchEngines.find(engine =>
    engine.name.toLowerCase().includes(name) && engine.id !== initialEngine)})).find(item => item.engine);
  assert.ok(target, 'The pinned Chromium engine catalog must offer an alternate default provider');
  await command('setPreference', {...fields('searchEngine'), text: target.engine.id});
  await waitFor(state => visible(state)?.preferences?.searchEngine === target.engine.id, 'default search changed');
  await command('navigate', {windowId: window.windowId, text: 'bark native preferences test'});
  state = await waitFor(state => {
    const tab = visible(state)?.tabs.find(tab => tab.active);
    try { return tab && new URL(tab.url).hostname === target.host; } catch { return false; }
  }, 'search uses chosen engine');
  report.checks.push('Typed searches use the selected engine; download folder and ask-before-saving update the real profile preferences');
  await command('preferencesState', {windowId: window.windowId, text: 'close'});
  await browser.close(); browser = null;

  browser = launch('restart');
  state = await waitFor(state => !!visible(state)?.activeSpaceId, 'restart window');
  window = visible(state);
  await command('preferencesState', {windowId: window.windowId, text: 'open'});
  state = await waitFor(state => visible(state)?.preferences?.searchLoaded, 'restored preferences');
  assert.equal(visible(state).preferences.searchEngine, target.engine.id);
  assert.equal(visible(state).preferences.downloadPath, downloads);
  assert.equal(visible(state).preferences.askDownload, !initialAsk);
  report.checks.push('Search and download preferences persist across a browser restart');
  await command('advancedSettings', {windowId: window.windowId, text: 'privacy'});
  await waitFor(state => visible(state)?.tabs.some(tab => tab.active && tab.url === 'chrome://settings/privacy'), 'advanced settings route');
  report.checks.push('Advanced privacy controls still open the full Chromium settings page');
  await command('showFactoryReset', {windowId: window.windowId});
  await waitFor(state => visible(state)?.tabs.some(tab => tab.active &&
    tab.url === 'chrome://spaces/#factory-reset'), 'factory reset confirmation route');
  report.checks.push('General settings opens the confirmation for resetting every profile');
  const onlyProfile = window.profileId;
  await command('deleteProfile', {windowId: window.windowId, text: '../Default'});
  assert.equal(visible(await command()).profiles[0].id, onlyProfile);
  await command('deleteProfile', {windowId: window.windowId, text: onlyProfile});
  state = await waitFor(state => visible(state)?.activeSpaceId && visible(state).profileId !== onlyProfile &&
    visible(state).profiles.length === 1, 'new profile after deleting the last profile');
  assert.ok(visible(state).spaces.every(space => space.profile === visible(state).profileId));
  report.checks.push('Unknown profile IDs are ignored and deleting the only profile opens a fresh profile and Space');
  await browser.close(); browser = null;
  report.passed = true;
  console.log(`${report.checks.length} focused native preferences checks passed`);
} catch (error) {
  report.error = error.stack || String(error);
  report.lastState = ui.latest;
  report.preservedProfile = profile;
  console.error(error);
  process.exitCode = 1;
} finally {
  if (browser) await browser.close().catch(error => { report.shutdownError = String(error); });
  fs.writeFileSync(path.join(reports, 'report.json'), JSON.stringify(report, null, 2) + '\n');
  if (report.passed) fs.rmSync(profile, {recursive: true, force: true});
  console.log('Reports:', reports);
}
