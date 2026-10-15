#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
#
# @launcher-deed begin
# ;; SPDX-License-Identifier: MPL-2.0
# (praxis-deed
#   :schema-version  "1.0.0"
#   :canonical-name  "metamanifold-webui-launcher"
#   (artefact :type "launcher" :version "0.1.0"
#             :generator "hand-adapted from launcher-standard 0.6.0's archetype")
#   (app :name "MetaManifold" :display "MetaManifold"
#        :url "https://github.com/hyperpolymath/MetaManifold-WebUI"
#        :archetype "application")
#   (compliance :standard-version "0.6.0"
#               :standards ("launcher-standard.adoc"))
#   (modes :accepted ("--setup" "--start" "--doctor" "--status" "--agent" "--help" "--version"))
#   (platforms :supported ("linux" "macos"))
#   (lifecycle-phases :covered ("provision" "diagnose" "run")
#                     :deferred ("heal")))
# @launcher-deed end
#
# The MetaManifold launcher, in the launcher-standard's mode vocabulary but
# self-contained: this is an application repository, not an RSR-minted one,
# so the modes delegate directly to the repository's own entry points
# (install.sh, start.sh) rather than through provision-set machinery.
#
# The one thing that is this launcher's own is --agent: the git-signing
# agent's persistence is the operator's choice, and every mode of it is
# reversible. The signing key is ~/.ssh/git-signing2; the socket is
# /tmp/git-signing-agent.sock.
#
#   --agent systemd   a systemd user service owns the agent, and the shell
#                      profile exports the socket (a service cannot export
#                      into login shells). Survives reboots; one instance.
#   --agent profile   the shell profile starts the agent if the socket is
#                      dead and exports it. No systemd; works over plain ssh.
#   --agent both      the service plus the spawn-if-dead fallback line.
#   --agent none      removes whatever of the above was installed.
#   --agent status    reports socket, key, and which mechanisms are present.
#
# Each mechanism is written between marked blocks in the profile and a unit
# file, idempotently, with a dated backup of anything edited.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
SOCKET="/tmp/git-signing-agent.sock"
KEY="${HOME}/.ssh/git-signing2"
UNIT_NAME="git-signing-agent"
UNIT_FILE="${HOME}/.config/systemd/user/${UNIT_NAME}.service"
PROFILE="${HOME}/.profile"
BLOCK_BEGIN="# >>> metamanifold git-signing agent >>>"
BLOCK_END="# <<< metamanifold git-signing agent <<<"

say()  { printf 'launcher: %s\n' "$*"; }
warn() { printf 'launcher: %s\n' "$*" >&2; }
die()  { warn "$*"; exit 1; }

agent_alive() {
    [ -S "$SOCKET" ] && SSH_AUTH_SOCK="$SOCKET" ssh-add -l >/dev/null 2>&1
}

remove_profile_block() {
    [ -f "$PROFILE" ] || return 0
    local target tmp mode
    target="$(readlink -f "$PROFILE")" || return 1
    tmp="$(mktemp "$(dirname "$target")/.profile.tmp.XXXXXX")" || return 1
    if ! awk -v b="$BLOCK_BEGIN" -v e="$BLOCK_END" '
        $0 == b {
            if (skip) exit 1
            skip = 1
            next
        }
        $0 == e {
            if (skip) { skip = 0; next }
            print
            next
        }
        !skip { print }
        END { if (skip) exit 1 }
    ' "$target" > "$tmp"; then
        rm -f "$tmp"
        return 1
    fi
    mode="$(stat -c '%a' "$target" 2>/dev/null || stat -f '%Lp' "$target")" || {
        rm -f "$tmp"
        return 1
    }
    chmod "$mode" "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    mv "$tmp" "$target" || {
        rm -f "$tmp"
        return 1
    }
}

write_profile_block() {  # $1 = "export" | "spawn"
    [ -f "$PROFILE" ] || touch "$PROFILE" || die "could not create $PROFILE"
    local backup
    backup="$(mktemp "$PROFILE.launcher-backup.$(date +%Y%m%d%H%M%S).XXXXXX")" ||
        die "could not create backup of $PROFILE"
    cp -p "$PROFILE" "$backup" || {
        rm -f "$backup"
        die "backup of $PROFILE failed"
    }
    remove_profile_block || die "could not update $PROFILE"
    {
        printf '%s\n' "$BLOCK_BEGIN"
        if [ "$1" = "spawn" ]; then
            printf 'if [ ! -S "%s" ] || ! SSH_AUTH_SOCK="%s" ssh-add -l >/dev/null 2>&1; then\n' "$SOCKET" "$SOCKET"
            printf '    ssh-agent -a "%s" >/dev/null 2>&1\n' "$SOCKET"
            printf 'fi\n'
        fi
        printf 'export SSH_AUTH_SOCK="%s"\n' "$SOCKET"
        printf '%s\n' "$BLOCK_END"
    } >> "$PROFILE"
}

