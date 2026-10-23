# gitbot-fleet report-backs

One JSON file per enrolled fleet member. The renderer uses the `reporter`
field as the row identity when present, falling back to the filename basename
without `.json` (for example, `rhodibot.json` becomes `rhodibot`). This identity
should match the key in `.gitbot-fleet/enrolment.json` (`rhodibot`, `seambot`, ...).

The Hypatia verdict grid reads this directory
(`.github/workflows/hypatia-scan-reusable.yml` passes it to
`scripts/verdict-grid.sh --report-backs`), so a report-back written here is the
only way a member's row stops being orange. The envelope is the one in
`docs/VERDICT-GRID-SPEC.adoc` of
[hyperpolymath/standards](https://github.com/hyperpolymath/standards):

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

The directory exists because this repository's deed declares it
(`MetaManifold-WebUI_chora.deed`, `:report-backs ".gitbot-fleet/report-backs/"`)
and a declared path that does not exist is a dangling reference. It is empty
on purpose: no member has reported back yet, and the grid says so - an
enrolled member with no report-back renders **orange** ("enrolled, but no
report-back was received"), never green. Do not add a placeholder envelope to
turn a row green; only a real run may.

Only files matching `*.json` are read, so this README is inert.
