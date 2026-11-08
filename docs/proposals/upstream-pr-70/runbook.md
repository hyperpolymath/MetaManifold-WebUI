<!-- SPDX-License-Identifier: CC-BY-SA-4.0 -->
<!-- SPDX-FileCopyrightText: 2026 Jonathan D.A. Jewell (hyperpolymath) <j.d.a.jewell@open.ac.uk> -->

# Runbook: sign, linearise, and let CI run in the fork

Nothing in this file can be done from the sandbox that authored it — it holds
no private key and has `pull` access only. Run it on a machine with the branch
checked out and a GitHub account that can sign commits and write to the fork.
Each section is self-contained; sections 1 and 2 are one session.

## 1. Sign the branch's commits

GitHub only counts a commit as **Verified** when the signature verifies against
a key registered to the account *and* the committer email is a verified account
email. Unsigned work cannot be fixed by re-signing the tip alone —
`CONTRIBUTING.md` rule 3 applies to every commit in the range, so the series is
re-signed in one pass in section 2.

**SSH signing (simplest on GitHub):**

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_signing -C "commit signing $(date +%F)"
gh ssh-key add ~/.ssh/id_ed25519_signing.pub --type signing   # 'signing', not 'authentication'

git config --global gpg.format ssh
git config --global user.signingkey ~/.ssh/id_ed25519_signing.pub
git config --global commit.gpgsign true
git config --global user.email "<your verified account email>"
```

GPG is equivalent: skip `gpg.format`, set `user.signingkey` to the key id, and
register the public key with `gh api user/gpg_keys -f
armored_public_key=@key.asc`. SSH signing needs git >= 2.34.

**Optional, for local verification** (without this, `git log
--show-signature` prints `E` — that is expected and does not affect GitHub's
badge, which is what rule 3 counts):

```bash
echo "$(git config user.email) $(cat ~/.ssh/id_ed25519_signing.pub)" > ~/.ssh/allowed_signers
git config --global gpg.ssh.allowedSignersFile ~/.ssh/allowed_signers
```

## 2. Linearise and re-sign in one pass

The branch currently ends in merge commit `be7792f` (the CI fix was landed with
a *merge* rather than a fast-forward). Rule 2 forbids merge commits; rule 3
requires every commit signed. One rebase does both: drop the merge, keep the
three fix commits, re-sign everything.

```bash
git fetch origin validation/issue-23-native-da
git switch validation/issue-23-native-da

# 1. linear history: same three commits, no merge commit
git reset --hard 7888150
git cherry-pick aac5716 9ea52fc d4b659f

# 2. re-sign every commit on the branch (CONTRIBUTING's own recipe)
git rebase --exec 'git commit --amend --no-edit -S' 89be534
```

Verify all four conditions before pushing:

```bash
git log --format='%h %G? %s' 89be534..HEAD   # every line must be 'G', never 'N'
git log --merges 89be534..HEAD               # must be empty
gh api repos/JoshuaJewell/MetaManifold-WebUI/compare/main...$(git rev-parse HEAD) \
  --jq '{behind_by, merge_base: .merge_base_commit.sha}'   # behind_by must be 0
