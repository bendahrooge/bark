#!/usr/bin/env node
// Verify the on-disk reset after quit, then open the same disposable installation again.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import {setTimeout as delay} from 'node:timers/promises';
import {Browser} from './test_chromium_browser.mjs';

const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'bark-factory-reset-'));
const data = path.join(fixture, 'browser');
const download = path.join(fixture, 'download.txt');
const marker = path.join(data, 'Bark Factory Reset');
fs.mkdirSync(data);
fs.writeFileSync(download, 'keep');
const app = () => new Browser(data, path.join(fixture, 'browser.log'), {
  nativeWindow: process.platform === 'darwin', nativeUI: process.platform === 'darwin', loadFixture: false,
});
async function waitFor(read, description) {
  for (let i = 0; i < 250; i++) {
    try {
      const value = await read();
      if (value) return value;
    } catch (error) {
      if (!/Execution context was destroyed|Cannot find context with specified id/.test(error.message)) throw error;
    }
    await delay(100);
  }
  throw Error('Timed out waiting for ' + description);
}
let browser;
async function page(url) {
  const {targetId} = await browser.send('Target.createTarget', {url});
  const {sessionId} = await browser.send('Target.attachToTarget', {targetId, flatten: true});
  const send = (method, params) => browser.send(method, params, sessionId);
  const evaluate = async expression => {
    const {result, exceptionDetails} = await send('Runtime.evaluate',
        {expression, awaitPromise: true, returnByValue: true});
    if (exceptionDetails) throw Error(exceptionDetails.exception?.description || exceptionDetails.text);
    return result.value;
  };
  const click = async id => {
    const {x,y} = await evaluate(`(() => {
      const element = document.getElementById(${JSON.stringify(id)});
      element.scrollIntoView({block:'center'});
      const box = element.getBoundingClientRect();
      return {x:box.x+box.width/2,y:box.y+box.height/2};
    })()`);
    for (const type of ['mousePressed', 'mouseReleased'])
      await send('Input.dispatchMouseEvent', {type, x, y, button:'left', clickCount:1});
  };
  return {evaluate, click, activate: () => browser.send('Target.activateTarget', {targetId})};
}
const findResetLink = `(function find(root) {
  for (const element of root.querySelectorAll('*')) {
    if (element.id === 'barkFactoryReset') return element;
    if (element.shadowRoot) { const found = find(element.shadowRoot); if (found) return found; }
  }
})(document)`;
const state = "(async () => (await import('chrome://resources/js/cr.js')).sendWithPromise('getState'))()";
const rowsReady = "Boolean(document.querySelector('#profiles [data-focus-key]'))";
let passed = false;
const transfer = http.createServer((_request, response) => {
  response.writeHead(200, {'Content-Type': 'text/plain', 'Content-Length': 65536, 'X-Content-Type-Options':'nosniff',
    'Content-Disposition': 'attachment; filename="in-progress.txt"'});
  response.write('x'.repeat(16384));  // Stays in progress until Bark closes.
});
try {
  browser = app();
  let {evaluate, click, activate} = await page('chrome://settings/reset');
  await waitFor(() => evaluate('Boolean(' + findResetLink + ')'), 'factory reset setting');
  await evaluate('(' + findResetLink + ').click()');
  await waitFor(() => evaluate("location.host === 'spaces' && !!document.querySelector('#deleteDialog')?.open"), 'reset confirmation');
  assert.match(await evaluate("document.querySelector('#deleteBody').textContent"), /every window.*all local spaces, profiles/);
  await click('cancelDelete');
  await browser.send('Storage.setCookies', {cookies: [{
    name: 'factory-reset-test', value: 'old', domain: 'reset-fixture.example', path: '/',
    expires: Date.now() / 1000 + 86400,
  }]});
  assert.ok((await browser.send('Storage.getCookies')).cookies.some(c => c.name === 'factory-reset-test'));
  await evaluate("chrome.send('createProfile', ['Reset fixture'])");
  const extra = await waitFor(async () => (await evaluate(state)).profiles.find(p => p.name === 'Reset fixture' && p.spaces), 'second profile and space');
  assert.notEqual(extra.id, 'Default');
  const oldData = path.join(data, 'Default', 'old-session');
  const safeLink = path.join(data, extra.id, 'external-data');
  fs.writeFileSync(oldData, 'old');
  fs.symlinkSync(path.dirname(download), safeLink);
  fs.writeFileSync(path.join(data, 'unrelated-file'), 'keep');
  const avatar = path.join(data, 'Avatars', 'old-avatar');
  fs.mkdirSync(path.dirname(avatar), {recursive:true});
  fs.writeFileSync(avatar, 'old');
  const notes = path.join(data, 'Profile 500', 'notes.txt');
  fs.mkdirSync(path.dirname(notes));
  fs.writeFileSync(notes, 'keep');
  await click('resetBark');
  await click('cancelDelete');
  assert.ok(fs.existsSync(oldData) && !fs.existsSync(marker));

  // A failed request must leave the browser open and let the user retry.
  fs.mkdirSync(marker);
  await click('resetBark');
  await click('confirmDelete');
  await waitFor(() => evaluate("document.querySelector('#resetStatus').textContent.includes('couldn’t start')"), 'reset failure feedback');
  assert.ok(fs.existsSync(oldData));
  fs.rmdirSync(marker);

  const downloads = path.join(fixture, 'downloads');
  fs.mkdirSync(downloads);
  await new Promise(resolve => transfer.listen(0, '127.0.0.1', resolve));
  let downloading = false;
  browser.onEvent = event => {
    if (event.method === 'Browser.downloadProgress' && event.params.state === 'inProgress') downloading = true;
  };
  await browser.send('Browser.setDownloadBehavior', {behavior:'allow', downloadPath:downloads, eventsEnabled:true});
  await browser.send('Target.createTarget', {url:`http://127.0.0.1:${transfer.address().port}/file`, background:true});
  await waitFor(() => downloading, 'active download');
  await activate();
  await click('resetBark');
  await click('confirmDelete');
  const exit = await Promise.race([browser.exit, delay(30000, null, {ref:false})]);
  assert.equal(exit?.code, 0, 'The original browser should close after confirmation');
  assert.equal(fs.existsSync(marker), false);
  assert.equal(fs.existsSync(oldData), false);
  assert.equal(fs.existsSync(path.join(data, 'Local State')), false);
  assert.equal(fs.existsSync(path.join(data, 'Default')), false);
  assert.equal(fs.existsSync(path.join(data, extra.id)), false);
  assert.equal(fs.existsSync(avatar), false);
  assert.equal(fs.readFileSync(notes, 'utf8'), 'keep');
  assert.equal(fs.readFileSync(download, 'utf8'), 'keep');
  assert.equal(fs.readFileSync(path.join(data, 'unrelated-file'), 'utf8'), 'keep');

  browser = app();
  ({evaluate} = await page('chrome://spaces/'));
  await waitFor(() => evaluate(rowsReady), 'fresh profile on next open');
  const clean = await evaluate(state);
  assert.ok(!(await browser.send('Storage.getCookies')).cookies.some(c => c.name === 'factory-reset-test'));
  assert.deepEqual(clean.profiles.map(profile => profile.id), ['Default']);
  assert.ok(clean.spaces.every(space => space.profile === 'Default' && space.name !== 'Reset fixture'));
  assert.ok(clean.spaces.length > 0 || process.platform !== 'darwin');
  passed = true;
  console.log('Factory reset, cancel, retry, erasure before reopening, fresh profiles, and file isolation passed.');
} finally {
  transfer.closeAllConnections();
  if (transfer.listening) transfer.close();
  if (browser && !browser.exited) await browser.close();
  if (passed) fs.rmSync(fixture, {recursive:true, force:true});
  else console.error('Disposable fixture:', fixture);
}
