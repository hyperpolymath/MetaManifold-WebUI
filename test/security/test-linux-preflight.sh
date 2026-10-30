#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Smoke/format regression: run from repository root, no elevated privileges.
set -eu
script=scripts/security/linux-preflight.sh
[ -f "$script" ] || { echo "Missing $script" >&2; exit 1; }
sh -n "$script"
help=$(sh "$script" --help)
case "$help" in *'Read-only'*) : ;; *) echo 'Missing read-only help contract' >&2; exit 1 ;; esac
if sh "$script" --invalid >/dev/null 2>&1; then
    echo 'Invalid option unexpectedly succeeded' >&2
    exit 1
fi
# Pure label fixtures: do not mistake a confined profile named "unconfined_*"
# for an actually unconfined task, or an unreadable value for evidence.
. scripts/security/label-state.sh
[ "$(classify_apparmor_label '')" = unknown ]
[ "$(classify_apparmor_label unconfined)" = unconfined ]
[ "$(classify_apparmor_label 'unconfined (complain)')" = unconfined ]
[ "$(classify_apparmor_label 'unconfined_worker (enforce)')" = label-present ]
[ "$(classify_apparmor_label 'myprofile (enforce)')" = label-present ]
[ "$(classify_generic_label 'unconfined_worker (enforce)')" = unknown ]
[ "$(classify_generic_label 'user_u:user_r:user_t:s0')" = label-present ]
[ "$(classify_generic_label '')" = unknown ]
out=$(sh "$script")
# Every non-comment row must have exactly three tab-separated fields.
printf '%s\n' "$out" | awk -F '\t' '/^#/ { next } NF != 3 { bad = 1; print "Bad record: " $0 > "/dev/stderr" } END { exit bad }'
for key in os selinux_mode active_lsms apparmor_process process_security_label no_new_privs landlock cgroup_v2 open_file_limit cpu_time_limit file_size_limit umask ssh_client tls_ingress user_authentication data_isolation audit_durability result; do
    count=$(printf '%s\n' "$out" | awk -F '\t' -v key="$key" '$1 == key { n++ } END { print n+0 }')
    [ "$count" -eq 1 ] || { echo "Expected one $key record; got $count" >&2; exit 1; }
done
printf '%s\n' "$out" | grep -q '^result[[:space:]]informational-only[[:space:]]' || { echo 'Missing non-certification result' >&2; exit 1; }
echo 'linux-preflight: PASS (format and safety-contract smoke tests)'
