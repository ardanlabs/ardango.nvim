local ui = require('ardango.ui')
local config = require('ardango.config')
local dbg = require('ardango.debug')

local M = {}

-- setup lets a user override plugin-wide config - currently just the
-- results popup's border/size/relative/position. See ardango.config.
M.setup = config.setup

-- Selects all test functions in the buffer
-- and captures their names.
local test_query = vim.treesitter.query.parse('go', [[
  (function_declaration
    name: (identifier) @name (#match? @name "Test*")
  )
  ]])

-- Selects all benchmark functions in the buffer and captures their names.
local bench_query = vim.treesitter.query.parse('go', [[
  (function_declaration
    name: (identifier) @name (#match? @name "Benchmark*")
  )
  ]])

-- Gets the treesitter root node of a buffer.
local function get_root(bufnr)
  local parser = vim.treesitter.get_parser(bufnr, "go", {})
  local tree = parser:parse()[1]

  return tree:root()
end

local api = vim.api

-- Tracks whichever go test/build job is currently in flight (RunCurrTest,
-- RunFileTests, RunPackageTests and BuildCurrPackage all share this - they
-- also share the same result popup/quickfix/telescope view, so only one
-- job's output is ever meaningful to show at a time).
local current_job = nil

-- The most recently computed job invocation (real run or opts.dry_run),
-- from any Run*/BuildCurrPackage call. See CopyLastCmd/RunLastTest.
local last_invocation = nil

-- Runs cmd, notifying when it starts and handing its combined
-- stdout/stderr to ui.show_results (merged with opts) on exit. Stops any
-- still-running previous job first, so spamming a Run.../Build... keymap
-- doesn't leave overlapping `go` processes racing to populate the same
-- result view - whichever happened to finish last would otherwise
-- silently win, even if it was the stale one.
--
-- opts.dry_run - don't actually run cmd, just show what would run (still
-- updates last_invocation, so a dry run can be followed by CopyLastCmd or
-- RunLastTest).
local function run_job(cmd, label, current_dir, opts)
  last_invocation = { cmd = cmd, label = label, current_dir = current_dir, opts = opts }

  if opts and opts.dry_run then
    vim.notify(label .. ": dry run: " .. cmd, vim.log.levels.INFO)
    return
  end

  if current_job then
    vim.fn.jobstop(current_job)
  end

  vim.notify(label .. ": running...", vim.log.levels.INFO)

  local output = {}
  local job_id
  job_id = vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      vim.list_extend(output, data or {})
    end,
    on_stderr = function(_, data)
      vim.list_extend(output, data or {})
    end,
    on_exit = function()
      -- A newer run superseded this one (it was jobstop'd above) - its
      -- output is stale, don't show it.
      if current_job ~= job_id then
        return
      end
      current_job = nil

      local show_opts = vim.tbl_extend("force",
        { label = label, base_dir = current_dir },
        opts or {})
      ui.show_results(output, show_opts)
    end,
  })
  current_job = job_id
end

-- Collects the names of every Test* function declared in bufnr.
local function test_names(bufnr)
  local root = get_root(bufnr)
  local names = {}
  for _, node in test_query:iter_captures(root, bufnr, 0, -1) do
    table.insert(names, vim.treesitter.get_node_text(node, bufnr))
  end
  return names
end

-- " -v" when opts.verbose is set (go test only prints a line per passing
-- test, e.g. "--- PASS: TestFoo (0.00s)", with -v), otherwise "".
local function verbose_flag(opts)
  if opts and opts.verbose then
    return " -v"
  end
  return ""
end

-- Runs the test under the cursor and shows the results in a popup by
-- default. Pass opts.quickfix = true (or opts.telescope = true) to show
-- them in the quickfix list / a Telescope picker instead, or
-- opts.verbose = true to also list passing tests - see ui.show_results
-- for the full set of opts.
M.RunCurrTest = function(opts)
  local current_dir = vim.fn.expand('%:h')
  local cursor = api.nvim_win_get_cursor(0)
  local bufnr = api.nvim_get_current_buf()
  local root = get_root(bufnr)

  -- Iterate over the treesitter captures.
  for _, node in test_query:iter_captures(root, bufnr, 0, -1) do
    if vim.treesitter.is_in_node_range(node:parent(), cursor[1] - 1, cursor[2]) then
      -- Gets the name through the node text.
      local test_name = vim.treesitter.get_node_text(node, bufnr)
      run_job(
        "go test ./" .. current_dir .. verbose_flag(opts) .. " -run ^" .. test_name .. "$",
        "go test: " .. test_name, current_dir, opts)
    end
  end
end

-- Runs every Test* function declared in the current buffer. Same opts as
-- RunCurrTest.
M.RunFileTests = function(opts)
  local current_dir = vim.fn.expand('%:h')
  local bufnr = api.nvim_get_current_buf()
  local names = test_names(bufnr)

  if #names == 0 then
    vim.notify("ardango: no tests found in this file", vim.log.levels.WARN)
    return
  end

  run_job(
    "go test ./" .. current_dir .. verbose_flag(opts) .. " -run '^(" .. table.concat(names, "|") .. ")$'",
    "go test: " .. #names .. " test(s) in file", current_dir, opts)
end

-- Runs every test in the current package (i.e. the whole current
-- directory, not just the current file). Same opts as RunCurrTest.
M.RunPackageTests = function(opts)
  local current_dir = vim.fn.expand('%:h')
  run_job("go test ./" .. current_dir .. verbose_flag(opts), "go test: package", current_dir, opts)
end

-- Runs the benchmark under the cursor and shows the results in a popup by
-- default (opts.quickfix/opts.telescope work the same as RunCurrTest,
-- though there's rarely a file:line to jump to in benchmark output;
-- opts.verbose is ignored - go test has no verbose flag for benchmarks,
-- their timing/alloc line prints unconditionally). Runs with -benchmem so
-- allocation stats show alongside ns/op.
M.RunCurrBenchmark = function(opts)
  local current_dir = vim.fn.expand('%:h')
  local cursor = api.nvim_win_get_cursor(0)
  local bufnr = api.nvim_get_current_buf()
  local root = get_root(bufnr)

  for _, node in bench_query:iter_captures(root, bufnr, 0, -1) do
    if vim.treesitter.is_in_node_range(node:parent(), cursor[1] - 1, cursor[2]) then
      local bench_name = vim.treesitter.get_node_text(node, bufnr)
      run_job(
        "go test ./" .. current_dir .. " -run '^$' -bench '^" .. bench_name .. "$' -benchmem",
        "go bench: " .. bench_name, current_dir, opts)
    end
  end
end

-- Build the package in the current dir, showing the results in a popup by
-- default. Same opts as RunCurrTest.
M.BuildCurrPackage = function(opts)
  local current_dir = vim.fn.expand('%:h')
  run_job("go build -o /dev/null ./" .. current_dir, "go build", current_dir, opts)
end

-- CopyLastCmd puts the most recently computed test/bench/build shell
-- command (from any Run*/BuildCurrPackage call - opts.dry_run = true or a
-- real run, either updates it) onto the system clipboard (the "+"
-- register), so it can be pasted into a terminal and run manually.
M.CopyLastCmd = function()
  if not last_invocation then
    vim.notify("ardango: no command run yet", vim.log.levels.WARN)
    return
  end
  vim.fn.setreg('+', last_invocation.cmd)
  vim.notify("ardango: copied to clipboard: " .. last_invocation.cmd, vim.log.levels.INFO)
end

-- RunLastTest re-runs whatever Run*/BuildCurrPackage invocation was most
-- recently computed (test, benchmark or build alike - whatever it was),
-- without needing to reposition the cursor back on the original
-- test/benchmark. {opts} is merged over (and overrides) the opts used
-- last time - e.g. RunLastTest({ quickfix = true }) reruns the same
-- command but through the quickfix list this time. Always actually runs,
-- even if the last invocation was itself an opts.dry_run preview - pass
-- { dry_run = true } again if you want to re-preview instead.
M.RunLastTest = function(opts)
  if not last_invocation then
    vim.notify("ardango: no command run yet", vim.log.levels.WARN)
    return
  end
  local merged_opts = vim.tbl_extend("force",
    last_invocation.opts or {}, { dry_run = false }, opts or {})
  run_job(last_invocation.cmd, last_invocation.label, last_invocation.current_dir, merged_opts)
end

-- Debug commands - drive Delve through lua/ardango/debug.lua (which spawns
-- `dlv --headless` plus the cmd/ardango-dbg proxy). DebugCurrTest/
-- DebugCurrBenchmark find the function under the cursor the same way
-- RunCurrTest/RunCurrBenchmark do, then hand off to debug.start; the rest
-- are session controls (no cursor context needed).

-- Starts a Delve session on the Test* function under the cursor and stops
-- on its first line (an entry breakpoint). Drive it with DebugContinue/
-- DebugNext/DebugStep/DebugStepOut, set more stops with DebugBreakpoint,
-- end it with DebugStop.
M.DebugCurrTest = function()
  local current_dir = vim.fn.expand('%:p:h')
  local file = vim.fn.expand('%:p')
  local cursor = api.nvim_win_get_cursor(0)
  local bufnr = api.nvim_get_current_buf()
  local root = get_root(bufnr)

  for _, node in test_query:iter_captures(root, bufnr, 0, -1) do
    if vim.treesitter.is_in_node_range(node:parent(), cursor[1] - 1, cursor[2]) then
      dbg.start({
        mode = "test", dir = current_dir, run = vim.treesitter.get_node_text(node, bufnr),
        entry = { file = file, line = ({ node:parent():range() })[1] + 1 },
      })
      return
    end
  end
  vim.notify("ardango: no Test function under the cursor", vim.log.levels.WARN)
end

-- Starts a Delve session on the Benchmark* function under the cursor
-- (dlv test -- -test.bench ^Name$ -test.run ^$ -test.benchmem), stopping
-- on its first line.
M.DebugCurrBenchmark = function()
  local current_dir = vim.fn.expand('%:p:h')
  local file = vim.fn.expand('%:p')
  local cursor = api.nvim_win_get_cursor(0)
  local bufnr = api.nvim_get_current_buf()
  local root = get_root(bufnr)

  for _, node in bench_query:iter_captures(root, bufnr, 0, -1) do
    if vim.treesitter.is_in_node_range(node:parent(), cursor[1] - 1, cursor[2]) then
      dbg.start({
        mode = "bench", dir = current_dir, bench = vim.treesitter.get_node_text(node, bufnr),
        entry = { file = file, line = ({ node:parent():range() })[1] + 1 },
      })
      return
    end
  end
  vim.notify("ardango: no Benchmark function under the cursor", vim.log.levels.WARN)
end

-- Starts a Delve session on the current buffer's package (dlv debug).
M.DebugPackage = function()
  dbg.start({ mode = "package", dir = vim.fn.expand('%:p:h') })
end

M.DebugContinue = dbg.continue
M.DebugStepOver = dbg.step_over
M.DebugStepInto = dbg.step_into
M.DebugStepOut = dbg.step_out
-- Back-compat aliases (not tab-completed).
M.DebugNext = dbg.step_over
M.DebugStep = dbg.step_into
-- DebugBreakpoint toggles a breakpoint at the cursor; with an argument
-- (:Ardango DebugBreakpoint x > 5) it sets a conditional one.
M.DebugBreakpoint = dbg.toggle_breakpoint
M.DebugStop = dbg.stop

-- Shows the value of {expr} (the <cexpr> under the cursor by default,
-- the Visual selection for DebugEvalVisual) in a floating window, like an
-- LSP hover. Halted target only.
M.DebugEval = dbg.eval
M.DebugEvalVisual = dbg.eval_visual

-- DebugLocals lists the current frame's args + local variables in a
-- popup; DebugStack shows the goroutine's call stack in a popup (press
-- <CR> on a frame line to jump to it). Halted target only.
M.DebugLocals = dbg.locals
M.DebugStack = dbg.stack

-- DebugFrameUp/DebugFrameDown walk the call stack (caller/callee) and
-- DebugFrame jumps to a numbered frame; DebugLocals/DebugEval then
-- operate in the selected frame. Reset to frame 0 on the next stop.
M.DebugFrameUp = dbg.frame_up
M.DebugFrameDown = dbg.frame_down
M.DebugFrame = dbg.frame

-- DebugGoroutines lists all goroutines in a popup; DebugGoroutine {id}
-- switches the selected goroutine (locals/eval/stack then follow it).
M.DebugGoroutines = dbg.goroutines
M.DebugGoroutine = dbg.switch_goroutine

-- DebugBreakpoints lists every breakpoint in a popup (<CR> jump, dd
-- delete, D clear all); `:Ardango DebugBreakpoints telescope` uses a
-- Telescope picker with a source preview instead. DebugBreakpointClearAll
-- removes them all.
M.DebugBreakpoints = dbg.breakpoints
M.DebugBreakpointClearAll = dbg.clear_breakpoints

-- debug_status() returns a compact one-line status for a statusline /
-- winbar / lualine component ("" when there's no session). DebugStatus
-- echoes it as a notification.
M.debug_status = dbg.debug_status
M.DebugStatus = function()
  local st = dbg.debug_status()
  vim.notify("ardango: " .. (st ~= "" and st or "no debug session"), vim.log.levels.INFO)
end

-- OrgImports is a function to update imports of the current buffer.
M.OrgBufImports = function(wait_ms)
  local params = vim.lsp.util.make_range_params()
  params.context = { only = { "source.organizeImports" } }
  local result = vim.lsp.buf_request_sync(0, "textDocument/codeAction", params, wait_ms)
  for _, res in pairs(result or {}) do
    for _, r in pairs(res.result or {}) do
      if r.edit then
        vim.lsp.util.apply_workspace_edit(r.edit, "utf-8")
      else
        vim.lsp.buf.execute_command(r.command)
      end
    end
  end
end

-- SignatureInStatusLine shows the element under the cursor's signature
-- info on hover. By default a one-line summary is shown via vim.notify
-- (close to the statusline); opts.float = true instead opens a floating
-- window with the full hover content, via the same
-- vim.lsp.util.open_floating_preview vim.lsp.buf.hover() itself uses -
-- syntax-highlighted, auto-closes on cursor move, etc.
M.SignatureInStatusLine = function(wait_ms, opts)
  opts = opts or {}
  local params = vim.lsp.util.make_position_params()
  local result = vim.lsp.buf_request_sync(0, "textDocument/hover", params, wait_ms)
  for _, res in pairs(result or {}) do
    for _, r in pairs(res or {}) do
      for _, elem in pairs(r or {}) do
        if elem.value ~= nil then
          if opts.float then
            vim.schedule(function()
              vim.lsp.util.open_floating_preview(vim.split(elem.value, '\n'), 'markdown',
                { border = config.options.popup.border })
            end)
          else
            local lines = elem.value:gmatch("([^\r\n]+)\r?\n?")
            -- throw away the first line of the iterator.
            lines()
            -- print the actual definition.
            local definition = lines()
            vim.schedule(function()
              vim.notify(definition, vim.log.levels.INFO)
            end)
          end
        end
      end
    end
  end
end

-- snake receives a string a returns it in snake case
local function snake(s)
  return s:gsub('%f[^%l]%u', '_%1')
      :gsub('%f[^%a]%d', '_%1')
      :gsub('%f[^%d]%a', '_%1')
      :gsub('(%u)(%u%l)', '%1_%2')
      :lower()
end

local structtag = require('ardango.struct_tag')

local COMMON_TAG_NAMES = { "json", "yaml", "db", "validate", "xml" }

-- Opens a prompt via Telescope - fuzzy-matching against `results`, using
-- whatever's typed if nothing matches (Telescope leaves no entry
-- selected when the filtered list is empty) - or a plain vim.ui.input if
-- telescope.nvim isn't installed, so a multi-step flow (tag name, then
-- tag value) looks/feels the same at every step instead of dropping to
-- the cmdline partway through.
--
-- on_result is called with the resolved string on <CR> ("" if confirmed
-- empty). On the Telescope path, cancelling (<esc>) does not call
-- on_result at all; on the vim.ui.input path, cancelling calls it with
-- nil, per vim.ui.input's own contract - callers should treat both "not
-- called" and "called with nil/empty" as "no input given".
local function prompt(title, results, input_opts, on_result)
  local ok_pickers, pickers = pcall(require, 'telescope.pickers')
  local ok_finders, finders = pcall(require, 'telescope.finders')
  local ok_config, telescope_config = pcall(require, 'telescope.config')
  local ok_actions, actions = pcall(require, 'telescope.actions')
  local ok_action_state, action_state = pcall(require, 'telescope.actions.state')

  if not (ok_pickers and ok_finders and ok_config and ok_actions and ok_action_state) then
    vim.ui.input(input_opts, on_result)
    return
  end

  pickers.new({}, {
    prompt_title = title,
    finder = finders.new_table({ results = results }),
    sorter = telescope_config.values.generic_sorter({}),
    previewer = false,
    attach_mappings = function(prompt_bufnr, _)
      actions.select_default:replace(function()
        local selection = action_state.get_selected_entry()
        local typed = action_state.get_current_line()
        actions.close(prompt_bufnr)
        on_result(selection and selection.value or typed)
      end)
      return true
    end,
  }):find()
