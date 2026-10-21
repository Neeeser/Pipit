#!/bin/bash
# Crashes the bundled Pipit on purpose and checks the path a crash takes from
# ReportCrash to a symbolicated frame, then kills it without a report and
# checks that the launch reads as unclean_unknown.
#
# The first run sends SIGABRT. ReportCrash writes Pipit-<date>.ips for it, and
# `pipit-cli diagnostics crashes --json` must list that crash with the pid the
# script killed and the executable's UUID, and must say the last launch ended
# in a crash. The faulting thread's frames in Pipit's own image are then
# symbolicated with `atos` against the dSYM scripts/archive-dsyms.sh wrote, and
# at least one must resolve to a Swift file and line. That is the whole chain a
# report from someone else's Mac depends on: the reduction keeps the right
# image, base and offsets, and the archived symbols match the bundled binary.
#
# The second run sends SIGKILL, which leaves no report. The command must then
# say the last launch ended unclean_unknown. Both verdicts on the last launch
# read state/launch.json, which the app writes at launch.
#
# Opt-in, because it crashes a real copy of Pipit on this Mac and leaves its
# report in ~/Library/Logs/DiagnosticReports, and the next launch of Pipit
# finds a launch that did not end cleanly. Quit Pipit first.
#
# Usage: PIPIT_LIVE_CRASH=1 scripts/check-crash-report.sh
# Needs dist/Pipit.app from scripts/bundle-app.sh and dist/dSYMs from
# scripts/archive-dsyms.sh, built from the same tree. PIPIT_CRASH_SETTLE sets
# how many seconds Pipit runs before it is killed, 10 by default.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$REPO_ROOT/dist/Pipit.app"
BINARY="$APP/Contents/MacOS/Pipit"
CLI="$APP/Contents/MacOS/pipit-cli"
DWARF="$REPO_ROOT/dist/dSYMs/Pipit.dSYM/Contents/Resources/DWARF/Pipit"
REPORTS="$HOME/Library/Logs/DiagnosticReports"
SETTLE="${PIPIT_CRASH_SETTLE:-10}"
REPORT_TIMEOUT=90

if [ "${PIPIT_LIVE_CRASH:-}" != "1" ]; then
    echo "check-crash-report: crashes Pipit on purpose; run with PIPIT_LIVE_CRASH=1" >&2
    exit 2
fi
[ "$(uname -s)" = "Darwin" ] || { echo "check-crash-report: macOS only" >&2; exit 2; }
test -x "$BINARY" || { echo "build the app first: scripts/bundle-app.sh release" >&2; exit 1; }
test -f "$DWARF" || { echo "write the symbols first: scripts/archive-dsyms.sh" >&2; exit 1; }
if pgrep -x Pipit >/dev/null; then
    echo "check-crash-report: quit Pipit first; the check launches and kills its own copy" >&2
    exit 1
fi

WORK="$(mktemp -d -t pipit-crash-check)"
LAUNCHED=""
cleanup() {
    if [ -n "$LAUNCHED" ]; then kill -9 "$LAUNCHED" 2>/dev/null || true; fi
    rm -rf "$WORK"
}
trap cleanup EXIT

# Launches the bundle through LaunchServices, as a person would, and prints
# the new process's pid once it is running.
launch() {
    open -n -a "$APP"
    local pid="" waited=0
    while [ -z "$pid" ] && [ "$waited" -lt 30 ]; do
        sleep 1
        waited=$((waited + 1))
        pid="$(pgrep -x Pipit || true)"
    done
    [ -n "$pid" ] || { echo "Pipit did not start within 30 seconds" >&2; return 1; }
    case "$pid" in
        *[!0-9]*) echo "more than one Pipit is running: $pid" >&2; return 1 ;;
    esac
    echo "$pid"
}

# Waits for the process to be gone, so the next step reads a finished launch.
wait_for_exit() {
    local pid="$1" waited=0
    while kill -0 "$pid" 2>/dev/null; do
        [ "$waited" -lt 30 ] || { echo "pid $pid is still running" >&2; return 1; }
        sleep 1
        waited=$((waited + 1))
    done
}

# Runs `pipit diagnostics crashes --json` and answers one question about its
# output with a short Python expression over `listing`, printing the result.
query() {
    "$CLI" diagnostics crashes --json >"$WORK/listing.json"
    python3 -I - "$WORK/listing.json" "$@" <<'PYTHON'
import json
import sys

listing = json.load(open(sys.argv[1]))
pid = int(sys.argv[3]) if len(sys.argv) > 3 else None
crash = next((c for c in listing["crashes"] if c["pid"] == pid), None)
last = listing.get("lastLaunch") or {}
print(eval(sys.argv[2], {"listing": listing, "crash": crash, "last": last, "pid": pid}))
PYTHON
}

