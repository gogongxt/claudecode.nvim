---toggleterm.nvim terminal provider for Claude Code.
---Single-window-multi-buffer: window_manager owns THE terminal window; this
---provider creates one toggleterm buffer per session and swaps them via
---window_manager.display_buffer on session switch.
---@module 'claudecode.terminal.toggleterm'

local M = {}

local logger = require("claudecode.logger")
local utils = require("claudecode.utils")

local toggleterm_available = pcall(require, "toggleterm")
local Terminal = nil
if toggleterm_available then
  Terminal = require("toggleterm.terminal").Terminal
end

-- session_id -> {bufnr, jobid, term, mode}. `mode` is the last user-intended
-- terminal-buffer mode ("t" insert, "n" normal), captured before a swap so the
-- session returns to it when displayed again.
local terminals = {}

---@return boolean
local function is_available()
  return toggleterm_available and Terminal ~= nil
end

---@return table? session_manager
local function session_manager()
  local ok, sm = pcall(require, "claudecode.session")
  if ok then
    return sm
  end
  return nil
end

---@return table window_manager
local function window_manager()
  return require("claudecode.terminal.window_manager")
end

---Resolve the spawn cwd from the effective config, mirroring native/snacks.
---@param effective_config ClaudeCodeTerminalConfig
---@return string|nil
local function resolve_cwd(effective_config)
  if effective_config.cwd and effective_config.cwd ~= "" then
    return effective_config.cwd
  end
  return vim.fn.getcwd()
end

---Attach the tabbar to the window_manager window, if any. Best-effort: tabbar
---is optional and may not be loaded in minimal test stubs.
local function attach_tabbar(bufnr)
  local winid = window_manager().get_window()
  if not winid then
    return
  end
  local ok, tabbar = pcall(require, "claudecode.terminal.tabbar")
  if ok then
    tabbar.attach(winid, bufnr)
  end
end

-- Snapshot the live mode of the session whose buffer is currently displayed,
-- before hiding/switching. "t"→"t", "nt"→"n"; other modes (cmdline "c" from a
-- <Cmd> mapping, plain "n" from a window switch) are transient and leave the
-- saved mode untouched. The result is stashed in terminals[sid].mode so the
-- NEXT restore for that session knows what to return to.
local function capture_displayed_session_mode()
  local wm = window_manager()
  local winid = wm.get_window()
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return
  end
  local ok_buf, bufnr = pcall(vim.api.nvim_win_get_buf, winid)
  if not ok_buf or not bufnr then
    return
  end
  local sid
  for id, st in pairs(terminals) do
    if st and st.bufnr == bufnr then
      sid = id
      break
    end
  end
  if not sid then
    return
  end
  local ok_mode, raw = pcall(function()
    return vim.api.nvim_get_mode().mode
  end)
  if not ok_mode or type(raw) ~= "string" then
    return
  end
  local mode
  if raw:match("nt") then
    mode = "n"
  elseif raw == "t" or raw:match("^t") then
    mode = "t"
  end
  if mode then
    terminals[sid].mode = mode
  end
end

-- Read the session's last-captured mode (or default "t" for a fresh spawn).
local function session_mode(session_id)
  local st = terminals[session_id]
  return st and st.mode or "t"
end

-- Restore a session's mode after its buffer was swapped in. `want` is captured
-- by the caller BEFORE the swap, so whatever TermLeave does asynchronously
-- after focus_window can't clobber it — the restore closure already holds its
-- value. Deferred so the caller's Ex command has fully returned (startinsert
-- inside a <Cmd> mapping is overridden by nvim's post-command mode restoration;
-- feedkeys("i") queued after the command returns enters terminal insert
-- cleanly).
local function restore_mode(bufnr, want)
  local restore = function()
    local ok, cur_buf = pcall(vim.api.nvim_get_current_buf)
    if not ok or cur_buf ~= bufnr then
      return
    end
    if want == "t" then
      pcall(vim.cmd, "stopinsert")
      if vim.api and vim.api.nvim_feedkeys and vim.api.nvim_replace_termcodes then
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("i", true, false, true), "n", false)
      else
        pcall(vim.cmd, "startinsert")
      end
    else
      pcall(vim.cmd, "stopinsert")
    end
  end
  if vim.schedule then
    vim.schedule(restore)
  else
    restore()
  end
end