end

-- Lets the user pick a tag name, from COMMON_TAG_NAMES or a custom one -
-- see `prompt`. callback is invoked with the chosen name, or not at all
-- if nothing was given (cancelled, or confirmed empty).
local function select_tag_name(callback)
  prompt('Tag name', COMMON_TAG_NAMES, { prompt = 'Enter tag name', default = 'json' }, function(name)
    if name and name ~= '' then
      callback(name)
    end
  end)
end

-- Combines the tag value and its common options (config.options.tag_options,
-- e.g. omitempty/-/required) into a single step, instead of two prompts in
-- a row: <Tab>-toggle any options first (usually short enough to stay
-- fully visible before you type anything), then type the value - typing
-- filters the list but multi-selected entries stay selected regardless.
-- <CR> confirms both at once. "-" wins over everything else if selected,
-- since a bare `-` means "skip this field" per Go tag convention.
--
-- Falls back to a single vim.ui.input prompt (`value,option1,option2`) if
-- telescope.nvim isn't installed. callback receives a function(field_name)
-- -> resolved tag value string; it may not be called at all if cancelled
-- via Telescope's <esc>, same as everywhere else `prompt` is used - the
-- vim.ui.input fallback instead resolves to the plain snake_case default
-- on cancel, per vim.ui.input's own contract.
local function prompt_tag_value_and_options(callback)
  local function resolve(value, options)
    if vim.tbl_contains(options, '-') then
      return function(_) return '-' end
    end
    return function(field_name)
      local parts = { (value ~= '' and value) or snake(field_name) }
      vim.list_extend(parts, options)
      return table.concat(parts, ',')
    end
  end

  local ok_pickers, pickers = pcall(require, 'telescope.pickers')
  local ok_finders, finders = pcall(require, 'telescope.finders')
  local ok_config, telescope_config = pcall(require, 'telescope.config')
  local ok_actions, actions = pcall(require, 'telescope.actions')
  local ok_action_state, action_state = pcall(require, 'telescope.actions.state')

  if not (ok_pickers and ok_finders and ok_config and ok_actions and ok_action_state) then
    vim.ui.input(
      { prompt = 'Tag value[,options] (empty value = snake_case field name, e.g. email,omitempty)' },
      function(input)
        local pieces = {}
        for piece in (input or ''):gmatch('[^,]+') do
          table.insert(pieces, piece)
        end
        local options = {}
        for i = 2, #pieces do
          table.insert(options, pieces[i])
        end
        callback(resolve(pieces[1] or '', options))
      end)
    return
  end

  local tag_options = config.options.tag_options
  pickers.new({}, {
    prompt_title = 'Tag value + options (<Tab> to toggle ' .. table.concat(tag_options, '/') ..
        ', then type the value)',
    finder = finders.new_table({ results = tag_options }),
    sorter = telescope_config.values.generic_sorter({}),
    previewer = false,
    attach_mappings = function(prompt_bufnr, map)
      map({ "i", "n" }, "<Tab>", actions.toggle_selection + actions.move_selection_worse)
      actions.select_default:replace(function()
        local picker = action_state.get_current_picker(prompt_bufnr)
        local selections = picker:get_multi_selection()
        local typed = action_state.get_current_line()
        actions.close(prompt_bufnr)

        local options = {}
        for _, sel in ipairs(selections) do
          table.insert(options, sel.value)
        end

        callback(resolve(typed or '', options))
      end)
      return true
    end,
  }):find()
