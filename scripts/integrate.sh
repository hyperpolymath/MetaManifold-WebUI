#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Hyperpolymath engineering series
#
# integrate.sh — fork↔upstream integration helper.
#
# The fork (this repo) and upstream (JoshuaJewell/MetaManifold-WebUI) share no
# git ancestor, so a naive merge conflicts on every shared-but-different path.
# This script reads config/integration.toml and turns that wall into a small,
# ordered set of trust decisions: which components are live (profiles), how any
# in-progress conflicts classify (triage), and what order to stage them (plan).
#
# Doctrine (matches the estate): every command either works or FAILS LOUDLY with
# an actionable message; nothing here silently passes. No hidden dependencies —
# bash + coreutils + git + awk only.
#
# Usage: scripts/integrate.sh <command> [args]
#   status                 Show active profile and each component's on/off state
#   profiles               List profiles with their component bundles
#   profile [NAME]         Print (no arg) or switch (NAME) the active profile
#   plan                   Recommended staging order (safest → riskiest)
#   triage [--from-file F] Classify current merge conflicts (auto/component/human)
#   enable  <id>           Augment: turn a component on for this checkout
#   disable <id>           Suspend: turn a component off for this checkout
#   verify [--strict]      List (and where possible run) the gates for active components
#
# The active selection is machine-local and never committed:
#   env METAMANIFOLD_INTEGRATION_PROFILE, else the git-excluded
#   config/integration.active.  Default (nothing set) is config/integration.toml's
#   default_profile — which is `base`, i.e. behave exactly like upstream.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="$ROOT/config/integration.toml"
ACTIVE="$ROOT/config/integration.active"

die() { printf 'integrate: %s\n' "$*" >&2; exit 1; }

[ -f "$CONFIG" ] || die "registry not found: $CONFIG"

# --------------------------------------------------------------------------- #
# TOML-subset parsers (awk). The registry is authored to a fixed shape:
#   key = "value"          scalar
#   [profiles.NAME]        profile section
#   [component.ID]         component section
# --------------------------------------------------------------------------- #

default_profile() {
    awk -F= '/^[[:space:]]*default_profile[[:space:]]*=/ { v=$2; gsub(/[[:space:]"]/,"",v); print v; exit }' "$CONFIG"
}

list_profiles() {
    awk '/^\[profiles\./{ s=$0; sub(/^\[profiles\./,"",s); sub(/\].*$/,"",s); print s }' "$CONFIG"
}

list_components() {
    awk '/^\[component\./{ s=$0; sub(/^\[component\./,"",s); sub(/\].*$/,"",s); print s }' "$CONFIG"
}

# field_value <section-kind> <id> <field>   (section-kind: profiles|component)
field_value() {
    local kind="$1" id="$2" field="$3"
    awk -v kind="$kind" -v id="$id" -v field="$field" '
        function trim(s){ gsub(/^[[:space:]]+|[[:space:]]+$/,"",s); return s }
        /^\[/ {
            sec=$0
            insec = (sec == "[" kind "." id "]")
            next
        }
        insec {
            k=trim($0); sub(/[[:space:]]*=.*$/,"",k)
            if (k==field) {
                v=$0; sub(/^[^=]*=/,"",v)
                gsub(/^[[:space:]"]+|[[:space:]"]+$/,"",v)
                print v; exit
            }
        }
    ' "$CONFIG"
}

profile_components() { field_value profiles "$1" components; }
component_field()   { field_value component "$1" "$2"; }

component_paths()   { component_field "$1" paths; }

# --------------------------------------------------------------------------- #
# Active-selection helpers (machine-local; never committed)
# --------------------------------------------------------------------------- #

active_profile() {
    if [ -n "${METAMANIFOLD_INTEGRATION_PROFILE:-}" ]; then
        printf '%s\n' "$METAMANIFOLD_INTEGRATION_PROFILE"
    elif [ -f "$ACTIVE" ]; then
        local p; p="$(awk -F= '/^profile=/{print $2}' "$ACTIVE" | tr -d '[:space:]')"
        printf '%s\n' "${p:-$(default_profile)}"
    else
        default_profile
    fi
}

override_list() { # override_list <enable|disable>
    [ -f "$ACTIVE" ] || { printf ''; return; }
    awk -F= -v key="$1" '$1==key { v=$2; gsub(/^[[:space:]]+|[[:space:]]+$/,"",v); print v; exit }' "$ACTIVE"
}

word_in() { case " $2 " in *" $1 "*) return 0;; *) return 1;; esac; }

