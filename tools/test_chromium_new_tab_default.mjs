#!/usr/bin/env node
// Test the macOS bundle's own New Tab default and extension override headlessly.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';
import {Browser, bundleEnablesSwiftUI, expectTitle} from './test_chromium_browser.mjs';

assert.equal(process.platform, 'darwin');
const nativeDefault = bundleEnablesSwiftUI();
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'bark-new-tab-default-'));
const browser = new Browser(path.join(directory, 'profile'), path.join(directory, 'browser.log'), {
  loadFixture: false, extraFlags: ['--enable-automation'],
});

async function newTabDocument() {
  const {targetId} = await browser.send('Target.createTarget', {
    url: 'data:text/html,<title>Before navigation</title>',
  });
  try {
    const {sessionId} = await browser.send('Target.attachToTarget', {targetId, flatten: true});
    await browser.send('Page.enable', {}, sessionId);
    await expectTitle(browser, sessionId, 'Before navigation');
    const nav = await browser.send('Page.navigate', {url: 'chrome://newtab/'}, sessionId);
    assert.ok(!nav.errorText && nav.loaderId, nav.errorText);
    for (let attempt = 0; attempt < 100; attempt++) {
      const {frameTree} = await browser.send('Page.getFrameTree', {}, sessionId);
      if (frameTree.frame.loaderId === nav.loaderId) {
        const {result} = await browser.send('Runtime.evaluate', {
          expression: `document.readyState === 'complete' && ({
            url: location.href, title: document.title, empty: document.body?.childElementCount === 0})`,
          returnByValue: true,
        }, sessionId);
        if (result.value) return result.value;
      }
      await delay(100);
    }
    throw new Error('New Tab navigation did not commit and finish loading');
  } finally {
    await browser.send('Target.closeTarget', {targetId});
  }
}

try {
  const args = (await browser.send('Browser.getBrowserCommandLine')).arguments;
  assert.ok(args.includes('--headless') && !args.includes('--bark-swift-ui'));
  const initial = await newTabDocument();
  if (nativeDefault) {
    assert.equal(initial.url, 'about:blank');
    assert.equal(initial.empty, true);
  } else {
    assert.equal(initial.url, 'chrome://new-tab-page/');
  }

  const extension = path.join(directory, 'extension');
  fs.mkdirSync(extension);
  fs.writeFileSync(path.join(extension, 'manifest.json'), JSON.stringify({
    manifest_version: 3, name: 'Bark New Tab fixture', version: '1.0',
    chrome_url_overrides: {newtab: 'newtab.html'},
  }));
  fs.writeFileSync(path.join(extension, 'newtab.html'), '<title>Extension New Tab</title>');
  const {id} = await browser.send('Extensions.loadUnpacked', {path: extension});
  const overridden = await newTabDocument();
  assert.equal(overridden.url, `chrome-extension://${id}/newtab.html`);
  assert.equal(overridden.title, 'Extension New Tab');
  console.log(`Verified bundle default ${initial.url} and New Tab extension override`);
} finally {
  await browser.close();
  fs.rmSync(directory, {recursive: true, force: true});
}
