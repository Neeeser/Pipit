"""Print the facts a benchmark result needs to be rerun or re-scored later.

    python3 Benchmarks/results/provenance.py [--hf-model ID ...] [--python PATH] \
        [--input FILE ...] > provenance.json

Records the commit, the diff of tracked files that changed since it, a SHA-256
for each untracked file (so the code that made a result can be identified even
when it was never committed), the machine, the
speech dependency versions pinned in Package.resolved, the Hugging Face
revision of each named model as found in the local cache, the packages
installed for a Python interpreter, and a SHA-256 for each input file.
"""

import argparse
import hashlib
import json
import platform
import subprocess
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HF_CACHE = Path("~/.cache/huggingface/hub").expanduser()


def run(*command: str) -> str:
    return subprocess.run(command, cwd=ROOT, capture_output=True, text=True, check=True).stdout.rstrip()


def swift_packages() -> dict[str, str]:
    resolved = json.loads((ROOT / "Package.resolved").read_text())
    return {pin["identity"]: pin["state"].get("version") or pin["state"]["revision"] for pin in resolved["pins"]}


def hf_revision(model: str) -> str | None:
    ref = HF_CACHE / ("models--" + model.replace("/", "--")) / "refs" / "main"
    return ref.read_text().strip() if ref.exists() else None


def python_packages(python: str) -> dict[str, str]:
    listing = run(python, "-c", "import importlib.metadata as m, json; "
                  "print(json.dumps({d.metadata['Name']: d.version for d in m.distributions()}))")
    return dict(sorted(json.loads(listing).items()))


def untracked_files() -> dict[str, str]:
    names = run("git", "ls-files", "--others", "--exclude-standard").splitlines()
    return {name: sha256(ROOT / name) for name in names}


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for block in iter(lambda: file.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--hf-model", action="append", default=[])
    parser.add_argument("--python", help="interpreter whose installed packages to list")
    parser.add_argument("--input", action="append", default=[], type=Path)
    args = parser.parse_args()
    record = {
        "recordedAt": datetime.now(UTC).isoformat(timespec="seconds"),
        "commit": run("git", "rev-parse", "HEAD"),
        "uncommittedChanges": run("git", "status", "--porcelain").splitlines(),
        "uncommittedDiff": run("git", "diff", "HEAD"),
        "untrackedFiles": untracked_files(),
        "machine": {
            "chip": run("sysctl", "-n", "machdep.cpu.brand_string"),
            "memoryGB": int(run("sysctl", "-n", "hw.memsize")) // 2**30,
            "macOS": platform.mac_ver()[0],
        },
        "swiftPackages": swift_packages(),
        "huggingFaceModels": {model: hf_revision(model) for model in args.hf_model},
        "pythonPackages": python_packages(args.python) if args.python else {},
        "inputs": {str(path): sha256(path) for path in args.input},
    }
    print(json.dumps(record, indent=1))


if __name__ == "__main__":
    main()
