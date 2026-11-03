#!/usr/bin/env python3
"""Write the transcripts and human summaries the summary evaluation reads.

Reads the AMI corpus's manual annotations and writes, for each meeting named:

- Benchmarks/summaries/transcripts/<meeting>.txt, one "[mm:ss] Role: text" line
  per turn, the shape Pipit sends a language model. Speakers are named by their
  role in the scenario, so an action item's owner can be checked by name.
- Benchmarks/summaries/human/<meeting>.json, the summary the AMI annotators
  wrote: an abstract and lists of actions, decisions and problems. The truth
  files mark which of their items echo these.

    scripts/fetch-bench-audio.sh --annotations ami
    python3 scripts/build-summary-transcripts.py \
        --annotations ~/Library/Caches/pipit-bench/ami_public_manual_1.6.2.zip ES2004c IS1009c

The annotations source is the published zip or a directory holding its
contents. The output is deterministic, so a rebuild that changes a committed
file means the converter or the corpus changed.
"""

import argparse
import json
import os
import re
import xml.etree.ElementTree as ET
import zipfile

NITE = "{http://nite.sourceforge.net/}"
ROLES = {
    "PM": "Project Manager",
    "ME": "Marketing Expert",
    "UI": "User Interface Designer",
    "ID": "Industrial Designer",
}
# Segments from one speaker closer than this read as one turn, as Pipit's own
# transcript joins a speaker's consecutive sentences.
JOIN_GAP_SECONDS = 2.0


class Annotations:
    """The annotation tree, read from a zip or from an unpacked directory."""

    def __init__(self, path):
        self.zip = zipfile.ZipFile(path) if zipfile.is_zipfile(path) else None
        self.path = path

    def read(self, relative):
        if self.zip is None:
            with open(os.path.join(self.path, relative), "rb") as handle:
                return handle.read()
        return self.zip.read(relative)


def timestamp(seconds):
    whole = int(seconds)
    if whole >= 3600:
        return "%d:%02d:%02d" % (whole // 3600, whole % 3600 // 60, whole % 60)
    return "%02d:%02d" % (whole // 60, whole % 60)


def roles(annotations, meeting):
    root = ET.fromstring(annotations.read("corpusResources/meetings.xml"))
    for entry in root:
        if entry.get("observation") == meeting:
            return {s.get("nxt_agent"): ROLES.get(s.get("role"), s.get("role")) for s in entry}
    raise SystemExit("%s is not in meetings.xml" % meeting)


def transcript(annotations, meeting):
    turns = []
    for agent, role in roles(annotations, meeting).items():
        words = list(ET.fromstring(annotations.read("words/%s.%s.words.xml" % (meeting, agent))))
        position = {element.get(NITE + "id"): index for index, element in enumerate(words)}
        segments = ET.fromstring(annotations.read("segments/%s.%s.segments.xml" % (meeting, agent)))
        for segment in segments:
            child = segment.find(NITE + "child")
            ids = re.findall(r"id\(([^)]+)\)", child.get("href"))
            text = ""
            for element in words[position[ids[0]]:position[ids[-1]] + 1]:
                if element.tag != "w" or not element.text:
                    continue
                text += element.text if element.get("punc") == "true" else " " + element.text
            text = text.strip()
            if text:
                turns.append((float(segment.get("transcriber_start")), role, text))
    turns.sort()

    merged = []
    for start, role, text in turns:
        if merged and merged[-1]["role"] == role and start - merged[-1]["last"] < JOIN_GAP_SECONDS:
            merged[-1]["text"] += " " + text
            merged[-1]["last"] = start
        else:
            merged.append({"start": start, "role": role, "text": text, "last": start})
    return "".join("[%s] %s: %s\n" % (timestamp(t["start"]), t["role"], t["text"]) for t in merged)


def human_summary(annotations, meeting):
    root = ET.fromstring(annotations.read("abstractive/%s.abssumm.xml" % meeting))
    summary = {}
    for section in ("abstract", "actions", "decisions", "problems"):
        element = root.find(section)
        sentences = element.findall("sentence") if element is not None else []
        summary[section] = [s.text.strip() for s in sentences if s.text and s.text.strip()]
    return summary


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--annotations", required=True)
    parser.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "Benchmarks", "summaries"))
    parser.add_argument("meetings", nargs="+")
    arguments = parser.parse_args()

    annotations = Annotations(os.path.expanduser(arguments.annotations))
    os.makedirs(os.path.join(arguments.out, "transcripts"), exist_ok=True)
    os.makedirs(os.path.join(arguments.out, "human"), exist_ok=True)
    for meeting in arguments.meetings:
        text = transcript(annotations, meeting)
        with open(os.path.join(arguments.out, "transcripts", meeting + ".txt"), "w") as handle:
            handle.write(text)
        summary = human_summary(annotations, meeting)
        with open(os.path.join(arguments.out, "human", meeting + ".json"), "w") as handle:
            json.dump(summary, handle, indent=2, ensure_ascii=False)
            handle.write("\n")
        counts = ", ".join("%d %s" % (len(summary[k]), k) for k in ("actions", "decisions", "problems"))
        print("%-8s %4d turns  %5d words  human summary: %s" % (
            meeting, text.count("\n"), len(text.split()), counts))


if __name__ == "__main__":
    main()
