# SPDX-License-Identifier: AGPL-3.0-only
# CI tooling lives in a temporary environment, separate from the app lockfile.
using Pkg
Pkg.activate(; temp=true)
Pkg.add(PackageSpec(name="CoverageTools", version="1.4.2"))
using CoverageTools
LCOV.writefile("lcov.info", process_folder("src"))
