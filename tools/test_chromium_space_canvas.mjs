#!/usr/bin/env node
// Color-point themes round-trip through the native bridge and persisted catalog.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';
import {Browser, uiDriver} from './test_chromium_browser.mjs';

const root = path.resolve('test-results/chromium-space-canvas');
fs.mkdirSync(root, {recursive: true});
const reports = fs.mkdtempSync(path.join(root, 'run-'));
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'bark-space-canvas-'));
const driver = path.join(profile, '.bark-ui-driver');
fs.mkdirSync(driver);
const report = {passed: false, checks: []};
let browser;
const visible = state => state.windows.find(window => window.visible && !window.incognito);
const ui = uiDriver({directory: () => driver, browser: () => browser});
const {command} = ui;
async function waitFor(predicate, label) {
  for (let attempt = 0; attempt < 100; attempt++) {
    const window = visible(await command());
    if (predicate(window)) return window;
    await delay(50);
  }
  throw Error('Timed out: ' + label);
}
function launch(name) {
  for (const file of ['request.json', 'response.json']) fs.rmSync(path.join(driver, file), {force: true});
  return new Browser(profile, path.join(reports, name + '.log'), {
    nativeWindow: true, nativeUI: true, loadFixture: false, testDirectory: driver,
    initialURL: 'data:text/html,<title>Space theme test</title><body>Space theme test</body>',
  });
}
try {
  assert.equal(process.platform, 'darwin');
  browser = launch('save');
  let window = await waitFor(window => !!window?.activeSpaceId, 'initial window');
  const original = window.activeSpaceId;
  const canvas = {startColor: '#7C68A6', endColor: '#AB607D', start: {x: 0.17, y: 0.19}, end: {x: 0.64, y: 0.62}};
  const edit = metadata => command('customizeSpace', {windowId: window.windowId, metadata: {space: original, ...metadata}});
  const saved = window => window.spaces.find(space => space.id === original);
  await edit({theme: 'lavender', emoji: '', gradient: 'rose', grain: '0.40', gradientCanvas: JSON.stringify(canvas)});
  window = await waitFor(window => saved(window)?.gradientCanvas?.start?.x === 0.17, 'saved canvas');
  assert.deepEqual(saved(window).gradientCanvas, canvas);
  assert.equal(saved(window).grain, 0.4);
  report.checks.push('Exact RGB colors, normalized points and grain reach the native space snapshot');

  for (const invalid of [
    {...canvas, startColor: '#GG0000'},
    {...canvas, start: {x: -0.2, y: 0.19}},
    {...canvas, end: {x: 0.64, y: 1.2}},
    {...canvas, start: {x: '0.17', y: 0.19}},
    {startColor: canvas.startColor, endColor: canvas.endColor},
    {...canvas, extra: true},
  ]) {
    await edit({gradientCanvas: JSON.stringify(invalid)});
    assert.deepEqual(saved(visible(await command())).gradientCanvas, canvas);
  }
  await edit({gradientCanvas: '{malformed'});
  assert.deepEqual(saved(visible(await command())).gradientCanvas, canvas);
  report.checks.push('Malformed colors, missing coordinates and invalid geometry cannot overwrite a saved theme');

  await edit({theme: 'lavender', emoji: '🎨', name: 'Canvas theme'});
  window = await waitFor(window => saved(window)?.name === 'Canvas theme', 'renamed space');
  assert.deepEqual(saved(window).gradientCanvas, canvas);
  report.checks.push('Editing space details without theme metadata preserves the canvas');

  const otherCanvas = {...canvas, startColor: '#477E9B', endColor: '#3D8270', start: {x: 0, y: 0}, end: {x: 1, y: 1}};
  await command('createSpace', {windowId: window.windowId, text: 'Ocean canvas', metadata: {
    theme: 'ocean', emoji: '', gradient: 'mint', grain: '0', gradientCanvas: JSON.stringify(otherCanvas),
  }});
  window = await waitFor(window => window?.activeSpaceId !== original && window?.spaces.some(space => space.name === 'Ocean canvas'), 'second space');
  const other = window.activeSpaceId;
  assert.deepEqual(window.spaces.find(space => space.id === other).gradientCanvas, otherCanvas);
  assert.deepEqual(saved(window).gradientCanvas, canvas);
  report.checks.push('New spaces accept their own canvas, including valid integer edge coordinates');

  await browser.close(); browser = launch('restore');
  // The catalog is available before Chromium finishes restoring its tabs and
  // Bark's deferred window presentation. Wait for that presentation to settle
  // before issuing a switch, which startup could otherwise immediately undo.
  let restoredSignature = '', settledSince = 0;
  window = await waitFor(window => {
    if (!window || window.activeSpaceId !== other || window.switchingSpace || !saved(window)) return false;
    const signature = JSON.stringify([window.windowId, window.windowGroup, window.allTabs.map(tab => tab.id)]);
    if (signature !== restoredSignature) { restoredSignature = signature; settledSince = Date.now(); }
    return Date.now() - settledSince >= 500;
  }, 'restored catalog and settled window');
  assert.deepEqual(saved(window).gradientCanvas, canvas);
  assert.deepEqual(window.spaces.find(space => space.id === other).gradientCanvas, otherCanvas);
  await command('space', {windowId: window.windowId, text: original});
  window = await waitFor(window => window?.activeSpaceId === original, 'switch to restored theme');
  assert.deepEqual(saved(window).gradientCanvas, canvas);
  report.checks.push('Both spaces keep their exact themes after browser restart and space switching');

  await edit({theme: 'sage', emoji: ''});
  window = await waitFor(window => saved(window)?.theme === 'sage' && !('gradientCanvas' in saved(window)), 'legacy color selection');
  assert.equal(saved(window).gradient, 'rose');
  await edit({theme: 'lavender', emoji: '', gradientCanvas: JSON.stringify(canvas)});
  window = await waitFor(window => saved(window)?.gradientCanvas?.startColor === canvas.startColor, 'restored custom color');
  assert.deepEqual(saved(window).gradientCanvas, canvas);
  report.checks.push('Older named-theme controls remain effective, while native canvas edits preserve exact colors');

  await edit({theme: 'ocean', emoji: '', gradient: '', grain: '0', gradientCanvas: ''});
  window = await waitFor(window => saved(window) && !('gradientCanvas' in saved(window)), 'clear canvas');
  assert.ok(!('gradient' in saved(window)) && !('grain' in saved(window)));
  assert.deepEqual(window.spaces.find(space => space.id === other).gradientCanvas, otherCanvas);
  report.checks.push('Clearing a custom theme restores a legacy solid without changing another space');
  report.passed = true;
  console.log(`${report.checks.length} space canvas checks passed: ${reports}`);
} catch (error) {
  report.error = String(error.stack ?? error);
  fs.writeFileSync(path.join(reports, 'last-state.json'), JSON.stringify(ui.latest ?? {}, null, 2));
  console.error(error);
  process.exitCode = 1;
} finally {
  fs.writeFileSync(path.join(reports, 'report.json'), JSON.stringify(report, null, 2));
  await browser?.close().catch(() => {});
  fs.rmSync(profile, {recursive: true, force: true});
}
