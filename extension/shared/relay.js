// Builds the envelope the background script sends to the native host.
//
// Kept apart from background.js so it can be tested under Node. The build
// concatenates it in front of background.js, because a Chrome MV3 service
// worker names a single file and cannot pick up a second one from the manifest.

// Adds the tab and the audible-tab count, which only the background script
// knows, to what the content script observed. `sentAt` is the time of the
// observation and survives the relay. Two audible-tab queries can finish out of
// order, so stamping the finish time here made an older observation carry a
// newer time, and the app's stale-event guard then kept the wrong one.
export function relayEnvelope(message, tabId, otherAudibleTabs) {
  const sentAt = typeof message.sentAt === 'number' ? message.sentAt : Date.now();
  return { ...message, tabId, otherAudibleTabs, sentAt };
}

// The wire shape this add-on speaks. The app carries the number it needs and
// tells the person to update the add-on when this one is lower. It moves only
// with a change the app depends on, never with a release that leaves the
// add-on alone.
export const SENSOR_PROTOCOL = 2;

export function helloMessage(extensionVersion, sentAt = Date.now()) {
  return { type: 'hello', extensionVersion, protocol: SENSOR_PROTOCOL, sentAt };
}

// How many tabs other than the meeting's own are playing audio.
//
// Undefined when the browser cannot say. Safari has no `audible` on its tabs
// and ignores that filter in a query, so it hands back every open tab, and
// counting those reported a quiet window full of tabs as competing audio.
export function otherAudibleTabs(tabs, senderTabId) {
  if (!Array.isArray(tabs)) return undefined;
  if (!tabs.some((tab) => tab && typeof tab.audible === 'boolean')) return undefined;
  return tabs.filter((tab) => tab.audible === true && tab.id !== senderTabId).length;
}

// Whether this browser keeps a native port open to Pipit's relay.
//
// Firefox and the Chromium browsers start Pipit's relay as a process and hold
// it for the life of the port. Safari has no such relay: each message goes to
// the app extension bundled inside Pipit, which handles it and may be stopped
// between messages, so it is sent one at a time instead. The extension's own
// address is the reliable tell; the user agent of every Chromium browser on a
// Mac also says Safari.
export function usesNativePort(extensionURL) {
  return !String(extensionURL || '').startsWith('safari-web-extension:');
}

// How often Safari's add-on says it is there. Its background page is unloaded
// when idle, so nothing would reach Pipit between meetings without this, and
// the app could not tell a loaded add-on from a missing one. One minute is the
// shortest period the alarms API allows.
export const SAFARI_HELLO_MINUTES = 1;
