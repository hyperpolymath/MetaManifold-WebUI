#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Install the pinned R runtime from the CRAN Ubuntu repository.
#
# R is not used to compute anything in either job that calls this script. It is
# installed because RCall's build step and module init require an R to exist:
# the package refuses to precompile without one, and MetaManifold includes
# provenance code that loads RCall. A Julia suite that never calls R still needs
# `R` on PATH.
#
# Usage: install-r-runtime.sh core|full
#
#   core  r-base-core only — enough for RCall to build and initialise.
#   full  the development, recommended and html packages — needed by the tests
#         suite, which restores renv and compiles packages from source.
#
# R_APT_VERSION must already be in the environment; CI reads it from
# config/defaults/tool_versions.yml so that the pinned revision, not whatever
# apt calls current, is what runs.
set -euo pipefail

mode="${1:-}"
case "$mode" in
  core | full) ;;
  *)
    echo "usage: $0 core|full" >&2
    exit 2
    ;;
esac

if [ -z "${R_APT_VERSION:-}" ]; then
  echo "R_APT_VERSION is not set; read it from config/defaults/tool_versions.yml" >&2
  exit 2
fi

# --https-only and an explicit keyring: the repository key is the only trust
# anchor for the archive, so it is fetched over TLS and never piped into apt's
# key management unattended.
wget --https-only -qO- https://cloud.r-project.org/bin/linux/ubuntu/marutter_pubkey.asc |
  sudo gpg --dearmor -o /usr/share/keyrings/r-project.gpg
echo "deb [signed-by=/usr/share/keyrings/r-project.gpg] https://cloud.r-project.org/bin/linux/ubuntu $(lsb_release -cs)-cran40/" |
  sudo tee /etc/apt/sources.list.d/r-project.list >/dev/null
sudo apt-get update -qq

packages=(r-base-core="$R_APT_VERSION")
options=()
if [ "$mode" = "full" ]; then
  packages+=(
    r-base-dev="$R_APT_VERSION"
    r-base-html="$R_APT_VERSION"
    r-recommended="$R_APT_VERSION"
    r-base="$R_APT_VERSION"
  )
  # r-base-dev does not carry every header the package builds need.
  sudo apt-get install -y --no-install-recommends \
    libcurl4-openssl-dev libssl-dev libxml2-dev libfontconfig1-dev
else
  # RCall only needs an R to link against, not the recommended package set.
  options+=(--no-install-recommends)
fi

sudo apt-get install -y "${options[@]}" "${packages[@]}"
R --version | head -1