# The resolved, ordered set of ON component ids for the active selection.
active_components() {
    local prof base en dis out=""
    prof="$(active_profile)"
    base="$(profile_components "$prof")"
    en="$(override_list enable)"
    dis="$(override_list disable)"
    local id
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        if word_in "$id" "$en"; then
            out="$out $id"
        elif word_in "$id" "$base" && ! word_in "$id" "$dis"; then
            out="$out $id"
        fi
    done < <(list_components)
    printf '%s\n' "$out" | xargs 2>/dev/null || printf '%s' "$out"
}

ensure_git_excluded() {
    local excl="$ROOT/.git/info/exclude"
    mkdir -p "$ROOT/.git/info"
    touch "$excl"
    grep -qxF 'config/integration.active' "$excl" 2>/dev/null || \
        printf '\n# active integration profile (machine-local; scripts/integrate.sh)\nconfig/integration.active\n' >> "$excl"
}

valid_component() { word_in "$1" "$(list_components | tr '\n' ' ')"; }
valid_profile()   { word_in "$1" "$(list_profiles  | tr '\n' ' ')"; }

# --------------------------------------------------------------------------- #
# Commands
# --------------------------------------------------------------------------- #

cmd_status() {
    local prof; prof="$(active_profile)"
    printf 'Active profile : %s\n' "$prof"
    printf 'Registry       : %s\n' "${CONFIG#$ROOT/}"
    [ -n "${METAMANIFOLD_INTEGRATION_PROFILE:-}" ] && printf 'Source         : env METAMANIFOLD_INTEGRATION_PROFILE\n'
    printf '\nComponents:\n'
    local on; on=" $(active_components) "
    local id name risk area state
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        name="$(component_field "$id" name)"
        risk="$(component_field "$id" risk)"
        area="$(component_field "$id" area)"
        if word_in "$id" "$on"; then state="ON "; else state="off"; fi
        printf '  [%s] %-16s %-6s %-9s %s\n' "$state" "$id" "$area" "$risk" "$name"
    done < <(list_components)
}

cmd_profiles() {
    local p desc comps n
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        desc="$(field_value profiles "$p" description)"
        comps="$(profile_components "$p")"
        if [ -z "$(printf '%s' "$comps" | tr -d '[:space:]')" ]; then n=0; else n=$(printf '%s\n' $comps | wc -l | xargs); fi
        printf '%-14s (%s component(s))\n    %s\n' "$p" "$n" "$desc"
    done < <(list_profiles)
}

cmd_profile() {
    local name="${1:-}"
    if [ -z "$name" ]; then active_profile; return; fi
    valid_profile "$name" || die "unknown profile '$name'. Try: $(list_profiles | tr '\n' ' ')"
    printf 'profile=%s\n' "$name" > "$ACTIVE"
    ensure_git_excluded
    printf 'Active profile set to %s (written to %s, git-excluded).\n' "$name" "${ACTIVE#$ROOT/}"
    printf 'Active components: %s\n' "$(active_components)"
}

