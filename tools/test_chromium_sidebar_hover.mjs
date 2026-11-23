#!/usr/bin/env node
// Real AppKit hover events, native caption controls, and sidebar presentation.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';
import {Browser, uiDriver} from './test_chromium_browser.mjs';

const root = path.resolve('test-results/chromium-sidebar-hover');
fs.mkdirSync(root, {recursive: true});
const reports = fs.mkdtempSync(path.join(root, 'run-'));
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'bark-sidebar-hover-'));
const driver = path.join(profile, '.bark-ui-driver');
fs.mkdirSync(driver);
const report = {passed: false, checks: []};
let browser;
const visible = state => state.windows.find(window => window.visible && window.incognito);
const ui = uiDriver({directory: () => driver, browser: () => browser, poll: 30});
const {command} = ui;
async function waitFor(predicate, label) {
  for (let i = 0; i < 100; i++) {
    const state = await command();
    if (predicate(visible(state))) return visible(state);
    await delay(30);
  }
  throw Error('Timed out: ' + label);
}
const hidden = window => window?.sidebarCollapsed && !window.sidebarRevealed &&
  !window.sidebarPresentation.sidebarVisible && !window.sidebarPresentation.headerVisible &&
  window.sidebarPresentation.opacity === 0;
const shown = window => window?.sidebarPresentation.sidebarVisible && window.sidebarPresentation.headerVisible &&
  window.sidebarPresentation.opacity === 1 && !window.sidebarPresentation.animating;