-- Terminal process exited: destroy the session, and if other sessions remain
-- surface the new active session's buffer in the same window; otherwise close.
local function handle_term_exit(session_id)
  local state = terminals[session_id]
  if not state then
    return
  end

  local current_bufnr = state.bufnr
  local sm = session_manager()
  local session_count = sm and sm.get_session_count() or 0

  -- Drop the buffer<->session mapping before deleting the buffer, so a recycled
  -- bufnr can't resolve to this (about-to-be-destroyed) session.
  if current_bufnr then
    pcall(function()
      require("claudecode.terminal").unregister_buffer_session(current_bufnr)
    end)
  end

  terminals[session_id] = nil
  if sm and sm.get_session(session_id) then
    sm.destroy_session(session_id)
  end

  local successor_displayed = false
  if session_count > 1 and sm then
    local new_active_id = sm.get_active_session_id()
    if new_active_id and new_active_id ~= session_id then
      local new_state = terminals[new_active_id]
      if new_state and new_state.bufnr and vim.api.nvim_buf_is_valid(new_state.bufnr) then
        local want = session_mode(new_active_id)
        window_manager().display_buffer(new_state.bufnr, false)
        window_manager().focus_window()
        attach_tabbar(new_state.bufnr)
        restore_mode(new_state.bufnr, want)
        successor_displayed = true
      end
    end
  end

  if current_bufnr and vim.api.nvim_buf_is_valid(current_bufnr) then
    local wm = window_manager()
    if not successor_displayed and wm.get_current_buffer() == current_bufnr then
      wm.close_window()
    end
    pcall(vim.api.nvim_buf_delete, current_bufnr, { force = true })
  end
end

