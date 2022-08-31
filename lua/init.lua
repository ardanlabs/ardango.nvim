local Popup = require('nui.popup')
local nuievent = require('nui.utils.autocmd').event
local tsutils = require('nvim-treesitter.ts_utils')

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

-- Show results opens up a popup showing the recived data.
local show_results = function(data)
  if data and not (data[1] == "") then
    -- Write into a hidden buffer.
    local popBuffer = api.nvim_create_buf(false, false)
    api.nvim_buf_set_lines(popBuffer, 0, -1, false, data)

    -- Create the popup
    local popup = Popup {
      relative = "cursor",
      position = 0,
      size = "50%",
      enter = true,
      bufnr = popBuffer,
    }

    print(vim.inspect(popup))
    popup:mount()

    popup:on({ nuievent.BufLeave }, function()
      popup:unmount()
      api.nvim_buf_delete(popBuffer)
    end, { once = true })

    popup:map("n", "<esc>", function()
      popup:unmount()
      api.nvim_buf_delete(popBuffer)
    end, { silent = true })
  end
end

-- Runs the test under the cursor and shows the results
-- in a popup window.
M.RunCurrentTest = function()
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
          show_results(data)
        end,
        stderr_buffered = true,
        on_stderr = function(_, data)
          show_results(data)
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
      show_results(data)
    end,
    stderr_buffered = true,
    on_stderr = function(_, data)
      show_results(data)
    end,
  })
end

return M
