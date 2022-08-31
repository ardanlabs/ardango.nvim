local tsutils = require('nvim-treesitter.ts_utils')
local ui = require('ui')

local M = {}

-- Selects all test functions in the buffer
-- and captures their names.
local test_query = vim.treesitter.parse_query('go', [[
  (function_declaration
    name: (identifier) @name (#match? @name "Test*")
  )
  ]])

-- Gets the treesitter root node of a buffer.
local function get_root(bufnr)
  local parser = vim.treesitter.get_parser(bufnr, "go", {})
  local tree = parser:parse()[1]

  return tree:root()
end

local api = vim.api

-- Runs the test under the cursor and shows the results
-- in a popup window.
M.RunCurrTest = function()
  local current_dir = vim.fn.expand('%:h')
  local cursor = api.nvim_win_get_cursor(0)
  local bufnr = api.nvim_get_current_buf()
  local root = get_root(bufnr)

  -- Iterate over the treesitter captures.
  for _, node in test_query:iter_captures(root, bufnr, 0, -1) do
    if tsutils.is_in_node_range(node:parent(), cursor[1] - 1, cursor[2]) then
      -- Gets the name through the node text.
      local test_name = tsutils.get_node_text(node)[1]

      -- Runs the go test tool, passing as callback the show results function.
      vim.fn.jobstart(
        "go test ./" .. current_dir .. " -run ^" .. test_name .. "$", {
        stdout_buffered = true,
        on_stdout = function(_, data)
          ui.show_results(data)
        end,
        stderr_buffered = true,
        on_stderr = function(_, data)
          ui.show_results(data)
        end,
      })
    end
  end
end

-- Build your the package in the current dir.
M.BuildCurrPackage = function()
  local current_dir = vim.fn.expand('%:h')

  -- Runs the go build, passing as callback the show results function.
  vim.fn.jobstart(
    "go build -o /dev/null ./" .. current_dir, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      ui.show_results(data)
    end,
    stderr_buffered = true,
    on_stderr = function(_, data)
      ui.show_results(data)
    end,
  })
end

return M
