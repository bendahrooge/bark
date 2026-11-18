#!/usr/bin/env node
// Native checks for Bark features including tab renaming, pinned pages,
// sidebar folders, automatic archiving, Control-Tab order, space gradients,
// picture-in-picture defaults, Peek and Little windows.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';
import {Browser} from './test_chromium_browser.mjs';

const resultRoot = path.resolve('test-results/chromium-bark-features');
fs.mkdirSync(resultRoot, {recursive: true});
const reports = fs.mkdtempSync(path.join(resultRoot, 'run-'));
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'bark-features-test-'));
const driver = path.join(profile, '.bark-ui-driver');
fs.mkdirSync(driver);
const report = {passed: false, checks: []};
let sequence = 0, browser;
const visible = state => state.windows.find(window => window.visible && !window.incognito);
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
  let state;
  for (let i = 0; i < 150; i++) {
    state = await command();
    if (predicate(state)) return state;
    await delay(100);
  }
  fs.writeFileSync(path.join(reports, 'last-state.json'), JSON.stringify(state, null, 2));
  throw Error('Timed out: ' + label);
}
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
  const links = `<a id="same" href="/inside">Same site</a> <a id="other" href="http://localhost:${port}/peek">Other site</a>
    <a id="new-target" href="/peek-new" target="_blank">Preview</a>`;
  response.end(`<title>Page ${url.pathname}</title><link rel="icon" href="data:,"><body>${links}</body>`);
});

