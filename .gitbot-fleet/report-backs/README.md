# gitbot-fleet report-backs

One JSON file per enrolled fleet member. The renderer uses the `reporter`
field as the row identity when present, falling back to the filename basename
without `.json` (for example, `rhodibot.json` becomes `rhodibot`). This identity
should match the key in `.gitbot-fleet/enrolment.json` (`rhodibot`, `seambot`, ...).

The Hypatia verdict grid reads this directory
(`.github/workflows/hypatia-scan-reusable.yml` passes it to
`scripts/verdict-grid.sh --report-backs`), so a report-back here is the only
way a member's row stops being orange. The envelope is the one in
`docs/VERDICT-GRID-SPEC.adoc` of
[metadatastician/standards](https://github.com/metadatastician/standards):

```json
{ "reporter": "rhodibot",
  "title": "rhodibot (RSR compliance)",
  "status": "ran",
  "reason": null,
  "ref": "<bot commit or version>",
  "findings": [
    { "rule_id": "RSR-001", "severity": "error",
      "file": "README.adoc", "line": 1, "message": "..." }
  ] }
```

`status` is one of `ran`, `not_run`, `error` or `not_applicable`; `reason` is
required unless the member ran, and `not_applicable` renders grey. `severity`
uses the fleet's own words (`error`, `warning`, `info`, `suggestion`) or the
scanner words (`critical`, `high`, `medium`, `low`); both normalise.

**How the files get here.** The `fleet` job of `.github/workflows/hypatia-scan.yml`
(gitbot-fleet's `fleet-report-back-reusable.yml`) runs the enrolled adapters on
the PR head and uploads the envelopes as the `fleet-report-backs` artifact;
the fork-local Hypatia reusable downloads that artifact into this directory
just before it renders the grid (fork delta 4). Nothing is ever committed here:
an envelope is evidence about one commit, and a committed one would read as
current when it is stale. The directory exists because this repository's deed
declares it (`MetaManifold-WebUI_chora.deed`,
`:report-backs ".gitbot-fleet/report-backs/"`), and it is empty in git on
purpose. An enrolled member with no report-back renders **orange** ("enrolled,
but no report-back was received"), never green; do not add a placeholder
envelope to turn a row green. Only a real run may.

Only files matching `*.json` are read, so this README is inert.
