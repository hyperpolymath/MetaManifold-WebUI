;; SPDX-License-Identifier: MPL-2.0
;; SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
;;
;; Guix development environment for MetaManifold-WebUI.
;;
;;   pinned, reproducible: guix time-machine -C channels.scm -- shell -D -f guix.scm
;;   against your current Guix: guix shell -D -f guix.scm
;;
;; Toolchain mapping (single source of truth: docs/reproducibility.md):
;;   julia   -> backend runtime (CI pins 1.12.5; see note below)
;;   r       -> system R for the renv lane (R packages pinned by renv.lock)
;;   node-lts-> Vite production build spawns node (verified: V8 traces)
;;   just    -> estate task runner (Justfile)
;;   git     -> hygiene gates read git ls-files
;;
;; Proof lane: agda + agda-stdlib from this pin run `just prove-agda`
;; (proofs/agda/README.md). The proofs themselves pin nothing about Agda's
;; version beyond the language features they use; the lane exists so that a
;; standalone checkout — and the stapeln image (stapeln.toml) — can check them
;; without a hand-assembled toolchain.
;;
;; Pipeline tools: config/defaults/tool_versions.yml is the BYTE-EXACT lane
;; (install.sh downloads cutadapt 5.2, multiqc 1.33, fastqc 0.12.1,
;; cd-hit-est 4.8.1, vsearch 2.30.5, swarm 3.1.6 against recorded sha256
;; checksums — that is the authoritative, reproducible path the pipeline
;; preflight asserts against). The guix inputs below are functional
;; equivalents for development convenience; their versions follow the
;; channels pin, NOT tool_versions.yml. swarm stays download-lane only
;; (no guix package at the pinned commit — checked 2026-09-18).
;;
;; Honest limitations (verified 2026-09-18, never faked):
;;   - Version drift: Guix package versions follow the channels.scm commit,
;;     so `julia` may not equal CI's exact 1.12.5. Where the exact CI pin is
;;     required (Pkg.test parity), use the mise lane (mise.toml) — that file
;;     pins exact binaries from upstream release archives.
;;   - bun is NOT packaged by Guix (upstream ships prebuilt binaries only).
;;     Bootstrap it deterministically with the pinned installer:
;;       curl -fsSL https://bun.sh/install | bash -s "bun-v1.3.10"
;;     The version matches .bun-version, exactly as CI reads it.

(use-modules (guix packages)
             (guix build-system gnu)
             (guix licenses)
             (gnu packages base)
             (gnu packages bash)
             (gnu packages bioinformatics)
             (gnu packages julia)
             (gnu packages statistics)
             (gnu packages node)
             (gnu packages version-control)
             (gnu packages rust-apps)
             ;; Agda: the proof lane (proofs/agda/README.md). Both the compiler
             ;; and the standard library come from the same channels pin, so the
             ;; proofs are checked against the revision the file records.
             (gnu packages agda))

(package
  (name "metamanifold-webui")
  (version "0.1.0")
  (source #f)
  (build-system gnu-build-system)
  (inputs (list julia r node-lts just git coreutils bash
                ;; proof lane (issue #21's laws + the impossibility result):
                agda agda-stdlib
                ;; pipeline-tool equivalents (see header scope note):
                cutadapt multiqc fastqc vsearch cd-hit))
  (synopsis "MetaManifold-WebUI development environment")
  (description "Development toolchain for the MetaManifold-WebUI fork:
Julia backend, bun-managed Vite/React frontend (bun bootstrapped via
pinned installer; see file header), R/renv lane, estate `just` runner.")
  (home-page "https://github.com/hyperpolymath/MetaManifold-WebUI")
  (license (@ (guix licenses) mpl2.0)))
