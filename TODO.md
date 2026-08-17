# TODO

Living list of TUI/usability improvement ideas for ardango.nvim. Check items off as they land; add new ones as they come up.

## Test/Build output (`lua/ardango/ui.lua`)
- [x] Parse output into a quickfix list (jump straight to the failing file:line instead of reading a text popup) — opt-in via `opts.quickfix` on `ui.show_results`; popup stays the default so it doesn't compete with the user's own quickfix list (`:grep`, LSP diagnostics, etc.)
- [x] "Running..." notification before a test/build job starts
- [x] Optional Telescope integration (`opts.telescope`) — browse failures as a fuzzy-searchable list with a preview of the failing location, via Telescope's built-in `quickfix()` picker; falls back to plain quickfix if telescope.nvim isn't installed
- [x] Wire `opts.quickfix`/`opts.telescope` up to something a user can actually flip — `RunCurrTest`/`BuildCurrPackage` now take an optional opts table forwarded to `ui.show_results`; example `<leader>gq`/`<leader>gs` keymaps in the README and `dev/init.lua`
- [x] Syntax highlight PASS/FAIL/error lines in the fallback popup — `DiagnosticOk`/`DiagnosticError` (line-level, via `nvim_buf_add_highlight`)
- [x] Optional `opts.verbose` — list each passing test as a single green line (`go test -v`, filtered to `--- PASS`/`--- FAIL` lines, `=== RUN` noise stripped) instead of only showing failures
- [x] Reuse one result buffer/window instead of a new scratch buffer per run — persists across calls; a still-open popup from a previous run is closed (not stacked) before the next one mounts
- [x] More popup keymaps — `q` to close (alongside `<esc>`), `<CR>` to jump to the file:line under the cursor (same idea as quickfix's `<CR>`)
- [x] Configurable popup (border, size, position) via `setup()` — `require("ardango").setup({ popup = { border, size, relative, position } })`, passed straight through to `nui.Popup`

## Struct tag editing (`lua/ardango/struct_tag.lua`)
- [x] Picker for common tag names (json, yaml, db, validate, xml) — fuzzy-searchable Telescope picker; typing something with no match uses what you typed. The tag-value prompt afterward uses the same Telescope-prompt mechanism (not a plain `vim.ui.input` cmdline drop) so the flow feels consistent end to end; both fall back to plain `vim.ui.input` if telescope.nvim isn't installed. Used by all four Add/Remove tag commands. Fixed a latent bug as part of this: cancelling the old free-text prompt on the Remove commands passed `nil` straight through and silently removed the *entire* tag; the picker now just no-ops on cancel.
- [x] Toggle common tag options (omitempty, "-", required) as a checklist — merged into the same prompt as the tag value (see below), not a separate step. The option list is configurable/expandable via `setup({ tag_options = {...} })` (`lua/ardango/config.lua`), replacing the default list entirely rather than merging with it.
- [x] Visual-mode support for tag add/remove across multiple fields — `AddTagToVisualFields`/`RemoveTagFromVisualFields` scope the same prompts to whatever field lines were last visually selected (via the `'</'>` marks), instead of every field in the struct or just the one under the cursor. Needs a Visual-mode keymap that exits Visual mode (`<Esc>`) before invoking the Lua function, so the marks are set in time — mapping straight to the function runs it while still in Visual mode.
- [x] ~~Live preview of resulting tag string before committing~~ — ruled out: the value/options prompt is already cheap to undo and retry, so a live preview isn't worth the added complexity (implemented once, then rolled back).

## Config & discoverability
- [x] `setup(opts)` entrypoint for plugin-wide config — `lua/ardango/config.lua`; currently only covers the popup, easy to extend as more config shows up
- [x] `:checkhealth ardango` (`lua/ardango/health.lua`) — checks the `go` binary and the Go treesitter parser (both errors, plugin can't function without them), `nui.nvim` (error, the default results popup needs it), and `telescope.nvim` (warning only, it's an optional dependency).
- [x] Vim help docs (`doc/ardango.txt`) — `:help ardango`, covering setup, every command, and configuration; `doc/tags` is generated (`:helptags doc`, or automatically by most plugin managers on install), so it's gitignored rather than committed.
- [ ] Replace remaining `print()` calls with `vim.notify`

## Editor integration
- [ ] `SignatureInStatusLine` → optional floating hover window
- [x] Command to run all tests in file/package, not just cursor under — `RunFileTests`/`RunPackageTests`
