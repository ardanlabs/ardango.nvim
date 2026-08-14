# ardango.nvim

This plugin exposes utility functions to enhance coding Go in Neovim.

## Exposed functions:

- __RunCurrTest__: Runs the test under the cursor and shows the results in a popup window by default. Takes an optional opts table (`{ quickfix = true }` or `{ telescope = true }`) to show them in the quickfix list or a Telescope picker instead, or `{ verbose = true }` to also list passing tests as a single green line each (instead of only showing failures) — see `lua/ardango/ui.lua`'s `show_results` for the full set of opts.
- __RunFileTests__: Runs every test declared in the current buffer. Same opts as `RunCurrTest`.
- __RunPackageTests__: Runs every test in the current package (whole directory, not just the current file). Same opts as `RunCurrTest`.
- __BuildCurrPackage__: Build the package in the current dir. Takes the same optional opts table as `RunCurrTest`.
- __OrgBufImports__: Update imports of the current buffer.
- __SignatureInStatusLine__: Shows the element under the cursor signature info on hover in the status line.
- __AddTagToField__: Adds go tag element to the struct field under the cursor, can handle exisiting elements. If no value is passed the snake cased field name will be the element value.
- __AddTagsToStruct__: Adds go tag element to all fields inside the struct under the cursor, can handle exisiting elements. If no value is passed the snake cased field name will be the element value.
- __RemoveTagFromField__: Removes a tag element from the field under the cursor.
- __RemoveTagsFromStruct__: Removes a tag element from all the fields inside the struct under the cursor.

## Dependencies

- [nvim-treesitter](https://github.com/nvim-treesitter/nvim-treesitter)
- [nvim-lspconfig](https://github.com/neovim/nvim-lspconfig)
- [nui.nvim](https://github.com/MunifTanjim/nui.nvim)
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) — optional, only needed if you pass `{ telescope = true }` to browse test/build failures through it instead of the plain quickfix list

## Install

With the dependencies installed add to your favorite package manager:

```lua
use 'ardanlabs/ardango.nvim'
```

```
Plug 'ardanlabs/ardango.nvim'
```

## How to use

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
-- Set the keymap to build the package under the cursor.
vim.keymap.set('n', '<leader>gp', ardango.BuildCurrPackage, opts)
-- Adds tag element to the field under the cursor field.
vim.keymap.set('n', '<leader>taf', ardango.AddTagToField, { buffer = 0 })
-- Adds tag element to all fields of the struct under the cursor field.
vim.keymap.set('n', '<leader>tas', ardango.AddTagsToStruct, { buffer = 0 })
-- Removes tag element from the field under the cursor.
vim.keymap.set('n', '<leader>trf', ardango.RemoveTagFromField, { buffer = 0 })
-- Removes tag element from the all fields of the struct under the cursor.
vim.keymap.set('n', '<leader>trs', ardango.RemoveTagsFromStruct, { buffer = 0 })
```