_override_add() { # _override_add <enable|disable> <id>
    local key="$1" id="$2"
    valid_component "$id" || die "unknown component '$id'. Try: $(list_components | tr '\n' ' ')"
    [ -f "$ACTIVE" ] || printf 'profile=%s\n' "$(active_profile)" > "$ACTIVE"
    ensure_git_excluded
    local cur; cur="$(override_list "$key")"
    if word_in "$id" "$cur"; then printf '%s already contains %s\n' "$key" "$id"; return; fi
    cur="$(printf '%s %s' "$cur" "$id" | xargs)"
    # rewrite the key line (or append it)
    if grep -q "^${key}=" "$ACTIVE"; then
        awk -v key="$key" -v val="$cur" 'BEGIN{FS=OFS="="} $1==key{sub(/=[^=]*$/,"="val)} {print}' "$ACTIVE" > "$ACTIVE.tmp"
    else
        cp "$ACTIVE" "$ACTIVE.tmp"; printf '%s=%s\n' "$key" "$cur" >> "$ACTIVE.tmp"
    fi
    mv "$ACTIVE.tmp" "$ACTIVE"
    printf '%s %s -> active components: %s\n' "$key" "$id" "$(active_components)"
}

cmd_enable()  { [ $# -ge 1 ] || die "usage: integrate.sh enable <component-id>"; _override_add enable  "$1"; }
cmd_disable() { [ $# -ge 1 ] || die "usage: integrate.sh disable <component-id>"; _override_add disable "$1"; }

risk_rank() { case "$1" in none) echo 0;; low) echo 1;; medium) echo 2;; high) echo 3;; *) echo 9;; esac; }

cmd_plan() {
    printf 'Recommended staging order (safest first). Merge/gate one tier, let CI go green, then the next.\n\n'
    local id name risk prs rank
    # stable sort by risk rank
    local ids; ids="$(list_components)"
    local sorted; sorted="$(while IFS= read -r id; do
        [ -n "$id" ] || continue
        risk="$(component_field "$id" risk)"
        printf '%s\t%s\n' "$(risk_rank "$risk")" "$id"
    done <<< "$ids" | sort -s -k1,1n | cut -f2)"
    local i=0
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        i=$((i+1))
        name="$(component_field "$id" name)"
        risk="$(component_field "$id" risk)"
        prs="$(component_field "$id" prs)"
        printf '%d. [%-6s] %-16s %s' "$i" "$risk" "$id" "$name"
        [ -n "$prs" ] && printf '   (upstream PR #%s)' "$prs"
        printf '\n'
    done <<< "$sorted"
    printf '\nTip: switch what is live with `just integrate profile <base|transitional|full>`;\n'
    printf '     flip a single component with `just augment <id>` / `just suspend <id>`.\n'
}

