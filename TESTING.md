# Testing

There is no automated test suite (no busted/plenary specs, no CI). This
plugin is verified by manually driving a real Neovim session against the
fixtures in `dev/`. This document is the current knowledge of how to do
that reliably, including the environment gotchas that aren't obvious.

## One-time setup

```sh
./dev/setup.sh
```

Clones `nui.nvim` and `nvim-treesitter` into `dev/.deps/` (gitignored) and
installs the Go treesitter parser via `TSInstallSync`. Safe to re-run.

`dev/setup.sh` pins `nvim-treesitter` to its **`master`** branch, not
`main`. `main` is a rewrite that requires a much newer Neovim than may be
installed; `master` has the `:TSInstall`/`configs.setup()` API the fixture
config relies on.

## Launching

Always launch from inside `dev/testdata/` — that's where the fixture
`go.mod` lives, and `RunCurrTest`/`BuildCurrPackage` run `go` relative to
Neovim's cwd, not the buffer's directory. Always pass `--clean`:

```sh
cd dev/testdata
nvim --clean -u ../init.lua sample_test.go
```

**Why `--clean` is required:** Neovim sources `plugin/` and
`after/plugin/` from the *default* runtimepath on startup regardless of
`-u` — `-u` only chooses which vimrc/init.lua to execute, it does not
suppress rtp-based auto-loading of a personal config (e.g. one managed by
home-manager/Nix outside `$XDG_CONFIG_HOME`). Without `--clean`, a
developer's real Neovim config gets loaded on top of `dev/init.lua`,
producing unrelated plugin errors and possibly conflicting keymaps/health
checks that have nothing to do with ardango.nvim.

Treesitter highlighting is deliberately disabled in `dev/init.lua`
(`highlight = { enable = false }`) — the `nvim-treesitter` `master` branch
ships `highlights.scm` queries that can use predicates newer than an older
bundled Neovim's `vim.treesitter` supports (observed: `No handler for
not-has-parent?` on Neovim 0.9.1). That's a highlighting-only failure,
unrelated to anything ardango.nvim does (it only uses raw
`vim.treesitter` queries it defines itself, never nvim-treesitter's
highlighter), so it's turned off to keep the fixture session quiet rather
than "fixed".

`dev/init.lua` sets `<leader>` to `<space>` and wires up the same keymaps
the README recommends:

- `<leader>gt` — `RunCurrTest`
- `<leader>gp` — `BuildCurrPackage`
- `<leader>taf` / `<leader>tas` — add tag to field / struct
- `<leader>trf` / `<leader>trs` — remove tag from field / struct

## Fixtures (`dev/testdata/`)

- `sample.go` — a `Person` struct (`Name`, `Age`, `Email`) for the tag
  commands. **Untracked by design for manual testing but committed as a
  fixture** — if you run tag commands against it, restore it afterward
  (`git diff dev/testdata/sample.go` / reset it back to the plain struct
  with no tags) so the fixture stays clean for the next run.
- `sample_test.go` — `TestGreetPass` (put the cursor inside it, run
  `<leader>gt`, expect a plain success notification, no popup/quickfix)
  and `TestGreetFail` (same, but expect the failure to open the quickfix
  list with a `file|line col N| message` entry that jumps to the failing
  `t.Fatalf` line on `<CR>`).
- `broken_example.go.txt` — inert by default so `go build ./...` stays
  green in the fixture module. To exercise `BuildCurrPackage`'s failure
  path:

  ```sh
  cp broken_example.go.txt broken.go
  nvim --clean -u ../init.lua broken.go   # <leader>gp
  rm broken.go
  ```

## Manual test matrix

Run these after any change to `lua/ardango/ui.lua`, `lua/ardango/init.lua`,
or `lua/ardango/struct_tag.lua`:

| Command | Fixture / cursor position | Expected result |
|---|---|---|
| `RunCurrTest` | inside `TestGreetPass` | notify: `go test: TestGreetPass: ok ...` |
| `RunCurrTest` | inside `TestGreetFail` | quickfix opens, one entry at the `t.Fatalf` line; `<CR>` jumps there |
| `BuildCurrPackage` | `broken.go` present (see above) | quickfix opens with an `undefined: ...` entry |
| `BuildCurrPackage` | only `sample.go`/`sample_test.go` present | notify: `go build: success` |
| `AddTagsToStruct` | cursor **inside the struct body** (a field line, not the `type X struct {` line — the `struct_type` node starts at `struct`, not `type`) | prompts for tag name/value, adds `name:"value"` to every field's tag |
| `AddTagToField` | cursor on one field line | same, but only that field |
| `RemoveTagsFromStruct` / `RemoveTagFromField` | struct/field with tags already present | removes the named tag element (or the whole tag, if no name given) |

## Verifying via tmux (for an agent/CI-less environment)

There's no headless test runner, so verification means driving an
interactive session and reading its state back:

```sh
tmux new-session -d -s ardango_verify -x 200 -y 50
tmux send-keys -t ardango_verify "cd dev/testdata && nvim --clean -u ../init.lua sample_test.go" Enter
tmux send-keys -t ardango_verify "/TestGreetPass(" Enter
tmux send-keys -t ardango_verify " gt"
tmux capture-pane -t ardango_verify -p   # inspect the notification/quickfix
```

Notes from doing this:

- The first `go test`/`go build` in a session is slow (cold compile) —
  give it a few seconds before capturing, or poll `:messages`.
- `:messages` is more reliable to read back than `capture-pane` alone,
  since floating windows (the popup fallback, quickfix) can visually
  overlap the buffer in a plain pane dump.
- Always `git checkout`/rewrite `dev/testdata/sample.go` and `rm
  dev/testdata/broken.go` after a manual run that mutates them, before
  finishing up — they're fixtures, not scratch files.
