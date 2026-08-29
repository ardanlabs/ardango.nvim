-- Go debugging via Delve, driven through the cmd/ardango-dbg helper.
--
-- Neovim spawns two child processes and never blocks on either:
--   1. `dlv <test|debug> ... --headless --listen=127.0.0.1:0` - its stdout
--      is scanned for the "API server listening at: ADDR" line.
--   2. bin/ardango-dbg - a thin proxy (see cmd/ardango-dbg/main.go). We
--      talk to it over stdin/stdout with a newline-delimited JSON line
--      protocol: one request object per line out (via chansend), one
--      response object per line back (via jobstart's on_stdout). Every
--      response echoes its request `id`; continue/next/step/stepout
--      responses are deferred until the program next stops or exits.
--
-- All of it is async (jobstart + chansend + callbacks), so a running
-- target never freezes editing/navigation. Only one session at a time -
-- there's one set of signs and one dlv target (mirrors init.lua's
-- current_job). Every job callback closes over its own session table `s`
-- and no-ops once it's no longer the current one, so a restart can't have
-- an old session's teardown reach the new one.

local api = vim.api
local config = require('ardango.config')
local ui = require('ardango.ui')

local M = {}

-- This file is lua/ardango/debug.lua, so three :h strips lua/ardango/ and
-- the filename to give the plugin root. The Delve proxy helper (see
-- cmd/ardango-dbg) is built lazily on first use - see ensure_helper - into
-- the cache dir, so it survives a plugin reinstall and a read-only plugin
-- dir.
local PLUGIN_ROOT = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
local HELPER_SRC = PLUGIN_ROOT .. "/cmd/ardango-dbg"
local HELPER_DIR = vim.fn.stdpath("cache") .. "/ardango"
local HELPER = HELPER_DIR .. "/ardango-dbg"

local SIGN_GROUP = "ardango_dbg"
local POS_SIGN = "ardango_dbg_pos"
local BP_SIGN = "ardango_dbg_bp"
-- Fixed id for the single "stopped here" sign; well clear of the ids
-- sign_place() auto-allocates (from 1) for breakpoint signs.
local POS_SIGN_ID = 990001

vim.fn.sign_define(POS_SIGN, { text = "▶", texthl = "DiagnosticWarn", linehl = "Visual" })
vim.fn.sign_define(BP_SIGN, { text = "●", texthl = "DiagnosticError" })

-- Breakpoints persist across sessions (and can be toggled with no session
-- running). Keyed "absfile\0lnum" -> { file, line, sign_id, applied }.
-- `applied` tracks whether the current session's dlv has this breakpoint;
-- reset when a session ends, re-synced when one starts / next stops.
local breakpoints = {}

-- The one in-flight session, or nil. Fields:
--   dlv_job, helper_job - jobstart ids
--   addr        - "127.0.0.1:PORT" once parsed from dlv's stdout
--   ready       - connect ack received
--   stopping    - being torn down (suppresses "exited unexpectedly")
--   running     - a continue/next/step/stepout is outstanding
--   next_id     - request id counter
--   pending     - { [id] = function(response_table) }
--   pending_clears - clearbreak ops deferred until the target next halts
local session = nil

local function bpkey(file, line)
  return file .. "\0" .. line
end

local function short(path)
  return vim.fn.fnamemodify(path, ":~:.")
end

local function clear_position_sign()
  pcall(vim.fn.sign_unplace, SIGN_GROUP, { id = POS_SIGN_ID })
end

-- Ends session s: stops both child processes and, if it's still the
-- current session, drops the position sign and marks every breakpoint
-- un-applied so the next session re-syncs them (breakpoint signs stay put
-- - breakpoints outlive sessions). A no-op for a session that already
-- lost "current" status, so stale job callbacks can call it freely.
local function finish(s)
  if not s then
    return
  end
  s.stopping = true
  -- Drop any un-resolved response callbacks so a late line from the
  -- helper can't run one against a dead session (dispatch also guards
  -- the scheduled call with session == s).
  s.pending = {}
  if s.helper_job then
    pcall(vim.fn.jobstop, s.helper_job)
  end
  if s.dlv_job then
    pcall(vim.fn.jobstop, s.dlv_job)
  end
  if session == s then
    session = nil
    for _, bp in pairs(breakpoints) do
      bp.applied = false
    end
    -- sign_unplace is a vim.fn call - finish() can run from a job
    -- on_exit, so hop to a safe context for it.
    vim.schedule(clear_position_sign)
  end
