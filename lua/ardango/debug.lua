-- Go debugging via Delve, driven through the cmd/ardango-dbg helper.
--
-- Neovim spawns two child processes and never blocks on either:
--   1. `dlv <test|debug> ... --headless --listen=127.0.0.1:0` - its stdout
--      is scanned for the "API server listening at: ADDR" line.
--   2. the ardango-dbg helper - a thin proxy (see cmd/ardango-dbg/main.go). We
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
local POS_SIGN = "ardango_dbg_pos"     -- execution stopped here (frame 0)
local FRAME_SIGN = "ardango_dbg_frame" -- inspecting a caller frame (frame > 0)
local BP_SIGN = "ardango_dbg_bp"
-- One fixed id for whichever of POS_SIGN/FRAME_SIGN is currently placed;
-- well clear of the ids sign_place() auto-allocates (from 1) for
-- breakpoint signs.
local POS_SIGN_ID = 990001

vim.fn.sign_define(POS_SIGN, { text = "▶", texthl = "DiagnosticWarn", linehl = "Visual" })
vim.fn.sign_define(FRAME_SIGN, { text = "▷", texthl = "DiagnosticHint" })
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
--   frame       - stack frame locals/eval operate in (0 = innermost)
--   frames      - cached [{file,line,function}] for the current stop, or
--                 nil (fetched lazily, invalidated on the next stop)
local session = nil

local function bpkey(file, line)
  return file .. "\0" .. line
end

-- Shortens a path for display: relative to cwd/$HOME when it's under one,
-- otherwise just the basename (stdlib / module-cache frames are usually
-- outside both and their full path swamps a popup line).
local function short(path)
  if not path or path == "" then
    return "?"
  end
  local s = vim.fn.fnamemodify(path, ":~:.")
  if s:sub(1, 1) == "/" then
    return vim.fn.fnamemodify(path, ":t")
  end
  return s
end

local function clear_position_sign()
  pcall(vim.fn.sign_unplace, SIGN_GROUP, { id = POS_SIGN_ID })
end

-- Nudges anything showing debug_status() (statusline, winbar, lualine, ...)
-- to re-render, and fires a `User ArdangoDebug` autocmd for custom hooks.
local function status_changed()
  vim.schedule(function()
    pcall(vim.cmd, "redrawstatus")
    pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "ArdangoDebug" })
  end)
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
  if s.dlv_bin then
    -- dlv usually removes its own --output binary; clean up if it was killed.
    vim.defer_fn(function() pcall(vim.fn.delete, s.dlv_bin) end, 500)
  end
  if session == s then
    session = nil
    for _, bp in pairs(breakpoints) do
      bp.applied = false
    end
    -- sign_unplace is a vim.fn call - finish() can run from a job
    -- on_exit, so hop to a safe context for it.
    vim.schedule(clear_position_sign)
    status_changed()
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
  -- pcall: the helper job may have just died (its on_exit is scheduled,
  -- not synchronous), and chansend on a closed channel throws.
  pcall(vim.fn.chansend, s.helper_job, vim.json.encode(req) .. "\n")
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

-- True when dlv's error means the line fundamentally can't hold a
-- breakpoint (blank, comment, `}`, a declaration, ...) rather than a
-- transient failure (connection lost mid-teardown, ...). Only the former
-- should make us drop the breakpoint; the latter is worth a retry.
local function is_unbreakable(err)
  err = (err or ""):lower()
  return err:find("could not find", 1, true) ~= nil
      or err:find("no statement", 1, true) ~= nil
      or err:find("no line ", 1, true) ~= nil
      or err:find("not found", 1, true) ~= nil
end

-- Drops a breakpoint dlv won't accept: unplace its sign, forget it, and
-- tell the user why. The mark is gone, so the ERROR is the only feedback.
local function reject_bp(bp, reason)
  local k = bpkey(bp.file, bp.line)
  if breakpoints[k] == bp then
    breakpoints[k] = nil
  end
  if bp.sign_id then
    pcall(vim.fn.sign_unplace, SIGN_GROUP, { id = bp.sign_id })
  end
  vim.notify(string.format("ardango: can't break at %s:%d — %s",
    short(bp.file), bp.line, reason or "?"), vim.log.levels.ERROR)
end