git log --format='%h %an <%ae> %G?' 89be534..HEAD          # committer email must be yours
```

If `behind_by` is not 0, upstream `main` has moved: rebase onto it first, then
re-run the `--exec` signing step. Push with force (the SHAs change):

```bash
git push --force-with-lease origin validation/issue-23-native-da
```

CI re-runs on the new SHAs; the content is unchanged, so the green run should
repeat. Wait for it before posting `../description.md` — the description ticks
the signed-commit and CI boxes on the strength of these steps.

If a commit was authored by someone else and must keep their author line,
`--exec` only re-signs: the author, date and message are preserved.

## 3. Let the fork run upstream's `ci.yml`

`startup_failure` on workflow validation: the fork's action policy blocks
`julia-actions/*`. The exact entries needed by the branch's `ci.yml` are below.
They are pinned to full commit SHAs — no wildcards, so a future release from
those organisations does not silently gain access.

| Entry | Used by |
|---|---|
| `julia-actions/setup-julia@4c0cb0fce8556fdb04a90347310e5db8b1f98fb9` | `Set up Julia` (v2.7.0) |
| `julia-actions/cache@d10a6fd8f31b12404a54613ebad242900567f2b9` | `Cache Julia packages` (v2.1.0) |
| `julia-actions/julia-processcoverage@03114f09f119417c3242a9fb6e0b722676aedf38` | `Process coverage` (v1.2.2) |
| `dcarbone/install-jq-action@f0e10f46ff84f4d32178b4b76e1ef180b16f82c3` | nested inside `julia-actions/cache` v2.1.0 — checked in its `action.yml`; needed at run time |
| `pyTooling/Actions/with-post-step@42e17fae05f224e5ac3d79d021a4e3577878efe5` | nested; add if the next run names it in the same error |

`actions/*` (checkout, cache, upload-artifact) are GitHub-owned and already
permitted. `oven-sh/setup-bun` and `codecov/codecov-action` passed the policy in
the run that produced the error above and were not named — leave them alone.

**Before anything else, back up the current policy.** A `PUT` to the selected
actions endpoint *replaces* the whole pattern array; sending only these five
lines would silently drop `arena-ai-coding-agent[bot]` and every other existing
entry.

```bash
gh api repos/hyperpolymath/MetaManifold-WebUI/actions/permissions/selected-actions > /tmp/allow.json
python3 - <<'PY'
import json
d = json.load(open('/tmp/allow.json'))
add = [
    "julia-actions/setup-julia@4c0cb0fce8556fdb04a90347310e5db8b1f98fb9",
    "julia-actions/cache@d10a6fd8f31b12404a54613ebad242900567f2b9",
    "julia-actions/julia-processcoverage@03114f09f119417c3242a9fb6e0b722676aedf38",
    "dcarbone/install-jq-action@f0e10f46ff84f4d32178b4b76e1ef180b16f82c3",
]
p = d.get("patterns_allowed") or []
d["patterns_allowed"] = p + [a for a in add if a not in p]
json.dump(d, open("/tmp/allow.new.json", "w"))
PY
gh api -X PUT repos/hyperpolymath/MetaManifold-WebUI/actions/permissions/selected-actions --input /tmp/allow.new.json
gh api repos/hyperpolymath/MetaManifold-WebUI/actions/permissions/selected-actions --jq '.patterns_allowed'
```

UI equivalent: **Settings → Actions → General → "Allow select actions and
reusable workflows"**, one pattern per line, then save. The sandbox token gets
`403 Resource not accessible by integration` on this endpoint — it needs an
account with admin on the fork.

**Note the scope.** This fork's own `ci.yml` on `main` does not use
`julia-actions` at all (it bootstraps Julia with `scripts/install-ci-julia.sh`
and pins `actions/checkout` v7.0.1, `actions/cache` v6.1.0,
`actions/upload-artifact` v7.0.2, `codecov/codecov-action` v7.1.1). The block
only bites when *upstream's* workflow file runs inside the fork. If you would
rather keep the policy strict, skip this section — upstream's `ci.yml` runs and
is validated in the upstream repository regardless, which is where it matters
for #70.

## 4. Re-check before posting

```bash
# every commit Verified on GitHub's side, not just locally
git rev-list 89be534..HEAD | while read sha; do
  gh api "repos/JoshuaJewell/MetaManifold-WebUI/commits/$sha" \
    --jq '"\(.sha[0:7]) \(.commit.verification.verified) \(.commit.verification.reason)"'
done
```

Then paste `../description.md` into #70's body and post `../response.md` as a
comment. Re-trigger Codex (`@codex review`) only after the review quota resets;
until then it repeats the limit message.