end

-- --------------------------------------------------------------------------
-- helper I/O
-- --------------------------------------------------------------------------

-- Sends one request line to s's helper. cb, if given, is invoked (on the
-- main loop, via vim.schedule in dispatch) with the matching response.
local function send(s, req, cb)
  if not s or not s.helper_job then
    return
  end
  local id = s.next_id
  s.next_id = id + 1
  req.id = id
  if cb then
    s.pending[id] = cb
  end
  vim.fn.chansend(s.helper_job, vim.json.encode(req) .. "\n")
  return id
end

local function dispatch(s, line)
  local ok, msg = pcall(vim.json.decode, line)
  if not ok or type(msg) ~= "table" then
    return
  end
  if msg.id and s.pending[msg.id] then
    local cb = s.pending[msg.id]
    s.pending[msg.id] = nil
    -- Response handlers touch buffers/windows/signs, so hop off the
    -- (possibly fast-event) job callback context first - and bail if the
    -- session was torn down (or replaced) between now and then, so a
    -- late response can't move the cursor / re-place signs / mark
    -- breakpoints applied against a session that's gone.
    vim.schedule(function()
      if session == s then
        cb(msg)
      end
    end)
  end
end

-- Returns a jobstart on_stdout handler that reassembles the byte stream
-- (jobstart splits on "\n" and leaves the trailing partial line as the
-- final list element, continued by the next callback) and calls on_line
-- once per complete, non-empty line. Used for both the helper's JSON
-- responses and dlv's "API server listening at:" line.
local function line_reader(on_line)
  local buf = ""
  return function(_, data)
    if not data then
      return
    end
    buf = buf .. table.concat(data, "\n")
    while true do
      local nl = buf:find("\n", 1, true)
      if not nl then
        break
      end
      local line = buf:sub(1, nl - 1)
      buf = buf:sub(nl + 1)
      if line ~= "" then
        on_line(line)
      end
    end
  end
end

-- --------------------------------------------------------------------------
-- breakpoint sync
-- --------------------------------------------------------------------------

-- Pushes any not-yet-applied breakpoints to s's dlv. No-op while the
-- target is running (dlv can only set breakpoints on a halted target) -
-- they get flushed the next time it stops.
local function sync_breakpoints(s)
  if not s or not s.ready or s.running then
    return
  end
  for _, bp in pairs(breakpoints) do
    if not bp.applied then
      bp.applied = true
      send(s, { op = "break", file = bp.file, line = bp.line }, function(r)
        if not r.ok then
          bp.applied = false
          vim.notify("ardango: breakpoint " .. short(bp.file) .. ":" .. bp.line ..
            " rejected: " .. (r.error or "?"), vim.log.levels.WARN)
        end
      end)
    end
  end
end

-- Sends the clearbreak ops queued by toggle_breakpoint while the target
-- was running (dlv can only change breakpoints on a halted target). Same
-- deferred-to-next-stop treatment the add path gets in sync_breakpoints.
local function flush_pending_clears(s)
  if not s or not s.ready or s.running then
    return
  end
  local queued = s.pending_clears
  s.pending_clears = {}
  for _, c in ipairs(queued) do
    send(s, { op = "clearbreak", file = c.file, line = c.line }, function(r)
      if not r.ok then
        vim.notify("ardango: clear breakpoint " .. short(c.file) .. ":" .. c.line ..
          " failed: " .. (r.error or "?"), vim.log.levels.WARN)
      end
    end)
  end
end

-- --------------------------------------------------------------------------
-- stop location
-- --------------------------------------------------------------------------

local function open_at(file, line)
  local target = vim.fn.resolve(vim.fn.fnamemodify(file, ":p"))
  if vim.fn.resolve(api.nvim_buf_get_name(0)) ~= target then
    local ok, err = pcall(vim.cmd, "edit " .. vim.fn.fnameescape(file))
    if not ok then
      vim.notify("ardango: can't open " .. short(file) .. ": " .. err, vim.log.levels.WARN)
      return nil
    end
  end
  pcall(api.nvim_win_set_cursor, 0, { line, 0 })
  vim.cmd("normal! zz")
  return api.nvim_get_current_buf()
