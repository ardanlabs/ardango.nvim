-- Minimal Neovim config for manually exercising ardango.nvim.
-- See dev/README.md for setup and a walkthrough.

local here = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local root = vim.fn.fnamemodify(here, ":h")

vim.g.mapleader = " "

vim.opt.rtp:prepend(here .. "/.deps/nui.nvim")
vim.opt.rtp:prepend(here .. "/.deps/nvim-treesitter")
vim.opt.rtp:prepend(root)

-- telescope.nvim's current release needs Neovim 0.11+ and errors loudly
-- on load otherwise; skip it on older Neovim so opts.telescope just falls
-- back to the plain quickfix list instead of an unrelated startup error.
if vim.fn.has("nvim-0.11") == 1 then
  vim.opt.rtp:prepend(here .. "/.deps/plenary.nvim")
  vim.opt.rtp:prepend(here .. "/.deps/telescope.nvim")
end

require("nvim-treesitter.configs").setup({
  ensure_installed = { "go" },
  sync_install = false,
  highlight = { enable = false },
})

local ardango = require("ardango")

local opts = { noremap = true, silent = true }
vim.keymap.set("n", "<leader>gt", ardango.RunCurrTest, opts)
vim.keymap.set("n", "<leader>gq", function() ardango.RunCurrTest({ quickfix = true }) end, opts)
vim.keymap.set("n", "<leader>gs", function() ardango.RunCurrTest({ telescope = true }) end, opts)
vim.keymap.set("n", "<leader>gf", ardango.RunFileTests, opts)
vim.keymap.set("n", "<leader>ga", ardango.RunPackageTests, opts)
vim.keymap.set("n", "<leader>gv", function() ardango.RunPackageTests({ verbose = true }) end, opts)
vim.keymap.set("n", "<leader>gp", ardango.BuildCurrPackage, opts)
vim.keymap.set("n", "<leader>taf", ardango.AddTagToField, opts)
vim.keymap.set("n", "<leader>tas", ardango.AddTagsToStruct, opts)
vim.keymap.set("n", "<leader>trf", ardango.RemoveTagFromField, opts)
vim.keymap.set("n", "<leader>trs", ardango.RemoveTagsFromStruct, opts)
-- <Esc> first so leaving Visual mode sets the '</'> marks before the
-- function runs - mapping straight to the Lua function would call it
-- while still in Visual mode, before the marks are up to date.
vim.keymap.set("x", "<leader>tavf", "<Esc>:lua require('ardango').AddTagToVisualFields()<CR>", opts)
vim.keymap.set("x", "<leader>trvf", "<Esc>:lua require('ardango').RemoveTagFromVisualFields()<CR>", opts)
