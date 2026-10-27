# Signed commits for upstream PRs

JoshuaJewell/MetaManifold-WebUI requires every commit to show as **Verified** on
GitHub, and merges by fast-forward only (CONTRIBUTING, "Pull requests", items 3
and 8, from upstream `bf1d3ef`). The commits on the branch are the commits that
land on `main`, so each one must build, pass and carry a message that stands on
its own.

## Who signs

Claude Code cloud sessions cannot sign: there is no signing key in the
container, and putting a private key in an environment secret is not worth the
risk. So a session prepares the branch unsigned, and the signing happens on a
machine that holds your key.

Your signing already works: the heads of upstream PRs 62 and 63 were Verified
on 2026-10-19.

## The routine

On the machine with your key, for a branch a session prepared before review
started, or after Joshua asked for a rebase:

```sh
git fetch upstream main                      # JoshuaJewell/MetaManifold-WebUI
git switch <branch>
git rebase upstream/main                     # only if main moved, or when asked
git rebase --exec 'git commit --amend --no-edit -S' upstream/main
git log --format='%h %G? %s' upstream/main..HEAD   # see the table below
git push --force-with-lease origin <branch>  # before review, or after a requested rebase
```

The `--exec` line replays every commit after `upstream/main` onto its tip, so on
a branch that started from an older `main` it is itself a rebase, whether or not
the line before it ran.

### A PR already under review

Once review has started, re-sign only the commits added since the head Joshua
reviewed, and push them as a fast-forward; the reviewed commits keep their
hashes and signatures:

```sh
git fetch origin <prepared-branch> <pr-branch>      # this fork
git switch -c <local> origin/<prepared-branch>
git merge-base --is-ancestor <reviewed-head> HEAD &&
  git rebase --exec 'git commit --amend --no-edit -S' <reviewed-head>
git log --format='%h %G? %s' <reviewed-head>..HEAD  # see the table below
git push origin <local>:<pr-branch>                 # fast-forward: no --force
```

`<reviewed-head>` is the PR's head commit when the review was given, and the
prepared branch must contain it. The `merge-base` check stops the re-sign when
it does not. Without that check, `git rebase <reviewed-head>` would replay the
branch onto the reviewed head, along with any upstream commits it carries, and
the push would then go through as a fast-forward. On `wip/pr62-theta`, for
example, it would replay Joshua's `78ffc2f` re-signed as yours, together with
copies of the PR's own commits. When the check stops it, nothing is rewritten,
and pushing the untouched branch is refused as a non fast-forward.

### Squash-merging the fork PR instead

Squash-merging a fork PR into `upstream/<topic>` on GitHub also works: GitHub
signs the squash commit (Verified, with its own key) and the upstream PR moves
forward by that one commit. Three things change:

- The prepared commits become one, so their separate messages are lost.
- The squash commit's message defaults to the fork PR's title and description,
  fork-internal notes and `(#NNN)` fork references included, and it lands on
  Joshua's `main` unchanged. Replace it in the merge dialog with a message that
  stands on its own upstream (upstream CONTRIBUTING item 8).
- The signature is GitHub's key, not yours. It shows Verified, but upstream
  CONTRIBUTING item 3 asks for a key registered to your account, so this path
  has not been cleared with Joshua. (This fork's own CONTRIBUTING numbers its
  items differently.)

This happened with #192: its squash commit `e28e832` on `upstream/glmgampoi-r`
carries #192's whole description as its message.

What `%G?` prints, and what to do:

| status | meaning | action |
| --- | --- | --- |
| `G` | good signature | pass |
| `E`, `U` | local git cannot check it, or the key's validity is unknown (`E` is usual for SSH signing without `gpg.ssh.allowedSignersFile`) | push, then confirm Verified on the PR's Commits tab |
| `N` | unsigned | re-sign |
| `B`, `X`, `Y`, `R` | bad signature, expired signature, expired key, revoked key | stop; fix the key, then re-sign |

GitHub's Verified badge is what upstream checks.

## Rules that follow from fast-forward merging

- Before review starts, rebase and re-sign freely.
- Once review has started, add commits; rebase only when Joshua asks, and
  re-sign when you do.
- Never merge `main` into a PR branch: the merge commit would land on his
  `main`.

## Branches known to need re-signing

None at present.

## Record

- Upstream PR 62 (glmGamPoi). The squash commit `e28e832` was replaced by
  #192's three commits, fetched from `refs/pull/192/head` and re-signed. At
  Joshua's request the five-commit stack was then rebased onto upstream
  `ce2c645`. He merged it by fast-forward on 2026-10-22 (head `08eaa8c`) and
  deleted `upstream/glmgampoi-r`.
- `wip/pr62-theta` was superseded by #192 and has since been deleted from this
  fork. Its theta commit landed upstream as `6b96d36`.
