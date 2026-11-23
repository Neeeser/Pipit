import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import MEETING_SITES from '../shared/meeting-sites.json' with { type: 'json' };
import { providerForURL, meetingIdForURL, siteMatchPatterns } from '../shared/sites.js';

const read = (path) => readFileSync(new URL(path, import.meta.url), 'utf8');

test('a wildcard site covers its domain and subdomains, with a dot boundary', () => {
  assert.equal(providerForURL('https://zoom.us/wc/1/join'), 'zoom');
  assert.equal(providerForURL('https://us02web.zoom.us/wc/1/join'), 'zoom');
  assert.equal(providerForURL('https://notzoom.us/wc/1/join'), 'unknown');
});

test('a plain site covers only its own host', () => {
  assert.equal(providerForURL('https://meet.google.com/jfp-btbt-owm'), 'meet');
  assert.equal(providerForURL('https://notmeet.google.com/jfp-btbt-owm'), 'unknown');
  assert.equal(providerForURL('https://google.com/'), 'unknown');
});

test('only https pages are meeting pages, as the manifests grant', () => {
  assert.equal(providerForURL('http://meet.google.com/jfp-btbt-owm'), 'unknown');
});

test('meeting identifiers come from the first pattern that matches', () => {
  assert.equal(meetingIdForURL('https://meet.google.com/JFP-BTBT-OWM?authuser=0'), 'jfp-btbt-owm');
  assert.equal(meetingIdForURL('https://app.zoom.us/wc/81771591841/join'), '81771591841');
  assert.equal(meetingIdForURL('https://app.zoom.us/meeting/81771591841'), '81771591841');
  assert.equal(meetingIdForURL('https://meet.google.com/landing'), null);
  assert.equal(meetingIdForURL('https://example.com/81771591841'), null);
});

test('every site has a provider, match patterns and at least one meeting-ID pattern', () => {
  const providers = MEETING_SITES.map((site) => site.provider);
  assert.equal(new Set(providers).size, providers.length, 'a provider is listed twice');
  for (const site of MEETING_SITES) {
    assert.match(site.provider, /^[a-z]+$/);
    assert.ok(site.matches.length > 0, `${site.provider} has no match patterns`);
    for (const pattern of site.matches) assert.match(pattern, /^https:\/\/(\*\.)?[a-z0-9.-]+\/\*$/);
    assert.ok(site.meetingIdPatterns.length > 0, `${site.provider} has no meeting-ID pattern`);
  }
});

// A site added to the list but not to a manifest never gets the content
// script, and one added to a manifest but not the list is a permission the
// sensor does nothing with. Either way the manifests must equal the list.
test('each manifest grants exactly the meeting sites, and injects into them', () => {
  const expected = [...siteMatchPatterns()].sort();
  for (const browser of ['chrome', 'firefox', 'safari']) {
    const manifest = JSON.parse(read(`../${browser}/manifest.json`));
    const hosts = (manifest.host_permissions ?? manifest.permissions).filter((entry) =>
      entry.includes('://'),
    );
    assert.deepEqual([...hosts].sort(), expected, `${browser} host permissions`);
    assert.deepEqual(
      [...manifest.content_scripts[0].matches].sort(), expected, `${browser} content script matches`,
    );
  }
});

test('every page reader belongs to a listed site', () => {
  // A reader for a provider the list does not have never runs, which usually
  // means one of the two was renamed.
  const content = read('../shared/content.js');
  const readers = content.slice(content.indexOf('const SITE_READERS = {'));
  const block = readers.slice(0, readers.indexOf('};'));
  const named = [...block.matchAll(/\n\s+([a-z]+): \{/g)].map((match) => match[1]);
  assert.ok(named.length > 0, 'no readers found');
  const providers = new Set(MEETING_SITES.map((site) => site.provider));
  for (const name of named) assert.ok(providers.has(name), `reader ${name} has no site`);
});
