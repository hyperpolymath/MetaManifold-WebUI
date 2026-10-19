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

On the machine with your key, for a branch a session prepared:

```sh
git fetch upstream main                      # JoshuaJewell/MetaManifold-WebUI
git switch <branch>
git rebase upstream/main                     # only if main moved, or when asked
git rebase --exec 'git commit --amend --no-edit -S' upstream/main
git log --format='%h %G? %s' upstream/main..HEAD   # see the table below
git push --force-with-lease origin <branch>  # before review, or after a requested rebase
```

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

- `wip/pr62-theta` (3 unsigned commits, 2026-10-19), if it becomes a PR.
