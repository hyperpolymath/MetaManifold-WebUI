#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Inventory lexical JSON/YAML candidates; NEVER a compliance verdict.

Includes tracked and non-ignored new files, including hidden workflow/hooks.
Search hits can be comments/test strings. Aliases/dynamic dispatch require human
review. Prints locations/operation names, not source lines or document contents.
"""
import argparse
import csv
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
CODE = {".yaml", ".yml", ".kyaml", ".jl", ".ts", ".tsx", ".js", ".mjs", ".py", ".sh", ".R", ".r", ".rs"}
DATA = {".json", ".jsonl", ".yaml", ".yml", ".kyaml"}
PATTERNS = {
    "JSON3.read": r"\bJSON3\.read\s*\(",
    "JSON3.write": r"\bJSON3\.write\s*\(",
    "YAML IO": r"\bYAML\.(?:load_file|load|write_file|write)\s*\(",
    "strict/JCS adapter": r"\b(?:ijson_read|jcs_bytes|jcs_sha256|ijsonJcsStringify|_request_json)\s*\(",
    "JSON.parse": r"\bJSON\.parse\s*\(",
    "JSON.stringify": r"\bJSON\.stringify\s*\(",
    "response.json candidate": r"\.json\s*\(",
    "Python JSON IO": r"\bjson\.(?:load|loads|dump|dumps)\s*\(",
    "Oxygen JSON candidate": r"(?<![\w.])json\s*\(",
    "R JSON IO": r"\b(?:jsonlite::)?(?:fromJSON|toJSON|read_json|write_json)\s*\(",
    "shell jq/yq candidate": r"(?m)(?<![\w/-])(?:jq|yq)\s+(?:-[A-Za-z]|['\"])",
}


def category(path):
    # Routing buckets, NOT automatic approval or proof of ownership/compliance.
    name = path.as_posix()
    if name.startswith(("test/", "tests/")):
        return "test-fixture-or-oracle"
    if name.startswith(".github/"):
        return "workflow-or-service-config"
    if name.startswith(("src/core/doi", "src/core/epistemic", "src/core/provenance")):
        return "legacy-identity-sensitive-review"
    if name in ("renv.lock", "frontend/bun.lock") or name.startswith("renv/"):
        return "external-tool-owned-review"
    if name.startswith(("src/", "frontend/src/")):
        return "application-mixed-boundaries-review"
    if name.startswith(("config/", "data/")):
        return "configuration-review"
    if name.startswith(("scripts/", "bench/", "proofs/")):
        return "tooling-or-reference-review"
    return "untriaged"


def _file_rows(root, name):
    path = root / name
    bucket = category(Path(name))
    if path.is_symlink():
        yield "symlink", bucket, name, 0, "target-not-followed"
        return
    if not path.is_file():
        yield "missing", bucket, name, 0, "missing-worktree-file"
        return
    suffix = path.suffix
    if suffix in DATA or path.name in ("renv.lock", "bun.lock"):
        yield "document", bucket, name, 0, "format-owner-needs-review"
    if suffix not in CODE:
        return
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeError:
        yield "unreadable", bucket, name, 0, "invalid-utf8-source"
        return
    for label, pattern in PATTERNS.items():
        for match in re.finditer(pattern, text):
            line = text.count("\n", 0, match.start()) + 1
            yield "candidate", bucket, name, line, label


def inventory(root):
    result = subprocess.run(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"],
        cwd=root, check=True, capture_output=True,
    )
    paths = sorted({p.decode("utf-8") for p in result.stdout.split(b"\0") if p})
    for name in paths:
        yield from _file_rows(root, name)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT)
    args = parser.parse_args(argv)
    writer = csv.writer(sys.stdout, delimiter="\t", lineterminator="\n")
    writer.writerow(("kind", "routing-bucket-not-verdict", "path", "line", "operation"))
    try:
        writer.writerows(inventory(args.root.resolve()))
        return 0
    except (OSError, UnicodeError, subprocess.CalledProcessError):
        print("inventory failed; no completeness or compliance claim", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
