#!/usr/bin/env node
// Native checks for organizing Bark tabs and sidebar folders.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import {Browser, uiDriver} from './test_chromium_browser.mjs';

const resultRoot = path.resolve('test-results/chromium-organization');
fs.mkdirSync(resultRoot, {recursive: true});
const reports = fs.mkdtempSync(path.join(resultRoot, 'run-'));
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'bark-organization-test-'));
const driver = path.join(profile, '.bark-ui-driver');
fs.mkdirSync(driver);
const report = {passed: false, checks: []};
let browser;
const visible = state => state.windows.find(window => window.visible && !window.incognito);
const ui = uiDriver({directory: () => driver, browser: () => browser, reports});
const {command, waitFor} = ui;
function launch(name) {
  for (const file of ['request.json', 'response.json']) fs.rmSync(path.join(driver, file), {force: true});
  return new Browser(profile, path.join(reports, name + '.log'), {
    nativeWindow: true, nativeUI: true, loadFixture: false, testDirectory: driver, profileDirectory: null,
  });
}
const server = http.createServer((request, response) => {
  const url = new URL(request.url, 'http://localhost');
  const port = server.address().port;
  response.writeHead(200, {'Content-Type': 'text/html', 'Cache-Control': 'no-store'});
  const links = `<a id="same" href="/inside">Same site</a> <a id="other" href="http://localhost:${port}/peek">Other site</a>`;
  response.end(`<title>Page ${url.pathname}</title><link rel="icon" href="data:,"><body>${links}</body>`);
});