const pageBounds = window => window.allTabs.find(tab => tab.id === window.tabs.find(tab => tab.active)?.id)?.contentBounds;
function checkBackdrop(window) {
  const presentation = window.sidebarPresentation;
  assert.equal(presentation.backdropVisible, presentation.sidebarVisible && window.sidebarCollapsed,
    'Only the floating sidebar has a separate backdrop; docked chrome shares the page frame');
  assert.equal(presentation.resizeVisible, presentation.sidebarVisible);
  assert.equal(presentation.resizeX, presentation.sidebarX + window.sidebarWidth - 1,
    'The resize target sits on the outer boundary, leaving the tab scrollbar and row width clear');
  assert.equal(presentation.resizeWidth, 12, 'The boundary keeps its generous resize hit target');
  assert.equal(presentation.backdropX + presentation.shadowMargin, presentation.sidebarX);
  assert.equal(presentation.backdropY + presentation.shadowMargin, presentation.panelInset,
    'The floating panel is inset while its shadow extends outside its surface');
  assert.ok(presentation.sidebarY > presentation.panelInset, 'Content stays below the caption row');
  assert.ok(presentation.backdropHeight > presentation.sidebarHeight,
    'The backdrop spans both the navigation controls and sidebar content');
  assert.equal(presentation.backdropOpacity, presentation.opacity);
  assert.equal(presentation.headerOpacity, presentation.opacity);
}
try {
  assert.equal(process.platform, 'darwin');
  // Private windows exercise the same UI without changing the user's shared
  // NSUserDefaults sidebar width/collapse preference.
  browser = new Browser(profile, path.join(reports, 'browser.log'), {
    nativeWindow: true, nativeUI: true, loadFixture: false, testDirectory: driver,
    extraFlags: ['--incognito', '--bark-ui-layout-report'],
    initialURL: 'data:text/html,<title>Sidebar hover test</title><body>Hover test page</body>',
  });
  let window = await waitFor(window => !!window, 'private browser window');
  const windowId = window.windowId;
  const send = (action, fields = {}) => command(action, {windowId, ...fields});
  const pointer = (x, fields = {}) => send('testSidebarPointer', {x, y: 300, ...fields});
  const activate = async () => {
    await send('testActivateWindow');
    await waitFor(window => window?.sidebarPresentation.keyWindow, 'key browser window');
  };
  await waitFor(window => window?.tabs.some(tab => tab.active && tab.title === 'Sidebar hover test' && !tab.loading), 'loaded test page');
  await activate();
  await pointer(600);
  if (window.sidebarCollapsed) await send('toggleSidebar');
  await waitFor(shown, 'docked sidebar');
  const sidebarWidth = 380;
  await send('resize', {width: sidebarWidth});
  for (const width of [960, 780, 960]) {
    await browser.send('Browser.setWindowBounds', {windowId, bounds: {width}});
    window = await waitFor(window => window?.bounds.width === width, `window width ${width}`);
    assert.equal(window.sidebarWidth, sidebarWidth, 'Window resizing keeps the manually selected sidebar width');
    checkBackdrop(window);
    assert.equal(window.sidebarPresentation.pageAreaBounds.width, width - sidebarWidth,
      'The page takes the remaining window width');
  }
  report.checks.push('Narrowing and widening the window keeps the docked sidebar at its manually selected width');

  await send('resize', {width: 260});
  const docked = await waitFor(shown, 'docked sidebar');
  const dockedLights = docked.sidebarPresentation.trafficLights;
  await send('toggleSidebar');
  window = await waitFor(hidden, 'collapsed sidebar');
  checkBackdrop(window);
  assert.ok(window.sidebarPresentation.edgeVisible && window.sidebarPresentation.edgeOpacity === 1);
  assert.ok(window.sidebarPresentation.trafficLights.every(button => button.hidden && button.opacity === 0));
  const collapsedPage = pageBounds(window);
  report.checks.push('Collapsing hides the sidebar, reopen control, and native traffic lights, leaving the edge hint');

  await activate();
  await pointer(24);
  await delay(300);
  assert.ok(hidden(visible(await command())), 'The wider reveal target must still leave ordinary page areas alone');
  await pointer(14, {leaveAfter: 30});
  await delay(450);
  assert.ok(hidden(visible(await command())), 'Brief edge crossings must not reveal the sidebar');
  await activate();
  await pointer(14, {leaveAfter: 160});
  await delay(750);
  assert.ok(hidden(visible(await command())), 'Leaving during the fade must not strand the sidebar open');
  report.checks.push('Quick edge crossings and leaving during a reveal do not leave the sidebar open');

  await activate();
  await pointer(14);
  // The file-based driver polls commands every 100 ms. Start after its
  // acknowledgement so transport latency is not charged to the UI animation.
  const revealStarted = performance.now();
  const revealFrames = [];
  window = await waitFor(window => {
    if (window) checkBackdrop(window);
    revealFrames.push(window?.sidebarPresentation);
    return window?.sidebarRevealed && shown(window);
  }, 'hover reveal');
  const revealMs = performance.now() - revealStarted;
  assert.ok(revealMs < 500, `The entrance spring should settle within 500 ms, took ${Math.round(revealMs)} ms`);
  report.revealMs = Math.round(revealMs);
  report.revealFrames = revealFrames;
  if (!window.sidebarPresentation.reduceMotion) {
    assert.ok(revealFrames.some(frame => frame && frame.sidebarVisible && frame.sidebarX < 0),
      'The reveal must slide in from the left edge');
    assert.ok(revealFrames.some(frame => frame && frame.sidebarX > frame.panelInset),
      'The entrance spring must overshoot once before settling into the floating position');
  }
  assert.equal(window.sidebarPresentation.sidebarX, 8, 'The panel rests inset from the window edge');
  assert.equal(window.sidebarPresentation.panelInset, 8);
  assert.ok(window.sidebarPresentation.backdropHeight - window.sidebarPresentation.shadowMargin * 2 < window.bounds.height,
    'The panel leaves a visible gap above and below');
  assert.ok(window.sidebarPresentation.trafficLights.every(button => !button.hidden && button.opacity === 1));
  assert.equal(window.sidebarPresentation.headerOpacity, 1);
  assert.equal(window.sidebarPresentation.edgeVisible, false);
  assert.deepEqual(pageBounds(window), collapsedPage, 'Hovering must overlay the page without resizing it');
  report.checks.push('Hovering 14 points from the edge reveals the floating panel without moving the page');
  report.checks.push('The caption row and sidebar share one floating backdrop and shadow throughout the entrance');

  const floatingLights = window.sidebarPresentation.trafficLights;
  await send('settings');
  await waitFor(window => !window?.sidebarPresentation.keyWindow, 'Settings takes focus');
  await activate();
  window = await waitFor(shown, 'floating sidebar after Settings');
  assert.deepEqual(window.sidebarPresentation.trafficLights, floatingLights,
    'Returning from Settings must preserve the floating traffic-light positions');
  report.checks.push('Returning from Settings keeps the caption controls aligned with the floating panel');

  await pointer(100);
  await delay(300);
  assert.ok(shown(visible(await command())));
  await pointer(600);
  await pointer(100);
  await delay(400);
  assert.ok(shown(visible(await command())), 'Reentering during the dismissal delay must keep the sidebar open');
  await pointer(window.sidebarWidth + 7);
  await delay(300);
  assert.ok(shown(visible(await command())), 'The inset panel’s rightmost controls remain inside the hover area');
  report.checks.push('Entering the revealed sidebar and returning during its dismissal delay keep it open');

  const originalWidth = window.sidebarWidth;
  await pointer(originalWidth + 30);
  await send('resize', {width: originalWidth + 40});
  await delay(300);
  assert.ok(shown(visible(await command())),
    'A queued exit must recheck the new bounds when resizing brings the pointer inside the panel');
  await pointer(100);
  await send('resize', {width: originalWidth});
  report.checks.push('Resizing rechecks the new panel bounds before dismissing it');

  await pointer(600);
  window = await waitFor(hidden, 'hover dismissal');
  checkBackdrop(window);
  assert.ok(window.sidebarPresentation.trafficLights.every(button => button.hidden));
  assert.ok(window.sidebarPresentation.edgeVisible);
  report.checks.push('Leaving the sidebar fades it away and restores the edge hint');

  await send('toggleSidebar');
  window = await waitFor(shown, 'reopen docked sidebar');
  checkBackdrop(window);
  assert.equal(window.sidebarCollapsed, false);
  assert.equal(window.sidebarPresentation.edgeVisible, false);
  assert.ok(window.sidebarPresentation.trafficLights.every(button => !button.hidden && button.opacity === 1));
  assert.deepEqual(window.sidebarPresentation.trafficLights, dockedLights,
    'Docking restores the native traffic lights to their original positions');
  report.checks.push('Reopening restores the docked sidebar and all three native window controls');
  await browser.close(); browser = null;
  report.passed = true;
  console.log(`${report.checks.length} focused sidebar-hover checks passed`);
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
