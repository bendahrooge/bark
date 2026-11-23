#!/usr/bin/env node
// Check the native split layout reached by sidebar drops, using real page bounds.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';
import {Browser, uiDriver} from './test_chromium_browser.mjs';

const root = path.resolve('test-results/chromium-splits');
fs.mkdirSync(root, {recursive: true});
const reports = fs.mkdtempSync(path.join(root, 'run-'));
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'bark-splits-'));
const driver = path.join(profile, '.bark-ui-driver');
fs.mkdirSync(driver);
const report = {passed: false, checks: []};
let browser;
const visible = state => state.windows.find(window => window.visible && !window.incognito);
const ui = uiDriver({directory: () => driver, browser: () => browser});
const {command, waitFor} = ui;
function launch(name) {
  for (const file of ['request.json', 'response.json']) fs.rmSync(path.join(driver, file), {force: true});
  return new Browser(profile, path.join(reports, name + '.log'), {
    nativeWindow: true, nativeUI: true, loadFixture: false, testDirectory: driver, profileDirectory: null,
  });
}
async function close() { await browser.close(); browser = null; }
const server = http.createServer((request, response) => {
  response.writeHead(200, {'Content-Type': 'text/html', 'Cache-Control': 'no-store'});
  response.end('<title>Split test</title><link rel="icon" href="data:,"><body>Split view test</body>');
});
try {
  assert.equal(process.platform, 'darwin');
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const tab = (state, name) => visible(state)?.tabs.find(tab => tab.url === base + '/' + name);
  const nativeTab = (state, name) => visible(state)?.allTabs.find(tab => tab.url === base + '/' + name);
  const action = async (name, page, text) => {
    const state = await command();
    return command(name, {windowId: visible(state).windowId, id: tab(state, page).id, text});
  };
  const layoutMatches = (state, side, dragged = 'b', active = 'a') => {
    const a = nativeTab(state, active), b = nativeTab(state, dragged);
    const stacked = side === 'top' || side === 'bottom';
    const layout = stacked ? 'stacked' : 'sideBySide';
    if (!a?.visible || !b?.visible || a.splitLayout !== layout || b.splitLayout !== layout ||
        !tab(state, active)?.split || tab(state, active).split !== tab(state, dragged)?.split) return false;
    const first = side === 'left' || side === 'top' ? b.contentBounds : a.contentBounds;
    const second = side === 'left' || side === 'top' ? a.contentBounds : b.contentBounds;
    if ([first, second].some(rect => rect.width <= 0 || rect.height <= 0)) return false;
    // Chromium screen coordinates increase downward, unlike AppKit's drop geometry.
    return stacked
      ? Math.abs(first.x - second.x) <= 1 && Math.abs(first.width - second.width) <= 1 &&
        first.y + first.height <= second.y && second.y - first.y - first.height <= 32
      : Math.abs(first.y - second.y) <= 1 && Math.abs(first.height - second.height) <= 1 &&
        first.x + first.width <= second.x && second.x - first.x - first.width <= 32;
  };
  const checkPageFrame = (state, names) => {
    const window = visible(state);
    const area = window.sidebarPresentation.pageAreaBounds;
    assert.equal(window.sidebarPresentation.pageFrameVisible, true);
    const panes = names.map(name => nativeTab(state, name));
    for (const pane of panes) assert.equal(pane.nativeCornerRadius, 10,
      'The actual native page surface has rounded corners');
    const left = Math.min(...panes.map(pane => pane.contentBounds.x));
    const top = Math.min(...panes.map(pane => pane.contentBounds.y));
    const right = Math.max(...panes.map(pane => pane.contentBounds.x + pane.contentBounds.width));
    const bottom = Math.max(...panes.map(pane => pane.contentBounds.y + pane.contentBounds.height));
    for (const gap of [left - area.x, top - area.y, area.x + area.width - right, area.y + area.height - bottom])
      assert.ok(Math.abs(gap - 7) <= 1, `The real page area reserves the 7pt frame, got ${gap}`);
  };

  browser = launch('four-directions');
  await waitFor(state => !!visible(state)?.activeSpaceId, 'initial window');
  for (const name of ['a', 'b', 'c']) {
    await browser.send('Target.createTarget', {url: base + '/' + name});
    await waitFor(state => tab(state, name)?.title === 'Split test' && !tab(state, name).loading, 'load ' + name);
  }
  await action('select', 'a');
  checkPageFrame(await command(), ['a']);
  report.checks.push('A single native page has an even 7pt gutter and 10pt corners');
  for (const side of ['left', 'right', 'top', 'bottom']) {
    await action('select', 'a');
    await action('splitTab', 'b', side);
    const splitState = await waitFor(state => layoutMatches(state, side), side + ' split page bounds');
    checkPageFrame(splitState, ['a', 'b']);
    await action('unsplit', 'a');
    await waitFor(state => !tab(state, 'a')?.split && !tab(state, 'b')?.split, 'separate ' + side + ' split');
    report.checks.push(`A ${side} drop places the dragged page on the correct half and separates cleanly`);
  }
  await action('select', 'a');
  await command('toggleSidebar', {windowId: visible(ui.latest).windowId});
  const collapsedState = await waitFor(state => visible(state)?.sidebarCollapsed &&
    !visible(state).sidebarPresentation.animating, 'collapsed frame');
  checkPageFrame(collapsedState, ['a']);
  await command('toggleSidebar', {windowId: visible(collapsedState).windowId});
  const expandedState = await waitFor(state => !visible(state)?.sidebarCollapsed &&
    !visible(state).sidebarPresentation.animating, 'expanded frame');
  checkPageFrame(expandedState, ['a']);
  report.checks.push('The real page frame stays aligned through sidebar collapse and expansion');
  const fullscreenTarget = (await browser.send('Target.getTargets')).targetInfos.find(target => target.url === base + '/a');
  const {windowId} = await browser.send('Browser.getWindowForTarget', {targetId: fullscreenTarget.targetId});
  const checkDockedWindow = async (fullscreen, label) => {
    const state = await waitFor(state => {
      const window = visible(state);
      const presentation = window?.sidebarPresentation;
      return presentation?.windowFullscreen === fullscreen && !presentation.animating && presentation.sidebarVisible &&
        presentation.headerVisible && presentation.pageFrameVisible && nativeTab(state, 'a')?.nativeCornerRadius === 10 &&
        presentation.pageAreaBounds.x - window.bounds.x === window.sidebarWidth;
    }, label);
    const window = visible(state);
    const ui = window.sidebarPresentation;
    assert.equal(ui.chromiumTabStripVisible, false, 'The horizontal tab strip stays hidden');
    assert.equal(ui.chromiumToolbarVisible, false, 'The stock toolbar stays hidden');
    assert.equal(ui.opacity, 1);
    assert.equal(ui.sidebarX, 0);
    checkPageFrame(state, ['a']);
  };
  await command('testActivateWindow', {windowId});
  await command('testClickZoomButton', {windowId});
  await checkDockedWindow(true, 'green button enters browser fullscreen with the docked sidebar');
  // Allow AppKit to finish moving the window into its fullscreen Space.
  await delay(1200);
  const {sessionId} = await browser.send('Target.attachToTarget', {targetId: fullscreenTarget.targetId, flatten: true});
  await browser.send('Page.bringToFront', {}, sessionId);
  await command('testActivateWindow', {windowId});
  await waitFor(state => visible(state)?.sidebarPresentation.keyWindow, 'focused fullscreen browser window');
  const evaluate = async expression => {
    const result = await browser.send('Runtime.evaluate', {expression, awaitPromise: true}, sessionId);
    assert.ok(!result.exceptionDetails, result.exceptionDetails?.exception?.description);
  };
  await evaluate(`document.addEventListener('click', () => {
    window.fullscreenRequest = document.documentElement.requestFullscreen();
  }, {once: true})`);
  for (const type of ['mousePressed', 'mouseReleased']) {
    await browser.send('Input.dispatchMouseEvent', {type, x: 40, y: 40, button: 'left', clickCount: 1}, sessionId);
  }
  await evaluate('window.fullscreenRequest');
  const contentState = await waitFor(state => {
    const ui = visible(state)?.sidebarPresentation;
    return ui?.windowFullscreen && !ui.sidebarVisible && !ui.headerVisible && !ui.pageFrameVisible;
  }, 'page fullscreen hides the browser sidebar');
  assert.equal(nativeTab(contentState, 'a').contentBounds.width, visible(contentState).bounds.width,
    'The fullscreen page uses the width previously occupied by the sidebar');
  await evaluate('document.exitFullscreen()');
  await checkDockedWindow(true, 'leaving page fullscreen restores the sidebar inside browser fullscreen');
  const checkCollapsedWindow = async fullscreen => {
    const state = await waitFor(state => {
      const window = visible(state);
      const ui = window?.sidebarPresentation;
      return ui?.windowFullscreen === fullscreen && window.sidebarCollapsed &&
        !ui.animating && !ui.sidebarVisible && ui.edgeVisible;
    }, 'collapsed sidebar with its reveal target');
    const window = visible(state);
    assert.equal(window.sidebarPresentation.pageAreaBounds.width, window.bounds.width,
      'Collapsing the sidebar gives its width back to the page');
    assert.equal(window.sidebarPresentation.chromiumTabStripVisible, false);
  };
  await command('toggleSidebar', {windowId});
  await checkCollapsedWindow(true);
  await command('testSidebarPointer', {windowId, x: 5, y: 300});
  const floatingState = await waitFor(state => {
    const window = visible(state);
    return window?.sidebarRevealed && window.sidebarPresentation.sidebarVisible &&
      !window.sidebarPresentation.animating;
  }, 'hover reveals the collapsed sidebar in browser fullscreen');
  assert.equal(visible(floatingState).sidebarPresentation.pageAreaBounds.width, visible(floatingState).bounds.width);
  await command('testSidebarPointer', {windowId, x: 600, y: 300});
  await checkCollapsedWindow(true);
  await browser.send('Browser.setWindowBounds', {windowId, bounds: {windowState: 'normal'}});
  await checkCollapsedWindow(false);
  await command('toggleSidebar', {windowId});
  await checkDockedWindow(false, 'restored window with the docked sidebar');
  report.checks.push('The green fullscreen button preserves the left sidebar and keeps the horizontal tab strip hidden');
  report.checks.push('A fullscreen page uses the full window and restores the docked sidebar on exit');
  report.checks.push('The collapsed sidebar reveals on hover in browser fullscreen and stays collapsed on exit');
  await action('select', 'a');
  await action('splitTab', 'b', 'left');
  await waitFor(state => layoutMatches(state, 'left'), 'existing side-by-side split');
  await action('splitTab', 'c', 'top');
  await waitFor(state => layoutMatches(state, 'top', 'c') && !tab(state, 'b')?.split,
    'replace side-by-side pair with a stacked pair');
  report.checks.push('Dropping above an existing split creates a stacked pair without leaving the old partner in the split');

  await close();
  browser = launch('restored-stack');
  await waitFor(state => nativeTab(state, 'a')?.splitLayout === 'stacked' &&
    nativeTab(state, 'c')?.splitLayout === 'stacked', 'saved stacked layout');
  // The shared launcher explicitly opens about:blank on every run. Select
  // the restored pair before checking its rendered bounds.
  await action('select', 'a');
  await waitFor(state => layoutMatches(state, 'top', 'c'), 'restored stacked split');
  assert.ok(tab(ui.latest, 'b') && !tab(ui.latest, 'b').split, 'The previous partner remains a separate tab');
  report.checks.push('A stacked split and its top/bottom order survive a normal browser restart');
  await close();
  report.passed = true;
  console.log(`${report.checks.length} focused split-view checks passed`);
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