is_generated() {
    case "$1" in
        Manifest.toml|renv.lock|frontend/bun.lock|bun.lockb|package-lock.json|pnpm-lock.yaml) return 0;;
        renv/activate.R|renv/library/*|R/_renv_dependencies.R) return 0;;
        web/dist/*|frontend/dist/*|*/dist/*) return 0;;
        *coverage/*|*.cov|lcov.info|*/test-results/*|*junit.xml|*results.json) return 0;;
        *) return 1;;
    esac
}

match_component() { # echoes best (longest-prefix) component id for a path, or nothing
    local path="$1" id p best="" bestlen=-1 plen
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        for p in $(component_paths "$id"); do
            case "$path" in
                "$p"*) plen=${#p}; if [ "$plen" -gt "$bestlen" ]; then bestlen=$plen; best="$id"; fi;;
            esac
        done
    done < <(list_components)
    [ -n "$best" ] && printf '%s\n' "$best"
}

cmd_triage() {
    local fromfile=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --from-file) [ -n "${2:-}" ] || die "--from-file requires a path"; fromfile="$2"; shift 2;;
            *) die "triage: unknown option '$1'";;
        esac
    done

    local files
    if [ -n "$fromfile" ]; then
        # Accept any readable source (regular file, pipe, /dev/stdin, process
        # substitution) — only fail when it genuinely cannot be read.
        files="$(cat "$fromfile" 2>/dev/null)" || die "cannot read conflict list: $fromfile"
    else
        if ! git -C "$ROOT" rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 && ! git -C "$ROOT" rev-parse -q --verify REBASE_HEAD >/dev/null 2>&1; then
            printf 'triage: no merge/rebase in progress (nothing to triage).\n'
            printf '        Point it at a conflict list with: integrate.sh triage --from-file <file>\n'
            return 0
        fi
        files="$(git -C "$ROOT" diff --name-only --diff-filter=U)"
    fi

    [ -n "$(printf '%s' "$files" | tr -d '[:space:]')" ] || { printf 'triage: no conflicted paths.\n'; return 0; }

    local auto=0 comp=0 unknown=0 f c risk
    printf '%-9s %-8s %-16s %s\n' "VERDICT" "RISK" "COMPONENT" "PATH"
    printf -- '--------------------------------------------------------------------------\n'
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        if is_generated "$f"; then
            auto=$((auto+1))
            printf '%-9s %-8s %-16s %s\n' "AUTO" "-" "(generated)" "$f"
        elif c="$(match_component "$f")" && [ -n "$c" ]; then
            comp=$((comp+1))
            risk="$(component_field "$c" risk)"
            printf '%-9s %-8s %-16s %s\n' "COMPONENT" "$risk" "$c" "$f"
        else
            unknown=$((unknown+1))
            printf '%-9s %-8s %-16s %s\n' "HUMAN" "?" "(unclassified)" "$f"
        fi
    done <<< "$files"
    printf -- '--------------------------------------------------------------------------\n'
    printf 'AUTO (regenerate, never hand-merge): %d\n' "$auto"
    printf 'COMPONENT (decide per registry)   : %d\n' "$comp"
    printf 'HUMAN (unclassified, review)      : %d\n' "$unknown"
    printf '\n'
    printf 'AUTO files are lockfiles/build output — resolve by regenerating, not editing:\n'
    printf '    just heal        # re-syncs pins, re-instantiates Julia, restores renv, re-installs frontend\n'
    printf 'COMPONENT files: take the side for the components you have chosen to trust\n'
    printf '    (see `just integrate status`), or hold them until you have.\n'
}

cmd_verify() {
    local strict=0 a
    for a in "$@"; do [ "$a" = "--strict" ] && strict=1 || die "verify: unknown option '$a'"; done
    local on; on=" $(active_components) "
    [ -z "$(printf '%s' "$on" | tr -d ' ')" ] && { printf 'verify: active profile has no components; nothing to verify.\n'; return 0; }

    # area -> gate recipe(s)
    local -A want=()
    local id area
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        word_in "$id" "$on" || continue
        area="$(component_field "$id" area)"
        case "$area" in
            frontend) want["check"]=1;;
            src|test) want["julia-test"]=1;;
            build)    want["ci"]=1;;
            *) : ;;
        esac
    done < <(list_components)

    [ "${#want[@]}" -gt 0 ] || { printf 'verify: active components carry no runnable gate (tooling/docs/data only).\n'; return 0; }

    printf 'Gates for the active selection (in order):\n'
    local g order="spdx format lint typecheck test julia-test ci check"
    for g in $order; do [ -n "${want[$g]:-}" ] && printf '  - just %s\n' "$g"; done
    printf '\nThis helper reports the plan; run each gate directly (e.g. `just ci`).\n'
    if [ "$strict" -eq 1 ]; then
        printf '\n--strict: verifying tool availability now.\n'
        local miss=0 t
        for t in bun julia just; do command -v "$t" >/dev/null 2>&1 || { printf 'FAIL  %s absent\n' "$t"; miss=1; }; done
        [ "$miss" -eq 0 ] && printf 'PASS  all gate tools present\n' || { printf 'Install missing tools with: just bootstrap\n' >&2; exit 1; }
    fi
}

usage() { sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

main() {
    local cmd="${1:-}"; shift || true
    case "$cmd" in
        status)   cmd_status "$@";;
        profiles) cmd_profiles "$@";;
        profile)  cmd_profile "$@";;
        plan)     cmd_plan "$@";;
        triage)   cmd_triage "$@";;
        enable)   cmd_enable "$@";;
        disable)  cmd_disable "$@";;
        verify)   cmd_verify "$@";;
        ""|help|-h|--help) usage;;
        *) die "unknown command '$cmd' (try: status|profiles|profile|plan|triage|enable|disable|verify)";;
    esac
}

main "$@"
