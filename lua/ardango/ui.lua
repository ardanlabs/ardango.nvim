local Popup = require('nui.popup')
local nuievent = require('nui.utils.autocmd').event
local config = require('ardango.config')
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
  return line:match("^ok%s") ~= nil or line == "PASS" or line:match("^%s*%-%-%- PASS:") ~= nil
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

-- Reused across runs instead of creating a new scratch buffer/popup every
-- time, so repeated RunCurrTest/BuildCurrPackage calls don't pile up
-- buffers or stack overlapping popup windows. Callers that want their own
-- independent popup (so it doesn't clobber this one) pass their own state
-- table to show_popup - see lua/ardango/debug.lua.
local result_popup_state = { bufnr = nil, popup = nil }

local function result_buf(state)
  if not state.bufnr or not api.nvim_buf_is_valid(state.bufnr) then
    -- listed = false, scratch = true: buftype=nofile, bufhidden=hide,
    -- noswapfile. A plain (scratch=false) buffer here is buftype="" and
    -- goes 'modified' as soon as we write lines into it, so it shows up
    -- in :ls! as a "[No Name]" buffer and can make :q / :qa prompt about
    -- unsaved changes. The scratch buffer is still reused across runs.
    state.bufnr = api.nvim_create_buf(false, true)
  end
  return state.bufnr
end

-- Opens filename:lnum:col in whatever window is current (i.e. the one
-- the popup was floating over, once closed).
local function jump_to(item)
  vim.cmd("edit " .. vim.fn.fnameescape(item.filename))
  api.nvim_win_set_cursor(0, { item.lnum, math.max(item.col - 1, 0) })
end

-- Show popup opens up a popup showing the received data, reusing the
-- previous run's buffer/window if there is one.
-- base_dir - directory used to resolve relative file:line references
--            under the cursor when pressing <CR>.
-- state    - optional { bufnr, popup } table to reuse instead of the
--            shared test/build results one, so an independent caller
--            (debug locals/stack) doesn't unmount the results popup.
-- opts     - optional:
--   on_enter(line, lnum, close) - overrides the default <CR> (file:line
--                                 jump). `close` unmounts the popup.
--   keymaps  = { [lhs] = function(line, lnum, close) end } - extra
--              normal-mode maps in the popup.
M.show_popup = function(data, base_dir, state, opts)
  opts = opts or {}
  state = state or result_popup_state
  if data and not (data[1] == "") then
    -- Close a still-open popup from a previous run rather than stacking
    -- a new one on top of it. Popup:unmount() is a no-op if not mounted.
    if state.popup then
      state.popup:unmount()
    end

    local bufnr = result_buf(state)
    api.nvim_buf_clear_namespace(bufnr, RESULT_NS, 0, -1)
    api.nvim_buf_set_lines(bufnr, 0, -1, false, data)
    -- Writing lines flips 'modified'; clear it so the reused buffer never
    -- reads as unsaved work.
    vim.bo[bufnr].modified = false
    highlight_results(bufnr, data)

    -- Create the popup. border/size/relative/position come from
    -- ardango.config (see M.setup); winhighlight is pinned explicitly so
    -- the popup always renders with the normal editor colors, regardless
    -- of what a colorscheme/terminal does with NormalFloat/FloatBorder.
    local popup_config = config.options.popup
    local popup = Popup {
      relative = popup_config.relative,
      position = popup_config.position,
      size = popup_config.size,
      enter = true,
      bufnr = bufnr,
      border = popup_config.border,
      win_options = {
        winhighlight = "Normal:Normal,FloatBorder:Normal",
      },
    }
    state.popup = popup

    popup:mount()

    popup:on({ nuievent.BufLeave }, function()
      popup:unmount()
    end, { once = true })

    local function close()
      popup:unmount()
    end
    popup:map("n", "<esc>", close, { silent = true })
    popup:map("n", "q", close, { silent = true })

    -- <CR>: caller-supplied action, else jump to the file:line under the
    -- cursor (same as quickfix's <CR>).
    popup:map("n", "<CR>", function()
      local line = api.nvim_get_current_line()
      local lnum = api.nvim_win_get_cursor(0)[1]
      if opts.on_enter then
        opts.on_enter(line, lnum, close)
        return
      end
      local item = parse_line(line, base_dir or vim.fn.getcwd())
      if not item then
        return
      end
      close()
      jump_to(item)
    end, { silent = true })

    for lhs, fn in pairs(opts.keymaps or {}) do
      popup:map("n", lhs, function()
        fn(api.nvim_get_current_line(), api.nvim_win_get_cursor(0)[1], close)
      end, { silent = true })
    end
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
-- opts.verbose   - list passing tests too (as a single green line each),
--                  instead of just failures. Only useful together with a
--                  caller that adds `go test`'s -v flag when this is set
--                  (RunCurrTest/RunFileTests/RunPackageTests do).
M.show_results = function(data, opts)
  opts = opts or {}
  local label = opts.label or "ardango"

  local lines = vim.tbl_filter(function(l) return l ~= "" end, data or {})

  if #lines == 0 then
    vim.notify(label .. ": success", vim.log.levels.INFO)
    return
  end

  if not opts.verbose and all_success(lines) then
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

  M.show_popup(lines, opts.base_dir)
end

return M
