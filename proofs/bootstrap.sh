#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# Bootstrap and run the Agda proof gate.
#
# This script exists because the proofs must be checkable by anyone, on a clean
# machine, with one command — and because a proof gate that silently passes when
# the prover is absent is worse than no gate at all.  Every failure mode below
# exits non-zero.  There is no `|| true`, no `command -v agda || exit 0`, and no
# path in which "prover not installed" is reported as success.
#
# Usage:
#   proofs/bootstrap.sh              bootstrap if needed, then check
#   proofs/bootstrap.sh --bootstrap  install toolchain only
#   proofs/bootstrap.sh --check      check only (fail if not bootstrapped)
#
# Environment:
#   AGDA_BIN      path to an agda binary to use instead of bootstrapping one
#   PROOFS_VENDOR directory for the vendored stdlib / Agda source
#                 (default: proofs/.vendor, which is git-ignored)
#
# Pinned versions — these are the versions the proofs were developed against.
# Agda 2.7.0.1 with stdlib 3.0.  Changing either is a real change to the gate and
# must be reviewed, not a maintenance chore to be done silently.

set -euo pipefail

AGDA_VERSION="2.7.0.1"

# agda-stdlib revision.  Pinned by SHA, not by tag, and the reason matters:
# these proofs use stdlib APIs (`Data.Integer.Properties._≡?_`, the `Dec` record
# shape, `toWitness {a? = …}`, `NonNegative` *instances* for
# `*-monoʳ-≤-nonNeg`) that exist only on the development line towards 3.0 — the
# branch self-identifies as `standard-library-3.0` but no `v3.0` tag has been cut.
# They do NOT compile against the latest release (v2.4) or against v2.1, which is
# the estate pin on `main`.  See proofs/residue/toolchain.residue.
STDLIB_VERSION="2ffa8b7d4e8e818717ad643d184f055a4d1b0447"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROOFS_DIR="$REPO_ROOT/proofs"
AGDA_DIR_SRC="$PROOFS_DIR/agda"
VENDOR="${PROOFS_VENDOR:-$PROOFS_DIR/.vendor}"
LIB_FILE="$AGDA_DIR_SRC/metamanifold-proofs.agda-lib"

log() { printf 'proofs: %s\n' "$*"; }
die() { printf 'proofs: FATAL: %s\n' "$*" >&2; exit 1; }

[[ -f "$LIB_FILE" ]] || die "missing $LIB_FILE"

##############################################################################
# Locate or install Agda
##############################################################################

resolve_agda() {
  if [[ -n "${AGDA_BIN:-}" ]]; then
    [[ -x "$AGDA_BIN" ]] || die "AGDA_BIN=$AGDA_BIN is not executable"
    AGDA="$AGDA_BIN"
    return 0
  fi
  if command -v agda >/dev/null 2>&1; then
    AGDA="$(command -v agda)"
    return 0
  fi
  if [[ -x "$VENDOR/venv/bin/agda" ]]; then
    AGDA="$VENDOR/venv/bin/agda"
    return 0
  fi
  return 1
}

install_agda() {
  log "no agda on PATH; installing agda $AGDA_VERSION from PyPI into $VENDOR/venv"
  command -v python3 >/dev/null 2>&1 || die "python3 is required to bootstrap agda"
  mkdir -p "$VENDOR"
  python3 -m venv "$VENDOR/venv"
  "$VENDOR/venv/bin/pip" install --quiet --disable-pip-version-check "agda==$AGDA_VERSION" \
    || die "pip install agda==$AGDA_VERSION failed"
  AGDA="$VENDOR/venv/bin/agda"
  [[ -x "$AGDA" ]] || die "agda was not installed at $AGDA"
}

##############################################################################
# Vendor the standard library and the Agda primitive libraries
##############################################################################

vendor_stdlib() {
  if [[ -f "$VENDOR/agda-stdlib/standard-library.agda-lib" ]]; then
    return 0
  fi
  log "cloning agda-stdlib at $STDLIB_VERSION"
  mkdir -p "$VENDOR"
  rm -rf "$VENDOR/agda-stdlib"
  # A tag would allow `--branch`; a SHA does not, so fetch the exact revision.
  git init -q "$VENDOR/agda-stdlib"
  git -C "$VENDOR/agda-stdlib" remote add origin https://github.com/agda/agda-stdlib
  git -C "$VENDOR/agda-stdlib" fetch -q --depth 1 origin "$STDLIB_VERSION" \
    && git -C "$VENDOR/agda-stdlib" checkout -q FETCH_HEAD \
    || die "could not fetch agda-stdlib $STDLIB_VERSION"
  # The upstream `.agda-lib` file is named after the tag (`agda-stdlib.agda-lib`
  # on some tags, `standard-library-2.1.agda-lib` on others) and its `name:` does
  # not always read `standard-library`, which is what `defaults` and every
  # `depend:` clause refer to.  Normalise both, whatever the tag ships.
  local lib
  lib="$(find "$VENDOR/agda-stdlib" -maxdepth 1 -name '*.agda-lib' | head -1)"
  [[ -n "$lib" ]] || die "the agda-stdlib checkout at $STDLIB_VERSION has no .agda-lib file"
  sed -i 's/^name: .*/name: standard-library/' "$lib"
  if [[ "$(basename "$lib")" != "standard-library.agda-lib" ]]; then
    cp "$lib" "$VENDOR/agda-stdlib/standard-library.agda-lib"
  fi
  log "stdlib library file: $lib"
}

