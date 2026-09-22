<!--
SPDX-License-Identifier: CC-BY-SA-4.0
-->
# Vendored archives

Third-party build inputs that are served from **this repository's own releases** instead
of from the party that publishes them. Vendoring is a decision, not a convenience: every
entry here states why the upstream location cannot be relied on, and every archive is
byte-identical to the upstream release it came from.

## The rule

1. **The checksum is the integrity claim, never the transport.** A vendored archive is
   accepted only against the SHA-256 that was already pinned while upstream was healthy.
   If a capture had to be made over a broken connection, that is recorded below rather
   than glossed.
2. **Never re-checksum to make a download succeed.** If the bytes differ, the vendoring
   failed — investigate, do not "fix" the pin.
3. **Licence travels with the archive.** The upstream licence stays inside the archive,
   unmodified, and is named below.
4. **Repointing back at a third party is a decision.** `test/unit/test_install_pins.jl`
   fails by name if a vendored URL quietly returns to its original host.

## Entries

### `fastqc_v0.12.1.zip` — FastQC 0.12.1

| | |
| --- | --- |
| Release | [`vendored/fastqc-v0.12.1`](https://github.com/hyperpolymath/MetaManifold-WebUI/releases/tag/vendored%2Ffastqc-v0.12.1) (marked *pre-release* — it is a build input, not a version of this software) |
| Upstream | `https://www.bioinformatics.babraham.ac.uk/projects/fastqc/fastqc_v0.12.1.zip` |
| SHA-256 | `5f4dba8780231a25a6b8e11ab2c238601920c9704caa5458d9de559575d58aa7` |
| Licence | GNU GPL v3 (the archive carries `FastQC/LICENSE.txt`), redistributed unmodified |
| Captured | 2026-09-22 |
| Pinned in | `config/defaults/tool_versions.yml` (`tools.fastqc.archives.any`) |

**Why.** On 2026-09-22 CI went red on a commit that touched nothing near FastQC: the
upstream host served an **expired TLS certificate**. There was no way out through the pin
file, because FastQC publishes **no GitHub release assets** — all six of its GitHub
releases carry none — so the URL could only ever point at that single host. A third
party's certificate renewal could therefore stop our builds, and did.

**Provenance.** The archive was captured once from the upstream URL above. The capture
used `curl --insecure`, because upstream's certificate was already invalid at that
moment; this is stated plainly because it is the one detail a reader should not have to
infer. Integrity does not rest on that transfer: the SHA-256 above is **unchanged from
the original upstream pin**, which was established while upstream was healthy, and the
captured file verifies against it. These are the bytes CI has always installed; only the
serving host changed.

**Effect.** CI installs FastQC from this repository's releases, over a connection to
GitHub — the same host that already serves `vsearch` and `swarm` — so the FastQC host is
no longer on the critical path for building or reproducing the pipeline.

## Adding an entry

Capture the archive, verify it against the existing pinned checksum (or, for a new tool,
establish a checksum through a healthy source and record how), attach it to a release
tagged `vendored/<tool>-v<version>` and marked as a pre-release, repoint the URL in
`config/defaults/tool_versions.yml` keeping the checksum unchanged, add an entry here
with the same fields, and extend the guard in `test/unit/test_install_pins.jl`.
