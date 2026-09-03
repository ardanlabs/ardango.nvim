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
`telescope.nvim` into `dev/.deps/` (gitignored), installs the Go
treesitter parser via `TSInstallSync`, and pre-builds the Delve proxy
helper the debug commands drive into `stdpath("cache")/ardango/` (where
the plugin also builds it lazily on first `:ArdangoDebug` use). Safe to
re-run.

The devShell (`shell.nix`) provides `go` and `delve` (`dlv`) — the same
Delve version the helper is built against — alongside Neovim, so nothing
Go-related needs to be on the host `PATH`. Outside the devShell the
helper build is skipped with a warning if `go` isn't found, and the
`:ArdangoDebug` commands additionally need `dlv` on `PATH` at runtime.

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
- `<leader>gr` — `RunLastTest`
- `<leader>taf` / `<leader>tas` — add tag to field / struct
- `<leader>trf` / `<leader>trs` — remove tag from field / struct
- `<leader>d…` — the `ardango.debug.*` commands: `dt`/`dB`/`dP` start on
  test/benchmark/package, `db` toggle breakpoint, `dm` breakpoint list,
  `dc`/`dn`/`ds`/`do` continue/step-over/step-into/step-out, `de`
  eval (`x`-mode: eval the selection), `dl`/`dS` locals/stack, `d[`/`d]`
  frame up/down, `dg` goroutines, `dq` stop

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
- `cmd/greet/main.go` — a runnable `package main` (calls `testdata.Greet`
  in a loop) for `:ArdangoDebug package` / `<leader>dP`, which runs `dlv
  debug` and needs a `main` package — the rest of the fixture is library
  code.
