import test from 'node:test';
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';
import {
  otherAudibleTabs,
  usesNativePort,
  SAFARI_HELLO_MINUTES,
  SENSOR_PROTOCOL,
} from '../shared/relay.js';

const read = (path) => readFileSync(new URL(path, import.meta.url), 'utf8');
const manifest = (browser) => JSON.parse(read(`../${browser}/manifest.json`));
const BROWSERS = ['firefox', 'chrome', 'safari'];

test('the audible count leaves out the meeting tab', () => {
  const tabs = [
    { id: 1, audible: true },
    { id: 2, audible: true },
    { id: 3, audible: false },
  ];
  assert.equal(otherAudibleTabs(tabs, 1), 1);
  assert.equal(otherAudibleTabs([{ id: 1, audible: true }], 1), 0);
});

test('a browser that cannot say which tabs play audio reports no count', () => {
  // Safari ignores the `audible` filter and returns every tab without the
  // property. Counting those would report every open tab as competing audio.
  assert.equal(otherAudibleTabs([{ id: 1 }, { id: 2 }, { id: 3 }], 1), undefined);
  assert.equal(otherAudibleTabs(undefined, 1), undefined);
  assert.equal(otherAudibleTabs([], 1), undefined);
});

test('only Safari sends message by message', () => {
  assert.equal(usesNativePort('moz-extension://0d1e/'), true);
  assert.equal(usesNativePort('chrome-extension://lcgklngllaakialhbekpihnjlciiijoc/'), true);
  assert.equal(usesNativePort('safari-web-extension://4C3A/'), false);
  assert.equal(usesNativePort(undefined), true);
});

test('every browser loads the same sensor on the same pages', () => {
  const [first, ...rest] = BROWSERS.map(manifest);
  for (const other of rest) {
    assert.equal(other.version, first.version);
    assert.deepEqual(other.content_scripts, first.content_scripts);
    assert.deepEqual(other.icons, first.icons);
  }
  for (const browser of BROWSERS) {
    const m = manifest(browser);
    assert.ok(m.permissions.includes('nativeMessaging'), `${browser} cannot reach Pipit`);
    const hosts = m.host_permissions ?? m.permissions.filter((p) => p.startsWith('https://'));
    assert.deepEqual(hosts, first.content_scripts[0].matches, `${browser} cannot read the meeting pages`);
  }
});

test('Safari wakes its background page to say hello', () => {
  const safari = manifest('safari');
  assert.equal(safari.manifest_version, 3);
  assert.ok(safari.permissions.includes('alarms'));
  assert.deepEqual(safari.background.scripts, ['shared/background.js']);
});

// Chrome derives an unpacked extension's identifier from the key in its
// manifest. The native host manifest Pipit writes allows that identifier and
// no other, so the two must agree or Chrome refuses the connection silently.
test('the Chrome key gives the identifier Pipit allows', () => {
  const key = Buffer.from(manifest('chrome').key, 'base64');
  const hex = createHash('sha256').update(key).digest('hex').slice(0, 32);
  const id = [...hex].map((c) => String.fromCharCode(97 + parseInt(c, 16))).join('');
  const swift = read('../../Sources/PipitCore/Detection/SensorProtocol.swift');
  const allowed = swift.match(/chromeExtensionID = "([a-p]{32})"/);
  assert.ok(allowed, 'SensorTransport.chromeExtensionID is missing');
  assert.equal(allowed[1], id);
});

// The background script as build.sh assembles it: relay.js without its module
// syntax, followed by background.js.
function backgroundSource() {
  const relay = read('../shared/relay.js').replace(/^export (function|const|let|class)/gm, '$1');
  return `${relay}\n${read('../shared/background.js')}`;
}