-- toggleterm's ui.find_open_windows matches any window whose buffer has
-- filetype "toggleterm" or b:toggle_number set. While session A's terminal is
-- displayed, spawning session B via Terminal:open() makes toggleterm find A's
-- window and `rightbelow split` it — halving A's window height mid-spawn. A's
-- PTY gets a SIGWINCH at the half height (Neovim 0.11+ auto-sync), garbling
-- its TUI; B is also spawned in the half-height temp window and never
-- re-SIGWINCH'd after the swap (auto-synced buffers skip our explicit
-- jobresize), so B renders at the wrong size. Camouflaging every other
-- session's terminal buffer for the duration of the synchronous term:open()
-- makes find_open_windows find nothing, so toggleterm uses `commands.new`
-- (botright vsplit) — a fresh vertical split that never touches A's height.
local function with_other_sessions_camouflaged(fn)
  local saved = {}
  for _, st in pairs(terminals) do
    local bufnr = st and st.bufnr
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      local ok_tn, tn = pcall(vim.api.nvim_buf_get_var, bufnr, "toggle_number")
      local has_tn = ok_tn and tn ~= nil
      local ft_ok, ft = pcall(function()
        return vim.bo[bufnr].filetype
      end)
      local has_term_ft = ft_ok and ft == "toggleterm"
      if has_tn or has_term_ft then
        saved[#saved + 1] = { bufnr = bufnr, tn = has_tn and tn or nil, restore_ft = has_term_ft }
        if has_tn then
          pcall(vim.api.nvim_buf_del_var, bufnr, "toggle_number")
        end
        if has_term_ft then
          pcall(function()
            vim.bo[bufnr].filetype = "claudecode_term_camouflage"
          end)
        end
      end
    end
  end

  local ok, err = pcall(fn)

  for _, entry in ipairs(saved) do
    local bufnr = entry.bufnr
    if vim.api.nvim_buf_is_valid(bufnr) then
      if entry.tn ~= nil then
        pcall(vim.api.nvim_buf_set_var, bufnr, "toggle_number", entry.tn)
      end
      if entry.restore_ft then
        pcall(function()
          vim.bo[bufnr].filetype = "toggleterm"
        end)
      end
    end
  end

  return ok, err
end

-- Spawn via Terminal:open() (not spawn()) so toggleterm's full window init
-- runs (wrap=false, scrolloff=0, etc.) — without those, Claude's TUI cursor
-- positioning goes wrong. Trade-off: open() briefly creates a window we
-- immediately close so window_manager can display the buffer in its own.
local function create_terminal_buffer(session_id, cmd_string, env_table, effective_config)
  if not is_available() then
    return nil, nil
  end

  -- Mark awaiting_handshake BEFORE the spawn (term:open below). The Claude
  -- process can complete its WebSocket handshake in the window between
  -- term:open() and finalize_session_terminal; if the mark isn't set yet,
  -- the server's initialize handler falls back to find_unbound_session /
  -- visible-buffer and may bind this client to the wrong session (e.g. an
  -- already-active session whose buffer is visible). Only mark when not
  -- already bound — toggling a connected session must not re-arm the flag.
  do
    local sm = session_manager()
    if sm and sm.mark_awaiting_handshake then
      local s = sm.get_session(session_id)
      if s and not s.client_id then
        sm.mark_awaiting_handshake(session_id)
      end
    end
  end

  local cwd = resolve_cwd(effective_config)

  local term = Terminal:new({
    cmd = cmd_string,
    dir = cwd,
    direction = "vertical",
    env = env_table,
    -- handle_term_exit owns window + buffer closure (successor swap or, for
    -- the last session, window close). Disabling close_on_exit keeps
    -- toggleterm's __handle_exit from adding a redundant stopinsert! / buf
    -- delete on top of our cleanup.
    close_on_exit = false,
    auto_scroll = false,
    hidden = true, -- keep out of toggleterm's global :ToggleTerm set
    on_open = function(t)
      if t.bufnr then
        vim.api.nvim_buf_set_var(t.bufnr, "toggle_number", t.id)
        -- Ctrl-/ and Ctrl-_ produce the same byte in terminal mode; route to ESC.
        vim.api.nvim_buf_set_keymap(t.bufnr, "t", "<C-/>", "<Esc>", { noremap = true, silent = true })
        vim.api.nvim_buf_set_keymap(t.bufnr, "t", "<C-_>", "<Esc>", { noremap = true, silent = true })
        -- Track insert/normal mode per session so a swap-back restores it.
        -- TermEnter → "t"; terminal-normal ("nt") is captured at swap time by
        -- capture_displayed_session_mode. pcall-wrapped for minimal test stubs.
        local tracked_sid = session_id
        pcall(vim.api.nvim_create_autocmd, { "TermEnter" }, {
          buffer = t.bufnr,
          callback = function()
            local s = terminals[tracked_sid]
            if s then
              s.mode = "t"
            end
          end,
        })
      end
      if t.window and vim.api.nvim_win_is_valid(t.window) then
        -- wrap=false stops long-line folding (breaks TUI cursor positioning);
        -- scrolloff=0 keeps the cursor anchored to the visible region.
        vim.wo[t.window].wrap = false
        vim.wo[t.window].scrolloff = 0
        vim.wo[t.window].sidescrolloff = 0
      end
    end,
    on_exit = function(_, _, _)
      handle_term_exit(session_id)
    end,
  })

  -- Camouflage other sessions so toggleterm's find_open_windows won't split
  -- the displayed session's window (see with_other_sessions_camouflaged).
  local ok, err = with_other_sessions_camouflaged(function()
    term:open()
  end)
  if not ok or not term.bufnr then
    logger.error("terminal", "toggleterm Terminal:open() failed for session: " .. session_id .. ": " .. tostring(err))
    return nil, nil
  end

  -- Close toggleterm's window; keep the buffer. nvim_win_close (not term:close)
  -- so on_exit/close_on_exit doesn't fire and kill the job.
  if term.window and vim.api.nvim_win_is_valid(term.window) then
    pcall(vim.api.nvim_win_close, term.window, false)
    term.window = nil
  end

  local jobid = term.job_id
  -- Start in terminal mode ("t") — toggleterm's on_open runs startinsert, and a
  -- freshly spawned Claude TUI expects keyboard input immediately.
  terminals[session_id] = { bufnr = term.bufnr, jobid = jobid, term = term, mode = "t" }

  -- Force bufhidden=hide so display_buffer swaps keep the buffer (and its
  -- scrollback) alive across session switches. toggleterm leaves it at default.
  if term.bufnr and vim.api.nvim_buf_is_valid(term.bufnr) then
    vim.bo[term.bufnr].bufhidden = "hide"
  end

  logger.debug("terminal", "Created toggleterm buffer " .. term.bufnr .. " for session " .. session_id)
  return term.bufnr, jobid
end

---Check whether a session has a valid terminal buffer.
---@param session_id string
---@return boolean
local function is_session_valid(session_id)
  local state = terminals[session_id]
  return state ~= nil and state.bufnr ~= nil and vim.api.nvim_buf_is_valid(state.bufnr)
end

-- Serialize spawns so ≤1 session awaits its handshake at a time. The server
-- binds each arriving client to the oldest awaiter; with several awaiting at
-- once, unordered handshake arrival scrambles the binding (wrong-Claude sends).
-- Blocking a new spawn until the in-flight one resolves makes that rule exact.
--
-- The in-flight session clears itself in two normal ways: it binds a client
-- (bind_client clears awaiting_handshake) or its terminal exits (handle_term_exit
-- destroys the session, taking the flag with it). Both make
-- is_handshake_in_flight() return nil, so we just poll until it does. The
-- timeout is a safety net for a LEAKED flag (a bug) — a slow-but-alive handshake
-- is NOT stale; Claude's cold start can take several seconds (config
-- connection_timeout defaults to 10s), so we must not clear a live awaiter.
---@param fn function Spawn continuation (mark + term:open + display).
local function spawn_when_handshake_free(fn)
  local sm = session_manager()
  if not (sm and sm.is_handshake_in_flight) then
    fn()
    return
  end

  local has_loop = vim.loop ~= nil and type(vim.loop.now) == "function"
  local has_defer = type(vim.defer_fn) == "function"
  local started = has_loop and vim.loop.now() or 0
  local poll_interval = 50 -- ms
  -- Match config.connection_timeout (10s): a live but slow Claude handshake is
  -- normal and must not be declared stale. Only a LEAKED flag (no bind, no
  -- terminal exit) should ever trip this.
  local timeout_ms = 10000
  local iters = 0
  local max_iters = math.floor(timeout_ms / poll_interval) + 10 -- backstop for non-advancing test clocks

  local function try_run()
    local inflight_id = sm.is_handshake_in_flight()
    if inflight_id then
      iters = iters + 1
      local now = has_loop and vim.loop.now() or started
      local timed_out = (now - started) >= timeout_ms
      local can_poll = has_defer and not timed_out and iters < max_iters
      if can_poll then
        vim.defer_fn(try_run, poll_interval)
        return
      end
      -- Safety net only: flag leaked past connection_timeout with no bind and
      -- no terminal exit. Clear it so creation isn't wedged; warn so the leak
      -- is visible.
      logger.warn(
        "terminal",
        "spawn serialization timeout: clearing leaked awaiting_handshake for " .. tostring(inflight_id)
      )
      if sm.clear_awaiting_handshake then
        sm.clear_awaiting_handshake(inflight_id)
      end
    end
    fn()
  end

  try_run()
