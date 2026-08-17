local ui = require('ardango.ui')
local config = require('ardango.config')

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

-- Gets the treesitter root node of a buffer.
local function get_root(bufnr)
  local parser = vim.treesitter.get_parser(bufnr, "go", {})
  local tree = parser:parse()[1]

  return tree:root()
end

local api = vim.api

-- Runs cmd, notifying when it starts and handing its combined
-- stdout/stderr to ui.show_results (merged with opts) on exit.
local function run_job(cmd, label, current_dir, opts)
  vim.notify(label .. ": running...", vim.log.levels.INFO)

  local output = {}
  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      vim.list_extend(output, data or {})
    end,
    on_stderr = function(_, data)
      vim.list_extend(output, data or {})
    end,
    on_exit = function()
      local show_opts = vim.tbl_extend("force",
        { label = label, base_dir = current_dir },
        opts or {})
      ui.show_results(output, show_opts)
    end,
  })
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

-- Build the package in the current dir, showing the results in a popup by
-- default. Same opts as RunCurrTest.
M.BuildCurrPackage = function(opts)
  local current_dir = vim.fn.expand('%:h')
  run_job("go build -o /dev/null ./" .. current_dir, "go build", current_dir, opts)
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


return M
