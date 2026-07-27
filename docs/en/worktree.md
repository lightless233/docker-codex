# Checkout and worktree behavior

This page explains how the launcher locates and mounts the current checkout,
and how the `--isolated` retained worktree and `--bind` extra directory
mounts behave. Read it when you need to manage isolated worktrees or mount
directories outside the checkout.

By default, the launcher uses the checkout containing the current directory. It
does not create a branch or worktree.

The checkout is mounted at the same absolute path in the container. When the
checkout is a linked worktree or submodule whose Git metadata lives elsewhere,
the launcher discovers that metadata with Git and mounts only the required
external Git directories, also at the same paths.

For example, a long-lived linked worktree can be used directly:

```bash
cd /home/me/program/my-long-lived-worktree
docker-codex
```

The container receives write access to the Git common directory because staging
and commits update its index and refs. It does not receive the sibling working
trees unless they are separately mounted.

## Optional isolated worktree

Create a new host worktree explicitly:

```bash
docker-codex --isolated issue-123
```

This creates:

- branch `codex/issue-123`;
- a worktree below
  `${DOCKER_CODEX_DATA_HOME:-${XDG_DATA_HOME:-$HOME/.local/share}/docker-codex}/worktrees`;
- a container using that new worktree.

The worktree and branch are retained when Codex or Docker exits, including when
startup fails. Inspect and remove them explicitly:

```bash
git worktree list
git worktree remove /absolute/path/from-the-list
git branch -d codex/issue-123
```

Git refuses removal when a worktree contains uncommitted changes unless the
user deliberately overrides it. The launcher never removes worktrees itself.

## Additional project directories

Use repeatable `--bind` options for fixtures or tools outside the checkout:

```bash
docker-codex \
  --bind /absolute/path/to/fixtures:ro \
  --bind /absolute/path/to/local-tooling \
  --
```

The source is mounted at the same absolute container path. Only directories are
accepted. Paths containing commas are rejected because Docker's `--mount`
grammar cannot represent them unambiguously.

The launcher deliberately does not mount the checkout's parent directory. This
keeps unrelated repositories and long-lived working trees outside the
container.

---

Back to [README](../../README.en.md)