end

-- AddTagToStruct receives a tag name and value and adds to
-- all fields inside the struct under the cursor.
-- It handles adding more values to an existing tag element.
M.AddTagsToStruct = function()
  select_tag_name(function(tag_name)
    prompt_tag_value_and_options(function(value_callback)
      structtag.add_to_struct_tag(tag_name, value_callback)
    end)
  end)
end

-- AddTagToField receives a tag name and value and adds to
-- struct field under the cursor.
-- It handles adding more values to an existing tag element.
M.AddTagToField = function()
  select_tag_name(function(tag_name)
    prompt_tag_value_and_options(function(value_callback)
      structtag.add_to_field_tag(tag_name, value_callback)
    end)
  end)
end

-- RemoveTagsFromStruct receives a tag name and removes the
-- element from all field tags inside the struct under the cursor.
M.RemoveTagsFromStruct = function()
  select_tag_name(function(tag_name)
    structtag.remove_from_struct_tag(tag_name)
  end)
end

-- RemoveTagFromField receives a tag name and removes the
-- element from the struct field under the cursor.
M.RemoveTagFromField = function()
  select_tag_name(function(tag_name)
    structtag.remove_from_field_tag(tag_name)
  end)
end

-- Reads the '</'> marks Neovim leaves after exiting visual mode into a
-- 0-indexed, inclusive row range. Meant to be called from a visual-mode
-- keymap - invoking the mapped function itself exits visual mode and sets
-- the marks before the function runs, so this doesn't need to be called
-- from inside a :'<,'> command.
local function visual_range()
  local start_row = vim.fn.getpos("'<")[2] - 1
  local end_row = vim.fn.getpos("'>")[2] - 1
  return start_row, end_row