- `cmd/cgohello/main.go` — a `main` package that uses cgo (needs a C
  compiler; always present inside `nix develop`). Only there to reproduce
  the NixOS `debug.env` scenario — see the last two `:ArdangoDebug
  package` rows in the debug matrix. `go build ./...` still needs cc
  because of it.
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
| `RunLastTest` | after `RunCurrTest({ dry_run = true })` on a test, cursor then moved elsewhere | actually runs (not another dry-run preview) the same command from wherever the cursor ended up; with nothing run yet, notify: `ardango: no command run yet` |
| `:Ardango ` + `<Tab>` | any buffer | completes to the list of command names; after a command name + space, `<Tab>` instead completes to the flag list (`quickfix`/`telescope`/`verbose`/`dry_run`/`float`) |
| `:Ardango RunCurrTest dry_run` | inside a test | same as `RunCurrTest({ dry_run = true })` |
| `:Ardango SignatureInStatusLine 500 float` | cursor on an identifier (needs the `vim.lsp.buf_request_sync` stub from above without a real LSP client) | same as `SignatureInStatusLine(500, { float = true })` |
| `:Ardango NotACommand` | any buffer | notify: `ardango: unknown command 'NotACommand'` |
| `BuildCurrPackage` | `broken.go` present (see above) | popup with the `undefined: ...` error |
| `BuildCurrPackage` | only `sample.go`/`sample_test.go` present | notify: `go build: success` |
| `ui.show_results(data, { quickfix = true, ... })` (called directly, e.g. via `:lua`) | same failing output as above | quickfix list populated and opened (`opts.open_qf = false` populates without opening); doesn't clobber an existing quickfix list in place — pushes a new one onto the stack (`:colder` recovers the previous one) |
| `ui.show_results(data, { telescope = true, ... })` (called directly) | same failing output as above | Telescope opens a "Results" picker with the failure(s) as entries and a preview of the source at that location; falls back to the plain quickfix list (with a notification) if telescope.nvim isn't on `rtp` |
| `AddTagsToStruct` | cursor **inside the struct body** (a field line, not the `type X struct {` line — the `struct_type` node starts at `struct`, not `type`) | prompts for tag name/value, adds `name:"value"` to every field's tag, and re-aligns the struct's columns via `gofmt` afterward (if it's on `PATH`) |
| `AddTagToField` | cursor on one field line | same, but only that field |
| any struct-tag command, deliberately misaligned struct (e.g. add a field with a much longer name than the rest, without running gofmt first) | one field edited | the *whole* struct gets re-aligned, not just the edited field's line - confirms `gofmt` is running on the full buffer, not a line-local patch |
| `RemoveTagsFromStruct` / `RemoveTagFromField` | struct/field with tags already present | removes the named tag element (or the whole tag, if no name given) |
| `SignatureInStatusLine(wait_ms)` | cursor on an identifier, LSP client attached (`dev/init.lua` doesn't wire one up - either attach `gopls` yourself or stub `vim.lsp.buf_request_sync`, see below) | one-line `vim.notify` with the hover's second line |
| `SignatureInStatusLine(wait_ms, { float = true })` | same | floating window with the full hover content, via `vim.lsp.util.open_floating_preview` (same as `vim.lsp.buf.hover()`) |

### Debugging (Delve) — `lua/ardango/debug.lua`, `cmd/ardango-dbg/`

Needs `dlv` on `PATH` and the helper built (`dev/setup.sh` pre-builds it
into `stdpath("cache")/ardango/ardango-dbg`; otherwise the first
`:ArdangoDebug` call builds it — `go build ./cmd/ardango-dbg` — which on a
cold machine pulls the Delve module and takes a bit). Run after any
change to `debug.lua`, `cmd/ardango-dbg/main.go`, or `ui.lua`'s
`show_popup`.

Commands are written as `:ArdangoDebug <sub>` below; the equivalent Lua
is `ardango.debug.<name>` (e.g. `over` → `step_over`, `break` →
`breakpoint`).

| Command | Fixture / cursor position | Expected result |
|---|---|---|
| `:ArdangoDebug break` then `:ArdangoDebug test` | breakpoint on `sample_test.go:8`, cursor inside `TestGreetPass` | notify `building debug helper...` (first run only), then `debug session ready`; `●` sign on line 8 |
| `:ArdangoDebug break` on `cmd/greet/main.go:20`, then `:ArdangoDebug package` | cursor in `cmd/greet/main.go` | `dlv debug .`; notify `debug session ready`; `:ArdangoDebug continue` stops at `main.main` line 20 (once per loop iteration), a final `continue` → `program exited (status 0)` + auto-stop |
| `:ArdangoDebug continue` | after the above | stops at `sample_test.go:8`, cursor jumps there, `▶` sign; notify `stopped at sample_test.go:8 (breakpoint, goroutine N)` |
| `:ArdangoDebug over` / `into` / `out` | halted in `TestGreetPass` | each moves the stop location (`into` steps into `Greet` in `sample.go`); `continue` again runs to exit → `program exited (status ...)` + session auto-stops |
| `:ArdangoDebug eval` | halted, cursor on `p` in `sample.go` `Greet` | float: `ardango/dev/testdata.Person = testdata.Person {Name: "Ardan", ...}` |
| `:ArdangoDebug eval p.Name` | halted | float: `string = "Ardan"` |
| `:ArdangoDebug locals` | halted in `Greet` | popup: `-- args --` / `  p = ...` (no synthetic `~r0`) |
| `:ArdangoDebug stack` | halted in `Greet` | popup: `sample.go:13:  #0  ...Greet` / `sample_test.go:8:  #1  ...TestGreetPass` / ...; `#0` marked `<- current`; `<CR>` on a frame line jumps to it |
| `:ArdangoDebug up` | halted in `Greet` | cursor jumps to `sample_test.go:8`, sign becomes `▷`; notify `frame #1: ...TestGreetPass (sample_test.go:8)`; a following `:ArdangoDebug locals` shows `TestGreetPass`'s `t` |
| `:ArdangoDebug down` (back to 0) / `:ArdangoDebug frame 0` | after the above | cursor back on `sample.go:13`, sign back to `▶`; `down` again → notify `already at the innermost frame` |
| `:ArdangoDebug frame 99` | halted | notify `no frame #99 (stack is N deep)` |
| any `:ArdangoDebug continue`/`over`/`into`/`out` | after navigating frames | selected frame resets to 0 (sign back to `▶` at the new stop) |
| `:ArdangoDebug goroutines` | halted (break at `sample_test.go:60` in a `TestManyMixed` subtest) | popup lists several goroutines (`file:line:  goroutine N  [status]  func`); the subtest's is `[running]` and marked `<- current`, the parent `TestManyMixed` one is `[waiting]` on `testing.(*T).Run` |
| `:ArdangoDebug goroutine <id>` (a `[waiting]` one from the list) | after the above | notify `switched to goroutine <id> (...)`; sign moves to that goroutine's location; a following `:ArdangoDebug stack` shows that goroutine's stack |
| `:ArdangoDebug goroutine 999999` | halted | notify `switch to goroutine 999999: unknown goroutine 999999` |
| `:ArdangoDebug breaks` | 2-3 breakpoints set across `sample.go`/`sample_test.go` | popup lists `file:line   <source line>`; `<CR>` jumps, `dd` deletes that one and re-renders, `D` clears all |
| `:ArdangoDebug breaks telescope` | same, telescope.nvim on `rtp` | Telescope picker with a source preview; `<C-d>` deletes; without telescope on `rtp` it falls back to the popup |
| toggle a breakpoint, then `:e` / wipe+reopen the file | — | the `●` sign comes back (BufReadPost re-places it) |
| `:ArdangoDebug break` on a blank / comment line, halted session | e.g. `cmd/greet/main.go:14` | notify `breakpoint set …:15 (snapped from line 14)`; `●` lands on the next line with code, not the blank one |
| `:ArdangoDebug break` where nothing is breakable in range, halted session | e.g. `cmd/greet/main.go:7` (`package main`) | notify `can't break at …:7 — no breakable line found (gave up after 5 tries)` at ERROR level; **no `●` sign left** |
| `:ArdangoDebug break c.name == "case 05"` inside a `TestManyMixed` subtest, then start + continue | — | stops only at the iteration where `c.name == "case 05"` (`:ArdangoDebug eval c.name` confirms); the condition shows as `[if …]` in `:ArdangoDebug breaks` |
| `<CR>` on a frame line in the `:ArdangoDebug stack` popup | halted | selects that frame (notify `frame #n/N`, sign + cursor move) — not just a cursor jump |
| `<CR>` on a goroutine line in the `:ArdangoDebug goroutines` popup; `a` in that popup | halted | `<CR>` switches to it; `a` (or `:ArdangoDebug goroutines all`) expands the `[+N runtime]` collapsed rows |
| `ardango.debug.eval_visual` (via an `x`-mode `<Esc>:lua …<CR>` map) over `p.Name` | halted in `Greet` | float shows `string = "Ardan"` |
| `:ArdangoDebug stop` | mid-session | `debug session stopped`; signs cleared; `pgrep dlv` shows nothing left |
| any `:ArdangoDebug` control | no session | notify `no debug session — start with :ArdangoDebug test` |
| `:ArdangoDebug test` | cursor not inside a `Test*` fn | notify `no Test function under the cursor` |
| `:ArdangoDebug stop` immediately after `:ArdangoDebug test` | (before the helper connects) | no error, no orphaned `dlv` (`pgrep dlv`) |
| `:qa` mid-session | halted or running | Neovim exits within ~½s; `pgrep dlv` / the compiled test binary show nothing left |

Headless probing (no interactive TTY needed) works well here — spawn
`nvim --clean -u ../init.lua --headless` from `dev/testdata/`, drive with
`:ArdangoDebug …` via `-c`, and `vim.wait(ms, cond)` for the async
notifications. Always end the script with `vim.cmd('qa!')` on every path;
an error before it leaves headless Neovim hanging.

#### `debug.env` — the NixOS cgo / `_FORTIFY_SOURCE` case

**Run this one from inside `nix develop`** (the repo's dev shell enables
`fortify`/`fortify3` hardening — a plain shell usually doesn't, so it
won't reproduce). Delve compiles the target with optimizations off; the
Nix `cc` wrapper forces `-D_FORTIFY_SOURCE=2` + `-Werror`, so any cgo in
the build (here `cmd/cgohello`'s `import "C"`, but in real projects a
transitive dep or the `net`/`os/user` cgo resolvers) fails to compile:

```
dlv: # runtime/cgo
… features.h:435: error: #warning _FORTIFY_SOURCE requires compiling with optimization (-O) [-Werror=cpp]
cc1: all warnings being treated as errors
```

→ `dlv exited before the session was ready`. The `debug.env` option
(`config.lua`, threaded to the `dlv` + helper-build `jobstart`s in
`debug.lua`) is the fix.

| Setup (via `setup({ debug = { env = … } })`) | Command | Expected result |
|---|---|---|
| `env = {}` (default) | `:ArdangoDebug package` in `cmd/cgohello/main.go` | notify `dlv: … _FORTIFY_SOURCE requires compiling with optimization …`, then `dlv exited before the session was ready` / `debug session stopped` |
| `env = { CGO_CFLAGS = "-O2" }` | breakpoint on `cmd/cgohello/main.go:25`, then `:ArdangoDebug package` | `debug session ready`; `:ArdangoDebug continue` stops at `main.main` line 25, a final `continue` → `program exited (status 0)` + auto-stop |
| `env = { CGO_ENABLED = "0" }` | `:ArdangoDebug package` in `cmd/cgohello/main.go` | still fails — `go build` errors `cannot use import "C"`; `CGO_ENABLED=0` only helps a target that _doesn't_ genuinely need cgo (e.g. `cmd/greet`, where it skips `runtime/cgo` entirely) |

`dev/init.lua` calls `require("ardango")` with no `setup()` args, so drive
this headless with a `:luafile` scratch script that calls `setup{}` itself
before `:ArdangoDebug package` — same pattern as the `SignatureInStatusLine`
stub below.

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
