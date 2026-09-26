<!--
SPDX-License-Identifier: CC-BY-SA-4.0
SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
-->

# Project wikis — source of truth

This directory is the **source** of the GitHub wiki for MetaManifold-WebUI
(`hyperpolymath/MetaManifold-WebUI.wiki.git`), per the RSR convention that
wiki content is versioned in the repository and synchronised to the forge.

## Format — BerryWiki page format

Every page is ordinary GitHub-flavoured Markdown that **may** begin with a
hidden metadata comment in the
[berrywiki](https://github.com/metadatastician/berrywiki) page format:

```markdown
<!-- berrywiki
id: 0198ba50-0000-7000-8000-000000000011
parent: 0198ba50-0000-7000-8000-000000000010
position: 10
kind: page
tags:
  - users
archived: false
-->
```

GitHub strips the comment when rendering, so the wiki stays fully usable with
nothing but `git` and a browser. Identity lives in `id` (stable across
renames); hierarchy lives in `parent`; the `--` in filenames
(`Users--Install-and-First-Run.md`) is a human-readable title path, not
structure. `_Sidebar.md` is generated from the tree and must not be hand-edited
beyond regenerating it.

The structure and status conventions used here (IN PLACE / PARTIAL / COMING /
BLOCKED) are described on the wiki's `Home` page.

## Layout of this source

- One `.md` file per wiki page, named exactly as the wiki page name
  (GitHub wiki page = filename without `.md`).
- `_Sidebar.md` — the generated sidebar (GitHub control file).
- No other formats; the wiki is plain Markdown by design.

## Synchronisation

Changes made here must be pushed to the forge wiki:

```bash
# from a checkout of https://github.com/hyperpolymath/MetaManifold-WebUI.wiki.git
cp docs/wikis/*.md /path/to/MetaManifold-WebUI.wiki/
cd /path/to/MetaManifold-WebUI.wiki
git add -A && git commit -m "docs(wiki): sync from docs/wikis" && git push
```

The two sides must stay byte-identical; `docs/wikis/` is the reviewable copy
(pull requests review wiki content like any other change) and the `.wiki.git`
push is the publish step. Last sync: 2026-09-26.