end

-- AddTagToVisualFields adds a tag element to every field declared inside
-- the last visual selection (within the struct under the cursor). Same
-- name/value/options prompts as AddTagToField.
M.AddTagToVisualFields = function()
  local start_row, end_row = visual_range()
  select_tag_name(function(tag_name)
    prompt_tag_value_and_options(function(value_callback)
      structtag.add_to_fields_in_range_tag(tag_name, value_callback, start_row, end_row)
    end)
  end)
end

-- RemoveTagFromVisualFields removes a tag element from every field
-- declared inside the last visual selection. Same name prompt as
-- RemoveTagFromField.
M.RemoveTagFromVisualFields = function()
  local start_row, end_row = visual_range()
  select_tag_name(function(tag_name)
    structtag.remove_from_fields_in_range_tag(tag_name, start_row, end_row)
  end)
end

-- ==========================================================================
-- :ArdangoDebug <sub> [args] - all the debug commands, in their own
-- namespace. Each row: { sub, M-function, one-line description, arg-kind }.
-- arg-kind: "text" (free expr / breakpoint condition), "num" (a number),
-- or nil. Order is the completion / menu order.
-- ==========================================================================
local DEBUG_SUBCOMMANDS = {
  { "test",        "DebugCurrTest",           "debug the Test under the cursor" },
  { "bench",       "DebugCurrBenchmark",      "debug the Benchmark under the cursor" },
  { "package",     "DebugPackage",            "dlv debug the current package" },
  { "continue",    "DebugContinue",           "run to the next breakpoint / exit" },
  { "over",        "DebugStepOver",           "step over the current line" },
  { "into",        "DebugStepInto",           "step into a call" },
  { "out",         "DebugStepOut",            "run until this function returns" },
  { "stop",        "DebugStop",               "end the session" },
  { "break",       "DebugBreakpoint",         "toggle breakpoint here (arg: condition)", "text" },
  { "breaks",      "DebugBreakpoints",        "list breakpoints",                        "text" },
  { "clearbreaks", "DebugBreakpointClearAll", "remove every breakpoint" },
  { "eval",        "DebugEval",               "evaluate an expression (arg: expr)",     "text" },
  { "locals",      "DebugLocals",             "show the frame's args + locals" },
  { "stack",       "DebugStack",              "show the call stack" },
  { "up",          "DebugFrameUp",            "select the caller frame" },
  { "down",        "DebugFrameDown",          "select the callee frame" },
  { "frame",       "DebugFrame",              "select frame N (arg: number)",           "num" },
  { "goroutines",  "DebugGoroutines",         "list goroutines",                        "text" },
  { "goroutine",   "DebugGoroutine",          "switch to goroutine N (arg: id)",        "num" },
  { "status",      "DebugStatus",             "echo the current debug status" },
  { "menu",        "DebugMenu",               "this menu" },
}