echo "==> crash: SIGABRT"
touch "$WORK/marker"
pid="$(launch)"
LAUNCHED="$pid"
sleep "$SETTLE"
kill -ABRT "$pid"
wait_for_exit "$pid"
LAUNCHED=""

# ReportCrash writes the report a few seconds after the process is gone.
report=""
waited=0
while [ -z "$report" ] && [ "$waited" -lt "$REPORT_TIMEOUT" ]; do
    while IFS= read -r candidate; do
        if python3 -I -c 'import json, sys
text = open(sys.argv[1]).read()
sys.exit(0 if json.loads(text.split("\n", 1)[1]).get("pid") == int(sys.argv[2]) else 1)' \
            "$candidate" "$pid" 2>/dev/null; then
            report="$candidate"
        fi
    done < <(find "$REPORTS" -maxdepth 1 -name 'Pipit-*.ips' -newer "$WORK/marker" 2>/dev/null)
    [ -n "$report" ] || { sleep 1; waited=$((waited + 1)); }
done
[ -n "$report" ] || { echo "no Pipit-*.ips for pid $pid within $REPORT_TIMEOUT seconds" >&2; exit 1; }
echo "==> ReportCrash wrote $(basename "$report")"

[ "$(query 'crash is not None' "$pid")" = "True" ] || {
    echo "pipit diagnostics crashes does not list the crash of pid $pid" >&2
    exit 1
}
binary_uuid="$(query 'crash.get("binaryUUID")' "$pid")"
# `dwarfdump --uuid` prints "UUID: <uuid> (<arch>) <path>" for each slice.
dwarf_uuids="$(xcrun dwarfdump --uuid "$BINARY" | awk '{ print tolower($2) }')"
grep -qx "$binary_uuid" <<<"$dwarf_uuids" || {
    echo "the listed executable UUID $binary_uuid is not the bundled binary's: $dwarf_uuids" >&2
    exit 1
}
[ "$(query 'last.get("pid") == pid and last.get("exit") == "crash"' "$pid")" = "True" ] || {
    echo "the last launch does not read as a crash of pid $pid: $(query 'last' "$pid")" >&2
    exit 1
}
echo "==> listed: pid $pid, executable $binary_uuid, last launch crash"

# Each frame in Pipit's own image, as "<arch> <load address> <address>".
frames="$(query '"\n".join("%s 0x%x 0x%x" % (img["arch"], img["base"], img["base"] + f["offset"])
    for f in crash["summary"]["frames"]
    for img in [crash["summary"]["images"][f["image"]]] if img["name"] == "Pipit")' "$pid")"
[ -n "$frames" ] || { echo "the faulting thread has no frame in Pipit's image" >&2; exit 1; }
arch="$(awk 'NR == 1 { print $1 }' <<<"$frames")"
load="$(awk 'NR == 1 { print $2 }' <<<"$frames")"
addresses="$(awk '{ print $3 }' <<<"$frames")"
# atos takes many addresses at once and prints one line for each. The output
# is captured whole before grep reads it, so pipefail sees no SIGPIPE.
# shellcheck disable=SC2086
resolved="$(xcrun atos -arch "$arch" -o "$DWARF" -l "$load" $addresses)"
line="$(grep -E '[.]swift:[1-9][0-9]*[)]' <<<"$resolved" || true)"
[ -n "$line" ] || {
    echo "no faulting frame in Pipit resolved to a Swift line:" >&2
    echo "$resolved" >&2
    exit 1
}
echo "==> symbolicated: $(awk 'NR == 1' <<<"$line")"

echo "==> no report: SIGKILL"
pid="$(launch)"
LAUNCHED="$pid"
sleep "$SETTLE"
kill -9 "$pid"
wait_for_exit "$pid"
LAUNCHED=""
[ "$(query 'last.get("pid") == pid and not last.get("running") and last.get("exit") == "unclean_unknown"' "$pid")" \
    = "True" ] || {
    echo "the killed launch does not read as unclean_unknown: $(query 'last' "$pid")" >&2
    exit 1
}
echo "==> last launch: pid $pid, unclean_unknown"
echo "==> passed"
