#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell <j.d.a.jewell@open.ac.uk>
#
# fetch_pinned.sh — download a pinned artifact, absorbing transient failures and
# naming a TLS failure as a TLS failure.
#
# SOURCED, not executed: it defines one function and returns. Callers keep the
# checksum check and the unpacking in their own step, because those differ per
# archive (zip vs tar.gz) and the pin test asserts the checksum line is visible in
# the workflow's own run block.
#
# Usage, from a step in .github/workflows/ci.yml:
#
#     source scripts/ci/fetch_pinned.sh
#     fetch_pinned "$VSEARCH_URL" vsearch.tar.gz
#     echo "$VSEARCH_SHA256  vsearch.tar.gz" | sha256sum -c -
#
# Why this exists. On 2026-09-22T07:09Z the "Install fastqc" step reddened main on
# commit 4df7881 with:
#
#     curl: (60) SSL certificate problem: certificate has expired
#
# Nothing in that commit could cause it: the pinned FastQC URL is hosted on one
# university web server, and that server's certificate had lapsed. The gate went red
# for a third party's TLS maintenance, and the run's log said only "Process completed
# with exit code 60", which reads like a code failure until someone opens the log and
# knows what 60 means.
#
# Two things are wrong with that, and they need different fixes:
#
#   1. A transient handshake failure (a reset mid-TLS, a slow CA fetch, a proxy)
#      should not fail the build at all. curl does NOT retry those by default, and
#      `--retry` alone still excludes them; `--retry-all-errors` is what covers the
#      TLS class. That is the retry below.
#
#   2. A genuine, sustained certificate expiry cannot be retried away, and must not
#      be papered over — skipping the tool is exactly the failure issue #30 was
#      about, and the repository's standing rule is that a skip is not a pass. So it
#      still fails, but it fails SAYING WHAT IT IS, with the command that confirms it
#      and the file that repoints it. The next person then spends a minute on it
#      instead of reading a diff for a certificate they did not touch.
#
# The checksum check stays hard, and stays in the caller: a retry must never turn
# "the artifact changed" into "the artifact was eventually accepted".

# fetch_pinned <url> <output-path>
#
# Downloads <url> to <output-path>, retrying transient failures. Returns 0 on a
# non-empty download. On failure, annotates the cause and returns curl's own exit
# code, so the step fails with the code that explains it.
fetch_pinned() {
    local url="$1" out="$2" rc=0

    # --retry-all-errors is the load-bearing flag: without it curl refuses to retry
    # exit 60 (certificate), 35 (handshake) and 56 (recv), which are precisely the
    # transient cases that used to fail a run on the first attempt.
    # -f/--fail as well: without it curl treats an HTTP 404 as success and writes the
    # error page to $out, so the failure would surface later as a checksum mismatch --
    # true, but it points at the artifact rather than at the URL being wrong.
    curl -fsSL --retry 4 --retry-delay 5 --retry-all-errors \
         --connect-timeout 20 --max-time 600 \
         -o "$out" "$url" || rc=$?

    if [[ "$rc" -eq 0 ]]; then
        # A 200 with an empty body is a success to curl and a broken artifact to
        # everyone else. The checksum check would catch it, but naming it here says
        # which of the two happened.
        if [[ -s "$out" ]]; then
            return 0
        fi
        echo >&2 "::error::fetched $url but it is empty; the checksum check would fail next"
        return 1
    fi

    local host="${url#https://}"
    host="${host%%/*}"
    # The port is only appended when the URL did not already carry one, or the
    # command printed below reads `host:8443:443` and cannot be pasted anywhere.
    case "$host" in
        *:*) ;;
        *)   host="$host:443" ;;
    esac

    case "$rc" in
        35|51|58|60|77|83|90)
            echo >&2 "::error::TLS verification failed (curl exit $rc) fetching $url"
            echo >&2 "::error::The certificate is the problem, not this commit. Confirm with:"
            echo >&2 "::error::  openssl s_client -connect $host:443 </dev/null 2>/dev/null | openssl x509 -noout -dates -subject"
            echo >&2 "::error::If it has expired, the host has to renew it: re-run then, or repoint"
            echo >&2 "::error::the URL and sha256 in config/defaults/tool_versions.yml if the"
            echo >&2 "::error::artifact has moved. Do NOT skip the tool — CI installs it because"
            echo >&2 "::error::the pipeline shells out to it (issue #30)."
            ;;
        22)
            echo >&2 "::error::the server answered with an HTTP error status fetching $url"
            echo >&2 "::error::(curl --fail, exit 22). The pinned URL is wrong or the artifact"
            echo >&2 "::error::was withdrawn; check config/defaults/tool_versions.yml against"
            echo >&2 "::error::whatever the project is serving now."
            ;;
        6|7|28|56)
            echo >&2 "::error::network failure (curl exit $rc) fetching $url after 4 retries;"
            echo >&2 "::error::host unreachable or slow rather than refusing TLS. Re-run, or check"
            echo >&2 "::error::the host is still the right place for this pin."
            ;;
        *)
            echo >&2 "::error::download failed (curl exit $rc) fetching $url"
            ;;
    esac
    return "$rc"
}