local DEBUG_BY_SUB, DEBUG_SUB_BY_FN = {}, {}
for _, e in ipairs(DEBUG_SUBCOMMANDS) do
  DEBUG_BY_SUB[e[1]] = e
  DEBUG_SUB_BY_FN[e[2]] = e[1]
end

-- Runs a resolved subcommand entry with the rest-of-line arg string.
local function run_debug(entry, argstr)
  local fn = M[entry[2]]
  argstr = argstr or ""
  if entry[4] == "num" then
    fn(argstr ~= "" and argstr or nil)
  elseif entry[1] == "breaks" then
    fn(argstr == "telescope" and { telescope = true } or nil)
  elseif entry[1] == "goroutines" then
    fn(argstr == "all" and { all = true } or nil)
  elseif entry[4] == "text" then
    fn(argstr) -- "" is meaningful: eval -> <cexpr>, break -> plain toggle
  else
    fn()
  end
end

-- Runs a menu-selected entry, prompting for its argument first if it
-- takes one.
local function menu_pick(e)
  if not e then
    return
  end
  if e[4] then
    vim.ui.input({ prompt = e[1] .. ": " }, function(arg)
      if arg ~= nil then
        run_debug(e, arg)
      end
    end)
  else
    run_debug(e, "")
  end
end

