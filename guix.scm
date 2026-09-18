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
             (gnu packages julia)
             (gnu packages statistics)
             (gnu packages node)
             (gnu packages version-control)
             (gnu packages rust-apps))

(package
  (name "metamanifold-webui")
  (version "0.1.0")
  (source #f)
  (build-system gnu-build-system)
  (inputs (list julia r node-lts just git coreutils bash))
  (synopsis "MetaManifold-WebUI development environment")
  (description "Development toolchain for the MetaManifold-WebUI fork:
Julia backend, bun-managed Vite/React frontend (bun bootstrapped via
pinned installer; see file header), R/renv lane, estate `just` runner.")
  (home-page "https://github.com/hyperpolymath/MetaManifold-WebUI")
  (license (@ (guix licenses) mpl2.0)))
