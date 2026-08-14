local Popup = require('nui.popup')
local nuievent = require('nui.utils.autocmd').event
local api = vim.api

local M = {}

-- Matches "path/file.go:line:col: message" or "path/file.go:line: message".
local FILE_LINE_PATTERN = "^%s*(.-%.go):(%d+):(%d*):?%s*(.*)$"

local function parse_line(line, base_dir)
  local file, lnum, _col, msg = line:match(FILE_LINE_PATTERN)
  if not file then
    return nil
  end

  if not file:match("^/") then
    file = base_dir .. "/" .. file
  end

  return {
    filename = vim.fn.fnamemodify(file, ":p"),
    lnum = tonumber(lnum),
    col = tonumber(_col) or 1,
    text = msg ~= "" and msg or line,
  }
end

-- Builds quickfix items out of raw job output lines, picking out any
-- "file.go:line[:col]: message" references (go build/vet/test errors).
M.build_qf_items = function(lines, base_dir)
  local items = {}
  for _, line in ipairs(lines or {}) do
    local item = parse_line(line, base_dir)
    if item then
      table.insert(items, item)
    end
  end
  return items
end

local function is_success_line(line)
  return line:match("^ok%s") ~= nil or line == "PASS"
end

local function all_success(lines)
  for _, line in ipairs(lines) do
    if not is_success_line(line) then
      return false
    end
  end
  return true
end

-- Show popup opens up a popup showing the received data.
M.show_popup = function(data)
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

    popup:mount()

    popup:on({ nuievent.BufLeave }, function()
      api.nvim_buf_delete(popBuffer, { force = true })
      popup:unmount()
    end, { once = true })

    popup:map("n", "<esc>", function()
      api.nvim_buf_delete(popBuffer, { force = true })
      popup:unmount()
    end, { silent = true })
  end
end

-- Show results handles the output of a finished job:
--   - no output at all           -> success notification.
--   - only "ok"/"PASS" lines     -> success notification with the summary.
--   - file:line references found -> populate + open the quickfix list.
--   - anything else              -> fall back to the raw text popup.
-- opts.label    - prefix used in notifications/quickfix title.
-- opts.base_dir - directory used to resolve relative file paths.
M.show_results = function(data, opts)
  opts = opts or {}
  local label = opts.label or "ardango"

  local lines = vim.tbl_filter(function(l) return l ~= "" end, data or {})

  if #lines == 0 then
    vim.notify(label .. ": success", vim.log.levels.INFO)
    return
  end

  if all_success(lines) then
    vim.notify(label .. ": " .. table.concat(lines, " "), vim.log.levels.INFO)
    return
  end

  local qf_items = M.build_qf_items(lines, opts.base_dir or vim.fn.getcwd())
  if #qf_items > 0 then
    vim.fn.setqflist({}, ' ', {
      title = label,
      items = qf_items,
    })
    vim.cmd("copen")
    vim.notify(
      string.format("%s: %d issue(s) found", label, #qf_items),
      vim.log.levels.WARN
    )
    return
  end

  M.show_popup(lines)
end

return M
