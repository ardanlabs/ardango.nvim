local ui = require('ardango.ui')

local M = {}

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

-- SignatureInStatusLine shows the element under the cursor
-- signature info on hover in the status line.
M.SignatureInStatusLine = function(wait_ms)
  local params = vim.lsp.util.make_position_params()
  local result = vim.lsp.buf_request_sync(0, "textDocument/hover", params, wait_ms)
  for _, res in pairs(result or {}) do
    for _, r in pairs(res or {}) do
      for _, elem in pairs(r or {}) do
        if elem.value ~= nil then
          local lines = elem.value:gmatch("([^\r\n]+)\r?\n?")
          -- throw away the first line of the iterator.
          lines()
          -- print the actual definition.
          local definition = lines()
          vim.schedule(function()
            print(definition)
          end)
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

-- AddTagToStruct receives a tag name and value and adds to
-- all fields inside the struct under the cursor.
-- It handles adding more values to an existing tag element.
M.AddTagsToStruct = function()
  vim.ui.input({ prompt = 'Enter tag name', default = 'json' }, function(name)
    local tag_name = name

    local callback = function(field_name)
      return snake(field_name)
    end

    vim.ui.input({ prompt = 'Enter tag value' }, function(value)
      if value and value ~= '' then
        callback = function(_)
          return value
        end
      end

      structtag.add_to_struct_tag(tag_name, callback)
    end)
  end)
end

-- AddTagToField receives a tag name and value and adds to
-- struct field under the cursor.
-- It handles adding more values to an existing tag element.
M.AddTagToField = function()
  vim.ui.input({ prompt = 'Enter tag name', default = 'json' }, function(name)
    local tag_name = name

    local callback = function(field_name)
      return snake(field_name)
    end

    vim.ui.input({ prompt = 'Enter tag value' }, function(value)
      if value and value ~= '' then
        callback = function(_)
          return value
        end
      end

      structtag.add_to_field_tag(tag_name, callback)
    end)
  end)
end

-- RemoveTagsFromStruct receives a tag name and removes the
-- element from all field tags inside the struct under the cursor.
M.RemoveTagsFromStruct = function()
  vim.ui.input({ prompt = 'Enter tag name' }, function(name)
    local tag_name = name
    structtag.remove_from_struct_tag(tag_name)
  end)
end

-- RemoveTagFromField receives a tag name and removes the
-- element from the struct field under the cursor.
M.RemoveTagFromField = function()
  vim.ui.input({ prompt = 'Enter tag name' }, function(name)
    local tag_name = name
    structtag.remove_from_field_tag(tag_name)
  end)
end


return M
