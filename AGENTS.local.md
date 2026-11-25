# pcode fork notes

Fork-specific rules for agents. `AGENTS.md` belongs to upstream Ghostty: leave
it alone so rebases stay clean, and put fork rules here.

- **`pcode-smooth` is the mainline.** `just install` builds whatever is checked
  out in `~/p/ghostty-smooth` (normally `pcode-smooth`) and points
  `builds/current` at it. A feature merged only into a spike or feature branch,
  or installed from a worktree, looks shipped until the next session runs
  `just install` from here and silently replaces it.
- **Work is done only when it's on `pcode-smooth` and installed.** Merge into
  `pcode-smooth` (from a worktree, if other sessions are using this checkout),
  push, run `just install` from `~/p/ghostty-smooth`, then confirm the build
  has your change: `strings - builds/current/Contents/MacOS/ghostty | grep
  <one of your symbols>`. If you can't merge (the checkout has someone else's
  uncommitted work, or the user said to hold off), say so at the top of your
  final message, name the branch, and say the change isn't in the installed app.
- **Several sessions share this checkout.** Check `git status` before merging,
  and commit only your own paths; untracked files can be another session's
  work in progress.