end

local function show_stop(s, st)
  if not st.file or st.file == "" then
    vim.notify("ardango: stopped (" .. (st.reason or "?") .. "), no source location",
      vim.log.levels.WARN)
    return
  end
  local bufnr = open_at(st.file, st.line)
  if bufnr then
    clear_position_sign()
    vim.fn.sign_place(POS_SIGN_ID, SIGN_GROUP, POS_SIGN, bufnr, { lnum = st.line, priority = 20 })
  end
  -- Breakpoint edits made while the target was running land now (clears
  -- before adds, in case the same line was toggled off then on).
  flush_pending_clears(s)
  sync_breakpoints(s)

  local where = st["function"] and (" in " .. st["function"]) or ""
  vim.notify(string.format("ardango: stopped at %s:%d (%s, goroutine %d)%s",
    short(st.file), st.line, st.reason or "?", st.goroutine or 0, where), vim.log.levels.INFO)
end

-- --------------------------------------------------------------------------
-- session lifecycle
-- --------------------------------------------------------------------------

local function connect_helper(s)
  s.helper_job = vim.fn.jobstart({ HELPER }, {
    on_stdout = line_reader(function(line) dispatch(s, line) end),
    on_stderr = function(_, d)
      local txt = table.concat(d or {}, "\n")
      if txt:gsub("%s", "") ~= "" then
        vim.schedule(function()
          vim.notify("ardango: debug helper: " .. txt, vim.log.levels.WARN)
        end)
      end
    end,
    on_exit = function()
      if session == s and not s.stopping then
        vim.schedule(function()
          vim.notify("ardango: debug helper exited unexpectedly", vim.log.levels.WARN)
        end)
      end
      finish(s)
    end,
  })

  if s.helper_job <= 0 then
    vim.notify("ardango: failed to start " .. HELPER, vim.log.levels.ERROR)
    finish(s)
    return
  end

  send(s, { op = "connect", addr = s.addr }, function(resp)
    if not resp.ok then
      vim.notify("ardango: debug connect failed: " .. (resp.error or "?"), vim.log.levels.ERROR)
      finish(s)
      return
    end
    s.ready = true
    flush_pending_clears(s)
    sync_breakpoints(s)
    vim.notify("ardango: debug session ready — :Ardango DebugContinue", vim.log.levels.INFO)
  end)
end

-- True when HELPER exists and is at least as new as every .go file in
-- cmd/ardango-dbg (so a plugin update that touches the helper triggers a
-- rebuild).
local function helper_fresh()
  if vim.fn.executable(HELPER) ~= 1 then
    return false
  end
  local bin_mtime = vim.fn.getftime(HELPER)
  for _, f in ipairs(vim.fn.glob(HELPER_SRC .. "/*.go", false, true)) do
    if vim.fn.getftime(f) > bin_mtime then
      return false
    end
  end
  return true
end

local helper_building = false
-- The single pending "run once the helper is ready" callback. Only the
-- latest matters (one debug session at a time), so a second Debug* issued
-- mid-build replaces the first rather than queueing another start.
local helper_waiter = nil

local start_session -- defined below; called once the helper is ready

