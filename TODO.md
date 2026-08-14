# TODO

Living list of TUI/usability improvement ideas for ardango.nvim. Check items off as they land; add new ones as they come up.

## Test/Build output (`lua/ardango/ui.lua`)
- [x] Parse output into a quickfix list (jump straight to the failing file:line instead of reading a text popup) — opt-in via `opts.quickfix` on `ui.show_results`; popup stays the default so it doesn't compete with the user's own quickfix list (`:grep`, LSP diagnostics, etc.)
- [x] "Running..." notification before a test/build job starts
- [x] Optional Telescope integration (`opts.telescope`) — browse failures as a fuzzy-searchable list with a preview of the failing location, via Telescope's built-in `quickfix()` picker; falls back to plain quickfix if telescope.nvim isn't installed
- [x] Wire `opts.quickfix`/`opts.telescope` up to something a user can actually flip — `RunCurrTest`/`BuildCurrPackage` now take an optional opts table forwarded to `ui.show_results`; example `<leader>gq`/`<leader>gs` keymaps in the README and `dev/init.lua`
- [ ] Syntax highlight PASS/FAIL/error lines in the fallback popup
- [ ] Reuse one result buffer/window instead of a new scratch buffer per run
- [ ] More popup keymaps (`q` to close, `<CR>` to jump to quickfix entry)
- [ ] Configurable popup (border, size, position) via `setup()`

## Struct tag editing (`lua/ardango/struct_tag.lua`)
- [ ] `vim.ui.select` for common tag names (json, yaml, db, validate, xml)
- [ ] Toggle common tag options (omitempty, "-") as a checklist
- [ ] Visual-mode support for tag add/remove across multiple fields
- [ ] Live preview of resulting tag string before committing

## Config & discoverability
- [ ] `setup(opts)` entrypoint for plugin-wide config
- [ ] `:checkhealth ardango` (treesitter go parser, nui.nvim, `go` binary in PATH)
- [ ] Vim help docs (`doc/ardango.txt`)
- [ ] Replace remaining `print()` calls with `vim.notify`

## Editor integration
- [ ] `SignatureInStatusLine` → optional floating hover window
- [ ] Command to run all tests in file/package, not just cursor under