end

function M.setup()
  -- toggleterm.nvim is configured by the user's own setup; nothing to do.
end

----------------------------------------------------------------
-- Session-aware API
----------------------------------------------------------------

---Open (or show) the terminal for a specific session.
---@param session_id string
---@param cmd_string string
---@param env_table table
---@param config ClaudeCodeTerminalConfig
---@param focus boolean?
function M.open_session(session_id, cmd_string, env_table, config, focus)
  if not is_available() then
    vim.notify("toggleterm.nvim provider selected but toggleterm not available.", vim.log.levels.ERROR)
    return
  end
  focus = utils.normalize_focus(focus)

  -- Existing buffer: swap it into the window. No forced refresh here —
  -- nvim_win_set_buf preserves the buffer's view (scroll position), and a
  -- forced SIGWINCH would make the TUI redraw and jump to its own cursor.
  if is_session_valid(session_id) then
    local bufnr = terminals[session_id].bufnr
    capture_displayed_session_mode()
    local want = session_mode(session_id)
    window_manager().display_buffer(bufnr, false)
    if focus and window_manager().get_window() then
      window_manager().focus_window()
    end
    attach_tabbar(bufnr)
    if focus then
      restore_mode(bufnr, want)
    end
    return
  end

  -- Fresh spawn: serialized (see spawn_when_handshake_free) so the mark + open
  -- + display run as one unit once the handshake slot is free.
  spawn_when_handshake_free(function()
    local bufnr, jobid = create_terminal_buffer(session_id, cmd_string, env_table, config)
    if not bufnr then
      return
    end

    -- Fresh spawn: one refresh to sync initial PTY dims, then display. New
    -- sessions start in terminal mode ("t").
    capture_displayed_session_mode()
    local want = "t"
    window_manager().display_buffer(bufnr, false)
    window_manager().refresh_window()

    local terminal_module = require("claudecode.terminal")
    terminal_module.update_session_terminal_info(session_id, {
      bufnr = bufnr,
      winid = window_manager().get_window(),
      jobid = jobid,
    })
    terminal_module.register_buffer_session(bufnr, session_id)
    attach_tabbar(bufnr)
    if focus then
      local winid = window_manager().get_window()
      local do_focus = function()
        if winid and vim.api.nvim_win_is_valid(winid) then
          window_manager().focus_window(winid)
        end
        restore_mode(bufnr, want)
      end
      if vim.schedule then
        vim.schedule(do_focus)
      else
        do_focus()
      end
    end
  end)