write_unit() {
    mkdir -p "$(dirname "$UNIT_FILE")"
    cat > "$UNIT_FILE" <<UNIT
[Unit]
Description=git signing ssh-agent (MetaManifold launcher)

[Service]
ExecStart=/usr/bin/ssh-agent -D -a ${SOCKET}
Restart=on-failure

[Install]
WantedBy=default.target
UNIT
}

agent_mode() {
    mode="${1:-}"
    case "$mode" in
        systemd)
            command -v systemctl >/dev/null || die "systemctl not found; use --agent profile"
            write_unit
            systemctl --user daemon-reload
            systemctl --user enable --now "$UNIT_NAME" || die "could not enable ${UNIT_NAME} (try: loginctl enable-linger)"
            write_profile_block export
            say "systemd user service enabled; profile exports SSH_AUTH_SOCK=$SOCKET"
            say "note: over plain ssh, or without a user session, also run: loginctl enable-linger \$USER"
            ;;
        profile)
            write_profile_block spawn
            say "profile now starts the agent if the socket is dead and exports SSH_AUTH_SOCK=$SOCKET"
            ;;
        both)
            command -v systemctl >/dev/null || die "systemctl not found; use --agent profile"
            write_unit
            systemctl --user daemon-reload
            systemctl --user enable --now "$UNIT_NAME" || die "could not enable ${UNIT_NAME}"
            write_profile_block spawn
            say "systemd service plus spawn-if-dead profile fallback installed"
            ;;
        none)
            systemctl --user disable --now "$UNIT_NAME" >/dev/null 2>&1
            rm -f "$UNIT_FILE"
            remove_profile_block
            say "removed unit and profile block; any agent already running is left alone"
            ;;
        status)
            agent_alive && say "socket alive: $SOCKET" || say "socket dead or absent: $SOCKET"
            [ -f "$KEY" ] && say "key present: $KEY" || say "key MISSING: $KEY"
            [ -f "$UNIT_FILE" ] && say "systemd unit: installed" || say "systemd unit: not installed"
            grep -q "$BLOCK_BEGIN" "$PROFILE" 2>/dev/null && say "profile block: present" || say "profile block: absent"
            ;;
        *)
            die "usage: launcher.sh --agent systemd|profile|both|none|status"
            ;;
    esac
}

doctor() {
    fail=0
    for tool in julia bun R git; do
        if command -v "$tool" >/dev/null; then
            say "ok: $tool on PATH"
        else
            warn "MISSING: $tool not on PATH"
            fail=1
        fi
    done
    [ -f "$REPO_DIR/config/tools.yml" ] && say "ok: config/tools.yml exists" \
        || warn "config/tools.yml missing (run: ./launcher.sh --setup)"
    if agent_alive; then
        say "ok: signing agent alive at $SOCKET"
        SSH_AUTH_SOCK="$SOCKET" ssh-add -l 2>/dev/null | grep -q "$(ssh-keygen -lf "${KEY}.pub" 2>/dev/null | awk '{print $2}')" \
            && say "ok: signing key loaded" || warn "signing key not loaded (run: ssh-add $KEY)"
    else
        warn "signing agent not reachable at $SOCKET (see: ./launcher.sh --agent status)"
        fail=1
    fi
    exit "$fail"
}

help() {
    sed -n '2,40p' "${BASH_SOURCE[0]}" | grep '^#' | sed 's/^# \{0,1\}//'
    cat <<'MODES'
Modes:
  --setup            install everything (delegates to install.sh; args pass through)
  --start            serve the web UI (delegates to start.sh)
  --doctor           check the toolchain and the signing agent
  --status           whether the server looks reachable on its port
  --agent MODE       systemd | profile | both | none | status  (the signing agent)
  --help             this text
  --version          the launcher's version
MODES
}

version() { echo "metamanifold-webui-launcher 0.1.0 (launcher-standard 0.6.0, hand-adapted)"; }

main() {
    case "${1:-}" in
        --setup)  shift; exec bash "$REPO_DIR/install.sh" "$@" ;;
        --start)  exec bash "$REPO_DIR/start.sh" ;;
        --doctor) doctor ;;
        --status)
            if curl -s -o /dev/null --max-time 2 http://127.0.0.1:8080/; then
                say "something is answering on http://127.0.0.1:8080/"
            else
                say "nothing answering on http://127.0.0.1:8080/ (start with: ./launcher.sh --start)"
            fi
            ;;
        --agent)  shift; agent_mode "${1:-}" ;;
        --help|-h) help ;;
        --version) version ;;
        *)        help; exit 1 ;;
    esac
}

main "$@"