-- How many "no statement on that line" replies from dlv to tolerate -
-- stepping forward one line each time - before giving up on a breakpoint.
-- (Blank / comment lines are skipped locally and don't count.)
local MAX_SNAP_TRIES = 5

-- Reads bp.file's lines from the loaded buffer, else off disk, else {}.
local function file_lines(path)
  local buf = vim.fn.bufnr(path)
  if buf ~= -1 and api.nvim_buf_is_loaded(buf) then
    return api.nvim_buf_get_lines(buf, 0, -1, false)
  end
  return vim.fn.filereadable(path) == 1 and vim.fn.readfile(path) or {}
end

-- Moves bp (sign + breakpoints[] key) to newline, in place. Returns false
-- if a different breakpoint already sits there.
local function move_bp(bp, newline)
  local newk = bpkey(bp.file, newline)
  if breakpoints[newk] and breakpoints[newk] ~= bp then
    return false
  end
  local oldk = bpkey(bp.file, bp.line)
  if breakpoints[oldk] == bp then
    breakpoints[oldk] = nil
  end
  bp.line = newline
  breakpoints[newk] = bp
  local buf = vim.fn.bufnr(bp.file)
  if bp.sign_id then
    pcall(vim.fn.sign_unplace, SIGN_GROUP, { id = bp.sign_id })
    bp.sign_id = nil
  end
  if buf ~= -1 and api.nvim_buf_is_loaded(buf) then
    local ok, sid = pcall(vim.fn.sign_place, 0, SIGN_GROUP, BP_SIGN, buf,
      { lnum = newline, priority = 10 })
    bp.sign_id = ok and sid or nil
  end
  return true
end

-- Applies bp to s's dlv, snapping forward to the next line that can hold a
-- breakpoint when bp.line can't. Obviously-blank / comment lines are
-- skipped locally; every other line costs one dlv round-trip, and after
-- MAX_SNAP_TRIES rejections it gives up. dlv may itself land the
-- breakpoint past the requested line; the reported line wins. Calls
-- cb(ok, err, exhausted): ok once dlv takes it (bp.line/key/sign already
-- moved to the landing line);
-- exhausted true when the snap ran out of tries (a transient error leaves
-- exhausted false, so the caller can retry).
local function apply_bp(s, bp, cb)
  local lines = file_lines(bp.file)

  local function try(n, tries)
    while lines[n] ~= nil do
      local t = vim.trim(lines[n])
      if t == "" or t:sub(1, 2) == "//" then
        n = n + 1
      else
        break
      end
    end
    send(s, { op = "break", file = bp.file, line = n, cond = bp.cond }, function(r)
      if r.ok then
        -- dlv reports the line it actually planted the breakpoint on - it
        -- can snap past our n to the next line with instructions. Trust
        -- that over n, so the sign / key sit where execution really stops.
        local landed = (r.breakpoint and r.breakpoint.line) or n
        if landed ~= bp.line and not move_bp(bp, landed) then
          reject_bp(bp, "snapped to line " .. landed .. ", which already has a breakpoint")
          return
        end
        cb(true)
      elseif not is_unbreakable(r.error) then
        cb(false, r.error, false)
      elseif tries + 1 >= MAX_SNAP_TRIES then
        cb(false, "no breakable line found (gave up after " .. MAX_SNAP_TRIES .. " tries)", true)
      else
        try(n + 1, tries + 1)
      end
    end)
  end

  try(bp.line, 0)
end

-- Pushes any not-yet-applied breakpoints to s's dlv. No-op while the
-- target is running (dlv can only set breakpoints on a halted target) -
-- they get flushed the next time it stops. A breakpoint on an unbreakable
-- line snaps forward to the next statement (see apply_bp); if there's no
-- statement in range it's dropped (sign and all), and any other failure
-- just leaves it un-applied to retry on the next stop.
local function sync_breakpoints(s)
  if not s or not s.ready or s.running then
    return
  end
  for _, bp in pairs(breakpoints) do
    if not bp.applied then
      bp.applied = true
      apply_bp(s, bp, function(ok, err, exhausted)
        if ok then
          return
        end
        if exhausted then
          reject_bp(bp, err)
        else
          bp.applied = false
          vim.notify("ardango: breakpoint " .. short(bp.file) .. ":" .. bp.line ..
            " not set — " .. (err or "?"), vim.log.levels.WARN)
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

-- Delve reports every next/step/stepout stop as "next finished" - useless
-- to show. Only surface a reason when it tells the user something.
local INTERESTING_REASON = {
  breakpoint = true,
  ["hardcoded breakpoint"] = true,
  panic = true,
  ["fatal error"] = true,
  ["manual stop"] = true,
  ["goroutine switch"] = true,
}

-- Jumps to file:line and puts the ▶ position sign there. Clears the old
-- position/frame sign even when the source can't be opened, so a stale ▶
-- never lingers at a location execution has left.
local function place_stop_sign(file, line)
  clear_position_sign()
  if not file or file == "" then
    return
  end
  local bufnr = open_at(file, line)
  if bufnr then
    vim.fn.sign_place(POS_SIGN_ID, SIGN_GROUP, POS_SIGN, bufnr, { lnum = line, priority = 20 })
  end
end

local function show_stop(s, st)
  -- A fresh stop invalidates any frame the user had navigated to.
  s.frame = 0
  s.frames = nil
  s.goroutine = st.goroutine

  -- The one-shot entry breakpoint has done its job.
  local was_entry = s.entry_bp ~= nil
  if s.entry_bp then
    local eb = s.entry_bp
    s.entry_bp = nil
    send(s, { op = "clearbreak", file = eb.file, line = eb.line }, function() end)
  end

  if not st.file or st.file == "" then
    s.loc = nil
    clear_position_sign()
    status_changed()
    vim.notify("ardango: stopped (" .. (st.reason or "?") .. "), no source location",
      vim.log.levels.WARN)
    return
  end
  s.loc = { file = st.file, line = st.line, func = st["function"] }
  status_changed()
  place_stop_sign(st.file, st.line)
  -- Breakpoint edits made while the target was running land now (clears
  -- before adds, in case the same line was toggled off then on).
  flush_pending_clears(s)
  sync_breakpoints(s)

  local reason
  if was_entry then
    reason = "entry, "
  else
    reason = (st.reason and INTERESTING_REASON[st.reason]) and (st.reason .. ", ") or ""
  end
  local where = st["function"] and (" in " .. st["function"]) or ""
  vim.notify(string.format("ardango: stopped at %s:%d (%sgoroutine %d)%s",
    short(st.file), st.line, reason, st.goroutine or 0, where), vim.log.levels.INFO)
end

-- --------------------------------------------------------------------------
-- session lifecycle
-- --------------------------------------------------------------------------

local run_cmd -- defined in "run control" below; used for the entry stop

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
    status_changed()
    flush_pending_clears(s)
    sync_breakpoints(s)

    if s.entry then
      -- Land on the first line of the debugged function, the way an IDE
      -- "debug this test" does. A temporary breakpoint, cleared on the
      -- first stop (see show_stop).
      send(s, { op = "break", file = s.entry.file, line = s.entry.line }, function(bp)
        if not bp.ok then
          vim.notify("ardango: couldn't set the entry breakpoint (" .. (bp.error or "?") ..
            ") — set one yourself, then :ArdangoDebug continue", vim.log.levels.WARN)
          return
        end
        s.entry_bp = { file = s.entry.file, line = s.entry.line }
        run_cmd("continue")
      end)
    else
      vim.notify("ardango: debug session ready — set a breakpoint " ..
        "(:ArdangoDebug break), then :ArdangoDebug continue", vim.log.levels.INFO)
    end
  end)
end

-- User-configured extra environment for the child processes that compile
-- Go (the `dlv` session and the helper's `go build`). Returns nil when
-- none is set, so jobstart just inherits Neovim's environment; otherwise
-- a name->value map jobstart merges over it. Chiefly for NixOS, where
-- cgo hardening breaks Delve's unoptimised build of the target
-- ("_FORTIFY_SOURCE requires compiling with optimization") - a
-- { CGO_ENABLED = "0" } or { CGO_CFLAGS = "-O2" } sidesteps it.
local function debug_env()
  local e = config.options.debug and config.options.debug.env
  if type(e) == "table" and next(e) then
    return e
  end
  return nil
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
  status_changed()
  vim.fn.mkdir(HELPER_DIR, "p")
  vim.notify("ardango: building debug helper...", vim.log.levels.INFO)
  local job = vim.fn.jobstart({ "go", "build", "-o", HELPER, "./cmd/ardango-dbg" }, {
    cwd = PLUGIN_ROOT,
    env = debug_env(),
    on_stderr = function(_, d)
      local t = table.concat(d or {}, "\n")
      if t:gsub("%s", "") ~= "" then
        vim.schedule(function() vim.notify("ardango: go build: " .. t, vim.log.levels.WARN) end)
      end
    end,
    on_exit = function(_, code)
      helper_building = false
      status_changed()
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

  local s = { next_id = 1, pending = {}, pending_clears = {}, frame = 0, entry = spec.entry }
  session = s

  local wd = (spec.dir and spec.dir ~= "") and spec.dir or vim.fn.getcwd()
  -- --output puts the compiled debug binary in a tempdir instead of the
  -- package dir, so a hard-killed dlv can't leave a debug.test* turd in
  -- the user's tree.
  s.dlv_bin = vim.fn.tempname()
  local cmd = {
    "dlv", spec.mode == "package" and "debug" or "test", ".",
    "--headless", "--listen=127.0.0.1:0", "--api-version=2", "--accept-multiclient",
    "--output", s.dlv_bin,
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
    env = debug_env(),
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
    vim.notify("ardango: no debug session to stop", vim.log.levels.INFO)
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
  status_changed()
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

run_cmd = function(op)
  local s = session
  if not s or not s.ready then
    vim.notify("ardango: no debug session — start with :ArdangoDebug test", vim.log.levels.WARN)
    return
  end
  if s.running then
    vim.notify("ardango: debug target is still running", vim.log.levels.WARN)
    return
  end
  s.running = true
  status_changed()

  local settled = false
  local id
  id = send(s, { op = op }, function(resp)
    if settled then
      return
    end
    settled = true
    s.running = false
    status_changed()
    if not resp.ok then
      local err = resp.error or "?"
      -- Stepping off the top of the stack is a boundary, not a failure.
      if op == "stepout" and err:find("nothing to stepout to", 1, true) then
        vim.notify("ardango: at the top of the call stack — nothing to step out to",
          vim.log.levels.INFO)
      else
        vim.notify("ardango: " .. op .. " failed: " .. err, vim.log.levels.ERROR)
      end
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
      status_changed()
      vim.notify("ardango: " .. op .. " timed out after " .. (STEP_TIMEOUT_MS / 1000) ..
        "s — session may be wedged, :ArdangoDebug stop to reset", vim.log.levels.ERROR)
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
    vim.notify("ardango: no debug session — start with :ArdangoDebug test", vim.log.levels.WARN)
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

  send(s, { op = "eval", expr = expr, frame = s.frame }, function(resp)
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

-- Evaluates the last Visual-mode selection (e.g. `p.Items[i].Name`).
-- Meant for an x-mode keymap that <Esc>s first so the '</'> marks are set.
function M.eval_visual()
  local a = vim.fn.getpos("'<")
  local b = vim.fn.getpos("'>")
  local ok, region = pcall(vim.fn.getregion, a, b, { type = vim.fn.visualmode() })
  local text
  if ok and region and #region > 0 then
    text = table.concat(region, "")
  else
    -- Fallback for older Neovim without getregion: single-line span.
    local l = vim.fn.getline(a[2])
    text = l:sub(a[3], b[3])
  end
  M.eval(vim.trim(text or ""))
end

-- Own popup state so locals/stack don't unmount (or get
-- unmounted by) the shared test/build results popup.
local inspect_popup_state = { bufnr = nil, popup = nil }

-- locals: the current frame's args + locals, in a popup. Each value is
-- capped for the list view - eval <name> shows the full thing.
local LOCALS_LINE_CAP = 200

function M.locals()
  local s = session
  if not inspect_ok(s) then
    return
  end
  send(s, { op = "locals", frame = s.frame }, function(resp)
    if not resp.ok then
      vim.notify("ardango: locals: " .. (resp.error or "?"), vim.log.levels.WARN)
      return
    end
    local lines = resp.lines or { "(no variables in scope)" }
    for i, l in ipairs(lines) do
      if #l > LOCALS_LINE_CAP then
        lines[i] = l:sub(1, LOCALS_LINE_CAP) .. " …"
      end
    end
    ui.show_popup(lines, vim.fn.getcwd(), inspect_popup_state)
  end)
end

-- --------------------------------------------------------------------------
-- stack frames
-- --------------------------------------------------------------------------

-- Calls cb(frames) with the current stop's call stack, fetching it once
-- and caching it on the session (show_stop clears s.frames on each stop).
local function with_frames(s, cb)
  if s.frames then
    cb(s.frames)
    return
  end
  send(s, { op = "stack", depth = 100 }, function(resp)
    if not resp.ok then
      vim.notify("ardango: stack: " .. (resp.error or "?"), vim.log.levels.WARN)
      return
    end
    s.frames = resp.frames or {}
    cb(s.frames)
  end)
end

-- Moves the inspection frame to n: jumps the cursor there and swaps the
-- position sign (▶ for frame 0, ▷ for a caller frame). Subsequent
-- locals/eval then operate in that frame.
local function goto_frame(s, n)
  local f = s.frames[n + 1]
  if not f then
    return
  end
  s.frame = n
  local bufnr = (f.file ~= "" and f.file ~= nil) and open_at(f.file, f.line) or nil
  clear_position_sign()
  if bufnr then
    vim.fn.sign_place(POS_SIGN_ID, SIGN_GROUP, n == 0 and POS_SIGN or FRAME_SIGN, bufnr,
      { lnum = f.line, priority = 20 })
  end
  s.loc = { file = f.file, line = f.line, func = f["function"] }
  status_changed()
  local loc = (f.file ~= "" and f.file ~= nil) and (" (" .. short(f.file) .. ":" .. f.line .. ")")
      or " (no source)"
  vim.notify(string.format("ardango: frame #%d/%d: %s%s", n, #s.frames - 1, f["function"] or "?", loc),
    vim.log.levels.INFO)
end

-- stack: the current goroutine's call stack, in a popup. <CR> on a
-- frame line selects it (locals/eval then operate there, cursor
-- + sign move); the current one is marked "←".
function M.stack()
  local s = session
  if not inspect_ok(s) then
    return
  end
  with_frames(s, function(frames)
    local lines = {}
    for i, f in ipairs(frames) do
      lines[i] = string.format("%s:%d:  #%d  %s%s", short(f.file), f.line, i - 1,
        f["function"] or "?", (i - 1 == s.frame) and "  ←" or "")
    end
    if #lines == 0 then
      lines = { "(empty stack)" }
    end
    ui.show_popup(lines, vim.fn.getcwd(), inspect_popup_state, {
      on_enter = function(_, lnum, close)
        if s.frames and s.frames[lnum] then
          close()
          goto_frame(s, lnum - 1)
        end
      end,
    })
  end)
end

-- frame_up/frame_down: move toward the caller / callee.
function M.frame_up()
  local s = session
  if not inspect_ok(s) then
    return
  end
  with_frames(s, function(frames)
    if s.frame + 1 < #frames then
      goto_frame(s, s.frame + 1)
    else
      vim.notify("ardango: already at the outermost frame", vim.log.levels.INFO)
    end
  end)
end

function M.frame_down()
  local s = session
  if not inspect_ok(s) then
    return
  end
  with_frames(s, function()
    if s.frame > 0 then
      goto_frame(s, s.frame - 1)
    else
      vim.notify("ardango: already at the innermost frame", vim.log.levels.INFO)
    end
  end)
end

-- frame {n}: jump straight to frame n.
function M.frame(n)
  local s = session
  if not inspect_ok(s) then
    return
  end
  local num = tonumber(n)
  if not num or num ~= math.floor(num) then
    vim.notify("ardango: :ArdangoDebug frame needs a frame number (see :ArdangoDebug stack)",
      vim.log.levels.WARN)
    return
  end
  with_frames(s, function(frames)
    if num >= 0 and num < #frames then
      goto_frame(s, num)
    else
      vim.notify("ardango: no frame #" .. num .. " (stack is " .. #frames .. " deep)",
        vim.log.levels.WARN)
    end
  end)
end

-- --------------------------------------------------------------------------
-- goroutines
-- --------------------------------------------------------------------------

-- Frames Delve reports for a parked goroutine start deep in the runtime
-- scheduler; a user switching goroutines wants their own code. Returns
-- the index of the first frame that's in a source file on disk and not
-- part of the runtime/stdlib/test harness, or 0 if there's no such frame.
local function first_user_frame(frames)
  for i, f in ipairs(frames) do
    local file = f.file
    if file and file ~= ""
        and not file:match("/src/runtime/")
        and not file:match("/src/testing/")
        and not file:match("/src/sync/")
        and not file:match("_testmain%.go$")
        and vim.fn.filereadable(file) == 1 then
      return i - 1
    end
  end
  return 0
end

-- goroutines: goroutines with their user-code location, in a popup.
-- <CR> switches to the one under the cursor. Pure-runtime goroutines
-- (parked in runtime.*, no user frame) are hidden behind a "[+N runtime]"
-- line - press `a`, or `:ArdangoDebug goroutines all`, to show them.
function M.goroutines(opts)
  opts = opts or {}
  local s = session
  if not inspect_ok(s) then
    return
  end
  send(s, { op = "goroutines" }, function(resp)
    if not resp.ok then
      vim.notify("ardango: goroutines: " .. (resp.error or "?"), vim.log.levels.WARN)
      return
    end

    local gs, hidden = {}, 0
    for _, g in ipairs(resp.goroutines or {}) do
      local runtime_only = (not g.file or g.file == "")
          or (g["function"] or ""):match("^runtime%.") ~= nil
      if opts.all or g.current or not runtime_only then
        gs[#gs + 1] = g
      else
        hidden = hidden + 1
      end
    end

    local lines = {}
    for i, g in ipairs(gs) do
      local loc = (g.file ~= "" and g.file ~= nil) and (short(g.file) .. ":" .. g.line .. ":")
          or "(no source):"
      lines[i] = string.format("%s  goroutine %d  [%s]  %s%s", loc, g.id, g.status,
        g["function"] or "?", g.current and "  ←" or "")
    end
    if hidden > 0 then
      lines[#lines + 1] = string.format("  … [+%d runtime]  (a: show all)", hidden)
    end
    if resp.truncated then
      lines[#lines + 1] = "  … (more goroutines not shown)"
    end
    if #lines == 0 then
      lines = { "(no goroutines)" }
    end

    ui.show_popup(lines, vim.fn.getcwd(), inspect_popup_state, {
      on_enter = function(_, lnum, close)
        local g = gs[lnum]
        if g and g.id then
          close()
          M.switch_goroutine(g.id)
        end
      end,
      keymaps = {
        a = function(_, _, close)
          close()
          M.goroutines({ all = true })
        end,
      },
    })
  end)
end

-- goroutine {id}: make goroutine {id} the selected one, and land on
-- its first user frame (not the runtime frame it's parked in). Locals/
-- eval/stack then reflect it.
function M.switch_goroutine(id)
  local s = session
  if not inspect_ok(s) then
    return
  end
  local gid = tonumber(id)
  if not gid or gid ~= math.floor(gid) then
    vim.notify("ardango: :ArdangoDebug goroutine needs a goroutine id (see :ArdangoDebug goroutines)",
      vim.log.levels.WARN)
    return
  end
  send(s, { op = "switchgoroutine", goroutine = gid }, function(resp)
    if not resp.ok then
      vim.notify("ardango: switch to goroutine " .. gid .. ": " .. (resp.error or "?"),
        vim.log.levels.WARN)
      return
    end
    s.frame = 0
    s.frames = nil
    s.goroutine = resp.stopped and resp.stopped.goroutine or gid
    vim.notify("ardango: switched to goroutine " .. s.goroutine, vim.log.levels.INFO)
    with_frames(s, function(frames)
      goto_frame(s, first_user_frame(frames))
    end)
  end)
end

-- --------------------------------------------------------------------------
-- breakpoints
-- --------------------------------------------------------------------------

-- Removes the breakpoint identified by key: drops its sign, forgets it,
-- and tells a live dlv (or queues the clear for the next stop).
local function remove_bp(key)
  local bp = breakpoints[key]
  if not bp then
    return
  end
  breakpoints[key] = nil
  if bp.sign_id then
    pcall(vim.fn.sign_unplace, SIGN_GROUP, { id = bp.sign_id })
  end
  -- Only needs an RPC if dlv actually has it (bp.applied). Send now if
  -- the target's halted, else queue for the next stop - dropping it here
  -- would leave a live, invisible breakpoint.
  if session and bp.applied then
    if session.ready and not session.running then
      send(session, { op = "clearbreak", file = bp.file, line = bp.line }, function(r)
        if not r.ok then
          vim.notify("ardango: clear breakpoint failed: " .. (r.error or "?"), vim.log.levels.WARN)
        end
      end)
    else
      table.insert(session.pending_clears, { file = bp.file, line = bp.line })
    end
  end
end

-- Toggle a breakpoint on the current line. With {cond} (a Go boolean
-- expression), set/replace a conditional breakpoint instead of toggling -
-- ":ArdangoDebug break x > 5". With a halted session, dlv validates the
-- line right away: the breakpoint snaps forward to the next real
-- statement if the cursor line has none, or errors out (no sign left) if
-- there's nothing in range. Without a session that check waits until one
-- starts (see sync_breakpoints).
function M.toggle_breakpoint(cond)
  local file = vim.fn.expand("%:p")
  if file == "" then
    vim.notify("ardango: no file in the current buffer", vim.log.levels.WARN)
    return
  end
  cond = (cond and cond ~= "") and cond or nil
  local line = api.nvim_win_get_cursor(0)[1]
  local key = bpkey(file, line)
  local bufnr = api.nvim_get_current_buf()

  if breakpoints[key] then
    if not cond then
      remove_bp(key)
      vim.notify(string.format("ardango: breakpoint removed %s:%d", short(file), line), vim.log.levels.INFO)
      return
    end
    -- Re-set with the new condition.
    remove_bp(key)
  end

  local function place_sign(lnum)
    local ok, sid = pcall(vim.fn.sign_place, 0, SIGN_GROUP, BP_SIGN, bufnr,
      { lnum = lnum, priority = 10 })
    return ok and sid or nil
  end
  local condtxt = cond and (" if " .. cond) or ""

  -- Halted session: let dlv place it (and snap / reject) before we mark
  -- anything, so a bad line never leaves a stray sign.
  if session and session.ready and not session.running then
    local bp = { file = file, line = line, sign_id = nil, applied = true, cond = cond }
    breakpoints[key] = bp
    apply_bp(session, bp, function(ok, err, exhausted)
      if breakpoints[bpkey(bp.file, bp.line)] ~= bp then
        return -- already removed (toggled off, or a snap collision)
      end
      if ok then
        if not bp.sign_id then
          bp.sign_id = place_sign(bp.line)
        end
        local moved = bp.line ~= line and (" (snapped from line " .. line .. ")") or ""
        vim.notify(string.format("ardango: breakpoint set %s:%d%s%s",
          short(bp.file), bp.line, condtxt, moved), vim.log.levels.INFO)
      elseif exhausted then
        reject_bp(bp, err)
      else
        bp.applied = false
        bp.sign_id = bp.sign_id or place_sign(bp.line)
        vim.notify("ardango: breakpoint " .. short(bp.file) .. ":" .. bp.line ..
          " not set — " .. (err or "?"), vim.log.levels.WARN)
      end
    end)
    return
  end

  -- No session (or target running): mark optimistically; sync_breakpoints
  -- validates (and snaps / drops) when a session next halts.
  breakpoints[key] = { file = file, line = line, sign_id = place_sign(line), applied = false, cond = cond }
  sync_breakpoints(session)
  local tail = (session and session.running) and " (applies when the target next stops)" or ""
  vim.notify(string.format("ardango: breakpoint set %s:%d%s%s", short(file), line,
    condtxt, tail), vim.log.levels.INFO)
end

-- Sorted list of breakpoint records with the source line read in for
-- display: { file, line, key, text }.
local function bp_records()
  local recs = {}
  local file_cache = {}
  for key, bp in pairs(breakpoints) do
    local lines = file_cache[bp.file]
    if lines == nil then
      local loaded = vim.fn.bufnr(bp.file)
      if loaded ~= -1 and api.nvim_buf_is_loaded(loaded) then
        lines = api.nvim_buf_get_lines(loaded, 0, -1, false)
      else
        lines = vim.fn.filereadable(bp.file) == 1 and vim.fn.readfile(bp.file) or {}
      end
      file_cache[bp.file] = lines
    end
    recs[#recs + 1] = {
      file = bp.file,
      line = bp.line,
      key = key,
      cond = bp.cond,
      text = vim.trim(lines[bp.line] or "") .. (bp.cond and ("   [if " .. bp.cond .. "]") or ""),
    }
  end
  table.sort(recs, function(a, b)
    if a.file ~= b.file then
      return a.file < b.file
    end
    return a.line < b.line
  end)
  return recs
end

local function jump_to_bp(r)
  pcall(vim.cmd, "edit " .. vim.fn.fnameescape(r.file))
  pcall(api.nvim_win_set_cursor, 0, { r.line, 0 })
  vim.cmd("normal! zz")
end

-- Telescope breakpoint picker: fuzzy list + source preview, <CR> opens,
-- <C-d> deletes. Returns false (caller falls back to the popup) if
-- telescope.nvim isn't installed.
local function breakpoints_telescope(recs)
  local ok_p, pickers = pcall(require, "telescope.pickers")
  local ok_f, finders = pcall(require, "telescope.finders")
  local ok_c, tconf = pcall(require, "telescope.config")
  local ok_a, actions = pcall(require, "telescope.actions")
  local ok_s, action_state = pcall(require, "telescope.actions.state")
  if not (ok_p and ok_f and ok_c and ok_a and ok_s) then
    return false
  end

  pickers.new({}, {
    prompt_title = "Breakpoints",
    finder = finders.new_table({
      results = recs,
      entry_maker = function(r)
        return {
          value = r,
          display = string.format("%s:%d   %s", short(r.file), r.line, r.text),
          ordinal = r.file .. ":" .. r.line,
          filename = r.file,
          lnum = r.line,
        }
      end,
    }),
    sorter = tconf.values.generic_sorter({}),
    previewer = tconf.values.grep_previewer({}),
    attach_mappings = function(_, map)
      map({ "i", "n" }, "<C-d>", function(prompt_bufnr)
        local sel = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if sel then
          remove_bp(sel.value.key)
          vim.notify(string.format("ardango: breakpoint removed %s:%d",
            short(sel.value.file), sel.value.line), vim.log.levels.INFO)
          M.breakpoints({ telescope = true })
        end
      end)
      return true
    end,
  }):find()
  return true
end

-- breakpoints: list every breakpoint. In the nui popup: <CR> jumps,
-- dd deletes the one under the cursor, D clears all. With opts.telescope
-- (or :ArdangoDebug breaks telescope), a Telescope picker with a
-- source preview instead - <C-d> deletes; falls back to the popup if
-- telescope.nvim isn't installed.
function M.breakpoints(opts)
  opts = opts or {}
  local recs = bp_records()
  if #recs == 0 then
    vim.notify("ardango: no breakpoints set", vim.log.levels.INFO)
    return
  end

  if opts.telescope and breakpoints_telescope(recs) then
    return
  end

  local lines = {}
  for i, r in ipairs(recs) do
    lines[i] = string.format("%s:%d   %s", short(r.file), r.line, r.text)
  end
  ui.show_popup(lines, vim.fn.getcwd(), inspect_popup_state, {
    on_enter = function(_, lnum, close)
      local r = recs[lnum]
      if r then
        close()
        jump_to_bp(r)
      end
    end,
    keymaps = {
      dd = function(_, lnum, close)
        local r = recs[lnum]
        if not r then
          return
        end
        remove_bp(r.key)
        vim.notify(string.format("ardango: breakpoint removed %s:%d", short(r.file), r.line),
          vim.log.levels.INFO)
        if next(breakpoints) then
          M.breakpoints(opts) -- re-render (reuses the same popup window)
        else
          close()
        end
      end,
      D = function(_, _, close)
        close()
        M.clear_breakpoints()
      end,
    },
  })
end

-- clear_breakpoints: remove every breakpoint.
function M.clear_breakpoints()
  local n = 0
  for key in pairs(breakpoints) do
    remove_bp(key)
    n = n + 1
  end
  vim.notify("ardango: cleared " .. n .. " breakpoint(s)", vim.log.levels.INFO)
end

-- --------------------------------------------------------------------------
-- status
-- --------------------------------------------------------------------------

-- A compact one-line debug status for a statusline / winbar / lualine
-- component. "" when there's no session. Re-render is nudged on every
-- state change (redrawstatus + a `User ArdangoDebug` autocmd).
--
--   vim.o.statusline = "%f %{v:lua.require('ardango').debug_status()} %="
--   vim.wo.winbar    = "%{v:lua.require('ardango').debug_status()}"
--   -- lualine: { function() return require('ardango').debug_status() end }
function M.debug_status()
  if helper_building then
    return "[debug: building helper]"
  end
  local s = session
  if not s then
    return ""
  end
  if not s.ready then
    return "[debug: starting]"
  end
  if s.running then
    return "[debug: running]"
  end
  local parts = { "debug:" }
  local loc = s.loc
  if loc then
    if loc.func and loc.func ~= "" then
      -- drop the package path prefix: ardango/dev/testdata.Greet -> testdata.Greet
      parts[#parts + 1] = loc.func:gsub("^.*/", "")
    end
    if loc.file and loc.file ~= "" then
      parts[#parts + 1] = short(loc.file) .. ":" .. (loc.line or 0)
    end
  end
  if s.goroutine then
    parts[#parts + 1] = "g" .. s.goroutine
  end
  if s.frame and s.frame > 0 then
    parts[#parts + 1] = s.frames
        and ("#" .. s.frame .. "/" .. (#s.frames - 1))
        or ("#" .. s.frame)
  end
  return "[" .. table.concat(parts, " ") .. "]"
end

-- Re-place breakpoint signs when a file is (re)loaded - a wiped/reopened
-- buffer loses its signs, but the breakpoint is still live.
api.nvim_create_autocmd("BufReadPost", {
  pattern = "*.go",
  callback = function(ev)
    local file = vim.fn.fnamemodify(ev.file, ":p")
    for _, bp in pairs(breakpoints) do
      if bp.file == file then
        if bp.sign_id then
          pcall(vim.fn.sign_unplace, SIGN_GROUP, { id = bp.sign_id })
        end
        bp.sign_id = vim.fn.sign_place(0, SIGN_GROUP, BP_SIGN, ev.buf, { lnum = bp.line, priority = 10 })
      end
    end
  end,
})

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