end

---Close a specific session's terminal. Does NOT touch the window (window_manager
---owns it); the caller routes the successor via close_session_keep_window.
---@param session_id string
function M.close_session(session_id)
  local state = terminals[session_id]
  if not state then
    return
  end

  -- jobstop signals the job's process group (SIGTERM), which covers shell
  -- children; no need for a separate pkill. Synchronous-only (no
  -- vim.fn.system) avoids blocking the UI and stays portable to platforms
  -- without pkill.
  if state.jobid then
    pcall(vim.fn.jobstop, state.jobid)
  end

  if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    pcall(function()
      require("claudecode.terminal").unregister_buffer_session(state.bufnr)
    end)
    pcall(vim.api.nvim_buf_delete, state.bufnr, { force = true })
  end

  terminals[session_id] = nil
end

---Close `old_session_id`'s terminal and reuse its window for `new_session_id`.
---If the new session has a valid buffer, display_buffer swaps it into the
---existing window (no close/reopen); otherwise close the window.
---@param old_session_id string
---@param new_session_id string
---@param effective_config ClaudeCodeTerminalConfig
function M.close_session_keep_window(old_session_id, new_session_id, effective_config)
  local old_state = terminals[old_session_id]
  local new_state = terminals[new_session_id]

  -- Display successor first so the window never goes empty.
  capture_displayed_session_mode()
  local new_want = new_state and session_mode(new_session_id) or "t"
  if new_state and new_state.bufnr and vim.api.nvim_buf_is_valid(new_state.bufnr) then
    window_manager().display_buffer(new_state.bufnr, false)
  else
    window_manager().close_window()
  end
  if new_state and new_state.bufnr and vim.api.nvim_buf_is_valid(new_state.bufnr) then
    window_manager().focus_window()
    attach_tabbar(new_state.bufnr)
    restore_mode(new_state.bufnr, new_want)
  end

  if old_state then
    -- jobstop covers the process group; see close_session for rationale.
    if old_state.jobid then
      pcall(vim.fn.jobstop, old_state.jobid)
    end
    if old_state.bufnr and vim.api.nvim_buf_is_valid(old_state.bufnr) then
      pcall(function()
        require("claudecode.terminal").unregister_buffer_session(old_state.bufnr)
      end)
      pcall(vim.api.nvim_buf_delete, old_state.bufnr, { force = true })
    end
  end
  terminals[old_session_id] = nil
end

function M.focus_session(session_id, config)
  if not is_session_valid(session_id) then
    return
  end
  local bufnr = terminals[session_id].bufnr
  capture_displayed_session_mode()
  local want = session_mode(session_id)
  window_manager().display_buffer(bufnr, false)
  window_manager().focus_window()
  attach_tabbar(bufnr)
  restore_mode(bufnr, want)
end

---Toggle a session's terminal: close the window if this session's buffer is
---currently displayed, otherwise open/focus it.
---@param session_id string
---@param config ClaudeCodeTerminalConfig
---@param cmd_string string|nil Required when the session has no terminal yet
---@param env_table table|nil
function M.toggle_session(session_id, config, cmd_string, env_table)
  if not is_available() then
    vim.notify("toggleterm.nvim provider selected but toggleterm not available.", vim.log.levels.ERROR)
    return
  end

  local wm = window_manager()
  -- Hide only when the window is visible AND in the current tabpage AND showing
  -- THIS session's buffer. A window living in another tab is "visible" to
  -- is_visible() but not to the user here — toggling should migrate it into
  -- this tab (via focus_session below), not hide it from a tab the user left.
  if
    wm.is_in_current_tab()
    and is_session_valid(session_id)
    and wm.get_current_buffer() == terminals[session_id].bufnr
  then
    capture_displayed_session_mode()
    wm.close_window()
    return
  end

  -- Otherwise show it. First toggle for a fresh session needs cmd/env to spawn.
  if not is_session_valid(session_id) then
    if not (cmd_string and env_table) then
      return
    end
    M.open_session(session_id, cmd_string, env_table, config, true)
    return
  end

  M.focus_session(session_id, config)
