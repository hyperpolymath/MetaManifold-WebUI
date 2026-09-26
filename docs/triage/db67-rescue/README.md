<!--
SPDX-License-Identifier: CC-BY-SA-4.0
-->

# Deleted branch `arena/01a0db67` — content preserved here

On 2026-09-26 the owner asked for this branch to be **closed (deleted)**
during the notification-backlog triage. Before deletion its full content
was preserved in this directory so nothing is lost:

- `deleted-branch.patch` (260 KB): the branch's true delta
  (`e33e10f..d94ecd4`, 41 files, +4,138/−691), verified to recreate the
  branch tree byte-for-byte.
- `deleted-branch-files.txt`: the file list (`A`/`M`/`D` per file).

## What the branch was

Three docs commits on top of `e33e10f` (fork `main` before the DOI and
ILR merges): a BerryWiki-format wiki (`docs/wikis/`, 33 pages),
`README.adoc` + `EXPLAINME.adoc`, the autolink specification
(`docs/integration/autolink-references.md`), a `.gitignore` negation for
`docs/wikis/`, and prose updates to `CHANGELOG.md`, `CONTRIBUTING.md`
and `NOTICE` (third-party table + acknowledgements). It also deleted
`README.md`, intending the `.adoc` pair to replace it.

## Correction to the first triage note

The first version of this triage's report called this branch
"DOI-deleting". That overstated it: diffed against *current* `main` the
branch *appears* to delete `src/doi/*` and the ILR work, but that is
base-difference noise — the branch predates those merges
(`git-filter-repo` era base `e33e10f`), so it never contained them. A
GitHub 3-way merge would **not** have reverted PR #74/#75. The genuine
landmines were the `README.md` deletion and the 32 wiki pages missing
SPDX headers (which would fail `scripts/check-spdx.sh`).

## Restore (if ever wanted)

```sh
git fetch https://github.com/hyperpolymath/MetaManifold-WebUI.git \
  arena/01a0dd12-metamanifold-webui
git checkout FETCH_HEAD -- docs/triage/db67-rescue
git checkout -b restore/db67 e33e10f
git apply --index docs/triage/db67-rescue/deleted-branch.patch
git commit -m "restore: db67 docs branch content"
```

Before merging a restore: rebase onto current `main`, decide
`README.md` vs `README.adoc` (keep both until decided), and add
`SPDX-License-Identifier: CC-BY-SA-4.0` headers to the wiki pages
(the `_Sidebar.md` file is generated upstream — its header needs to
come from the generator, or the file needs a gate exemption).

Branch head SHA at deletion: `d94ecd4e99dbda819fdc0fe1913d5caaabca414a`.