-- Telescope debug-command picker (real fuzzy find + narrowing). Returns
-- false if telescope.nvim isn't installed, so DebugMenu falls back to
-- vim.ui.select.
local function debug_menu_telescope(items)
  local ok_p, pickers = pcall(require, "telescope.pickers")
  local ok_f, finders = pcall(require, "telescope.finders")
  local ok_c, tconf = pcall(require, "telescope.config")
  local ok_a, actions = pcall(require, "telescope.actions")
  local ok_s, action_state = pcall(require, "telescope.actions.state")
  if not (ok_p and ok_f and ok_c and ok_a and ok_s) then
    return false
  end

  pickers.new({}, {
    prompt_title = "Debug",
    finder = finders.new_table({
      results = items,
      entry_maker = function(e)
        return {
          value = e,
          display = string.format("%-11s  %s", e[1], e[3]),
          ordinal = e[1] .. " " .. e[3],
        }
      end,
    }),
    sorter = tconf.values.generic_sorter({}),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local sel = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if sel then
          menu_pick(sel.value)
        end
      end)
      return true
    end,
  }):find()
  return true
end

-- The debug-command picker. Uses a Telescope picker when telescope.nvim
-- is installed (fuzzy find), otherwise vim.ui.select (which itself
-- fuzzy-finds via telescope-ui-select / dressing / snacks / fzf-lua, or
-- is a plain numbered prompt).
function M.DebugMenu()
  local items = {}
  for _, e in ipairs(DEBUG_SUBCOMMANDS) do
    if e[1] ~= "menu" then
      items[#items + 1] = e
    end
  end
  if debug_menu_telescope(items) then
    return
  end
  vim.ui.select(items, {
    prompt = "Debug",
    format_item = function(e) return string.format("%-11s  %s", e[1], e[3]) end,
  }, menu_pick)
end

vim.api.nvim_create_user_command("ArdangoDebug", function(cmd_opts)
  local sub = cmd_opts.fargs[1]
  if not sub or sub == "menu" then
    M.DebugMenu()
    return
  end
  local entry = DEBUG_BY_SUB[sub]
  if not entry then
    vim.notify("ardango: unknown debug command '" .. sub .. "' (:ArdangoDebug <Tab>)",
      vim.log.levels.ERROR)
    return
  end
  run_debug(entry, table.concat({ unpack(cmd_opts.fargs, 2) }, " "))
end, {
  nargs = "*",
  desc = "Run an ardango.nvim debug command",
  complete = function(arglead, cmdline)
    local words = {}
    for w in cmdline:gmatch("%S+") do
      words[#words + 1] = w
    end
    local on_sub = #words <= 1 or (#words == 2 and not cmdline:match("%s$"))
    if on_sub then
      local subs = {}
      for _, e in ipairs(DEBUG_SUBCOMMANDS) do
        subs[#subs + 1] = e[1]
      end
      return vim.tbl_filter(function(c) return c:find(arglead, 1, true) == 1 end, subs)
    end
    if words[2] == "breaks" then
      return { "telescope" }
    end
    if words[2] == "goroutines" then
      return { "all" }
    end
    return {}
  end,
})

-- Every M command reachable from :Ardango, in the order they're offered
-- for completion. (Debug commands moved to :ArdangoDebug.)
local EX_COMMANDS = {
  "RunCurrTest", "RunFileTests", "RunPackageTests", "RunCurrBenchmark",
  "BuildCurrPackage", "RunLastTest", "CopyLastCmd",
  "AddTagToField", "AddTagsToStruct", "RemoveTagFromField", "RemoveTagsFromStruct",
  "AddTagToVisualFields", "RemoveTagFromVisualFields",
  "OrgBufImports", "SignatureInStatusLine",
}

-- Commands that take a wait_ms number (milliseconds) as their first
-- argument, instead of an opts table.
local WAIT_MS_COMMANDS = { OrgBufImports = true, SignatureInStatusLine = true }
local DEFAULT_WAIT_MS = 1000

-- Boolean opts recognized as bare words after the subcommand, e.g.
-- `:Ardango RunCurrTest quickfix verbose`.
local BOOL_OPTS = { "quickfix", "telescope", "verbose", "dry_run", "float", "all" }

-- :Ardango <Command> [flag...] - a tab-completable Ex-command layer over
-- the Lua API above, for discoverability without a keymap. <Command> is
-- any name in EX_COMMANDS; any following bare words matching BOOL_OPTS
-- become `{ [flag] = true }` opts (for commands that take opts - it's a
-- harmless no-op for the ones that don't). OrgBufImports/
-- SignatureInStatusLine take a milliseconds number instead of/alongside
-- flags (defaults to 1000 if omitted), e.g. `:Ardango OrgBufImports 2000`
-- or `:Ardango SignatureInStatusLine 500 float`.
vim.api.nvim_create_user_command("Ardango", function(cmd_opts)
  local name = cmd_opts.fargs[1]

  -- Debug commands moved to their own :ArdangoDebug namespace.
  if name and name:match("^Debug") then
    local s = DEBUG_SUB_BY_FN[name]
    vim.notify("ardango: debug commands are now :ArdangoDebug" ..
      (s and (" — try `:ArdangoDebug " .. s .. "`") or " (`:ArdangoDebug <Tab>`)"),
      vim.log.levels.WARN)
    return
  end

  if not name or not M[name] then
    vim.notify("ardango: unknown command '" .. tostring(name) .. "'", vim.log.levels.ERROR)
    return
  end

  local rest = { unpack(cmd_opts.fargs, 2) }

  if WAIT_MS_COMMANDS[name] then
    local wait_ms = tonumber(rest[1]) or DEFAULT_WAIT_MS
    if name == "SignatureInStatusLine" and vim.tbl_contains(rest, "float") then
      M[name](wait_ms, { float = true })
    else
      M[name](wait_ms)
    end
    return
  end

  local flag_opts = {}
  for _, arg in ipairs(rest) do
    if vim.tbl_contains(BOOL_OPTS, arg) then
      flag_opts[arg] = true
    end
  end

  if next(flag_opts) then
    M[name](flag_opts)
  else
    M[name]()
  end
end, {
  nargs = "+",
  desc = "Run an ardango.nvim command by name",
  complete = function(arglead, cmdline)
    -- Whatever's already on the line before the word being completed -
    -- ["Ardango"] means we're completing the subcommand itself;
    -- ["Ardango", subcommand, ...] means we're completing a flag.
    local prefix = cmdline:sub(1, #cmdline - #arglead)
    local prefix_words = {}
    for w in prefix:gmatch("%S+") do
      table.insert(prefix_words, w)
    end
    local candidates = (#prefix_words <= 1) and EX_COMMANDS or BOOL_OPTS
    return vim.tbl_filter(function(c) return c:find(arglead, 1, true) == 1 end, candidates)
  end,
})

return M
