unposted draft
SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk>
SPDX-License-Identifier: AGPL-3.0-or-later

# Final step: after CompositionalDA is registered in General (General#175952)

Do not run this before the registry shows CompositionalDA 0.1.0. Target: v0.1.0 at bb3cf54
(Release 0.1.0 for registration in General). Note for the owner: the existing git tag v0.1.0
in hyperpolymath/CompositionalDA.jl points at 320513d, not bb3cf54. See the hub card.

Owner confirmation for signing (SR-011) is needed again for this amend.

```
cd /home/user/MetaManifold-WebUI
git switch rebuild/pr70-native-da
git fetch upstream main            # if main moved: git rebase upstream/main (no merge commits)
export R_HOME=/opt/R/4.5.0/lib/R LD_LIBRARY_PATH=$R_HOME/lib   # a Julia 1.12.5 on PATH
julia --project=. -e 'using Pkg; Pkg.Registry.update(); Pkg.resolve(); Pkg.instantiate()'
# Project.toml already declares CompositionalDA = "0.1". resolve adds the Manifest entry.
# Checks, all must hold:
grep -n -A6 '^\[\[deps.CompositionalDA\]\]' Manifest.toml     # version = "0.1.0", a git-tree-sha1, NO repo-url, NO path
git diff --stat -- Manifest.toml                              # only CompositionalDA and its new dependencies
julia --project=. -t 2 test/runtests.jl differential_native differential
git add Project.toml Manifest.toml
git commit --amend --no-edit -S    # with the SR-011 per-commit identity and signing options
git log -1 --format='%G? %ce'      # G and the signing email
bash scripts/maintenance/check-pr-freshness.sh --base upstream/main --head HEAD   # if the script exists on main
```
No `Pkg.develop`, no `Pkg.add(url=...)`, no `[sources]` entry anywhere.
