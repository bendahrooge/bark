#!/usr/bin/env node
// Check the real About page in both development and signed release bundles.
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
import {setTimeout as delay} from 'node:timers/promises';
import {Browser} from './test_chromium_browser.mjs';

assert.equal(process.platform, 'darwin', 'The Sparkle About page is macOS-only');
const root = path.dirname(path.dirname(fileURLToPath(import.meta.url)));
const binary = path.resolve(process.argv[2] || path.join(root,
  '.deps/chromium-source/src/out/Bark-mac-arm64/Bark-dev.app/Contents/MacOS/Bark'));
const info = JSON.parse(execFileSync('plutil', ['-convert', 'json', '-o', '-',
  path.join(path.dirname(binary), '../Info.plist')], {encoding: 'utf8'}));
const configured = !!(info.SUFeedURL && info.SUPublicEDKey);
const resultsRoot = path.join(root, 'test-results/chromium-updates');
fs.mkdirSync(resultsRoot, {recursive: true});
const reports = fs.mkdtempSync(path.join(resultsRoot, 'run-'));
const profile = fs.mkdtempSync(path.join(os.tmpdir(), 'bark-about-test-'));
const browser = new Browser(profile, path.join(reports, 'browser.log'), {
  nativeWindow: true, nativeUI: true, loadFixture: false,
});
const report = {passed: false, binary, configured, checks: []};
const snapshot = `(() => {
  function find(root) {
    const page = root.querySelector('settings-about-page');
    if (page) return page;
    for (const node of root.querySelectorAll('*')) {
      if (node.shadowRoot) { const found = find(node.shadowRoot); if (found) return found; }
    }
  }
  const page = find(document)?.shadowRoot;
  const button = page?.querySelector('#barkCheckForUpdates');
  if (!button) return null;
  return {text: page.textContent,
    release: page.querySelector('#barkReleaseVersion').textContent.trim(),
    engine: page.querySelector('#barkEngineVersion').textContent.trim(),
    description: page.querySelector('#barkUpdateDescription').textContent.trim(),
    disabled: button.disabled,
    googleUpdater: !!page.querySelector('a[href*="support.google.com/chrome?p=update_error"]')};
})()`;

try {
  for (const url of ['chrome://settings/help', 'chrome://help']) {
    const {targetId} = await browser.send('Target.createTarget', {url});
    const {sessionId} = await browser.send('Target.attachToTarget', {targetId, flatten: true});
    async function evaluate(expression) {
      const reply = await browser.send('Runtime.evaluate', {
        expression, awaitPromise: true, returnByValue: true,
      }, sessionId);
      assert.ok(!reply.exceptionDetails, JSON.stringify(reply.exceptionDetails));
      return reply.result.value;
    }
    let page;
    for (let attempt = 0; attempt < 100; ++attempt) {
      page = await evaluate(snapshot);
      if (page) break;
      await delay(100);
    }
    assert.ok(page, `${url}: Bark updates card must be present`);
    assert.equal(page.googleUpdater, false, 'Google update error UI must be absent');
    assert.equal(page.disabled, !configured);
    assert.equal(page.release, configured ? `Version ${info.CFBundleShortVersionString}` : 'Development build');
    assert.match(page.engine, /^Chromium \d+\.\d+\.\d+\.\d+$/);
    if (!configured) assert.match(page.description, /development build does not receive updates/);
    await evaluate(`(async () => {
      window.barkUpdateEvents = [];
      const {addWebUiListener} = await import('chrome://resources/js/cr.js');
      addWebUiListener('update-status-changed', event => window.barkUpdateEvents.push(event));
      chrome.send('refreshUpdateStatus');
    })()`);
    await delay(1500);
    assert.deepEqual(await evaluate('window.barkUpdateEvents'), [],
      'Refreshing the About page must not invoke Chromium updater status events');
    report.checks.push(`${url}: correct Bark/engine versions, update availability, and no Chromium updater`);
    await browser.send('Target.closeTarget', {targetId});
  }
  report.passed = true;
} catch (error) {
  report.error = error.stack;
  throw error;
} finally {
  await browser.close();
  fs.writeFileSync(path.join(reports, 'report.json'), JSON.stringify(report, null, 2) + '\n');
  fs.rmSync(profile, {recursive: true, force: true});
  console.log(`${report.passed ? 'Passed' : 'Failed'} About page checks: ${reports}`);
}
