#!/usr/bin/env bash
# SPDX-License-Identifier: MPL-2.0
# Run existing synthetic-data tests at both pins. Never start a live server,
# SSH session, DOI publication or destructive scanner mode.
set -euo pipefail
if [[ $# -ne 3 ]]; then
  echo 'Usage: test-two-tree.sh CONFIG WORKSPACE OUTPUT' >&2; exit 2
fi
config=$(realpath "$1"); workspace=$(realpath "$2"); out=$(realpath "$3")
harness=$(dirname "$(dirname "$(dirname "$config")")")
for exe in julia R Rscript jq timeout; do command -v "$exe" >/dev/null; done
julia --version > "$out/julia-version.txt"
R --version > "$out/r-version.txt"
# Both Julia lockfiles are byte-identical at the measured tips. Assert this
# before sharing a depot; R lockfiles differ and are restored separately below.
up=$(jq -r .trees.upstream.revision "$config"); fork=$(jq -r .trees.fork.revision "$config")
for file in Project.toml Manifest.toml; do
  [[ "$(git -C "$workspace/upstream" rev-parse "HEAD:$file")" == \
     "$(git -C "$workspace/fork" rev-parse "HEAD:$file")" ]]
done
# No publication even if the runner has deployment variables configured.
unset DOI_ENABLED ZENODO_TOKEN JULIA_METAMANIFOLD_ALLOWED_ORIGINS
# This is a targeted evidence run, not the repository's full CI job. Keep the
# tests' own loud-skip behaviour for absent external bioinformatics binaries;
# required R packages for the selected scientific tests are asserted below.
export CI=false CI_SKIP_TAXONOMY=1
failed=0
for side in upstream fork; do
  tree="$workspace/$side"; dest="$out/$side"; mkdir -p "$dest"
  (
    cd "$tree"
    julia --project=. -e 'using Pkg; Pkg.instantiate()' > "$dest/julia-instantiate.log" 2>&1
    # A writable, per-tree library outside the measured checkout and outside the
    # sealed evidence directory. renv's default .Library target is not writable
    # on the hosted runner; a shared library would also leak fork packages.
    export R_LIBS_USER="$workspace/r-libraries/$side"
    export RENV_PATHS_CACHE="$workspace/renv-cache"
    export RENV_CONFIG_AUTOLOADER_ENABLED=FALSE
    mkdir -p "$R_LIBS_USER" "$RENV_PATHS_CACHE"
    sudo env R_LIBS_SITE="$R_LIBS_SITE" R_CLI_DYNAMIC=false TERM=dumb \
      Rscript --no-init-file -e 'if (!requireNamespace("renv", quietly=TRUE)) install.packages("renv", repos="https://cloud.r-project.org", lib=.Library)' \
      > "$dest/renv-bootstrap.log" 2>&1
    Rscript --no-init-file -e 'renv::restore(project=".", library=Sys.getenv("R_LIBS_USER"), prompt=FALSE)' \
      > "$dest/renv-restore.log" 2>&1
    Rscript --no-init-file -e 'cat(R.version.string, "\n"); cat("library:", .libPaths(), "\n"); p <- c("MASS","vegan","zCompositions","glmGamPoi","dada2"); for (x in p) cat(x, if (requireNamespace(x,quietly=TRUE)) as.character(packageVersion(x)) else "ABSENT", "\n")' \
      > "$dest/r-packages.txt"
    mapfile -t tests < <(jq -r '.julia_tests[]' "$config")
    if [[ "$side" == fork ]]; then
      mapfile -t extra < <(jq -r '.fork_only_julia_tests[]' "$config"); tests+=("${extra[@]}")
    fi
    rc=0
    timeout 1800 julia --project=. -t 2 test/runtests.jl "${tests[@]}" \
      > "$dest/julia-tests.log" 2>&1 || rc=$?
    echo "$rc" > "$dest/julia-tests.exit"
    jq -n --argjson rc "$rc" --argjson tests "$(printf '%s\n' "${tests[@]}" | jq -R . | jq -s .)" \
      '{command: (["julia","--project=.","-t","2","test/runtests.jl"] + $tests), exit_code: $rc,
        data: "synthetic fixtures only", live_ssh: false, live_doi: false}' > "$dest/julia-tests-command.json"
    status="$rc"
    fc=0
    EVIDENCE_FAULT_JSON="$dest/fault-injection.json" timeout 180 \
      julia --project=. "$harness/scripts/evidence/fault-injection.jl" \
      > "$dest/fault-injection.log" 2>&1 || fc=$?
    echo "$fc" > "$dest/fault-injection.exit"
    jq -n --argjson rc "$fc" --arg script "$harness/scripts/evidence/fault-injection.jl" \
      '{command: ["julia","--project=.",$script], exit_code: $rc, live_network: false,
        faults: ["upload-truncate","remote-fail","download-truncate"], data: "synthetic bytes only"}' \
      > "$dest/fault-injection-command.json"
    [[ "$fc" == 0 ]] || status=1
    while IFS= read -r test; do
      [[ -n "$test" ]] || continue
      name=$(basename "$test" .R); rc=0
      timeout 300 Rscript --vanilla "$test" > "$dest/$name.log" 2>&1 || rc=$?
      echo "$rc" > "$dest/$name.exit"
      [[ "$rc" == 0 ]] || status=1
    done < <(jq -r '.r_tests[]' "$config")
    exit "$status"
  ) || failed=1
done
# Return failure only after both trees have had a chance to produce evidence.
exit "$failed"