try {
  assert.equal(process.platform, 'darwin');
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const tabWith = (state, suffix) => visible(state)?.tabs.find(tab => tab.url === base + suffix);
  const open = async suffix => {
    await browser.send('Target.createTarget', {url: base + suffix});
    return waitFor(state => tabWith(state, suffix) && !tabWith(state, suffix).loading, 'open ' + suffix);
  };
  const space = state => visible(state).spaces.find(space => space.active);
  const folders = state => space(state).folders ?? [];
  browser = launch('organization');
  let state = await waitFor(state => !!visible(state)?.activeSpaceId, 'initial window');
  let windowId = visible(state).windowId;
  state = await open('/nested');
  const nested = tabWith(state, '/nested').id;
  await command('newFolder', {windowId, text: 'Research'});
  state = await waitFor(state => folders(state).some(folder => folder.name === 'Research'), 'root folder');
  const root = folders(state).find(folder => folder.name === 'Research').id;
  await command('toggleFolder', {windowId, metadata: {folder: root}});
  await waitFor(state => folders(state).find(folder => folder.id === root).collapsed === true, 'collapsed parent');
  await command('newFolder', {windowId, text: 'Reading', metadata: {parent: root}});
  state = await waitFor(state => folders(state).some(folder => folder.parent === root), 'nested folder');
  assert.equal(folders(state).find(folder => folder.id === root).collapsed, false, 'Nested creation reveals its parent for inline naming');
  await command('undoOrganization', {windowId});
  state = await waitFor(state => folders(state).length === 1, 'undo nested creation');
  assert.equal(folders(state)[0].collapsed, true, 'Undo restores parent collapse together with removing the new child');
  await command('newFolder', {windowId, text: 'Reading', metadata: {parent: root}});
  state = await waitFor(state => folders(state).some(folder => folder.parent === root), 'recreate nested folder');
  report.checks.push('Nested creation expands collapsed ancestry; one Undo restores both hierarchy and collapse');
  const child = folders(state).find(folder => folder.name === 'Reading').id;
  await command('moveToFolder', {windowId, id: nested, metadata: {folder: child}});
  state = await waitFor(state => tabWith(state, '/nested')?.folder === child, 'nested tab');
  await command('moveFolder', {windowId, metadata: {folder: root, parent: child}});
  state = await command();
  assert.equal(folders(state).find(folder => folder.id === root).parent, undefined, 'Cycle rejected');
  await command('moveFolder', {windowId, metadata: {folder: child, parent: child}});
  await command('moveFolder', {windowId, metadata: {folder: child, parent: 'missing'}});
  state = await command();
  assert.equal(folders(state).find(folder => folder.id === child).parent, root, 'Self and missing-parent moves rejected');
  report.checks.push('Nested folder storage pins the real tab and rejects cycles, self-parenting, and missing parents');

  await command('deleteFolder', {windowId, metadata: {folder: root}});
  state = await waitFor(state => folders(state).length === 1, 'delete parent');
  assert.equal(folders(state)[0].parent, undefined, 'Children promoted without losing tabs');
  assert.equal(tabWith(state, '/nested').folder, child);
  await command('undoOrganization', {windowId});
  state = await waitFor(state => folders(state).length === 2 && folders(state).find(folder => folder.id === child).parent === root, 'undo folder deletion');
  report.checks.push('Deleting a parent promotes children; Undo restores the hierarchy');

  await command('renameTab', {windowId, id: nested, text: 'Saved title'});
  state = await waitFor(state => tabWith(state, '/nested')?.customTitle === 'Saved title', 'rename');
  const {targetInfos} = await browser.send('Target.getTargets');
  const target = targetInfos.find(info => info.type === 'page' && info.url === base + '/nested');
  const {sessionId} = await browser.send('Target.attachToTarget', {targetId: target.targetId, flatten: true});
  await browser.send('Page.navigate', {url: base + '/navigated'}, sessionId);
  await waitFor(state => tabWith(state, '/navigated') && !tabWith(state, '/navigated').loading, 'navigate after rename');
  await command('undoOrganization', {windowId});
  state = await waitFor(state => tabWith(state, '/navigated') && !tabWith(state, '/navigated').customTitle, 'undo rename');
  assert.equal(tabWith(state, '/navigated').id, nested, 'Undo preserves live tab identity');
  report.checks.push('Undo rename preserves navigation and live WebContents');

  await command('pin', {windowId, id: nested});
  await waitFor(state => !tabWith(state, '/navigated')?.pinned, 'unpin');
  await command('undoOrganization', {windowId});
  state = await waitFor(state => tabWith(state, '/navigated')?.pinned && tabWith(state, '/navigated').folder === child, 'undo unpin');
  report.checks.push('Undo unpin restores the pin and its folder');

  state = await open('/closed');
  const closed = tabWith(state, '/closed').id;
  await command('renameTab', {windowId, id: closed, text: 'Rename only'});
  await waitFor(state => tabWith(state, '/closed')?.customTitle === 'Rename only', 'rename before external reorder');
  state = await open('/neighbor');
  await command('testReorderTab', {windowId, id: closed, index: visible(state).allTabs.length - 1});
  state = await command();
  const externallyOrdered = visible(state).allTabs.map(tab => tab.id);
  await command('undoOrganization', {windowId});
  state = await waitFor(state => !tabWith(state, '/closed')?.customTitle, 'undo rename after external reorder');
  assert.deepEqual(visible(state).allTabs.map(tab => tab.id), externallyOrdered, 'Undo rename must not revert native/extension tab ordering');
  report.checks.push('Undo rename leaves later native tab reordering intact');
  await command('renameTab', {windowId, id: closed, text: 'Will close'});
  await waitFor(state => tabWith(state, '/closed')?.customTitle === 'Will close', 'rename before close');
  await command('close', {windowId, id: closed});
  await waitFor(state => !tabWith(state, '/closed'), 'close tab');
  await command('undoOrganization', {windowId});
  state = await command();
  assert.ok(!visible(state).allTabs.some(tab => tab.id === closed), 'Organization Undo never reopens closed tabs');
  report.checks.push('Undo skips closed tabs instead of resurrecting browsing state');

  await command('togglePinnedSection', {windowId, metadata: {space: 'previous-space'}});
  state = await command();
  assert.ok(!space(state).pinsCollapsed, 'A click from the previous Space must not collapse the current Space');
  await command('togglePinnedSection', {windowId, metadata: {space: space(state).id}});
  await waitFor(state => space(state).pinsCollapsed === true, 'collapse pins');
  await browser.close(); browser = null;
  browser = launch('restored');
  state = await waitFor(state => !!visible(state)?.activeSpaceId && folders(state).length === 2, 'restore folders');
  windowId = visible(state).windowId;
  assert.equal(space(state).pinsCollapsed, true);
  assert.equal(folders(state).find(folder => folder.id === child).parent, root);
  report.checks.push('Nested hierarchy and collapsed pinned section survive restart');

  state = await open('/archive-one');
  state = await open('/archive-two');
  await command('archiveTabs', {windowId});
  state = await waitFor(state => visible(state).archivedTabs.some(tab => tab.url === base + '/archive-two'), 'archive');
  const archived = visible(state).archivedTabs;
  const openingSpace = space(state).id;
  const archivedURLs = archived.map(tab => tab.url);
  for (const action of ['restoreAllArchived', 'clearArchive']) {
    await command(action, {windowId, metadata: {space: 'stale-opening-space'}});
    state = await command();
    assert.deepEqual(visible(state).archivedTabs.map(tab => tab.url), archivedURLs,
      `${action} rejects a stale opening space`);
    assert.ok(!tabWith(state, '/archive-one') && !tabWith(state, '/archive-two'),
      'Stale bulk commands neither reopen nor erase archive entries');
    await command(action, {windowId, metadata: {}});
    state = await command();
    assert.deepEqual(visible(state).archivedTabs.map(tab => tab.url), archivedURLs,
      `${action} rejects incomplete sheet scope`);
  }
  report.checks.push('Bulk archive actions reject stale or incomplete opening-space scope');
  const index = archived.findIndex(tab => tab.url === base + '/archive-two');
  await command('restoreArchived', {windowId, id: index, metadata: {space: space(state).id, title: archived[index].title, url: base + '/wrong'}});
  state = await command();
  assert.ok(!tabWith(state, '/archive-two'), 'Stale archive selection rejected');
  await command('restoreArchived', {windowId, id: index, metadata: {space: space(state).id, title: archived[index].title, url: archived[index].url}});
  await waitFor(state => !!tabWith(state, '/archive-two'), 'restore exact selected result');
  report.checks.push('Search-result restore is scoped to the exact space, title, and URL');
  await command('restoreAllArchived', {windowId, metadata: {space: openingSpace}});
  state = await waitFor(state => visible(state).archivedTabs.length === 0 && !!tabWith(state, '/archive-one'), 'scoped restore all');
  await command('archiveTabs', {windowId});
  state = await waitFor(state => visible(state).archivedTabs.length > 0, 'archive for scoped clear');
  await command('clearArchive', {windowId, metadata: {space: openingSpace}});
  await waitFor(state => visible(state).archivedTabs.length === 0, 'scoped clear');
  report.checks.push('Matching opening-space scope restores all or clears the intended archive');
  report.passed = true;
} finally {
  if (browser) await browser.close();
  server.close();
  fs.writeFileSync(path.join(reports, 'report.json'), JSON.stringify(report, null, 2));
  console.log(JSON.stringify({reports, ...report}, null, 2));
  if (report.passed) fs.rmSync(profile, {recursive: true, force: true});
}