end

---Get the buffer number for a session's terminal, if any.
---@param session_id string
---@return number?
function M.get_session_bufnr(session_id)
  if is_session_valid(session_id) then
    return terminals[session_id].bufnr
  end
  return nil
end

---Bind an externally-created terminal buffer to a session (compat hook).
---We own per-session buffers via spawn(), so this only adopts a buffer that
---matches nothing yet — used for legacy-to-session migration.
---@param session_id string
---@param bufnr number
function M.register_terminal_for_session(session_id, bufnr)
  if not (session_id and bufnr) or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  -- Refuse if another session already owns this buffer.
  for sid, state in pairs(terminals) do
    if state and state.bufnr == bufnr and sid ~= session_id then
      return
    end
  end
  if not terminals[session_id] then
    terminals[session_id] = { bufnr = bufnr, jobid = nil, term = nil }
  end
end

----------------------------------------------------------------
-- Legacy (non-session-aware) API — routed through the active session
----------------------------------------------------------------

---@return string|nil
local function active_session_id()
  local sm = session_manager()
  if sm then
    return sm.get_active_session_id()
  end
  return next(terminals)
end

---Open the Claude terminal (legacy entry point).
---@param cmd_string string
---@param env_table table
---@param config ClaudeCodeTerminalConfig
---@param focus boolean?
function M.open(cmd_string, env_table, config, focus)
  if not is_available() then
    vim.notify("toggleterm.nvim provider selected but toggleterm not available.", vim.log.levels.ERROR)
    return
  end
  focus = utils.normalize_focus(focus)
  local sm = session_manager()
  local session_id = (sm and sm.get_active_session_id()) or (sm and sm.ensure_session()) or active_session_id()
  if not session_id then
    return
  end
  M.open_session(session_id, cmd_string, env_table, config, focus)
end

function M.close()
  capture_displayed_session_mode()
  window_manager().close_window()
end

---Simple toggle: show/hide the active session regardless of focus.
---@param cmd_string string
---@param env_table table
---@param config ClaudeCodeTerminalConfig
function M.simple_toggle(cmd_string, env_table, config)
  if not is_available() then
    vim.notify("toggleterm.nvim provider selected but toggleterm not available.", vim.log.levels.ERROR)
    return
  end
  local wm = window_manager()
  if wm.is_visible() then
    capture_displayed_session_mode()
    wm.close_window()
    return
  end
  M.open(cmd_string, env_table, config)
end

---Smart focus toggle: focus when unfocused, hide when focused.
---@param cmd_string string
---@param env_table table
---@param config ClaudeCodeTerminalConfig
function M.focus_toggle(cmd_string, env_table, config)
  if not is_available() then
    vim.notify("toggleterm.nvim provider selected but toggleterm not available.", vim.log.levels.ERROR)
    return
  end
  local wm = window_manager()
  if not wm.is_visible() then
    M.open(cmd_string, env_table, config)
    return
  end

  local winid = wm.get_window()
  if winid == vim.api.nvim_get_current_win() then
    capture_displayed_session_mode()
    wm.close_window()
  else
    wm.focus_window(winid)
    vim.cmd("startinsert")
  end
end

---Legacy toggle alias.
function M.toggle(cmd_string, env_table, config)
  M.simple_toggle(cmd_string, env_table, config)
end

---Get the active session's terminal buffer number.
---@return number?
function M.get_active_bufnr()
  local sid = active_session_id()
  if sid then
    return M.get_session_bufnr(sid)
  end
  return nil
end

---@return boolean
function M.is_available()
  return is_available()
end

function M.ensure_visible()
  local sid = active_session_id()
  if sid and is_session_valid(sid) then
    local wm = window_manager()
    if not wm.is_visible() then
      capture_displayed_session_mode()
      wm.display_buffer(terminals[sid].bufnr, false)
    end
  end
end

---For testing purposes.
---@return table? state The active session's terminal state, or nil
function M._get_terminal_for_test()
  local sid = active_session_id()
  if sid then
    return terminals[sid]
  end
  return nil
end

---@type ClaudeCodeTerminalProvider
return M
