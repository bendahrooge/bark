#!/usr/bin/env node
// Bark import bridge, with disposable profiles and loopback-only tabs.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
import {setTimeout as delay} from 'node:timers/promises';
import {Browser} from './test_chromium_browser.mjs';

const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'bark-import-test-'));
const driver = path.join(profile, '.bark-ui-driver');
fs.mkdirSync(driver);
const reports = path.resolve('test-results/chromium-bark-import');
fs.mkdirSync(reports, {recursive: true});
let sequence = 0, browser, passed = false;
async function command(action = 'snapshot', fields = {}) {
  const requestId = ++sequence;
  fs.writeFileSync(path.join(driver, 'request.tmp'), JSON.stringify({action, requestId, ...fields}));
  fs.renameSync(path.join(driver, 'request.tmp'), path.join(driver, 'request.json'));
  for (let i = 0; i < 400; i++) {
    try {
      const state = JSON.parse(fs.readFileSync(path.join(driver, 'response.json')));
      if (state.requestId === requestId) return state;
    } catch (error) { if (error.code !== 'ENOENT' && !(error instanceof SyntaxError)) throw error; }
    await delay(50);
  }
  throw Error('Timed out: ' + action);
}
async function waitFor(predicate, label) {
  for (let i = 0; i < 300; i++) {
    const state = await command();
    if (predicate(state)) return state;
    await delay(100);
  }
  throw Error('Timed out: ' + label);
}
function visible(state) { return state.windows.find(window => window.visible && !window.incognito); }
function launch(name) {
  for (const name of ['request.json', 'response.json']) fs.rmSync(path.join(driver, name), {force: true});
  return new Browser(profile, path.join(reports, name + '.log'), {
    nativeWindow: true, nativeUI: true, loadFixture: false, testDirectory: driver, profileDirectory: null,
  });
}
const server = http.createServer((_, response) => {
  response.writeHead(200, {'Content-Type': 'text/html'});
  response.end('<title>Bark import fixture</title><body>Imported tab</body>');
});
try {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const time = Date.now() - 3600000;
  const history = (title, suffix) => ({title, url: base + suffix, visitedAt: time});
  const tab = (id, pinned) => ({id, title: id, url: base + '/' + id, pinned});
  const payload = {
    request: 'fixture-import',
    profiles: [
      {source: 'source-personal', name: 'Imported — Personal', extensions: 1,
        spaces: [{id: 'source-research', name: 'Research', theme: 'ocean', emoji: '🔬', tabs: [tab('pin', true), tab('today', false)]}],
        bookmarks: [
          {id: 'folder', parent: '', title: 'Reading'},
          {id: 'nested', parent: 'folder', title: 'Nested'},
          {id: 'bookmark', parent: 'nested', title: 'Saved article', url: base + '/article'},
          {id: 'extensions', parent: '', title: 'Extensions to reinstall'},
          {id: 'extension/' + 'a'.repeat(32), parent: 'extensions', title: 'Example extension (disabled in source browser)', url: 'https://chromewebstore.google.com/detail/' + 'a'.repeat(32)},
        ],
        history: [history('Personal history', '/personal-history'), {...history('Expired', '/expired'), visitedAt: 1000}],
      },
      {source: 'source-work', name: 'Imported — Work', extensions: 0,
        spaces: [{id: 'source-work-space', name: 'Work', theme: 'clay', emoji: '💼', tabs: [tab('work', true)]}],
        bookmarks: [], history: [history('Work history', '/work-history')]},
    ],
  };
  browser = launch('import');
  let state = await waitFor(state => !!visible(state)?.activeSpaceId, 'initial window');
  let current = visible(state);
  const originalProfile = current.profileId, originalSpace = current.activeSpaceId;
  const windowId = current.windowId;
  const bad = structuredClone(payload);
  bad.request = 'invalid'; bad.profiles[1].spaces[0].tabs[0].url = 'file:///private/data';
  await command('importBrowserData', {windowId, text: JSON.stringify(bad)});
  state = await waitFor(state => visible(state)?.browserImportResult?.request === bad.request, 'invalid result');
  assert.equal(visible(state).browserImportResult.success, false);
  assert.equal(visible(state).profiles.length, 1, 'Reject the entire invalid request before creating profiles');
  assert.equal(visible(state).spaces.length, 1);

  await command('importBrowserData', {windowId, text: JSON.stringify(payload)});
  state = await waitFor(state => visible(state)?.browserImportResult?.request === payload.request, 'import result');
  current = visible(state);
  assert.equal(current.browserImportResult.success, true, JSON.stringify(current.browserImportResult));
  for (const [key, count] of Object.entries({profiles: 2, spaces: 2, tabs: 3, history: 2, bookmarks: 5, extensions: 1, expiredHistory: 1}))
    assert.equal(current.browserImportResult[key], count, key);
  assert.equal(current.activeSpaceId, originalSpace, 'Import preserves the current space and browser session');
  assert.equal(state.windows.length, 1, 'Import opens no windows or sites');
  assert.equal(current.allTabs.length, 1);
  assert.equal(current.profiles.length, 3);
  assert.equal(current.spaces.length, 3, 'Profile creation must not add empty spaces ahead of the imported spaces');
  const personalProfile = current.spaces.find(space => space.id === 'source-research').profile;
  const workProfile = current.spaces.find(space => space.id === 'source-work-space').profile;
  assert.notEqual(personalProfile, workProfile); assert.notEqual(personalProfile, originalProfile);

  await command('customizeSpace', {windowId, metadata: {space: 'source-research', name: 'My research', theme: 'mint', emoji: '🌱'}});
  payload.request = 'retry';
  await command('importBrowserData', {windowId, text: JSON.stringify(payload)});
  state = await waitFor(state => visible(state)?.browserImportResult?.request === payload.request, 'retry result');
  assert.equal(visible(state).browserImportResult.success, true);
  assert.equal(visible(state).spaces.find(space => space.id === 'source-research').name, 'My research', 'Retry preserves user customization');
  for (const key of ['profiles', 'spaces', 'tabs', 'history', 'bookmarks', 'extensions']) assert.equal(visible(state).browserImportResult[key], 0, 'Retry: ' + key);
  await command('space', {windowId, text: 'source-research'});
  // A newly opened Chromium profile also has its normal starter New Tab.
  // Count imported URLs separately; importing must not remove existing tabs.
  const importedURLs = [base + '/pin', base + '/today'];
  state = await waitFor(state => visible(state)?.activeSpaceId === 'source-research' &&
    visible(state).tabs.filter(tab => importedURLs.includes(tab.url)).length === 2, 'imported tabs');
  assert.ok(visible(state).tabs.every(tab => importedURLs.includes(tab.url) || ['chrome://newtab/', 'about:blank'].includes(tab.url)));
  assert.ok(visible(state).tabs.some(tab => tab.url === base + '/pin' && tab.pinned));
  assert.ok(visible(state).tabs.some(tab => tab.url === base + '/today' && !tab.pinned));
  await delay(1000);
  await browser.close(); browser = null;

  function bookmarks(directory) { return JSON.parse(fs.readFileSync(path.join(profile, directory, 'Bookmarks'))); }
  const saved = bookmarks(personalProfile);
  const imported = saved.roots.other.children.find(node => node.name === 'Imported bookmarks');
  assert.equal(imported.children.find(node => node.name === 'Reading').children[0].children[0].url, base + '/article');
  assert.equal(imported.children.find(node => node.name === 'Extensions to reinstall').children.length, 1);
  const query = `import sqlite3,json,sys\nc=sqlite3.connect(sys.argv[1])\nprint(json.dumps(c.execute('SELECT urls.url,COUNT(*) FROM visits JOIN urls ON visits.url=urls.id GROUP BY urls.url').fetchall()))`;
  function historyRows(directory) { return new Map(JSON.parse(execFileSync('python3', ['-c', query, path.join(profile, directory, 'History')], {encoding: 'utf8'}))); }
  assert.equal(historyRows(personalProfile).get(base + '/personal-history'), 1);
  assert.equal(historyRows(personalProfile).has(base + '/work-history'), false);
  assert.equal(historyRows(workProfile).get(base + '/work-history'), 1);
  assert.equal(historyRows(workProfile).has(base + '/personal-history'), false);

  browser = launch('restart');
  state = await waitFor(state => !!visible(state)?.spaces.some(space => space.id === 'source-work-space'), 'restart');
  await command('space', {windowId: visible(state).windowId, text: 'source-work-space'});
  state = await waitFor(state => visible(state)?.activeSpaceId === 'source-work-space' && visible(state).tabs.some(tab => tab.url === base + '/work'), 'pending tabs after restart');
  assert.equal(visible(state).profileId, workProfile);
  assert.equal(visible(state).tabs.filter(tab => tab.url === base + '/work').length, 1);
  await browser.close(); browser = null;
  fs.writeFileSync(path.join(reports, 'result.json'), JSON.stringify({passed: true, checks: [
    'Invalid requests do not change profiles or spaces',
    'Two source profiles import into isolated Bark profiles without opening sites',
    'Retry adds no duplicate profiles, spaces, tabs, bookmarks, extension links or history visits',
    'Nested folders and extension reinstall links are persisted in bookmarks',
    'Native history preserves timestamps and profile isolation',
    'Pending tabs survive restart and open in the correct space with pin state',
  ]}, null, 2));
  passed = true;
  console.log('Bark import browser checks passed');
} finally {
  if (browser) await browser.close();
  server.close();
  // Keep failed fixtures with the logs; remove successful test profiles.
  if (passed) fs.rmSync(profile, {recursive: true, force: true});
  else console.error('Failed test profile:', profile);
}
