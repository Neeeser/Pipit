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
