local M = {}

local function check_go_binary()
  if vim.fn.executable("go") == 1 then
    vim.health.ok("`go` binary found on PATH (" .. vim.fn.exepath("go") .. ")")
  else
    vim.health.error("`go` binary not found on PATH",
      "Install Go (https://go.dev/dl/) - RunCurrTest/RunFileTests/RunPackageTests/BuildCurrPackage shell out to it")
  end
end

local function check_treesitter_parser()
  local ok = pcall(vim.treesitter.language.add, "go")
  if ok then
    vim.health.ok("Go treesitter parser is installed")
  else
    vim.health.error("Go treesitter parser not installed",
      "Run :TSInstall go (nvim-treesitter) - struct-tag and test-name lookups need it")
  end
end

local function check_nui()
  if pcall(require, "nui.popup") then
    vim.health.ok("nui.nvim found")
  else
    vim.health.error("nui.nvim not found",
      "Install nui.nvim (https://github.com/MunifTanjim/nui.nvim) - the default results popup needs it")
  end
end

local function check_telescope()
  if pcall(require, "telescope") then
    vim.health.ok("telescope.nvim found (optional) - enables opts.telescope and the tag name/value/options pickers")
  else
    vim.health.warn("telescope.nvim not found (optional)",
      "Install telescope.nvim for fuzzy pickers; falls back to the quickfix list / vim.ui.input otherwise")
  end
end

M.check = function()
  vim.health.start("ardango.nvim")
  check_go_binary()
  check_treesitter_parser()
  check_nui()
  check_telescope()
end

return M
