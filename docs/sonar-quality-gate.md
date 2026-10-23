# The SonarCloud check, and why it fails on a frontend change

**Status: diagnosis and local guard.** `scripts/lint-sonar-reliability.sh`
reproduces, locally and in about 0.1 s, the two SonarCloud rules that have
actually failed this repository's required check. It does not replace the gate.

## What the check is

The required **SonarCloud Code Analysis** check is the SonarQube Cloud GitHub
App running **Automatic Analysis**. There is no scanner workflow in
`.github/workflows/`, no `sonar-project.properties`, and therefore no file in
this repository that configures it. Two consequences follow, and both have cost
time:

- **Nothing here can change what it analyses or what it reports.** Automatic
  analysis ignores `sonar-project.properties`, and `.sonarcloud.properties`
  accepts only source/test scope, exclusions and duplicate-detection settings —
  not rule selection, not new-code definition, not issue suppression. Changing
  the gate is a SonarCloud UI action (Administration → Analysis Method /
  New Code / Quality Gate), not a pull request.
- **The only feedback is the check itself.** No lint step runs in CI, so a
  finding appears after a push, about 90 seconds later, on a third-party
  dashboard.

## What it enforces

The project's gate is Sonar's built-in **Sonar way**, with the coverage
condition absent (automatic analysis reports no coverage). Measured from
`/api/qualitygates/project_status` on PR #224:

| Condition                | Threshold | Meaning                                  |
| ------------------------ | --------- | ---------------------------------------- |
| `new_reliability_rating` | ≤ A       | **zero** reliability findings, any severity |
| `new_security_rating`    | ≤ A       | zero security findings                   |
| `new_maintainability_rating` | ≤ A   | zero maintainability findings            |
| `new_duplicated_lines_density` | ≤ 3% | duplicate lines                      |
| `new_security_hotspots_reviewed` | = 100% | hotspots reviewed                   |

Rating `A` is not "no important findings": it is **no findings**. A single
`MINOR` issue — the least severe level Sonar reports — makes the rating `B` and
fails the gate. That is the whole failure mode: a change that a reviewer would
call a style remark blocks the merge.

"New code" is the pull request's changed lines. On `main` it is a **three-day
sliding window**, so a finding merged into `main` keeps `main` red for three
days and re-running the analysis does not clear it.

## The two rules that have failed it

### `typescript:S2871` — a `sort()` with no compare function

*"Provide a compare function that depends on `String.localeCompare`, to reliably
sort elements alphabetically."* Reported as a **CRITICAL** bug with a HIGH
reliability impact, on:

- `frontend/src/api/ijsonJcs.ts:53` in PR #224 (the check under discussion);
- `frontend/src/views/CompositionsView.tsx:23` and `:28` on `main` (open since
  July 2026).

**The rule's own suggestion is wrong here.** `localeCompare` applies locale
collation; a bare `sort()` applies UTF-16 code unit order. They disagree —
`['z', 'ä'].sort()` gives `['z', 'ä']`, `localeCompare` gives `['ä', 'z']`:

```
node> ['z','ä','A','a','Z','é','e']
default    : A, Z, a, e, z, ä, é
byCodeUnit : A, Z, a, e, z, ä, é     same
localeCompare: a, A, ä, e, é, z, Z   different
```

For a sorted identifier list that is a silent behaviour change; for RFC 8785
canonical JSON, which defines member order as UTF-16 code unit order, it is a
correctness bug that would break canonicalisation *while making the check go
green*. The fix that satisfies both the rule and the specification is to pass
the comparator explicitly:

```ts
import { byCodeUnit } from '../utils/text'
Object.keys(library.filters).sort(byCodeUnit)
```

`byCodeUnit` lives in `frontend/src/utils/text.ts`, is tested in
`frontend/src/utils/text.test.ts`, and is byte-for-byte the same ordering as the
bare `sort()` it replaces.

### `typescript:S7758` — `charCodeAt` where `codePointAt` is wanted

*"Prefer `String#codePointAt()` over `String#charCodeAt()`."* Reported as
**MINOR**, reliability LOW — and MINOR still fails the gate. It fired twice on
`ijsonJcs.ts` (`:8`, `:10`) because the I-JSON validator walked UTF-16 *units*
to reject unpaired surrogates.

The rewrite iterates by code point:

```ts
for (let i = 0; i < value.length; i++) {
  const code = value.codePointAt(i)!
  if (code >= 0xd800 && code <= 0xdfff) throw new TypeError(/* unpaired surrogate */)
  if ((code & 0xfffe) === 0xfffe || (code >= 0xfdd0 && code <= 0xfdef)) throw new TypeError(/* noncharacter */)
  if (code > 0xffff) i++   // skip the low half of a pair
}
```

`codePointAt` returns a surrogate's own value only when it is unpaired, so one
test covers lone high and lone low surrogates; a valid pair arrives as the
combined code point and its low half is skipped. This was verified against the
original implementation over 2,628,290 inputs — every single BMP unit alone and
sandwiched between ASCII, every high×low surrogate pair, every noncharacter in
every plane, and 400,000 random strings from a hostile alphabet — with zero
disagreements.

**This rule is sometimes simply wrong** and must not be applied blindly:
`frontend/src/tree/model.ts` hashes tip names with FNV-1a, which is defined over
UTF-16 code units; `codePointAt` would merge surrogate pairs and change every
tip key. That file is listed in `CHARCODE_ALLOWED` in the guard script, with its
reason, rather than suppressed with `// NOSONAR` — a suppression still leaves
the finding counted, and `typescript:S1291` ("Track uses of NOSONAR") would add
a maintainability finding of its own.

## Reproducing it locally

```
bash scripts/lint-sonar-reliability.sh
```

Exits 0 clean, 1 on findings, 2 outside the repository. In GitHub Actions the
findings are also emitted as `::error` annotations, so they are readable from
the API. The `Julia tests` job runs it first, before any toolchain is installed.

It is a **guard, not a linter**. It covers S2871 and S7758 because those are the
rules that have failed the required check; it cannot cover the rest of the Sonar
TypeScript profile. If a new rule bites, add it here *and* to this page, with
the measurement that justifies it — the point is that each addition is a
decision, not that the script encodes the profile.

## Why this keeps happening

1. **No local feedback.** No ESLint, no lint step, no configuration file. The
   gate is a cloud service, so the first signal is the red check.
2. **The gate is absolute.** Rating A means zero findings; one MINOR fails it.
   There is no "important findings only" tier to fall back on.
3. **The suggested fix is dangerous.** S2871's `localeCompare` suggestion is
   wrong for canonical JSON and for stable identifier ordering, so the obvious
   fix trades a red check for a silent behaviour change. `byCodeUnit` exists so
   the correct fix is also the easy one.
4. **The new-code window is invisible.** Three days on `main`; PR diff on a
   pull request; neither is stated anywhere in the repository.

Points 1, 3 and 4 are what the guard and this page address. Point 2 is a
SonarCloud UI setting: a custom gate that tolerates MINOR findings on new code
would remove the trap entirely, but it cannot be done from this repository.
