// Which pages belong to which meeting app, read from meeting-sites.json.
//
// That file is the one list of meeting sites. The manifests' host lists, the
// tabs the background page injects into at startup, and the provider names the
// app accepts are all checked against it by the tests. Each entry's `provider`
// is the name the app maps to a meeting app (`browserExtensionID` in
// Sources/PipitCore/MeetingApps), and content.js has a page reader for each.
//
// The build replaces the import with the file's contents, since neither a
// content script nor a service worker can load JSON this way.
import MEETING_SITES from './meeting-sites.json' with { type: 'json' };

// The host part of a manifest match pattern. `*.zoom.us` covers zoom.us and
// every subdomain; a plain host covers only itself.
function hostRule(pattern) {
  const host = new URL(pattern.replace('://*.', '://wildcard.')).hostname;
  return pattern.includes('://*.')
    ? { suffix: host.slice('wildcard.'.length) }
    : { exact: host };
}

function hostMatches(host, rule) {
  if (rule.exact) return host === rule.exact;
  // The dot boundary keeps `notzoom.us` out.
  return host === rule.suffix || host.endsWith(`.${rule.suffix}`);
}

export function siteMatchPatterns() {
  return MEETING_SITES.flatMap((site) => site.matches);
}

export function siteForURL(href) {
  let url;
  try {
    url = new URL(href);
  } catch {
    return null;
  }
  if (url.protocol !== 'https:') return null;
  const host = url.hostname.toLowerCase();
  return MEETING_SITES.find((site) =>
    site.matches.some((pattern) => hostMatches(host, hostRule(pattern))),
  ) ?? null;
}

export function providerForURL(href) {
  return siteForURL(href)?.provider ?? 'unknown';
}

export function meetingIdForURL(href) {
  const site = siteForURL(href);
  if (!site) return null;
  const path = new URL(href).pathname;
  for (const pattern of site.meetingIdPatterns) {
    const match = path.match(new RegExp(pattern, 'i'));
    if (match) return match[1].toLowerCase();
  }
  return null;
}
