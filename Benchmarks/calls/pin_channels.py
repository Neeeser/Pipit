#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10,<3.14"
# dependencies = ["numpy>=1.26", "scipy>=1.11", "soundfile>=0.12"]
# ///
"""Pin the AMI headset channels the two-track call suite is built from.

Reads the headset channel each annotation agent spoke into from AMI's
`corpusResources/meetings.xml`, downloads every channel into the benchmark
cache, and rewrites the `calls` block at the end of `Benchmarks/manifest.json`
with the channel numbers, their SHA-256 checksums, and the local person the
seed picks for each meeting, and keeps the variants the block already lists.
`scripts/fetch-bench-audio.sh calls` then fetches
and verifies exactly those files.

    scripts/fetch-bench-audio.sh --annotations ami
    Benchmarks/calls/pin_channels.py IS1009a EN2002a EN2002b EN2002d IS1009c

The meetings are given on the command line because only meetings the shipped
models never trained on may rank anything: the script refuses a meeting whose
manifest partition is not `ami-eval` or `clean`.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import callsim  # noqa: E402

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
MANIFEST = os.path.join(ROOT, "Benchmarks", "manifest.json")
TRUTH = os.path.join(ROOT, "Benchmarks", "ground-truth")
CACHE = os.path.expanduser("~/Library/Caches/pipit-bench")
MIRROR = (
    "https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/"
    "{meeting}/audio/{meeting}.Headset-{channel}.wav"
)
ALLOWED_PARTITIONS = {"ami-eval", "clean"}
SEED = 20261119


def channels_of(zip_path, meeting):
    """agent letter -> headset channel number, from meetings.xml."""
    with zipfile.ZipFile(zip_path) as archive:
        text = archive.read("corpusResources/meetings.xml").decode("latin-1")
    for block in re.findall(r"(<meeting\b[^>]*>.*?</meeting>)", text, re.S):
        if re.search(r'observation="%s"' % meeting, block):
            found = {}
            for tag in re.findall(r"<speaker\b[^>]*>", block):
                agent = re.search(r'nxt_agent="([A-E])"', tag)
                channel = re.search(r'channel="(\d+)"', tag)
                if agent and channel:
                    found[agent.group(1)] = int(channel.group(1))
            return found
    raise SystemExit("no participant record for %s" % meeting)


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(4 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download(url, path):
    if os.path.exists(path):
        return
    partial = path + ".partial"
    subprocess.run(["curl", "-fsSL", "--retry", "3", "-o", partial, url], check=True)
    os.replace(partial, path)


def render(calls):
    """The block as hand-formatted JSON, matching the rest of the manifest."""
    lines = ['  "calls": {']
    lines.append('    "seed": %d,' % calls["seed"])
    lines.append('    "mirror": %s,' % json.dumps(calls["mirror"]))
    lines.append('    "variants": [')
    for index, variant in enumerate(calls["variants"]):
        comma = "," if index < len(calls["variants"]) - 1 else ""
        lines.append("      %s%s" % (json.dumps(variant), comma))
    lines.append("    ],")
    lines.append('    "meetings": {')
    names = list(calls["meetings"])
    for index, name in enumerate(names):
        entry = calls["meetings"][name]
        lines.append('      "%s": {' % name)
        lines.append('        "localAgent": "%s",' % entry["localAgent"])
        lines.append('        "channels": {')
        agents = sorted(entry["channels"])
        for position, agent in enumerate(agents):
            comma = "," if position < len(agents) - 1 else ""
            lines.append("          %s: %s%s" % (json.dumps(agent), json.dumps(entry["channels"][agent]), comma))
        lines.append("        }")
        lines.append("      }%s" % ("," if index < len(names) - 1 else ""))
    lines.append("    }")
    lines.append("  }")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("meetings", nargs="+")
    parser.add_argument(
        "--annotations", default=os.path.join(CACHE, "ami_public_manual_1.6.2.zip")
    )
    parser.add_argument("--audio-dir", default=CACHE)
    args = parser.parse_args()

    with open(MANIFEST) as handle:
        text = handle.read()
    manifest = json.loads(text)
    meetings = {}
    for meeting in args.meetings:
        held = manifest["partition"].get(meeting)
        if held not in ALLOWED_PARTITIONS:
            raise SystemExit("%s is %s: only ami-eval and clean meetings may be used" % (meeting, held))
        with open(os.path.join(TRUTH, meeting + ".json")) as handle:
            truth = json.load(handle)
        channels = {}
        for agent, channel in sorted(channels_of(args.annotations, meeting).items()):
            name = "%s.Headset-%d.wav" % (meeting, channel)
            path = os.path.join(args.audio_dir, name)
            download(MIRROR.format(meeting=meeting, channel=channel), path)
            channels[agent] = {"channel": channel, "sha256": sha256(path)}
            print("%s %s" % (name, channels[agent]["sha256"]), file=sys.stderr)
        meetings[meeting] = {
            "localAgent": callsim.choose_local_agent(SEED, meeting, truth),
            "channels": channels,
        }
    # The variants are edited in the manifest itself, which the generator and
    # the bench read, so a re-pin keeps them as they are.
    calls = {"seed": SEED, "mirror": MIRROR, "variants": manifest["calls"]["variants"], "meetings": meetings}

    # The block is always the last key, so replacing it is a cut and an append
    # and leaves the hand-formatted rest of the file as it was.
    marker = text.find(',\n  "calls": {')
    if marker >= 0:
        text = text[:marker] + "\n}\n"
    head = text.rstrip()
    assert head.endswith("}"), "manifest does not end with an object"
    head = head[:-1].rstrip()
    with open(MANIFEST, "w") as handle:
        handle.write(head + ",\n" + render(calls) + "\n}\n")
    json.load(open(MANIFEST))
    print("wrote the calls block for %d meetings" % len(meetings))


if __name__ == "__main__":
    main()
