<!-- berrywiki
SPDX-License-Identifier: CC-BY-SA-4.0
id: 0198ba50-0000-7000-8000-000000000024
parent: 0198ba50-0000-7000-8000-000000000020
position: 40
kind: page
tags:
  - maintainers
  - compliance
  - estate
archived: false
-->

# Compliance and estate

**Status: IN PLACE — compliant-with-documented-deviations** (the deviations
are the point of the record: they are written down, dated, and reasoned).
This page orients maintainers in the hyperpolymath estate's machinery.

## Where this repository sits in the estate

| Estate artefact | Role here | Record |
|---|---|---|
| [standards](https://github.com/hyperpolymath/standards) | Organisation-wide specs: README/EXPLAINME authoring, A2ML metadata family, RSR canon, licence policy | `docs/compliance/standards-alignment.md` |
| [rsr-template-repo](https://github.com/hyperpolymath/rsr-template-repo) | The Rhodium Standard Repository template this tree is aligned against | `docs/compliance/rsr-alignment.md` |
| LICENCE-POLICY (in standards) | Five-rule register; the AGPL/MPL split applied here | `NOTICE`, `docs/compliance/standards-alignment.md` |
| Language policy | TypeScript is estate-banned but **fork-exempt** here (the strict compiler is declared the lint dialect); Julia/R are the science stack | `docs/compliance/standards-alignment.md` |

## The licence split (do not "tidy" this)

- Upstream-authored files: `AGPL-3.0-only` (inherited work licence — the
  origin's choice, untouchable under fork rules).
- Fork-authored files: `MPL-2.0` (code) / `CC-BY-SA-4.0` (prose).
- Authorship classification is mechanical (first-commit author), stated in
  `NOTICE`; `scripts/check-spdx.sh` gates headers across the covered set
  (machine metadata and generated files excluded, list in the compliance
  record).
- `LICENSES/` holds the canonical texts (AGPL-3.0-only, MPL-2.0,
  CC-BY-SA-4.0); `LICENSE` is the AGPL root.

## Documentation standards in force

- **README + EXPLAINME authoring standard** (`standards:docs/README-EXPLAINME-STANDARD.adoc`)
  — the root `README.adoc` + `EXPLAINME.adoc` pair follows it: README sells,
  EXPLAINME proves with claim→implementation receipts, the mathematics lives
  in this wiki (deliberately, so neither file becomes unreadable).
- **BerryWiki page format** for this wiki ([metadatastician/berrywiki](https://github.com/metadatastician/berrywiki))
  — plain Markdown with hidden tree metadata; sourced from `docs/wikis/`.
- GitHub-required files stay `.md` (SECURITY, CONTRIBUTING, CODE_OF_CONDUCT,
  CHANGELOG) — the standard's platform exception.

## Repository settings (the manual surface)

- **Autolink references** — the complete four-tier elaboration (lineage and
  estate; upstream bioinformatics tools; runtime/toolchain; registries) is
  specified paste-ready in `docs/integration/autolink-references.md`.
  Applying it needs Settings → Autolink references (Administration
  permission). When estate automation gains that permission, the same file
  is the machine source of truth. **Action pending: one human pass.**
- Rulesets (`Immutable-Tags` style) and CODEOWNERS (`@hyperpolymath`) are in
  force; Dependabot scoping is deliberate (see
  [Steward Track](Maintainers--Steward-Track)).

## Estate patterns this repository dogfoods

Listed with their receipts in `EXPLAINME.adoc` ("Dogfooded across the
account"): the README/EXPLAINME pair standard, BerryWiki page format, the
Justfile command surface (Makefiles banned estate-wide), the pinned
dual-lane toolchain (mise + Guix), and publish-conditions-before-implementation
for statistics methods. The last is the pattern the estate's statistics
track ([statistikles](https://github.com/hyperpolymath/statistikles)) adopts
in turn — the method catalogue and method-conditions documents here are its
working exemplar.

## Reading the alignment records

Both alignment checklists are **dated snapshots** ("compliant-with-
documented-deviations, 2026-09-17"). When the estate standards move (they
are a moving target by design — e.g. the language policy's ReScript ban
date), re-run the comparison and update the checklist with a new date rather
than editing history in place. The fixme index
(`docs/compliance/fixme-index.md`) is the living exception register
(`skipLibCheck`, `alphaFig`, `FIXME(types)` stubs) with exit criteria.
