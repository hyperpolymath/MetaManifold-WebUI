;; SPDX-License-Identifier: MPL-2.0
;; SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
;;
;; channels.scm — time-machine pin for the Guix lane (see guix.scm).
;;
;;   guix time-machine -C channels.scm -- shell -D -f guix.scm
;;
;; Commit 0daef659 is guix master as of 2026-09-18, verified live via
;; `git ls-remote` against the same URL below (Codeberg hosts the canonical
;; Guix repo; the savannah host is a mirror of it).

(list (channel
        (name 'guix)
        (url "https://codeberg.org/guix/guix")
        (commit "0daef659a23220fa76a62dcbda7057cb649f415c")))
