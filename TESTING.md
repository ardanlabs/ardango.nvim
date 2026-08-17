# Testing

There is no automated test suite (no busted/plenary specs, no CI). This
plugin is verified by manually driving a real Neovim session against the
fixtures in `dev/`. This document is the current knowledge of how to do
that reliably, including the environment gotchas that aren't obvious.

## One-time setup

Use this repo's own Nix devShell — `shell.nix`/`flake.nix` pin a Neovim
new enough for everything below (0.12.x as of writing, well above
Telescope's 0.11+ floor):

```sh
nix develop --command ./dev/setup.sh
```

(`nix-shell --run ./dev/setup.sh` works the same if you're not using
flakes.) Outside that shell, plain `./dev/setup.sh` also works as long as
whatever `nvim` is on your `PATH` is reasonably recent — it warns
(doesn't fail) if it detects something older than 0.11, and honors
`NVIM=/path/to/nvim` to target a specific binary instead of `PATH`.

This clones `nui.nvim`, `nvim-treesitter`, `plenary.nvim`, and
`telescope.nvim` into `dev/.deps/` (gitignored) and installs the Go
treesitter parser via `TSInstallSync`. Safe to re-run.

`dev/setup.sh` pins `nvim-treesitter` to its **`master`** branch, not
`main`. `main` is a rewrite that needs a much newer Neovim; `master` has
the `:TSInstall`/`configs.setup()` API the fixture config relies on and
works fine on anything reasonably recent. `telescope.nvim` and
`plenary.nvim` are cloned unpinned (latest).

## Launching

Always launch from inside `dev/testdata/` — that's where the fixture
`go.mod` lives, and `RunCurrTest`/`BuildCurrPackage` run `go` relative to
Neovim's cwd, not the buffer's directory. Always pass `--clean`. Same as
setup, prefer running it inside the devShell:

```sh
cd dev/testdata
nix develop --command nvim --clean -u ../init.lua sample_test.go
# or, outside the devShell, provided your own `nvim` is recent enough:
nvim --clean -u ../init.lua sample_test.go   # or your modern $NVIM
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
- `<leader>gb` — `RunCurrBenchmark`
- `<leader>gp` — `BuildCurrPackage`
- `<leader>gd` — `RunCurrTest({ dry_run = true })`
- `<leader>gc` — `CopyLastCmd`
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
  and `TestGreetFail` (same, but expect the failure text in a popup by
  default — the quickfix list is opt-in, see below). `BenchmarkGreet` is
  for `RunCurrBenchmark`/`<leader>gb`.
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
| `RunCurrTest` | inside `TestGreetFail` | popup with the raw failure text (default; quickfix is opt-in via `opts.quickfix`, not currently wired to a keymap) |
| `RunCurrBenchmark` | inside `BenchmarkGreet` | popup with the `ns/op`/`B/op`/`allocs/op` line (never collapses to a plain success notify - the benchmark result line itself isn't a recognized "success" line, so `ui.show_results` always shows it) |
| `RunCurrTest({ dry_run = true })` | inside any test | notify only: `go test: Name: dry run: go test ./. -run ^Name$` - nothing actually runs, no popup |
| `CopyLastCmd` | after any Run\*/BuildCurrPackage call (dry run or real) | notify with the copied command; `:echo getreg("+")` confirms it landed in the register; with nothing run yet, notify: `ardango: no command run yet` |
| `BuildCurrPackage` | `broken.go` present (see above) | popup with the `undefined: ...` error |
| `BuildCurrPackage` | only `sample.go`/`sample_test.go` present | notify: `go build: success` |
| `ui.show_results(data, { quickfix = true, ... })` (called directly, e.g. via `:lua`) | same failing output as above | quickfix list populated and opened (`opts.open_qf = false` populates without opening); doesn't clobber an existing quickfix list in place — pushes a new one onto the stack (`:colder` recovers the previous one) |
| `ui.show_results(data, { telescope = true, ... })` (called directly) | same failing output as above | Telescope opens a "Results" picker with the failure(s) as entries and a preview of the source at that location; falls back to the plain quickfix list (with a notification) if telescope.nvim isn't on `rtp` |
| `AddTagsToStruct` | cursor **inside the struct body** (a field line, not the `type X struct {` line — the `struct_type` node starts at `struct`, not `type`) | prompts for tag name/value, adds `name:"value"` to every field's tag |
| `AddTagToField` | cursor on one field line | same, but only that field |
| `RemoveTagsFromStruct` / `RemoveTagFromField` | struct/field with tags already present | removes the named tag element (or the whole tag, if no name given) |
| `SignatureInStatusLine(wait_ms)` | cursor on an identifier, LSP client attached (`dev/init.lua` doesn't wire one up - either attach `gopls` yourself or stub `vim.lsp.buf_request_sync`, see below) | one-line `vim.notify` with the hover's second line |
| `SignatureInStatusLine(wait_ms, { float = true })` | same | floating window with the full hover content, via `vim.lsp.util.open_floating_preview` (same as `vim.lsp.buf.hover()`) |

Testing `SignatureInStatusLine` without a real LSP client: `dev/init.lua`
doesn't attach `gopls` (no `nvim-lspconfig` in `dev/.deps/`), so the
easiest way to exercise it is stubbing `vim.lsp.buf_request_sync` to
return a canned hover response, e.g. via `:luafile` on a scratch script:

```lua
vim.lsp.buf_request_sync = function()
  return {
    [1] = { result = { contents = { kind = "markdown", value = "```go\nfunc Foo()\n```" } } },
  }
end
require('ardango').SignatureInStatusLine(1000)
```

Note the shape: `result.contents.value`, not `result.value` - easy to get
wrong, the function silently shows nothing (no error) if the stub doesn't
match, since indexing a plain Lua string with `.value` just yields `nil`
rather than erroring.

`{ float = true }` opens the hover through Neovim's own markdown
highlighter - if the `markdown`/`markdown_inline` treesitter parsers
aren't installed (only `go` is required by ardango.nvim itself), a fenced
code block in the hover content triggers a noisy but harmless
`Decoration provider "conceal_line"` error from Neovim's highlighter, not
from ardango.nvim. `dev/setup.sh` installs both parsers to avoid this in
the dev sandbox.

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
