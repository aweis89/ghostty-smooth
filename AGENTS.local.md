# pcode fork notes

Fork-specific rules for agents. `AGENTS.md` belongs to upstream Ghostty: leave
it alone so rebases stay clean, and put fork rules here.

- **pcode's Swift is not in this repo.** The workspace window, dock, popups,
  pickers and their tests live in the pcode repo under `app/macos`, which its
  `app/scripts/build.sh` copies into `macos/Sources/Features/PCode/` and
  `macos/Tests/Features/PCode/` here (both gitignored). Files you find there
  are a build's copy: edits to them are overwritten by the next build. Make
  Swift changes in the pcode repo; this repo keeps the Zig core, generic
  Swift (the debug socket, config helpers) and the seam. Xcode compiles those
  ignored files whenever they're on disk, so delete both directories before
  checking that the fork builds on its own.
- **Upstream Swift reaches pcode only through `PCodeAppHooks`**
  (`macos/Sources/App/PCodeHooks.swift`). Without pcode's code every hook is
  upstream behavior, so this repo still builds alone. A new entry point means
  a new hook here plus its implementation in pcode's `PCodeAppHooksImpl`;
  never call a pcode type from an upstream file.
- **`pcode-smooth` is the mainline, and a change ships when the pcode repo
  locks it.** Merge into `pcode-smooth` (from a worktree: several sessions
  share this checkout, and untracked files can be another session's work),
  push, then in the pcode repo's main checkout run `make app-lock` and
  `make app`, and commit the new `app/ghostty.lock`. A seam change needs
  both sides in that one pcode commit. To try unmerged fork work with pcode's
  Swift: `GHOSTTY_SRC=<this checkout> make app` in pcode.
- **Push from the parent directory.** This repo has upstream's own `.envrc`,
  which is blocked, so direnv doesn't load the credentials from `~/p` here and
  `git push` fails with "Invalid username or token". Run `direnv exec ~/p git
  -C ~/p/ghostty-smooth push origin <branch>`. A bare `cd ~/p &&` isn't enough
  in an agent's shell, because nothing runs direnv's hook there.
