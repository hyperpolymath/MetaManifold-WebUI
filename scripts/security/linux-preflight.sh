#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Read-only evidence for a native Linux security deployment review.
# This script DOES NOT certify a deployment or enforce host settings.
set -eu
. "$(dirname "$0")/label-state.sh"

if [ "${1-}" = '--help' ]; then
    printf '%s\n' 'Usage: sh scripts/security/linux-preflight.sh' \
      'Print tab-separated check, observation, and explanation records.' \
      'Read-only. Inspect the actual application/worker process separately.'
    exit 0
fi
if [ "$#" -ne 0 ]; then
    printf '%s\n' 'Unexpected arguments; use --help' >&2
    exit 2
fi

# Values in observations are bounded to a single printable line. Do not print
# hostnames, usernames, filesystem paths, secrets, or environment variables.
clean() {
    printf '%s' "$1" | LC_ALL=C tr '\n\r\t' '   ' | LC_ALL=C cut -c 1-160
}
record() {
    printf '%s\t%s\t%s\n' "$1" "$(clean "$2")" "$(clean "$3")"
}
read_one() {
    # One-line read via shell, never evaluate the contents as code.
    answer=''
    if [ -r "$1" ]; then
        IFS= read -r answer < "$1" || :
        printf '%s' "${answer-}"
    fi
}

printf '# check\tobservation\tinterpretation (no deployment assurance implied)\n'
if [ "$(uname -s)" != 'Linux' ]; then
    record os unsupported 'Native Linux preflight requires Linux'
    exit 1
fi
record os Linux 'Current process is running on Linux'
record kernel "$(uname -r)" 'Kernel version is descriptive, not a feature guarantee'

# SELinux can be enabled globally while THIS process is unconfined. In
# particular, `getenforce` never proves the Julia/worker process is confined.
if command -v getenforce >/dev/null 2>&1; then
    selinux=$(getenforce 2>/dev/null || printf 'unknown')
elif [ -r /sys/fs/selinux/enforce ]; then
    case "$(read_one /sys/fs/selinux/enforce)" in
        1) selinux=Enforcing ;;
        0) selinux=Permissive ;;
        *) selinux=unknown ;;
    esac
else
    selinux=not-detected
fi
record selinux_mode "$selinux" 'Global mode only; process confinement not established'

lsm=$(read_one /sys/kernel/security/lsm)
if [ -n "$lsm" ]; then
    record active_lsms "$lsm" 'Kernel LSM list; not proof of application confinement'
else
    record active_lsms not-observable 'LSM interface may be inaccessible or unmounted'
fi

# An AppArmor label may appear in either the module-specific attr or the
# generic LSM attr, depending on the kernel. Only use the latter as an
# AppArmor label when the LSM inventory explicitly advertises AppArmor.
if [ -r /proc/self/attr/apparmor/current ]; then
    aa=$(read_one /proc/self/attr/apparmor/current)
    record apparmor_process "$(classify_apparmor_label "$aa")" 'Observed on this probe process, not on Julia'
else
    case ",$lsm," in
        *,apparmor,*)
            if [ -r /proc/self/attr/current ]; then
                aa=$(read_one /proc/self/attr/current)
                record apparmor_process "$(classify_apparmor_label "$aa")" 'Generic LSM attr fallback for this probe; verify worker separately'
            else
                record apparmor_process not-observable 'No readable AppArmor process attribute'
            fi ;;
        *)
            record apparmor_process not-observable 'AppArmor profile not established by observable kernel interfaces' ;;
    esac
fi
if [ -r /proc/self/attr/current ]; then
    label=$(read_one /proc/self/attr/current)
    record process_security_label "$(classify_generic_label "$label")" 'A label is not evidence of effective worker confinement'
else
    record process_security_label not-observable 'Current security label cannot be read'
fi

if [ -r /proc/self/status ]; then
    nnp=$(sed -n 's/^NoNewPrivs:[[:space:]]*//p' /proc/self/status | head -n 1)
    case "$nnp" in
        1) nnp_state=enabled ;;
        0) nnp_state=disabled ;;
        *) nnp_state=unknown ;;
    esac
    record no_new_privs "$nnp_state" 'Only for this probe; worker launcher must set and verify its own'
else
    record no_new_privs not-observable 'No proc status available'
fi

case ",$lsm," in
    *,landlock,*) record landlock advertised 'Kernel LSM lists Landlock; syscall usability not tested' ;;
    *) record landlock not-verified 'Do not infer unsupported merely because kernel LSM list is inaccessible' ;;
esac

if [ -r /sys/fs/cgroup/cgroup.controllers ]; then
    ctrls=$(read_one /sys/fs/cgroup/cgroup.controllers)
    record cgroup_v2 detected 'Controller presence does not mean delegated writable quotas'
    if [ -n "$ctrls" ]; then
        record cgroup_controllers "$ctrls" 'Available controllers; no delegation test performed'
    fi
else
    record cgroup_v2 not-observable 'Root controller file not available; delegation not established'
fi

# Portable POSIX shell limits. Values are environmental observations only.
record open_file_limit "$(ulimit -n 2>/dev/null || printf unknown)" 'Soft limit for this probe process'
record cpu_time_limit "$(ulimit -t 2>/dev/null || printf unknown)" 'Soft CPU seconds limit for this probe process'
record file_size_limit "$(ulimit -f 2>/dev/null || printf unknown)" 'Soft file-size limit for this probe process'
record umask "$(umask)" 'Effective creation mask of this probe process'
if command -v ssh >/dev/null 2>&1; then
    record ssh_client available 'No connection or host-key verification attempted'
else
    record ssh_client unavailable 'SSH remote worker requires supported client'
fi
record tls_ingress not-assessed 'Must independently verify actual browser-facing HTTPS and identity boundary'
record user_authentication not-assessed 'Application identity, sessions and authorisation require runtime tests'
record data_isolation not-assessed 'App/DB/worker cross-tenant isolation requires separate adversarial tests'
record audit_durability not-assessed 'Audit tamper model and crash recovery require separate tests'
record result informational-only 'No permissions, files, network settings, policy or host state changed'