vendor_prims() {
  # The PyPI wheel ships the Agda executable but not `Agda.Primitive` and
  # friends, which every module transitively needs.  They come from the source
  # tree at the matching tag.  A wheel installed from a system package manager
  # normally has them already, in which case this is a no-op.
  local datadir
  datadir="$("$AGDA" --print-agda-dir)"
  if [[ -d "$datadir/lib/prim/Agda" ]]; then
    log "primitive libraries already present at $datadir/lib/prim"
    PRIM_SRC=""
    return 0
  fi
  log "fetching Agda v$AGDA_VERSION source for the primitive libraries"
  mkdir -p "$VENDOR"
  if [[ ! -d "$VENDOR/agda-src/src/data/lib/prim/Agda" ]]; then
    rm -rf "$VENDOR/agda-src"
    git clone --quiet --depth 1 --branch "v$AGDA_VERSION" \
      https://github.com/agda/agda "$VENDOR/agda-src" \
      || die "could not clone agda v$AGDA_VERSION (needed for the primitive libraries)"
  fi
  mkdir -p "$datadir/lib"
  cp -r "$VENDOR/agda-src/src/data/lib/prim" "$datadir/lib/prim" \
    || die "could not install the primitive libraries into $datadir/lib/prim"
}

# Agda looks for the library list in two places, and which one wins depends on
# how Agda was installed: the user config directory (`~/.config/agda/`, i.e.
# $XDG_CONFIG_HOME/agda/) and the data directory reported by --print-agda-dir.
# A PyPI wheel reads one, a distro package the other.  Write both, so the gate
# does not depend on how the toolchain happens to have been installed.
AGDA_LIBRARIES_FILE="$PROOFS_DIR/.agda-libraries"

write_agda_config() {
  # A stable, in-repo libraries file.  check() passes this to Agda explicitly via
  # --library-file, so the gate works even if neither config location is read.
  {
    printf '%s\n' "$LIB_FILE"
    printf '%s\n' "$VENDOR/agda-stdlib/standard-library.agda-lib"
  } > "$AGDA_LIBRARIES_FILE"

  local datadir userdir
  datadir="$("$AGDA" --print-agda-dir)"
  userdir="${XDG_CONFIG_HOME:-$HOME/.config}/agda"
  for d in "$datadir/lib" "$userdir"; do
    mkdir -p "$d"
    cp "$AGDA_LIBRARIES_FILE" "$d/libraries"
    printf 'standard-library\n' > "$d/defaults"
    log "wrote $d/{libraries,defaults}"
  done
}

##############################################################################
# The gate itself
##############################################################################

check() {
  resolve_agda || die "agda is not installed and no AGDA_BIN was given; run proofs/bootstrap.sh"
  log "using $("$AGDA" --version)"
  cd "$AGDA_DIR_SRC"
  # --safe: no postulates, no foreign code, no `--type-in-type`.  A proof that
  # needs an escape hatch is not a proof.
  # --without-K: no proof-irrelevance-by-fiat for equality.
  log "type-checking MetaManifold.All (this reaches every module in the tree)"
  if [[ -f "$AGDA_LIBRARIES_FILE" ]]; then
    "$AGDA" --library-file="$AGDA_LIBRARIES_FILE" --safe --without-K MetaManifold/All.agda
  else
    die "$AGDA_LIBRARIES_FILE is missing; run proofs/bootstrap.sh --bootstrap first"
  fi
  log "axiom audit"
  "$PROOFS_DIR/tests/axiom-audit.sh"
  log "OK"
}

case "${1:-}" in
  --bootstrap)
    resolve_agda || install_agda
    vendor_stdlib
    vendor_prims
    write_agda_config
    ;;
  --check)
    check
    ;;
  "")
    resolve_agda || install_agda
    vendor_stdlib
    vendor_prims
    write_agda_config
    check
    ;;
  *)
    die "unknown argument: $1 (expected --bootstrap, --check, or nothing)"
    ;;
esac
