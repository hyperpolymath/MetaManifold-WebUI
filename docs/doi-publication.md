<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
# Publish an analysis DOI with Zenodo

Issue [#8](https://github.com/hyperpolymath/MetaManifold-WebUI/issues/8).
**Opt-in, single-user feature. Publication is irreversible.** The implementation
is reviewable; see [verification status](testing/doi-publication.md) before
production enablement. No live record is created by the test suite.

## What is published

A new, frozen ZIP contains the exact saved AnalysisConfig, an **explicitly chosen**
completed result (or an explicitly labelled configuration-only payload), original
provenance, scientific DANGER warnings, SHA-256 checksums, DataCite/Zenodo metadata,
CITATION.cff/text, and JSON/Nickel/DEED publication attestations. It does **not**
include raw sequencing inputs or reference databases. Authors must document how
those inputs can be obtained; a DOI does not make missing inputs reproducible.

No scientific object is rewritten to insert a DOI. A separate, immutable
post-publication receipt binds the DOI to the config/result identities **and their
exact file hashes**, the uploaded ZIP hash, metadata and journal events. Its hash
is recorded in the private journal. This avoids a circular archive/receipt hash.

The ZIP records a **reserved** identifier. Reservation is not registration, and
HTTP 202 is only acceptance. Only a verified published record gets a DOI badge.
Sandbox records remain visibly **TEST DOI**, never production citations.

## Operator setup

Requirements: Julia 1.12.5 and the repository dependencies, `zip`, a Unix filesystem
with working `flock`, atomic rename and `fsync` (native Linux/macOS or WSL2). Use a
local filesystem, not an untested shared/network mount. Native Windows is refused
rather than silently using an unsafe process-local lock.

1. Start with a **Zenodo sandbox** account and a sandbox token with `deposit:write`
   and `deposit:actions` scopes. Inject it as `ZENODO_SANDBOX_TOKEN` into the server
   environment using your private secret manager. Do not put it in source, config
   JSON, a URL, browser storage, a receipt, shell history, an issue, or chat.
2. Set these **non-secret** server options:

   ```sh
   export METAMANIFOLD_ZENODO_ENABLED=true
   export METAMANIFOLD_ZENODO_ENVIRONMENT=sandbox
   # ZENODO_SANDBOX_TOKEN is supplied by your secret manager, not this command.
   just start
   ```

3. Enable production only after the acceptance checks below. Set the environment
   to `production` and supply a **separate** `ZENODO_TOKEN`. No sandbox-token
   fallback is used in production. Unset the enable flag to disable new actions;
   saved receipts and downloads remain available.
4. Back up `projects/<study>/.analysis` and `projects/<study>/.doi` **together**,
   including hidden files and filesystem permissions. The public `/files` route
   refuses hidden path segments. Publication-aware study rename/delete and bound
   config deletion return 409 rather than orphaning the journal.

**Authentication boundary:** CSRF tokens, same-origin checks and JSON-only requests
are not authentication. This is a local single-user application. Do not expose it
as a public upload service. A network deployment requires an authenticated reverse
proxy, TLS, trusted filesystem access and operator-controlled credentials. For a
proxy with a different internal Host, set `METAMANIFOLD_PUBLIC_ORIGIN` to the exact
external origin, with no trailing slash. Normal same-origin preview/proxy hosts
work without wildcard CORS. The browser uses relative API paths, never a separate
localhost backend or a direct Zenodo request.

Capabilities report **local configuration**, not proof that Zenodo has accepted the
token. Raw HTTP exceptions and remote error bodies are not returned or journalled.
The server's token is never added to a bundle; user-authored scientific metadata
can still contain sensitive content and must be reviewed by the author.

## Author workflow

1. Open a study's **Evidence / DOI publication** link. An AnalysisConfigEditor
   supplied with a study context also offers a **Mint DOI** launcher. The current
   React editor is not mounted in the application; the study link is the reachable
   entry point. The publication page is Julia-rendered with a small DOM/fetch
   adapter, consistent with the UI migration policy.
2. Enable **Evidence Mode**. Select an immutable saved config and choose a specific
   completed result **or Configuration only**. There is no implicit “latest result”.
   The web scaffold run endpoint is marked mock and cannot supply a publishable
   result. The page can save an explicit config, but never invokes that scaffold.
3. Supply a real title, description/limitations, creators, date/version and a
   licence you are entitled to grant. Supported licences are `CC-BY-4.0`,
   `CC-BY-SA-4.0` and `CC0-1.0`. The API additionally supports creator affiliation
   and checksum-validated ORCID. Placeholders such as “Anonymous” are rejected.
4. Optionally enter an existing GitHub release URL and Projects v2 URL. Links are
   fixed to `github.com`; release tags use ordinary ASCII characters, not encoded
   tags, queries, fragments or traversal segments. A project link alone does not
   suffice for the release-linking helper: it also needs an existing release.
5. Acknowledge that **Prepare** sends the files off this machine as a private
   Zenodo draft. It reserves a DOI and verifies the uploaded archive, but **does
   not publish**. Retries/restarts reuse the same durable operation.
6. Download the exact ZIP. Check privacy, host/sample paths, consent, licence,
   scientific warnings, selected result and missing raw inputs. Record its SHA-256.
   Modifying metadata or files after preparation is refused, not silently accepted.
7. Click **Mint DOI…**, read the DANGER dialog, acknowledge the review, and type
   exactly `PUBLISH <environment> <deposition-id>`. Cancel, an incorrect phrase, a
   missing acknowledgement or a stale/different ZIP hash cannot publish.
8. Wait for a verified badge. If Zenodo is still processing, **Refresh** the existing
   deposition. Download the receipt and citation only after verification.

Real Julia analyses can be enrolled explicitly with
`AnalysisStore.save_config!(store, config)` and
`AnalysisStore.save_result!(store, result)`, where `store` is the study's `.analysis`
directory. Results must reference that exact config ID, hash and method. Mock,
empty and failed/not-run results are refused. Publication never executes an
analysis or treats a mock result as scientific evidence.

Context-help keys: `doi`, `doi.environment`, `doi.confirmation`, `doi.recovery`,
`doi.github` in `AnalysisConfig.context_help` and the existing help API.

## Recovery — never mint a replacement to fix a timeout

| Saved state / failure | Safe next action |
|---|---|
| `preparing` | Resume the same operation. No successful create has been recorded. |
| `creating` / `creation_uncertain` | Creation might have succeeded. Find the draft on Zenodo by the publication-ID marker in its notes and recover its numeric deposition ID. Recovery requires the matching, unsubmitted, empty draft. Never guess another ID or create a replacement. |
| `draft` | Resume against the same deposition. Idempotent upload retries reopen the exact frozen file from byte zero. |
| `ready` | Download/review, then use the separate confirmation dialog. Refresh does not publish. |
| `publishing` / `publication_uncertain` | Refresh/reconcile by GET. The application **will not replay** an uncertain publish POST. If Zenodo still shows a draft after review, finish that same deposition there manually, then refresh here. |
| `published` | Repeated confirmation/status reads do not create another deposition or DOI. Use the saved receipt. |
| 401/403 | Operator checks environment, ownership, token validity/scopes; do not paste credentials into the UI. |
| 429 | Honour Retry-After. Default policy allows four attempts and at most 60 seconds of retry sleep; excessive hints stop retries and are surfaced, not truncated to an unsafe wait. |
| Integrity/metadata mismatch | Stop. Restore exact local bytes from backup or inspect the existing remote deposition. Do not overwrite the frozen archive or bypass the mismatch by erasing the journal. |
| Local 409 busy | Another process owns the kernel lock. Wait, then reload. Process death releases the lock; no age-based lock stealing is used. |
| GitHub failure | Resume the linker with the same receipt; publication is already independent of GitHub. |

A definite 429 can retry a POST. Disconnects, unexpected successes, 408 and 5xx on
non-idempotent create/publish calls are ambiguous and **never blindly replayed**.
Intents are fsynced before those requests. A false-negative/uncertain result is
preferable to duplicate irreversible publication. There is no automatic delete,
withdrawal, new-version publication or local-journal reset operation.

## Link the published DOI to GitHub

The web server does not hold GitHub credentials. On an operator-controlled Unix
machine with `gh` (2.32+ for Projects v2), `jq` and `flock`, use the downloaded **production** receipt:

```sh
scripts/link-doi.sh --receipt /private/path/publication-ID.json          # offline plan
scripts/link-doi.sh --receipt /private/path/publication-ID.json --apply  # explicit writes
```

The helper uses existing `gh` authentication, requires an already-published
release, preserves notes outside its ID-marked block, uploads ID-named receipt/CFF
assets, and upserts one marked draft item on the optional Projects v2 board. It
never creates/publishes a GitHub release or talks to Zenodo. Sandbox/pending records
are refused. The production CFF is validated against the official 1.2.0 schema in
contract tests. Receipts are local attestations, **not cryptographic signatures**;
use the receipt downloaded from your trusted application, not an untrusted file.

Release edits need repository write permission; Projects v2 updates need appropriate
project access (for classic OAuth/PAT authentication, the `project` scope). Consult
`gh auth status` privately. Do not paste its credentials into an issue. Local
replays are locked by receipt; GitHub does not supply a cross-machine notes-edit
transaction, so do not run independent release-note writers concurrently. A partial
failure can leave release notes/assets already updated. Rerun the **same receipt**;
incomplete project listings and duplicate/malformed markers stop rather than
risking an additional item or deleting other notes.

## API and contract boundary

- Capability/assets: `/api/v1/doi/capabilities`, `/api/v1/doi/assets/{name}`.
- UI: `/api/v1/studies/{study}/doi-ui?config={config-id}`.
- Study publications: `/api/v1/studies/{study}/doi-publications` (GET list, POST prepare).
- `/{id}` status; POST `/{id}/{resume,refresh,recover,publish}`;
  GET `/{id}/download/{bundle,receipt,citation}`.
- Mutations require `application/json`, at most 64 KiB, the current `X-DOI-CSRF`
  token and an accepted origin. Unknown fields (including tokens/API roots) fail.
- `config/schemas/doi_publication.schema.json` is the public status/receipt contract
  with request/metadata/binding/reserved-attestation definitions. The Nickel contract
  and DEED template cover the flat **reserved attestation**, not a second lifecycle
  implementation. Optional JSON/Nickel null maps to an empty string in DEED. Julia
  owns semantic validation, hashes, remote-state verification and confirmation.

The compatibility target is explicitly **Zenodo deposition-v1**, recorded in
receipts. The documented endpoint is `/api/deposit/depositions`, not an invented
`/v1` URL. `application/json` intentionally selects the legacy deposition serializer;
`application/vnd.zenodo.v1+json` selects a different serializer and is **not** an
interchangeable “version pin”. Origins are fixed to production/sandbox, redirects
are refused, HTTP/JSON3 dependencies are pinned, and contract tests verify the
expected response shapes. Zenodo can still change its service: perform an explicit
sandbox acceptance check before production deployment. MD5 is used only for the
Zenodo bucket integrity protocol; provenance identity uses SHA-256.
