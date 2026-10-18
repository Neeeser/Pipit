// Relays content-script observations to the native host, and counts audible tabs.
//
// The helpers come from shared/relay.js, which the build concatenates in front
// of this file.
/* global relayEnvelope, helloMessage, otherAudibleTabs, usesNativePort */
/* global SAFARI_HELLO_MINUTES */

const api = globalThis.browser ?? globalThis.chrome;
const HOST_NAME = 'com.pipit.sensor';
const NATIVE_PORT = usesNativePort(api.runtime.getURL(''));
const HELLO_ALARM = 'pipit-hello';

let port = null;

// Retry after a dropped connection, backing off to a minute. Pipit not running
// is the common case, and each attempt spawns a host process that exits at
// once, so this trades a spawn per minute for Pipit seeing the add-on within a
// minute of starting up.
const RECONNECT_MIN_MS = 5_000;
const RECONNECT_MAX_MS = 60_000;
let reconnectDelay = RECONNECT_MIN_MS;
let reconnectTimer = null;

function scheduleReconnect() {
  if (reconnectTimer) return;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connect();
  }, reconnectDelay);
  reconnectDelay = Math.min(reconnectDelay * 2, RECONNECT_MAX_MS);
}

function connect() {
  if (port) return port;
  try {
    port = api.runtime.connectNative(HOST_NAME);
    port.onDisconnect.addListener(() => {
      port = null;
      scheduleReconnect();
    });
    port.onMessage.addListener(() => {
      // The host answered, so this connection reached Pipit. Anything that
      // drops it after this is a fresh problem and gets the short retry again.
      reconnectDelay = RECONNECT_MIN_MS;
    });
    port.postMessage(helloMessage(api.runtime.getManifest().version));
  } catch {
    port = null;
    scheduleReconnect();
  }
  return port;
}

// Safari's route: one message per request to the app extension inside Pipit.
// A refusal means Pipit is not running, which the next message retries.
async function sendToApp(message) {
  try {
    await api.runtime.sendNativeMessage(HOST_NAME, message);
  } catch {
    // Nothing to do: the app treats a silent sensor as absent.
  }
}

function sayHello() {
  sendToApp(helloMessage(api.runtime.getManifest().version));
}

function post(message) {
  if (!NATIVE_PORT) {
    sendToApp(message);
    return;
  }
  const active = connect();
  if (!active) return;
  try {
    active.postMessage(message);
  } catch {
    port = null;
  }
}

// A browser plays every tab through the same audio process, so meeting audio
// cannot be separated from a video playing in another tab. The count is
// reported so the app can say so; it never blocks or delays recording.
async function countOtherAudibleTabs(senderTabId) {
  try {
    return otherAudibleTabs(await api.tabs.query({ audible: true }), senderTabId);
  } catch {
    return undefined;
  }
}

api.runtime.onMessage.addListener(async (message, sender) => {
  // Only this extension's own content scripts, running in a tab.
  if (!sender || sender.id !== api.runtime.id || !sender.tab) return;
  if (!message || message.type !== 'state') return;
  const tabId = sender.tab ? sender.tab.id : null;
  const otherAudibleTabs = await countOtherAudibleTabs(tabId);
  post(relayEnvelope(message, tabId, otherAudibleTabs));
});

api.tabs.onRemoved.addListener((tabId) => {
  post({ type: 'tab_removed', tabId, sentAt: Date.now() });
});

// Order matters: provider.js defines what content.js calls.
const CONTENT_FILES = ['shared/provider.js', 'shared/content.js'];

// MV3 has scripting.executeScript; MV2 has tabs.executeScript, and one file at a
// time. Firefox ships MV2 here, so both paths are needed.
async function injectInto(tabId) {
  if (api.scripting && api.scripting.executeScript) {
    const details = { target: { tabId }, files: CONTENT_FILES };
    try {
      await api.scripting.executeScript({ ...details, injectImmediately: true });
    } catch {
      // Safari rejects an option it does not know rather than ignoring it.
      await api.scripting.executeScript(details);
    }
    return;
  }
  for (const file of CONTENT_FILES) {
    await api.tabs.executeScript(tabId, { file, runAt: 'document_idle' });
  }
}

// Content scripts do not appear in tabs that were already open when the
// extension loaded, so they are injected explicitly at startup. Without this a
// meeting already on screen is invisible until the tab is reloaded.
async function injectIntoOpenTabs() {
  try {
    const tabs = await api.tabs.query({
      url: ['https://meet.google.com/*', 'https://*.zoom.us/*'],
    });
    for (const tab of tabs) {
      try {
        await injectInto(tab.id);
      } catch {
        // A tab that refuses injection simply reports nothing.
      }
    }
  } catch {
    // Injection is unavailable; newly opened tabs still work.
  }
}

injectIntoOpenTabs();

// Connecting at startup is what lets Pipit tell a loaded add-on from a missing
// one. Waiting for the first meeting made the two look identical, so Settings
// reported "not installed" for an add-on that was loaded and working, and the
// menu bar could not warn when a temporary add-on was dropped.
//
// Safari has no connection to hold, so it says hello when its background page
// starts and again on an alarm. The listener is registered at the top level
// because Safari only wakes a background page for listeners that exist when it
// first runs.
if (NATIVE_PORT) {
  connect();
} else {
  sayHello();
  if (api.alarms) {
    api.alarms.onAlarm.addListener((alarm) => {
      if (alarm && alarm.name === HELLO_ALARM) sayHello();
    });
    api.alarms.create(HELLO_ALARM, { periodInMinutes: SAFARI_HELLO_MINUTES });
  }
}
