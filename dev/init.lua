-- Minimal Neovim config for manually exercising ardango.nvim.
-- See dev/README.md for setup and a walkthrough.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local root = vim.fn.fnamemodify(here, ":h")

vim.g.mapleader = " "

vim.opt.rtp:prepend(here .. "/.deps/nui.nvim")
vim.opt.rtp:prepend(here .. "/.deps/nvim-treesitter")
vim.opt.rtp:prepend(root)

require("nvim-treesitter.configs").setup({
  ensure_installed = { "go" },
  sync_install = false,
  highlight = { enable = false },
})

local ardango = require("ardango")

local opts = { noremap = true, silent = true }
vim.keymap.set("n", "<leader>gt", ardango.RunCurrTest, opts)
vim.keymap.set("n", "<leader>gp", ardango.BuildCurrPackage, opts)
vim.keymap.set("n", "<leader>taf", ardango.AddTagToField, opts)
vim.keymap.set("n", "<leader>tas", ardango.AddTagsToStruct, opts)
vim.keymap.set("n", "<leader>trf", ardango.RemoveTagFromField, opts)
vim.keymap.set("n", "<leader>trs", ardango.RemoveTagsFromStruct, opts)