-- Runs cb() once HELPER is present and up to date, building it (async, via
-- `go build`) first if needed. cb is dropped (with a notification) if the
-- build can't run or fails.
local function ensure_helper(cb)
  if helper_fresh() then
    cb()
    return
  end
  helper_waiter = cb
  if helper_building then
    return
  end
  if vim.fn.executable("go") ~= 1 then
    helper_waiter = nil
    vim.notify("ardango: the debug helper needs building but `go` isn't on PATH", vim.log.levels.ERROR)
    return
  end

  helper_building = true
  vim.fn.mkdir(HELPER_DIR, "p")
  vim.notify("ardango: building debug helper...", vim.log.levels.INFO)
  local job = vim.fn.jobstart({ "go", "build", "-o", HELPER, "./cmd/ardango-dbg" }, {
    cwd = PLUGIN_ROOT,
    on_stderr = function(_, d)
      local t = table.concat(d or {}, "\n")
      if t:gsub("%s", "") ~= "" then
        vim.schedule(function() vim.notify("ardango: go build: " .. t, vim.log.levels.WARN) end)
      end
    end,
    on_exit = function(_, code)
      helper_building = false
      local waiter = helper_waiter
      helper_waiter = nil
      vim.schedule(function()
        if code ~= 0 or vim.fn.executable(HELPER) ~= 1 then
          vim.notify("ardango: debug helper build failed (exit " .. code .. ")", vim.log.levels.ERROR)
          return
        end
        vim.notify("ardango: debug helper built", vim.log.levels.INFO)
        if waiter then
          waiter()
        end
      end)
    end,
  })

  if job <= 0 then
    helper_building = false
    helper_waiter = nil
    vim.notify("ardango: couldn't start `go build` for the debug helper", vim.log.levels.ERROR)
  end
end

-- spec = { mode = "test" | "bench" | "package", dir = <absolute buffer dir>,
--          run = <Test name> (mode "test"), bench = <Benchmark name> (mode "bench") }
-- dlv runs with its cwd set to spec.dir and `.` as the package, so the
-- caller doesn't have to reason about paths relative to Neovim's cwd.
function M.start(spec)
  if vim.fn.executable("dlv") ~= 1 then
    vim.notify("ardango: `dlv` not found on PATH — install Delve " ..
      "(https://github.com/go-delve/delve)", vim.log.levels.ERROR)
    return
  end
  ensure_helper(function() start_session(spec) end)
end

start_session = function(spec)
  if session then
    vim.notify("ardango: restarting debug session", vim.log.levels.INFO)
    M.stop()
  end

  local s = { next_id = 1, pending = {}, pending_clears = {} }
  session = s

  local wd = (spec.dir and spec.dir ~= "") and spec.dir or vim.fn.getcwd()
  local cmd = {
    "dlv", spec.mode == "package" and "debug" or "test", ".",
    "--headless", "--listen=127.0.0.1:0", "--api-version=2", "--accept-multiclient",
  }
  local dlv_args = config.options.debug and config.options.debug.dlv_args
  vim.list_extend(cmd, type(dlv_args) == "table" and dlv_args or {})
  if spec.mode == "test" then
    vim.list_extend(cmd, { "--", "-test.run", "^" .. spec.run .. "$" })
  elseif spec.mode == "bench" then
    vim.list_extend(cmd, { "--", "-test.run", "^$", "-test.bench", "^" .. spec.bench .. "$", "-test.benchmem" })
  end

  local label = spec.run or spec.bench or "package"
  vim.notify("ardango: starting dlv (" .. label .. ")...", vim.log.levels.INFO)

  s.dlv_job = vim.fn.jobstart(cmd, {
    cwd = wd,
    on_stdout = line_reader(function(line)
      local addr = line:match("API server listening at:%s+(%S+)")
      if addr and not s.addr then
        s.addr = addr
        vim.schedule(function() connect_helper(s) end)
      end
    end),
    on_stderr = function(_, data)
      local txt = table.concat(data or {}, "\n")
      if txt:gsub("%s", "") ~= "" then
        vim.schedule(function() vim.notify("ardango: dlv: " .. txt, vim.log.levels.WARN) end)
      end
    end,
    on_exit = function(_, code)
      if session == s and not s.ready and not s.stopping then
        vim.schedule(function()
          vim.notify("ardango: dlv exited before the session was ready (code " .. code .. ")",
            vim.log.levels.ERROR)
        end)
      end
      finish(s)
    end,
  })

  if s.dlv_job <= 0 then
    vim.notify("ardango: failed to launch dlv", vim.log.levels.ERROR)
    finish(s)
    return
  end

  -- Watchdog: if dlv never prints its listen address (stalled build, wrong
  -- package, ...) and hasn't exited either, don't leave a half-started
  -- session hanging silently.
  vim.defer_fn(function()
    if session == s and not s.addr and not s.stopping then
      vim.notify("ardango: dlv didn't report a listen address within 15s — giving up",
        vim.log.levels.ERROR)
      finish(s)
    end
  end, 15000)
