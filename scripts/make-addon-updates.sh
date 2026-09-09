#!/bin/bash
# Adds one signed add-on to the Firefox update feed.
#
# Usage: scripts/make-addon-updates.sh <xpi> <download-url> <updates.json>
#
#   xpi           The signed add-on, as Mozilla returned it.
#   download-url  Where that file is served from, which for a release asset is
#                 https://github.com/Neeeser/Pipit/releases/download/v0.2.0/pipit-sensor.xpi
#   updates.json  The feed to write. An existing feed keeps its entries, so a
#                 Firefox that skipped a release still finds the next one.
#
# The add-on's manifest names its update URL, and Firefox fetches this file
# from there once a day. The version in the feed is read from the add-on
# itself, because the release signs it as <app version>.<run number> and only
# the file knows the run number.
set -euo pipefail

XPI="${1:?usage: make-addon-updates.sh <xpi> <download-url> <updates.json>}"
LINK="${2:?usage: make-addon-updates.sh <xpi> <download-url> <updates.json>}"
FEED="${3:?usage: make-addon-updates.sh <xpi> <download-url> <updates.json>}"

test -f "$XPI" || { echo "no such add-on: $XPI" >&2; exit 1; }

XPI="$XPI" LINK="$LINK" FEED="$FEED" python3 - <<'PY'
import json, os, zipfile

xpi, link, feed = os.environ["XPI"], os.environ["LINK"], os.environ["FEED"]
with zipfile.ZipFile(xpi) as archive:
    manifest = json.loads(archive.read("manifest.json"))
version = manifest["version"]
addon_id = manifest["browser_specific_settings"]["gecko"]["id"]

document = {"addons": {}}
if os.path.exists(feed):
    with open(feed) as handle:
        document = json.load(handle)
entries = document.setdefault("addons", {}).setdefault(addon_id, {}).setdefault("updates", [])
entries[:] = [entry for entry in entries if entry.get("version") != version]
entries.append({"version": version, "update_link": link})

os.makedirs(os.path.dirname(feed) or ".", exist_ok=True)
with open(feed, "w") as handle:
    json.dump(document, handle, indent=2)
    handle.write("\n")
print(f"==> {feed}: {addon_id} {version}")
PY