try {
  assert.equal(process.platform, 'darwin');
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  const tabWith = (state, suffix) => visible(state)?.tabs.find(tab => tab.url === base + suffix);
  const metaOf = (state, id) => visible(state).allTabs.find(tab => tab.id === id)?.meta ?? {};
  const open = async suffix => {
    await browser.send('Target.createTarget', {url: base + suffix});
    return waitFor(state => tabWith(state, suffix) && !tabWith(state, suffix).loading &&
      tabWith(state, suffix).title === 'Page ' + suffix, 'open ' + suffix);
  };
  const page = async url => {
    let session;
    for (let i = 0; i < 100; i++) {
      if (!session) {
        const {targetInfos} = await browser.send('Target.getTargets');
        const target = targetInfos.find(info => info.type === 'page' && info.url === url);
        if (target) session = (await browser.send('Target.attachToTarget', {targetId: target.targetId, flatten: true})).sessionId;
      }
      if (session) {
        const {result} = await browser.send('Runtime.evaluate', {
          expression: `location.href === ${JSON.stringify(url)} && document.readyState === 'complete'`, returnByValue: true,
        }, session);
        if (result.value) return session;
      }
      await delay(50);
    }
    throw Error('Timed out waiting for page document: ' + url);
  };
  const clickNewTarget = async (session, href, meta = false) => {
    const {result} = await browser.send('Runtime.evaluate', {
      expression: `(() => {
        const link = document.getElementById('new-target');
        link.href = ${JSON.stringify(href)};
        window.lastLinkClick = null;
        link.addEventListener('click', event => {
          window.lastLinkClick = {trusted: event.isTrusted, meta: event.metaKey};
        }, {once: true});
        link.scrollIntoView();
        const rect = link.getBoundingClientRect();
        return {x: rect.x + rect.width / 2, y: rect.y + rect.height / 2};
      })()`, returnByValue: true,
    }, session);
    const mouse = {...result.value, button: 'left', clickCount: 1, modifiers: meta ? 4 : 0};
    await browser.send('Input.dispatchMouseEvent', {...mouse, type: 'mousePressed', buttons: 1}, session);
    await browser.send('Input.dispatchMouseEvent', {...mouse, type: 'mouseReleased', buttons: 0}, session);
    const click = await browser.send('Runtime.evaluate', {expression: 'window.lastLinkClick', returnByValue: true}, session);
    assert.deepEqual(click.result.value, {trusted: true, meta});
  };

  browser = launch('features');
  let state = await waitFor(state => !!visible(state)?.activeSpaceId, 'initial window');
  const windowId = visible(state).windowId;
  const features = visible(state).features;
  assert.deepEqual(features, {archiveAfterHours: 12, peek: true, littleWindow: true, autoPictureInPicture: true});
  assert.equal(visible(state).autoPictureInPictureDefault, 'allow');
  assert.equal(visible(state).autoPictureInPictureFeature, true);
  report.checks.push('Bark defaults: 12-hour archiving, Peek, Little windows, and automatic picture-in-picture allowed and enabled');

  // Rename a tab, then clear the name.
  state = await open('/rename');
  const renamed = tabWith(state, '/rename').id;
  await command('renameTab', {windowId, id: renamed, text: '  Reading list  '});
  state = await waitFor(state => tabWith(state, '/rename')?.customTitle === 'Reading list', 'custom title');
  assert.equal(tabWith(state, '/rename').title, 'Page /rename', 'The page title is kept alongside the custom title');
  report.checks.push('A tab can be given its own title');

  // Pinned page memory and drift.
  state = await open('/pin');
  const pin = tabWith(state, '/pin').id;
  await command('pin', {windowId, id: pin});
  state = await waitFor(state => tabWith(state, '/pin')?.pinnedURL === base + '/pin', 'pinned URL');
  assert.equal(tabWith(state, '/pin').drifted, false);
  const pinSession = await page(base + '/pin');
  await browser.send('Runtime.evaluate', {expression: "document.getElementById('same').click()", userGesture: true}, pinSession);
  state = await waitFor(state => tabWith(state, '/inside')?.drifted === true, 'pin drifts within its own site');
  assert.equal(visible(state).popups.length, 0, 'Same-site links stay in the pinned tab');
  await command('resetPin', {windowId, id: pin});
  state = await waitFor(state => tabWith(state, '/pin')?.drifted === false && !tabWith(state, '/pin').loading, 'reset pin');
  report.checks.push('A pin remembers its page, shows when it navigated away, and returns to it');

  const pinPage = await page(base + '/pin');
  const beforePeek = visible(state).allTabs.map(tab => tab.id);
  const peekOpens = suffix => waitFor(state =>
    visible(state)?.popups.some(popup => popup.kind === 'peek' && popup.url === base + suffix), suffix + ' Peek');
  const checkOpener = state => {
    assert.equal(tabWith(state, '/pin')?.active, true);
    assert.equal(tabWith(state, '/pin').id, pin);
    assert.deepEqual(visible(state).allTabs.map(tab => tab.id), beforePeek, 'Peek leaves the window tab strip intact');
  };
  await clickNewTarget(pinPage, '/peek-close');
  state = await peekOpens('/peek-close');
  checkOpener(state);
  const {copyPasteboardName} = await command('testUsePrivateCopyPasteboard', {windowId});
  assert.match(copyPasteboardName, /^BarkUITest\.CopyLink\.[0-9a-f-]{36}$/);
  const copiedPath = '/peek-close?view=details#section';
  const closePage = await page(base + '/peek-close');
  await browser.send('Runtime.evaluate', {
    expression: `history.pushState({}, '', ${JSON.stringify(copiedPath)})`,
  }, closePage);
  await peekOpens(copiedPath);
  await command('testPopupControl', {windowId, kind: 'peek', text: 'copyURL'});
  checkOpener(await peekOpens(copiedPath));
  const copied = execFileSync('/usr/bin/osascript', ['-l', 'JavaScript', '-e', `
    ObjC.import('AppKit');
    function run([name]) {
      return ObjC.unwrap($.NSPasteboard.pasteboardWithName(name).stringForType($.NSPasteboardTypeString));
    }
  `, copyPasteboardName], {encoding: 'utf8'}).trimEnd();
  assert.equal(copied, base + copiedPath);
  report.checks.push('Copying the live Peek URL includes its query and fragment and leaves the preview open');
  await command('testPopupCommand', {windowId, kind: 'peek', text: 'close'});
  checkOpener(await waitFor(state => visible(state)?.popups.length === 0, 'dismiss same-site Peek'));
  await clickNewTarget(pinPage, '/peek-expand');
  checkOpener(await peekOpens('/peek-expand'));
  const expandSession = await page(base + '/peek-expand');
  const context = await browser.send('Runtime.evaluate', {
    expression: `({referrer: document.referrer, noOpener: window.opener === null,
      token: (window.barkPreviewToken = crypto.randomUUID())})`, returnByValue: true,
  }, expandSession);
  assert.equal(context.result.value.referrer, base + '/pin', 'Same-origin links retain their full referrer');
  assert.equal(context.result.value.noOpener, true, 'target=_blank retains its implicit noopener policy');
  await command('testPopupControl', {windowId, kind: 'peek', text: 'expand', count: 3});
  state = await waitFor(state => visible(state)?.popups.length === 0 && tabWith(state, '/peek-expand')?.active, 'expand same-site Peek');
  assert.equal(visible(state).allTabs.length, beforePeek.length + 1);
  assert.equal(tabWith(state, '/peek-expand').pinned, false);
  assert.equal(tabWith(state, '/pin').id, pin);
  const expandedPage = await browser.send('Runtime.evaluate', {
    expression: `new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(() => resolve({
      token: window.barkPreviewToken, visibility: document.visibilityState, focused: document.hasFocus()
    }))))`, awaitPromise: true, returnByValue: true,
  }, expandSession);
  assert.deepEqual(expandedPage.result.value, {token: context.result.value.token, visibility: 'visible', focused: true},
    'The + control promotes and focuses the original preview renderer');
  state = await command();
  assert.equal(tabWith(state, '/peek-expand')?.active, true);
  assert.equal(visible(state).allTabs.length, beforePeek.length + 1, 'Repeated + actions yield one selected tab');
  report.checks.push('A plain same-site target=_blank click from a pin keeps the opener selected, dismisses cleanly and adds one tab only on expansion');

  // An ordinary cross-site link from a pinned tab still opens over the window.
  await command('select', {windowId, id: pin});
  await browser.send('Runtime.evaluate', {expression: "document.getElementById('other').click()", userGesture: true}, pinPage);
  state = await waitFor(state => visible(state)?.popups.some(popup => popup.kind === 'peek' && popup.url.endsWith('/peek')), 'peek opens');
  assert.equal(tabWith(state, '/pin').drifted, false, 'The pinned tab stays on its page');
  const peek = visible(state).popups.find(popup => popup.kind === 'peek');
  assert.ok(peek.hasControls, 'Peek shows Bark controls');
  const window = visible(state).bounds;
  assert.ok(peek.bounds.width < window.width && peek.bounds.height < window.height, 'Peek sits over the window');
  await command('testPopupCommand', {windowId, kind: 'peek', text: 'expand'});
  state = await waitFor(state => visible(state)?.popups.length === 0 &&
    visible(state).tabs.some(tab => tab.active && tab.url.endsWith('/peek') && !tab.pinned), 'peek becomes a tab');
  report.checks.push('Cross-site links in pinned tabs open in Peek, which can become a tab in the space');

  // Promoting Peek to a split moves its live page, retaining JavaScript and
  // history instead of opening a second copy of the URL.
  await command('select', {windowId, id: pin});
  await clickNewTarget(pinPage, '/peek-split');
  state = await waitFor(state => visible(state)?.popups.some(popup => popup.kind === 'peek' && popup.url.endsWith('/peek-split') && popup.canSplit), 'splittable Peek');
  assert.ok(tabWith(state, '/pin').active && !tabWith(state, '/peek-split'));
  const splitSession = await page(base + '/peek-split');
  await browser.send('Runtime.evaluate', {
    expression: "window.peekToken = 'live-page-kept'; history.pushState({step: 1}, '', '/peek-split/step')",
  }, splitSession);
  const priorHistory = await browser.send('Page.getNavigationHistory', {}, splitSession);
  await command('testPopupCommand', {windowId, kind: 'peek', text: 'split'});
  state = await waitFor(state => visible(state)?.popups.length === 0 &&
    visible(state).tabs.some(tab => tab.active && tab.url.endsWith('/peek-split/step') && tab.split && tab.split === tabWith(state, '/pin')?.split), 'Peek joins source in split');
  const promoted = visible(state).tabs.find(tab => tab.url.endsWith('/peek-split/step'));
  const members = visible(state).tabs.filter(tab => tab.split === promoted.split);
  assert.deepEqual(members.map(tab => tab.id), [pin, promoted.id], 'Peek follows its source in the split');
  // allTabs holds renderer/layout diagnostics, while the visible tab model
  // carries split membership. Join them by id and wait for native layout.
  state = await waitFor(state => {
    const source = visible(state).allTabs.find(tab => tab.id === pin);
    const preview = visible(state).allTabs.find(tab => tab.id === promoted.id);
    return source?.visible && preview?.visible && source.splitLayout === 'sideBySide' &&
      preview.splitLayout === 'sideBySide' && source.contentBounds.width > 0 && preview.contentBounds.width > 0 &&
      preview.contentBounds.x >= source.contentBounds.x + source.contentBounds.width;
  }, 'Peek lays out on the right of its source');
  const live = await browser.send('Runtime.evaluate', {expression: 'window.peekToken', returnByValue: true}, splitSession);
  assert.equal(live.result.value, 'live-page-kept', 'The live renderer survives promotion');
  const movedHistory = await browser.send('Page.getNavigationHistory', {}, splitSession);
  assert.deepEqual(movedHistory.entries.map(entry => entry.url), priorHistory.entries.map(entry => entry.url));
  assert.equal(movedHistory.currentIndex, priorHistory.currentIndex);
  await command('unsplit', {windowId, id: promoted.id});
  report.checks.push('Peek promotes its live page into a right-hand split while preserving JavaScript state and navigation history');

  // A stale source must not silently split the preview beside another page.
  await command('select', {windowId, id: pin});
  await browser.send('Runtime.evaluate', {
    expression: `document.getElementById('other').href = 'http://localhost:${server.address().port}/peek-stale'; document.getElementById('other').click()`,
    userGesture: true,
  }, pinPage);
  await waitFor(state => visible(state)?.popups.some(popup => popup.url.endsWith('/peek-stale')), 'stale-context Peek opens');
  await browser.send('Runtime.evaluate', {expression: "history.pushState({}, '', '/pin-changed')"}, pinPage);
  await command('testPopupCommand', {windowId, kind: 'peek', text: 'split'});
  state = await waitFor(state => visible(state)?.popups.some(popup => popup.url.endsWith('/peek-stale') && !popup.canSplit), 'stale source rejected');
  assert.ok(!visible(state).tabs.some(tab => tab.url.endsWith('/peek-stale')), 'Rejected promotion keeps the preview intact');
  await command('testPopupCommand', {windowId, kind: 'peek', text: 'close'});
  await command('resetPin', {windowId, id: pin});
  await waitFor(state => tabWith(state, '/pin') && !tabWith(state, '/pin').loading && !visible(state).popups.length, 'source restored');

  // Favorites are shared across spaces, and cannot become split members.
  await command('moveTab', {windowId, id: pin, metadata: {zone: 'favorites', before: ''}});
  await command('select', {windowId, id: pin});
  const favoritePage = await page(base + '/pin');
  await browser.send('Runtime.evaluate', {
    expression: `document.getElementById('other').href = 'http://localhost:${server.address().port}/peek-favorite'; document.getElementById('other').click()`,
    userGesture: true,
  }, favoritePage);
  state = await waitFor(state => visible(state)?.popups.some(popup => popup.url.endsWith('/peek-favorite')), 'Favorite Peek');
  assert.equal(visible(state).popups.find(popup => popup.kind === 'peek').canSplit, false);
  await command('testPopupCommand', {windowId, kind: 'peek', text: 'split'});
  state = await command();
  assert.ok(visible(state).popups.some(popup => popup.url.endsWith('/peek-favorite')));
  assert.ok(!visible(state).tabs.some(tab => tab.url.endsWith('/peek-favorite')));
  await command('testPopupCommand', {windowId, kind: 'peek', text: 'close'});
  await command('moveTab', {windowId, id: pin, metadata: {zone: 'pinned', before: ''}});
  await waitFor(state => tabWith(state, '/pin')?.pinned && !visible(state).popups.length, 'Favorite restored as pin');
  report.checks.push('Peek split rejects stale source pages and Favorites without closing or copying the preview');

  await command('setPinURL', {windowId, id: pin});
  await command('select', {windowId, id: pin});
  const restoredPinPage = await page(base + '/pin');
  await clickNewTarget(restoredPinPage, '/background', true);
  state = await waitFor(state => tabWith(state, '/background') && !tabWith(state, '/background').loading, 'Cmd-click background tab');
  assert.equal(tabWith(state, '/pin')?.active, true);
  assert.equal(tabWith(state, '/background').active, false);
  assert.equal(visible(state).popups.length, 0);

  await command('select', {windowId, id: tabWith(state, '/background').id});
  await clickNewTarget(await page(base + '/background'), '/regular-new-target');
  state = await waitFor(state => tabWith(state, '/regular-new-target')?.active, 'ordinary foreground tab');
  assert.equal(visible(state).popups.length, 0);

  await command('select', {windowId, id: pin});
  await command('setPeek', {windowId, text: 'off'});
  state = await waitFor(state => visible(state)?.features.peek === false, 'peek off');
  await clickNewTarget(restoredPinPage, '/disabled-new-target');
  state = await waitFor(state => tabWith(state, '/disabled-new-target')?.active, 'foreground tab with Peek disabled');
  assert.equal(visible(state).popups.length, 0);
  await command('setPeek', {windowId, text: 'on'});
  await command('select', {windowId, id: pin});
  report.checks.push('Cmd-click opens a background tab, and ordinary tabs or disabled Peek retain native foreground-tab behavior');

  // Folders.
  await command('newFolder', {windowId, id: pin, text: 'Work'});
  state = await waitFor(state => tabWith(state, '/pin')?.folder, 'pin in folder');
  let space = visible(state).spaces.find(space => space.active);
  const folder = space.folders[0];
  assert.equal(folder.name, 'Work');
  assert.equal(tabWith(state, '/pin').folder, folder.id);
  await command('toggleFolder', {windowId, metadata: {folder: folder.id}});
  await command('renameFolder', {windowId, text: 'Projects', metadata: {folder: folder.id}});
  state = await waitFor(state => {
    const entry = visible(state).spaces.find(space => space.active).folders?.[0];
    return entry?.collapsed === true && entry.name === 'Projects';
  }, 'folder closed and renamed');
  state = await open('/folder-new');
  const loose = tabWith(state, '/folder-new').id;
  await command('moveToFolder', {windowId, id: loose, metadata: {folder: folder.id}});
  state = await waitFor(state => tabWith(state, '/folder-new')?.pinned && tabWith(state, '/folder-new').folder === folder.id,
    'moving into a folder pins the tab');
  await command('pin', {windowId, id: loose});
  state = await waitFor(state => tabWith(state, '/folder-new') && !tabWith(state, '/folder-new').pinned &&
    !tabWith(state, '/folder-new').folder && !metaOf(state, loose).pinnedURL, 'unpinning leaves the folder');
  report.checks.push('Pinned tabs go into folders that can be closed and renamed; unpinning takes a tab out');

  // Restart: titles, pinned pages and folders are saved with the session.
  await browser.close();
  browser = launch('restart');
  state = await waitFor(state => tabWith(state, '/rename') && tabWith(state, '/pin') &&
    visible(state).spaces.find(space => space.active)?.folders?.length === 1, 'restored session');
  assert.equal(tabWith(state, '/rename').customTitle, 'Reading list');
  assert.equal(tabWith(state, '/pin').pinnedURL, base + '/pin');
  assert.equal(tabWith(state, '/pin').folder, visible(state).spaces.find(space => space.active).folders[0].id);
  report.checks.push('Custom titles, pinned pages and folders survive a restart');
  const restoredWindow = visible(state).windowId;
  const restoredPin = tabWith(state, '/pin').id;

  await command('deleteFolder', {windowId: restoredWindow, metadata: {folder: tabWith(state, '/pin').folder}});
  state = await waitFor(state => !visible(state).spaces.find(space => space.active).folders && tabWith(state, '/pin')?.pinned &&
    !tabWith(state, '/pin').folder, 'delete folder keeps pins');
  await command('renameTab', {windowId: restoredWindow, id: tabWith(state, '/rename').id, text: ''});
  state = await waitFor(state => tabWith(state, '/rename') && !tabWith(state, '/rename').customTitle, 'clear title');
  report.checks.push('Deleting a folder keeps its pins; clearing a custom title follows the page again');

  // Control-Tab order: most recently shown first.
  state = await open('/recent-a');
  state = await open('/recent-b');
  await command('select', {windowId: restoredWindow, id: restoredPin});
  state = await waitFor(state => visible(state).switcher[0]?.id === restoredPin, 'switcher order');
  const order = visible(state).switcher.map(tab => tab.url);
  assert.ok(order.indexOf(base + '/recent-b') < order.indexOf(base + '/recent-a'), 'Recent tabs come first');
  report.checks.push('Control-Tab lists tabs most recently shown first');

  // Automatic archiving.
  state = await command();
  const old = tabWith(state, '/recent-a').id;
  await command('testAgeTab', {windowId: restoredWindow, id: old, hours: 13});
  await command('testAgeTab', {windowId: restoredWindow, id: restoredPin, hours: 100});
  await command('testAutoArchive', {windowId: restoredWindow});
  state = await waitFor(state => !tabWith(state, '/recent-a') &&
    visible(state).archivedTabs.some(tab => tab.url === base + '/recent-a'), 'auto archive');
  assert.ok(tabWith(state, '/pin') && tabWith(state, '/recent-b'), 'Pins and recently shown tabs stay open');
  await command('setArchiveAfter', {windowId: restoredWindow, text: '0'});
  await command('testAgeTab', {windowId: restoredWindow, id: tabWith(state, '/recent-b').id, hours: 1000});
  await command('testAutoArchive', {windowId: restoredWindow});
  await delay(300);
  state = await command();
  assert.ok(tabWith(state, '/recent-b'), 'Never archives nothing');
  assert.equal(visible(state).features.archiveAfterHours, 0);
  await command('setArchiveAfter', {windowId: restoredWindow, text: '12'});
  report.checks.push('Unpinned tabs not shown for the chosen time move to the archive; pins stay; Never turns it off');

  // Space gradient and grain.
  const active = visible(state).spaces.find(space => space.active);
  await command('customizeSpace', {windowId: restoredWindow, metadata: {space: active.id, theme: 'ocean', emoji: '',
    gradient: 'rose', grain: '0.40'}});
  state = await waitFor(state => {
    const space = visible(state).spaces.find(space => space.id === active.id);
    return space.gradient === 'rose' && Math.abs(space.grain - 0.4) < 0.001 && space.emoji === '';
  }, 'gradient saved');
  await command('customizeSpace', {windowId: restoredWindow, metadata: {space: active.id, theme: 'ocean', emoji: '',
    gradient: '', grain: '0'}});
  state = await waitFor(state => {
    const space = visible(state).spaces.find(space => space.id === active.id);
    return !('gradient' in space) && !('grain' in space);
  }, 'gradient cleared');
  report.checks.push('Spaces keep a gradient and grain, and return to a single color');

  // Little window for links from other apps.
  await command('testExternalLinks', {windowId: restoredWindow, urls: [base + '/little']});
  state = await waitFor(state => visible(state)?.popups.some(popup => popup.kind === 'little' && popup.url === base + '/little'), 'little window');
  assert.ok(!tabWith(state, '/little'), 'The link is not added as a tab');
  await command('testPopupCommand', {windowId: restoredWindow, kind: 'little', text: 'expand'});
  state = await waitFor(state => visible(state)?.popups.length === 0 && tabWith(state, '/little')?.active, 'little becomes tab');
  await command('setLittleWindow', {windowId: restoredWindow, text: 'off'});
  state = await waitFor(state => visible(state)?.features.littleWindow === false, 'little window off');
  await command('setLittleWindow', {windowId: restoredWindow, text: 'on'});
  report.checks.push('Links from other apps open in a Little window that can move into the space');

  await browser.close(); browser = null;
  report.passed = true;
  console.log(`${report.checks.length} Bark feature checks passed`);
} catch (error) {
  report.error = String(error.stack ?? error);
  console.error(error);
  process.exitCode = 1;
} finally {
  fs.writeFileSync(path.join(reports, 'report.json'), JSON.stringify(report, null, 2));
  await browser?.close().catch(() => {});
  server.close();
  fs.rmSync(profile, {recursive: true, force: true});
}
