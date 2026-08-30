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
vim.keymap.set("n", "<leader>gb", ardango.RunCurrBenchmark, opts)
vim.keymap.set("n", "<leader>gd", function() ardango.RunCurrTest({ dry_run = true }) end, opts)
vim.keymap.set("n", "<leader>gc", ardango.CopyLastCmd, opts)
vim.keymap.set("n", "<leader>gr", ardango.RunLastTest, opts)
vim.keymap.set("n", "<leader>taf", ardango.AddTagToField, opts)
vim.keymap.set("n", "<leader>tas", ardango.AddTagsToStruct, opts)
vim.keymap.set("n", "<leader>trf", ardango.RemoveTagFromField, opts)
vim.keymap.set("n", "<leader>trs", ardango.RemoveTagsFromStruct, opts)
-- <Esc> first so leaving Visual mode sets the '</'> marks before the
-- function runs - mapping straight to the Lua function would call it
-- while still in Visual mode, before the marks are up to date.
vim.keymap.set("x", "<leader>tavf", "<Esc>:lua require('ardango').AddTagToVisualFields()<CR>", opts)
vim.keymap.set("x", "<leader>trvf", "<Esc>:lua require('ardango').RemoveTagFromVisualFields()<CR>", opts)
vim.keymap.set("n", "<leader>gh", function() ardango.SignatureInStatusLine(1000) end, opts)
vim.keymap.set("n", "<leader>gH", function() ardango.SignatureInStatusLine(1000, { float = true }) end, opts)

-- Delve debugging (needs `dlv` on PATH + bin/ardango-dbg built by setup.sh).
vim.keymap.set("n", "<leader>dt", ardango.DebugCurrTest, opts)
vim.keymap.set("n", "<leader>dB", ardango.DebugCurrBenchmark, opts)
vim.keymap.set("n", "<leader>dP", ardango.DebugPackage, opts)
vim.keymap.set("n", "<leader>db", ardango.DebugBreakpoint, opts)
vim.keymap.set("n", "<leader>dc", ardango.DebugContinue, opts)
vim.keymap.set("n", "<leader>dn", ardango.DebugNext, opts)
vim.keymap.set("n", "<leader>ds", ardango.DebugStep, opts)
vim.keymap.set("n", "<leader>do", ardango.DebugStepOut, opts)
vim.keymap.set("n", "<leader>dq", ardango.DebugStop, opts)
vim.keymap.set("n", "<leader>de", ardango.DebugEval, opts)
vim.keymap.set("n", "<leader>dl", ardango.DebugLocals, opts)
vim.keymap.set("n", "<leader>dS", ardango.DebugStack, opts)
vim.keymap.set("n", "<leader>d[", ardango.DebugFrameUp, opts)
vim.keymap.set("n", "<leader>d]", ardango.DebugFrameDown, opts)
vim.keymap.set("n", "<leader>dg", ardango.DebugGoroutines, opts)
vim.keymap.set("n", "<leader>dm", ardango.DebugBreakpoints, opts)
