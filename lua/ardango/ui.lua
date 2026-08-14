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

local FAIL_HL = "DiagnosticError"
local PASS_HL = vim.fn.has("nvim-0.10") == 1 and "DiagnosticOk" or "String"
local RESULT_NS = api.nvim_create_namespace("ardango_results")

-- Highlights PASS/ok lines and FAIL/error-reference lines in a popup
-- buffer so failures stand out without having to read every line.
local function highlight_results(bufnr, lines)
  for i, line in ipairs(lines) do
    if is_success_line(line) then
      api.nvim_buf_add_highlight(bufnr, RESULT_NS, PASS_HL, i - 1, 0, -1)
    elseif line:match("FAIL") or line:match(FILE_LINE_PATTERN) then
      api.nvim_buf_add_highlight(bufnr, RESULT_NS, FAIL_HL, i - 1, 0, -1)
    end
  end
end

-- Show popup opens up a popup showing the received data.
M.show_popup = function(data)
  if data and not (data[1] == "") then
    -- Write into a hidden buffer.
    local popBuffer = api.nvim_create_buf(false, false)
    api.nvim_buf_set_lines(popBuffer, 0, -1, false, data)
    highlight_results(popBuffer, data)

    -- Create the popup. winhighlight is pinned explicitly so the popup
    -- always renders with the normal editor colors, regardless of what a
    -- colorscheme/terminal does with NormalFloat/FloatBorder.
    local popup = Popup {
      relative = "cursor",
      position = 0,
      size = "50%",
      enter = true,
      bufnr = popBuffer,
      border = "rounded",
      win_options = {
        winhighlight = "Normal:Normal,FloatBorder:Normal",
      },
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

-- Opens the current quickfix list through Telescope's built-in quickfix
-- picker (fuzzy-searchable list + a preview of the location) instead of
-- a plain :copen. Returns false if telescope.nvim isn't installed, so
-- the caller can fall back to :copen.
local function open_telescope_quickfix()
  local ok, telescope_builtin = pcall(require, 'telescope.builtin')
  if not ok then
    return false
  end

  telescope_builtin.quickfix({})
  return true
end

-- Show results handles the output of a finished job:
--   - no output at all       -> success notification.
--   - only "ok"/"PASS" lines -> success notification with the summary.
--   - anything else          -> raw text popup by default, or (with
--                                opts.quickfix/opts.telescope) the
--                                quickfix list when file:line references
--                                are parseable.
-- opts.label     - prefix used in notifications/quickfix title.
-- opts.base_dir  - directory used to resolve relative file paths.
-- opts.quickfix  - use the quickfix list instead of the popup for
--                  parseable output (default false, since populating the
--                  quickfix list competes with whatever else uses it,
--                  e.g. :grep or LSP diagnostics).
-- opts.open_qf   - whether to :copen when the quickfix list gets
--                  populated (default true, only relevant with
--                  opts.quickfix and ignored if opts.telescope is used).
-- opts.telescope - browse the quickfix list through Telescope instead of
--                  :copen (implies opts.quickfix); falls back to a plain
--                  :copen if telescope.nvim isn't installed.
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

  if opts.quickfix or opts.telescope then
    local qf_items = M.build_qf_items(lines, opts.base_dir or vim.fn.getcwd())
    if #qf_items > 0 then
      vim.fn.setqflist({}, ' ', {
        title = label,
        items = qf_items,
      })

      vim.notify(
        string.format("%s: %d issue(s) found", label, #qf_items),
        vim.log.levels.WARN
      )

      if opts.telescope and open_telescope_quickfix() then
        return
      end
      if opts.telescope then
        vim.notify(label .. ": telescope.nvim not found, showing quickfix list instead", vim.log.levels.WARN)
      end

      local open_qf = opts.open_qf
      if open_qf == nil then
        open_qf = true
      end
      if open_qf then
        vim.cmd("copen")
      end
      return
    end
  end

  M.show_popup(lines)
end

return M
