# ardango.nvim

This plugin exposes utility functions to enhance coding Go in Neovim.

## Exposed functions:

- __RunCurrTest__: Runs the test under the cursor and shows the results in a popup window by default. Takes an optional opts table (`{ quickfix = true }` or `{ telescope = true }`) to show them in the quickfix list or a Telescope picker instead, or `{ verbose = true }` to also list passing tests as a single green line each (instead of only showing failures) — see `lua/ardango/ui.lua`'s `show_results` for the full set of opts. `{ dry_run = true }` doesn't run anything — it just notifies the exact `go test`/`go build` command that would've run (also works on `RunFileTests`/`RunPackageTests`/`RunCurrBenchmark`/`BuildCurrPackage`, see below).
- __RunFileTests__: Runs every test declared in the current buffer. Same opts as `RunCurrTest`.
- __RunPackageTests__: Runs every test in the current package (whole directory, not just the current file). Same opts as `RunCurrTest`.
- __RunCurrBenchmark__: Runs the benchmark under the cursor (`go test -bench '^Name$' -run '^$' -benchmem`) and shows the results (ns/op, allocation stats) in a popup by default. Same `opts` as `RunCurrTest`, except `opts.verbose` is a no-op — `go test` has no verbose flag for benchmarks.
- __BuildCurrPackage__: Build the package in the current dir. Takes the same optional opts table as `RunCurrTest`.
- __CopyLastCmd__: Copies the most recently computed `go test`/`go build` command (from any Run\*/BuildCurrPackage call above — a dry run or a real one, either counts) onto the system clipboard (the `"+"` register), so it can be pasted into a terminal and run manually.
- __RunLastTest__: Re-runs whatever Run\*/BuildCurrPackage invocation was most recently computed (test, benchmark, or build — whatever it was), without needing to reposition the cursor. Takes an optional opts table merged over (and overriding) the opts used last time. Always actually runs, even if the last invocation was itself a `{ dry_run = true }` preview — pass `{ dry_run = true }` again if you want to re-preview instead.
- __OrgBufImports__: Update imports of the current buffer.
- __SignatureInStatusLine__: Shows the element under the cursor's signature info on hover. By default a one-line summary is shown via `vim.notify` (close to the statusline); pass `{ float = true }` to instead open a floating window with the full hover content, via the same `vim.lsp.util.open_floating_preview` `vim.lsp.buf.hover()` itself uses.
- __AddTagToField__: Adds go tag element to the struct field under the cursor, can handle exisiting elements. Prompts for the tag name via a fuzzy-searchable Telescope picker of common names (json, yaml, db, validate, xml) — typing something that doesn't match any of them uses what you typed instead. Then a single combined prompt handles both the tag value and its common options: `<Tab>`-toggle any of `omitempty`/`-`/`required` (they stay selected as you type, even though typing filters the visible list), then type the value (empty defaults to the snake cased field name) and confirm with `<CR>`. Picking `-` wins over everything else, since a bare `-` means "skip this field" per Go tag convention. Falls back to plain `vim.ui.input` prompts (`value,option1,option2`) if telescope.nvim isn't installed. All struct-tag commands re-run the buffer through `gofmt` afterward (if it's on `PATH`) so the struct's columns stay aligned — splicing raw text in doesn't otherwise re-align them.
- __AddTagsToStruct__: Adds go tag element to all fields inside the struct under the cursor, can handle exisiting elements. Same prompts as `AddTagToField`. If no value is passed the snake cased field name will be the element value.
- __RemoveTagFromField__: Removes a tag element from the field under the cursor. Same prompts as `AddTagToField`.
- __RemoveTagsFromStruct__: Removes a tag element from all the fields inside the struct under the cursor. Same prompts as `AddTagToField`.
- __AddTagToVisualFields__: Adds a tag element to every field declared inside the last visual selection (within the struct under the cursor) — same prompts as `AddTagToField`, but scoped to the selected lines instead of every field or just one. Meant to be called from a Visual-mode keymap (see below) so the `'</'>` marks are set before it runs.
- __RemoveTagFromVisualFields__: Removes a tag element from every field declared inside the last visual selection. Same prompt as `RemoveTagFromField`.

## Ex command

Every function above is also reachable from the cmdline via `:Ardango
<Command> [flag...]`, with tab completion for both the command name and
any boolean flags (`quickfix`, `telescope`, `verbose`, `dry_run`, `float`)
it accepts — handy if you don't want to set up keymaps for everything.
`OrgBufImports`/`SignatureInStatusLine` take a milliseconds number
instead of/alongside flags (defaults to 1000 if omitted). Examples:

```vim
:Ardango RunCurrTest
:Ardango RunCurrTest quickfix verbose
:Ardango RunCurrTest dry_run
:Ardango RunLastTest
:Ardango AddTagToField
:Ardango SignatureInStatusLine 500 float
```

## Debugging (Delve)

Drive a [Delve](https://github.com/go-delve/delve) session on the current
buffer's package without leaving Neovim — one session at a time, with a
breakpoint sign in the gutter and the stop location marked and jumped to.

The whole debugger is under **`:ArdangoDebug <sub> [args]`** (tab-completed)
and, for keymaps, the **`ardango.debug.*`** Lua table.

- __`test`__ / __`bench`__ (`debug.curr_test` / `debug.curr_benchmark`): start a session on the `Test*`/`Benchmark*` function under the cursor (`dlv test`) and stop on its first line. __`package`__ (`debug.curr_package`): `dlv debug` the current package (no auto-stop — set a breakpoint first).
- __`continue`__ / __`over`__ / __`into`__ / __`out`__ (`debug.continue` / `debug.step_over` / `debug.step_into` / `debug.step_out`): run / step over / step into / step out (only while halted).
- __`break`__ (`debug.breakpoint`): toggle a breakpoint on the current line. Works with no session running; breakpoints persist across sessions and their signs come back when a file is reopened. `:ArdangoDebug break <expr>` sets a **conditional** breakpoint. With a halted session, a line with no statement **snaps forward** to the next one that has code (giving up after 5 tries), and a line with nothing breakable in range is rejected with an error instead of leaving a dead sign.
- __`breaks`__ (`debug.breakpoints`): list all breakpoints in a popup — `<CR>` jump, `dd` delete, `D` clear all. `:ArdangoDebug breaks telescope` uses a Telescope picker with a source preview. __`clearbreaks`__ (`debug.clear_breakpoints`) removes them all.
- __`eval`__ (`debug.eval`): show the value of an expression — the identifier under the cursor by default (`p`, `p.Name`, `xs[i]`), `:ArdangoDebug eval <expr>`, or `debug.eval_visual` for the Visual selection — in a floating window, like an LSP hover.
- __`locals`__ (`debug.locals`): the selected frame's args and locals, in a popup.
- __`stack`__ (`debug.stack`): the goroutine's call stack, in a popup; `<CR>` on a frame **selects** it (cursor + sign move; locals/eval follow).
- __`up`__ / __`down`__ / __`frame <n>`__ (`debug.frame_up` / `debug.frame_down` / `debug.frame`): walk the call stack — the cursor and sign move to that frame (`▷` for a caller, `▶` for the innermost), and `locals`/`eval` then evaluate there. Resets on the next step/continue.
- __`goroutines`__ (`debug.goroutines`): list goroutines in a popup (runtime-only ones collapsed behind `[+N runtime]`, `a` to expand); `<CR>` switches to one. __`goroutine <id>`__ (`debug.goroutine`) switches by id — locals/eval/stack then follow it.
- __`stop`__ (`debug.stop`): end the session (also automatic on program exit / `:q`).

`require('ardango').debug_status()` returns a one-line status
(`[debug: testdata.Greet sample.go:13 g6 #2/5]`, or `""` with no session)
for a statusline / winbar / lualine component — it refreshes itself on
every state change:

```lua
vim.wo.winbar = "%{v:lua.require('ardango').debug_status()}"
```

**`:ArdangoDebug`** with no argument (or `ardango.debug.menu`) opens a
**fuzzy picker** of every subcommand: a Telescope picker if telescope.nvim
is installed, otherwise `vim.ui.select` (which fuzzy-finds through
telescope-ui-select / dressing / snacks / fzf-lua if you have one set up).

`dlv` must be on `PATH`; a small Go helper is built automatically on first
use (needs the `go` toolchain), so there's no manual build step.

Extra flags and environment for the `dlv`/`go build` child processes go
through `setup()`:

```lua
require("ardango").setup({
  debug = {
    -- Extra flags for `dlv test` / `dlv debug` (before the `--` separator).
    dlv_args = { "--build-flags=-tags=integration" },
    -- Env merged over Neovim's for `dlv` and the helper build. On NixOS,
    -- cgo hardening breaks Delve's unoptimised build of the target
    -- ("_FORTIFY_SOURCE requires compiling with optimization"); set
    -- CGO_ENABLED = "0" (if the target needs no cgo) or CGO_CFLAGS = "-O2".
    env = { CGO_ENABLED = "0" },
  },
})
```

```lua
local ardango = require "ardango"
local opts = { noremap = true, silent = true }
vim.keymap.set('n', '<leader>dd', ardango.debug.menu, opts)
vim.keymap.set('n', '<leader>dt', ardango.debug.curr_test, opts)
vim.keymap.set('n', '<leader>dB', ardango.debug.curr_benchmark, opts)
vim.keymap.set('n', '<leader>dP', ardango.debug.curr_package, opts)
vim.keymap.set('n', '<leader>db', ardango.debug.breakpoint, opts)
vim.keymap.set('n', '<leader>dc', ardango.debug.continue, opts)
vim.keymap.set('n', '<leader>dn', ardango.debug.step_over, opts)
vim.keymap.set('n', '<leader>ds', ardango.debug.step_into, opts)
vim.keymap.set('n', '<leader>do', ardango.debug.step_out, opts)
vim.keymap.set('n', '<leader>de', ardango.debug.eval, opts)
vim.keymap.set('x', '<leader>de', "<Esc>:lua require('ardango').debug.eval_visual()<CR>", opts)
vim.keymap.set('n', '<leader>dl', ardango.debug.locals, opts)
vim.keymap.set('n', '<leader>dS', ardango.debug.stack, opts)
vim.keymap.set('n', '<leader>d[', ardango.debug.frame_up, opts)
vim.keymap.set('n', '<leader>d]', ardango.debug.frame_down, opts)
vim.keymap.set('n', '<leader>dg', ardango.debug.goroutines, opts)
vim.keymap.set('n', '<leader>dm', ardango.debug.breakpoints, opts)
vim.keymap.set('n', '<leader>dq', ardango.debug.stop, opts)

-- Run control gets hit constantly — single keys (matching nvim-dap's
-- defaults) are easier on the hands:
vim.keymap.set('n', '<F5>',    ardango.debug.continue, opts)
vim.keymap.set('n', '<F9>',    ardango.debug.breakpoint, opts)
vim.keymap.set('n', '<F10>',   ardango.debug.step_over, opts)
vim.keymap.set('n', '<F11>',   ardango.debug.step_into, opts)
vim.keymap.set('n', '<S-F11>', ardango.debug.step_out, opts)
```

## Dependencies

- [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter)
- [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig)
- [nui.nvim](https://github.com/MunifTanjim/nui.nvim)
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) — optional: used for the tag name/value prompts (`AddTagToField` & co.), and for browsing test/build failures when you pass `{ telescope = true }`. Falls back to plain `vim.ui.input`/the quickfix list if it isn't installed.
- `gofmt` — optional, ships with the Go toolchain (so present anywhere `go` is): used to re-align struct columns after a tag edit. Skipped silently if it isn't on `PATH`.
- [`dlv`](https://github.com/go-delve/delve) (Delve) — optional: required by the `:ArdangoDebug` commands. The `go` toolchain is also needed the first time (to build the bundled debug helper).

Run `:checkhealth ardango` to verify the `go` binary, the Go treesitter
parser, and these dependencies are all in place. `:help ardango` covers
every command and config option in more detail than this README.

## Install

With the dependencies installed add to your favorite package manager:

```lua
use 'ardanlabs/ardango.nvim'
```

```
Plug 'ardanlabs/ardango.nvim'
```

## How to use

### Configuring the results popup:

```lua
require("ardango").setup({
  popup = {
    border = "single",    -- default: "rounded"
    size = "80%",         -- default: "50%"
    relative = "editor",  -- default: "cursor"
    position = "50%",     -- default: 0
  },
  -- Options offered (via <Tab>-toggle) in AddTagToField/AddTagsToStruct's
  -- value+options prompt. Replaces the default list entirely.
  tag_options = { "omitempty", "-", "required", "unique", "index" },
})
```

`setup()` is optional — everything works with its defaults if you skip it.
Popup fields are passed straight through to `nui.Popup` (`:h nui.popup`),
so any shape it accepts for `size`/`position` works here too.

### Setting as an autocommand:

```lua
local ardango = require "ardango"

-- Update imports on save.
vim.api.nvim_create_autocmd("BufWritePre", {
  group = "my_augroup",
  pattern = "*.go",
  callback = function() ardango.OrgBufImports(1000) end,
})
```

### Setting as a keymap:

```lua
local ardango = require "ardango"

local opts = { noremap = true, silent = true }
-- Set the keymap to test the package under the cursor.
vim.keymap.set('n', '<leader>gt', ardango.RunCurrTest, opts)
-- Same, but browse failures via the quickfix list instead of a popup.
vim.keymap.set('n', '<leader>gq', function() ardango.RunCurrTest({ quickfix = true }) end, opts)
-- Same, but browse failures via Telescope instead of a popup (needs
-- telescope.nvim installed).
vim.keymap.set('n', '<leader>gs', function() ardango.RunCurrTest({ telescope = true }) end, opts)
-- Set the keymap to run every test in the current file.
vim.keymap.set('n', '<leader>gf', ardango.RunFileTests, opts)
-- Set the keymap to run every test in the current package.
vim.keymap.set('n', '<leader>ga', ardango.RunPackageTests, opts)
-- Set the keymap to run the benchmark under the cursor.
vim.keymap.set('n', '<leader>gb', ardango.RunCurrBenchmark, opts)
-- Set the keymap to build the package under the cursor.
vim.keymap.set('n', '<leader>gp', ardango.BuildCurrPackage, opts)
-- Preview the test command under the cursor without running it.
vim.keymap.set('n', '<leader>gd', function() ardango.RunCurrTest({ dry_run = true }) end, opts)
-- Copy the last computed test/build command to the clipboard.
vim.keymap.set('n', '<leader>gc', ardango.CopyLastCmd, opts)
-- Re-run the last test/build invocation without moving the cursor back.
vim.keymap.set('n', '<leader>gr', ardango.RunLastTest, opts)
-- Adds tag element to the field under the cursor field.
vim.keymap.set('n', '<leader>taf', ardango.AddTagToField, { buffer = 0 })
-- Adds tag element to all fields of the struct under the cursor field.
vim.keymap.set('n', '<leader>tas', ardango.AddTagsToStruct, { buffer = 0 })
-- Removes tag element from the field under the cursor.
vim.keymap.set('n', '<leader>trf', ardango.RemoveTagFromField, { buffer = 0 })
-- Removes tag element from the all fields of the struct under the cursor.
vim.keymap.set('n', '<leader>trs', ardango.RemoveTagsFromStruct, { buffer = 0 })
-- Adds/removes a tag element to/from every field in a visual selection.
-- <Esc> first so leaving Visual mode sets the '</'> marks before the
-- function runs - mapping straight to the Lua function would call it
-- while still in Visual mode, before the marks are up to date.
vim.keymap.set('x', '<leader>tavf', "<Esc>:lua require('ardango').AddTagToVisualFields()<CR>", { buffer = 0 })
vim.keymap.set('x', '<leader>trvf', "<Esc>:lua require('ardango').RemoveTagFromVisualFields()<CR>", { buffer = 0 })
-- Shows the signature of the element under the cursor as a one-line
-- notification, or in a floating window instead.
vim.keymap.set('n', '<leader>gh', function() ardango.SignatureInStatusLine(1000) end, opts)
vim.keymap.set('n', '<leader>gH', function() ardango.SignatureInStatusLine(1000, { float = true }) end, opts)
```