end

function M.stop()
  if not session then
    vim.notify("ardango: no debug session", vim.log.levels.INFO)
    return
  end
  local s = session
  s.stopping = true
  session = nil
  s.pending = {}
  clear_position_sign()
  for _, bp in pairs(breakpoints) do
    bp.applied = false
  end
  if s.helper_job then
    -- Ask the helper to Halt + Detach(kill) dlv cleanly, then hard-stop
    -- both a beat later. defer_fn doesn't block.
    pcall(vim.fn.chansend, s.helper_job, vim.json.encode({ id = -1, op = "stop" }) .. "\n")
    vim.defer_fn(function()
      pcall(vim.fn.jobstop, s.helper_job)
      pcall(vim.fn.jobstop, s.dlv_job)
    end, 200)
  elseif s.dlv_job then
    -- Stopped during startup, before the helper was spawned - nothing to
    -- do gracefully, just kill dlv now.
    pcall(vim.fn.jobstop, s.dlv_job)
  end
  vim.notify("ardango: debug session stopped", vim.log.levels.INFO)
end

-- --------------------------------------------------------------------------
-- run control
-- --------------------------------------------------------------------------

-- next/step/stepout should return promptly; if one doesn't, assume the
-- response was lost (rather than the program legitimately taking a while,
-- as `continue` can) and unstick the session instead of wedging `running`
-- true forever. `continue` gets no timeout.
local STEP_TIMEOUT_MS = 30000

local function run_cmd(op)
  local s = session
  if not s or not s.ready then
    vim.notify("ardango: no debug session — start with :Ardango DebugCurrTest", vim.log.levels.WARN)
    return
  end
  if s.running then
    vim.notify("ardango: debug target is still running", vim.log.levels.WARN)
    return
  end
  s.running = true

  local settled = false
  local id
  id = send(s, { op = op }, function(resp)
    if settled then
      return
    end
    settled = true
    s.running = false
    if not resp.ok then
      vim.notify("ardango: " .. op .. " failed: " .. (resp.error or "?"), vim.log.levels.ERROR)
      return
    end
    if resp.terminated then
      vim.notify(string.format("ardango: program exited (status %d)", resp.terminated.exitStatus),
        vim.log.levels.INFO)
      if session == s then
        M.stop()
      end
      return
    end
    if resp.stopped then
      show_stop(s, resp.stopped)
    end
  end)

  if op ~= "continue" then
    vim.defer_fn(function()
      if settled or session ~= s then
        return
      end
      settled = true
      s.pending[id] = nil
      s.running = false
      vim.notify("ardango: " .. op .. " timed out after " .. (STEP_TIMEOUT_MS / 1000) ..
        "s — session may be wedged, :Ardango DebugStop to reset", vim.log.levels.ERROR)
    end, STEP_TIMEOUT_MS)
  end
end

function M.continue() run_cmd("continue") end

function M.step_over() run_cmd("next") end

function M.step_into() run_cmd("step") end

function M.step_out() run_cmd("stepout") end

-- --------------------------------------------------------------------------
-- inspection (eval / locals / stack) - all halted-target only
-- --------------------------------------------------------------------------

local function inspect_ok(s)
  if not s or not s.ready then
    vim.notify("ardango: no debug session — start with :Ardango DebugCurrTest", vim.log.levels.WARN)
    return false
  end
  if s.running then
    vim.notify("ardango: debug target is still running", vim.log.levels.WARN)
    return false
  end
  return true
end

-- Evaluates {expr} (default: the <cexpr> under the cursor - `p`, `p.Name`,
-- `xs[i]`, ...) in the current stack frame and shows Delve's rendering of
-- the value in a floating window, the way vim.lsp.buf.hover() shows hover
-- text. Only works while the target is halted.
function M.eval(expr)
  local s = session
  if not inspect_ok(s) then
    return
  end

  expr = (expr and expr ~= "") and expr or vim.fn.expand("<cexpr>")
  if expr == "" then
    vim.notify("ardango: no expression under the cursor", vim.log.levels.WARN)
    return
  end

  send(s, { op = "eval", expr = expr, frame = 0 }, function(resp)
    if not resp.ok then
      vim.notify("ardango: eval " .. expr .. ": " .. (resp.error or "?"), vim.log.levels.WARN)
      return
    end
    local lines = resp.lines or {}
    if #lines == 0 then
      lines = { "(no value)" }
    end
    table.insert(lines, 1, expr)
    vim.lsp.util.open_floating_preview(lines, "go", {
      border = config.options.popup.border,
      focus = false,
      focusable = true,
    })
  end)
