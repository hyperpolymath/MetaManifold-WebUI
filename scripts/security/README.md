<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
# Native Linux deployment preflight (B0)

This is a **read-only inventory**, not a security certification or a startup
gate. Run on each intended **Linux application and worker host**, as the
account that would run the service or worker. It requires only POSIX `sh`
and conventional Linux `/proc` and `/sys` interfaces; it does not run
`sudo`, enable SELinux, install policy, open network connections, inspect
secret material or change the host. It prints no hostname or username.

```sh
sh scripts/security/linux-preflight.sh
sh test/security/test-linux-preflight.sh
```

The report contains three tab-separated columns (`check`, `observation`,
`interpretation`). Keep the result with its deployment review and separately
record the **host identity, date, runtime account and command version** in a
protected location. Do not infer those details from this deliberately redacted
output. CI runs show only CI-runner capabilities, **never the eventual host's**.

## Interpret conservatively

- `selinux_mode=Enforcing` reports a global setting, **not** whether the Julia,
  R or SSH worker is confined to an appropriate SELinux domain. A host
  administrator must install/activate policy and label files as necessary.
- `apparmor_process` and `process_security_label` describe only the probe's
  own process. Inspect and test the **actual service and worker processes**.
- `landlock=advertised` only means the kernel LSM list contains Landlock. It
  does not prove the intended ABI is usable or that a child process is
  restricted; test that separately by creating and checking a restriction.
- `cgroup_v2=detected` does not establish delegated controllers or resource
  quotas. `ulimit` values describe this shell, not future services.
- Authentication, HTTPS ingress, authorisation, storage isolation, remote
  SSH host keys, backup, logging and audit are **not assessed** here.
- A missing or inaccessible `/proc`/`/sys` interface is reported as
  *not observable*, not as proof of insecurity or lack of support.
- The report is diagnostic. **The secure multi-user service cannot be accepted
  without application-level trusted identity, default-deny authorisation,
  owner-bound jobs, protected cross-tenant data paths and adversarial tests.**
  Optional host confinement adds defence in depth, not a replacement.

Use the security coordination issue for the deployment decision and the
required identity/tenancy architecture. Do not make a pass/fail security claim
from this report alone, and do not require containers, VMs or root access.