function fakeBrowser(extensionURL, tabs) {
  const calls = { native: [], posted: [], alarms: [], injected: [] };
  const listeners = { message: [], alarm: [] };
  const browser = {
    runtime: {
      id: 'self',
      getURL: () => extensionURL,
      getManifest: () => ({ version: '9.9.9' }),
      sendNativeMessage: async (host, message) => {
        calls.native.push({ host, message });
        return { type: 'ack', connected: true };
      },
      connectNative: () => ({
        onDisconnect: { addListener() {} },
        onMessage: { addListener() {} },
        postMessage: (message) => calls.posted.push(message),
      }),
      onMessage: { addListener: (fn) => listeners.message.push(fn) },
    },
    tabs: {
      query: async () => tabs,
      onRemoved: { addListener() {} },
    },
    scripting: {
      executeScript: async (details) => calls.injected.push(details),
    },
    alarms: {
      create: (name, info) => calls.alarms.push({ name, info }),
      onAlarm: { addListener: (fn) => listeners.alarm.push(fn) },
    },
  };
  return { browser, calls, listeners };
}

function load(browser) {
  vm.runInNewContext(backgroundSource(), {
    browser,
    setTimeout,
    clearTimeout,
    Date,
  });
}

const plain = (value) => JSON.parse(JSON.stringify(value));

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

test('Safari relays each observation to the app extension', async () => {
  const { browser, calls, listeners } = fakeBrowser('safari-web-extension://4C3A/', [
    { id: 7, url: 'https://meet.google.com/abc-defg-hij' },
    { id: 8, url: 'https://example.com/' },
  ]);
  load(browser);
  await settle();

  const hello = calls.native.find((call) => call.message.type === 'hello');
  assert.ok(hello, 'Safari never said hello');
  assert.equal(hello.message.extensionVersion, '9.9.9');
  assert.equal(hello.message.protocol, SENSOR_PROTOCOL);
  // Objects made inside the script's own context have its prototypes, so
  // they are compared by value.
  assert.deepEqual(plain(calls.alarms), [
    { name: 'pipit-hello', info: { periodInMinutes: SAFARI_HELLO_MINUTES } },
  ]);
  assert.equal(calls.posted.length, 0, 'Safari has no native port');

  await listeners.message[0](
    { type: 'state', provider: 'meet', state: 'in_call', sentAt: 1000 },
    { id: 'self', tab: { id: 7 } }
  );
  const state = calls.native.find((call) => call.message.type === 'state');
  assert.ok(state, 'the observation never reached the app extension');
  assert.equal(state.message.tabId, 7);
  assert.equal(state.message.sentAt, 1000);
  assert.equal(state.message.otherAudibleTabs, undefined);

  calls.native.length = 0;
  listeners.alarm[0]({ name: 'pipit-hello' });
  await settle();
  assert.equal(calls.native.length, 1);
  assert.equal(calls.native[0].message.type, 'hello');
});

test('a message from another extension is not relayed', async () => {
  const { browser, calls, listeners } = fakeBrowser('safari-web-extension://4C3A/', []);
  load(browser);
  await settle();
  calls.native.length = 0;
  await listeners.message[0]({ type: 'state', state: 'in_call' }, { id: 'other', tab: { id: 1 } });
  assert.equal(calls.native.length, 0);
});

test('Chrome holds a native port and greets through it', async () => {
  const { browser, calls, listeners } = fakeBrowser(
    'chrome-extension://lcgklngllaakialhbekpihnjlciiijoc/',
    [
      { id: 7, audible: true },
      { id: 9, audible: true },
    ]
  );
  load(browser);
  await settle();

  assert.equal(calls.native.length, 0);
  assert.equal(calls.alarms.length, 0);
  assert.equal(calls.posted[0].type, 'hello');

  await listeners.message[0](
    { type: 'state', provider: 'zoom', state: 'in_call', sentAt: 2000 },
    { id: 'self', tab: { id: 7 } }
  );
  const state = calls.posted.find((message) => message.type === 'state');
  assert.equal(state.otherAudibleTabs, 1);
});

test('open meeting tabs get the sensor without a reload', async () => {
  const { browser, calls } = fakeBrowser('safari-web-extension://4C3A/', [{ id: 7 }]);
  // Safari refuses an option it does not know, so the first call fails.
  let attempts = 0;
  browser.scripting.executeScript = async (details) => {
    attempts += 1;
    if ('injectImmediately' in details) throw new TypeError('unknown key');
    calls.injected.push(details);
  };
  load(browser);
  await settle();
  await settle();
  assert.equal(attempts, 2);
  assert.deepEqual(plain(calls.injected[0].files), ['shared/provider.js', 'shared/content.js']);
});