end

-- Own popup state so DebugLocals/DebugStack don't unmount (or get
-- unmounted by) the shared test/build results popup.
local inspect_popup_state = { bufnr = nil, popup = nil }

-- DebugLocals: the current frame's args + locals, in a popup.
function M.locals()
  local s = session
  if not inspect_ok(s) then
    return
  end
  send(s, { op = "locals", frame = 0 }, function(resp)
    if not resp.ok then
      vim.notify("ardango: locals: " .. (resp.error or "?"), vim.log.levels.WARN)
      return
    end
    ui.show_popup(resp.lines or { "(no variables in scope)" }, vim.fn.getcwd(), inspect_popup_state)
  end)
end

-- DebugStack: the current goroutine's call stack, in a popup. Lines lead
-- with file:line so the popup's <CR> jumps to the frame.
function M.stack()
  local s = session
  if not inspect_ok(s) then
    return
  end
  send(s, { op = "stack", depth = 50 }, function(resp)
    if not resp.ok then
      vim.notify("ardango: stack: " .. (resp.error or "?"), vim.log.levels.WARN)
      return
    end
    ui.show_popup(resp.lines or { "(empty stack)" }, vim.fn.getcwd(), inspect_popup_state)
  end)
end

-- --------------------------------------------------------------------------
-- breakpoints
-- --------------------------------------------------------------------------

function M.toggle_breakpoint()
  local file = vim.fn.expand("%:p")
  if file == "" then
    vim.notify("ardango: no file in the current buffer", vim.log.levels.WARN)
    return
  end
  local line = api.nvim_win_get_cursor(0)[1]
  local key = bpkey(file, line)
  local bufnr = api.nvim_get_current_buf()

  local existing = breakpoints[key]
  if existing then
    breakpoints[key] = nil
    if existing.sign_id then
      pcall(vim.fn.sign_unplace, SIGN_GROUP, { id = existing.sign_id })
    end
    -- Only needs an RPC if dlv actually has it (existing.applied). Send
    -- now if the target's halted, otherwise queue it for the next stop -
    -- dropping it here would leave a live, invisible breakpoint.
    if session and existing.applied then
      if session.ready and not session.running then
        send(session, { op = "clearbreak", file = file, line = line }, function(r)
          if not r.ok then
            vim.notify("ardango: clear breakpoint failed: " .. (r.error or "?"), vim.log.levels.WARN)
          end
        end)
      else
        table.insert(session.pending_clears, { file = file, line = line })
      end
    end
    vim.notify(string.format("ardango: breakpoint removed %s:%d", short(file), line), vim.log.levels.INFO)
    return
  end

  local sign_id = vim.fn.sign_place(0, SIGN_GROUP, BP_SIGN, bufnr, { lnum = line, priority = 10 })
  breakpoints[key] = { file = file, line = line, sign_id = sign_id, applied = false }
  sync_breakpoints(session)
  local tail = (session and session.running) and " (applies when the target next stops)" or ""
  vim.notify(string.format("ardango: breakpoint set %s:%d%s", short(file), line, tail), vim.log.levels.INFO)
end

api.nvim_create_autocmd("VimLeavePre", {
  callback = function()
    local s = session
    if not s then
      return
    end
    s.stopping = true
    if s.helper_job then
      -- Give the helper up to 500ms to Halt + Detach(kill) dlv cleanly so
      -- the compiled test binary doesn't outlive the editor; then hard-stop.
      pcall(vim.fn.chansend, s.helper_job, vim.json.encode({ id = -1, op = "stop" }) .. "\n")
      pcall(vim.fn.jobwait, { s.helper_job }, 500)
      pcall(vim.fn.jobstop, s.helper_job)
    end
    pcall(vim.fn.jobstop, s.dlv_job)
  end,
})

return M
