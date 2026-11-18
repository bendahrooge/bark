#!/usr/bin/env node
// Chromium notification banners must never occupy Bark's page layout.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';
import {Browser} from './test_chromium_browser.mjs';

const root = path.resolve('test-results/chromium-notification-banners');
fs.mkdirSync(root, {recursive: true});
const reports = fs.mkdtempSync(path.join(root, 'run-'));
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'bark-no-banners-'));
const driver = path.join(profile, '.bark-ui-driver');
fs.mkdirSync(driver);
const report = {passed: false, checks: []};
let browser, latest, sequence = 0;
const visible = state => state.windows.find(window => window.visible);
const active = window => window.tabs.find(tab => tab.active);
const bounds = window => window.allTabs.find(tab => tab.id === active(window)?.id)?.contentBounds;
const hidden = window => window?.sidebarPresentation.notificationBannerVisible === false &&
  window.sidebarPresentation.notificationBannerHeight === 0;
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
function launch(name, incognito = false) {
  for (const file of ['request.json', 'response.json']) fs.rmSync(path.join(driver, file), {force: true});
  return new Browser(profile, path.join(reports, name + '.log'), {
    nativeWindow: true, nativeUI: true, loadFixture: false, testDirectory: driver,
    extraFlags: incognito ? ['--incognito'] : [],
    initialURL: 'data:text/html,<title>Banner test</title><body>Full page area</body>',
  });
}
try {
  assert.equal(process.platform, 'darwin');
  browser = launch('normal');
  let state = await waitFor(state => !!visible(state)?.activeSpaceId && active(visible(state))?.title === 'Banner test' && !active(visible(state)).loading, 'initial page');
  const original = visible(state);
  const windowId = original.windowId;
  const originalBounds = bounds(original);
  state = await command('testDefaultBrowserPrompt', {windowId});
  assert.equal(state.defaultPromptShown, false);
  assert.equal(state.defaultPromptSurfaceCreated, false);
  assert.ok(hidden(visible(state)));
  report.checks.push('The default-browser promo is rejected before its banner, bubble, or dialog is created');

  // Bypass the prompt manager to exercise an actual late-created Chromium
  // infobar. Hiding only the startup promo is insufficient for this case.
  await command('testNotificationBanner', {windowId});
  state = await waitFor(state => visible(state)?.sidebarPresentation.notificationBannerPresent && hidden(visible(state)), 'late banner stays hidden');
  assert.deepEqual(bounds(visible(state)), originalBounds, 'Notification banners must not shrink or move the webpage');
  assert.deepEqual(visible(state).notices, [], 'Default-browser promos must not reappear as native notices');
  report.checks.push('A real Chromium banner added after startup is invisible and reserves zero page height');

  await command('createSpace', {windowId, text: 'Other space', metadata: {profile: original.profileId, emoji: '', theme: 'ocean'}});
  await waitFor(state => visible(state)?.activeSpaceId !== original.activeSpaceId && hidden(visible(state)), 'switch spaces');
  await command('space', {windowId, text: original.activeSpaceId});
  state = await waitFor(state => visible(state)?.activeSpaceId === original.activeSpaceId &&
    visible(state).sidebarPresentation.notificationBannerPresent && hidden(visible(state)), 'return to banner tab');
  assert.deepEqual(bounds(visible(state)), originalBounds);
  report.checks.push('Returning to a tab through a space switch cannot bring its notification banner back');

  await command('testNotificationBanner', {windowId, text: 'clear'});
  state = await waitFor(state => visible(state)?.sidebarPresentation.notificationBannerPresent === false && hidden(visible(state)), 'clear test banner');
  assert.deepEqual(bounds(visible(state)), originalBounds);
  state = await command('testBrowserNotice', {windowId});
  let notice = visible(state).notices[0];
  assert.ok(notice && notice.message.includes('needs your attention'));
  assert.ok(notice.actions.some(action => action.id === 'accept' && action.enabled));
  assert.ok(notice.actions.some(action => action.id === 'extra' && !action.enabled));
  assert.ok(hidden(visible(state)));
  assert.deepEqual(bounds(visible(state)), originalBounds);
  const noticeCommand = (item, text, fields = {}) => command('noticeAction', {
    windowId, id: item.tabId, text, metadata: {url: item.url, notice: item.id}, ...fields,
  });
  for (const fields of [{id: -1}, {metadata: {url: notice.url + '/stale', notice: notice.id}},
                        {metadata: {url: notice.url, notice: 'not-a-notice'}}, {metadata: {notice: notice.id}}]) {
    state = await noticeCommand(notice, 'accept', fields);
    assert.equal(visible(state).lastNoticeAction, '');
    assert.equal(visible(state).notices.length, 1);
  }
  state = await noticeCommand(notice, 'extra');
  assert.equal(visible(state).lastNoticeAction, '');
  const oldNotice = notice;
  state = await command('testBrowserNotice', {windowId});
  notice = visible(state).notices[0];
  assert.notEqual(notice.id, oldNotice.id);
  state = await noticeCommand(oldNotice, 'accept');
  assert.equal(visible(state).lastNoticeAction, '');
  state = await noticeCommand(notice, 'link');
  assert.equal(visible(state).lastNoticeAction, 'link');
  assert.equal(visible(state).notices.length, 1, 'The delegate controls whether a link closes its notice');
  state = await noticeCommand(notice, 'dismiss');
  assert.equal(visible(state).lastNoticeAction, 'dismiss');
  assert.deepEqual(visible(state).notices, []);
  report.checks.push('Native notices preserve real messages/actions without moving the page and reject stale or disabled actions');

  state = await command('testBrowserNotice', {windowId, text: 'locked'});
  notice = visible(state).notices[0];
  assert.equal(notice.closeable, false);
  state = await noticeCommand(notice, 'dismiss');
  assert.equal(visible(state).lastNoticeAction, '');
  assert.equal(visible(state).notices.length, 1);
  state = await noticeCommand(notice, 'accept');
  assert.equal(visible(state).lastNoticeAction, 'accept');
  assert.deepEqual(visible(state).notices, []);
  state = await command('testBrowserNotice', {windowId});
  state = await noticeCommand(visible(state).notices[0], 'cancel');
  assert.equal(visible(state).lastNoticeAction, 'cancel');
  assert.deepEqual(visible(state).notices, []);
  report.checks.push('Notice Accept, Cancel, link, and Dismiss call the real delegate; non-closeable notices stay until acted on');

  await command('navigate', {windowId, text: 'chrome://settings/defaultBrowser'});
  await waitFor(state => active(visible(state))?.url === 'chrome://settings/defaultBrowser' && !active(visible(state)).loading, 'manual default-browser settings');
  report.checks.push('Clearing a banner leaves no layout gap, and manual default-browser settings remain accessible');
  await browser.close(); browser = null;

  browser = launch('incognito', true);
  state = await waitFor(state => visible(state)?.incognito && active(visible(state))?.title === 'Banner test' && !active(visible(state)).loading, 'private page');
  const privateWindow = visible(state);
  const privateBounds = bounds(privateWindow);
  await command('testNotificationBanner', {windowId: privateWindow.windowId});
  state = await waitFor(state => visible(state)?.sidebarPresentation.notificationBannerPresent && hidden(visible(state)), 'private banner hidden');
  assert.deepEqual(bounds(visible(state)), privateBounds);
  report.checks.push('Private windows also suppress the notification-banner strip');
  await browser.close(); browser = null;
  report.passed = true;
  console.log(`${report.checks.length} focused notification-banner checks passed`);
} catch (error) {
  report.error = error.stack || String(error);
  report.lastState = latest;
  report.preservedProfile = profile;
  console.error(error);
  process.exitCode = 1;
} finally {
  if (browser) await browser.close().catch(error => { report.shutdownError = String(error); });
  fs.writeFileSync(path.join(reports, 'report.json'), JSON.stringify(report, null, 2) + '\n');
  if (report.passed) fs.rmSync(profile, {recursive: true, force: true});
  console.log('Reports:', reports);
}
