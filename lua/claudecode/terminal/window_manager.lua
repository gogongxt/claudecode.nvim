---Window manager for Claude Code terminal.
---Singleton module that owns THE terminal window. Providers create buffers,
---window_manager displays them in the single managed window.
---@module 'claudecode.terminal.window_manager'

local M = {}

local logger = require("claudecode.logger")

---@class WindowManagerState
---@field winid number|nil The single terminal window (nil if closed)
---@field current_bufnr number|nil Buffer currently displayed
---@field config table|nil Window configuration (position, width, etc.)

---@type WindowManagerState
local state = {
  winid = nil,
  current_bufnr = nil,
  config = nil,
  last_width = nil,
  last_height = nil,
  resize_pending = false,
  -- User-dragged width; preserved across hide→show, cleared on VimResized.
  user_width = nil,
}

-- Debounce timer for WinResized-driven SIGWINCH. Module-level so reset() can
-- close a pending timer; otherwise a reload mid-debounce leaves an orphaned
-- timer that fires notify_resize against stale state.
local resize_timer = nil

-- Find our terminal window across all tabpages (it's global). Only matches
-- windows we tagged with vim.w.claudecode_terminal, so a user's own
-- `:terminal` split is never mistaken for ours.
local function find_terminal_window()
  local wins = vim.api.nvim_list_wins()

  for _, win in ipairs(wins) do
    if vim.api.nvim_win_is_valid(win) then
      local ok, marked = pcall(function()
        return vim.w[win].claudecode_terminal
      end)
      if ok and marked then
        return win
      end
    end
  end

  return nil
end

-- toggleterm split terminals (b:toggle_number) are auto-synced by Neovim
-- 0.11+ (PR neovim/neovim#33915): it resizes the PTY and sends SIGWINCH on
-- its own. A plugin jobresize races with that and garbles the TUI render, so
-- we skip it for those buffers. native/snacks still need the explicit call.
local function is_auto_synced_buffer(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local ok, val = pcall(vim.api.nvim_buf_get_var, bufnr, "toggle_number")
  return ok and val ~= nil
end

-- Restore width: prefer the user's last dragged width (state.user_width) so
-- manual resize survives hide→show; fall back to the configured percentage.
local function restore_configured_width()
  if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
    return false
  end
  if not state.config then
    return false
  end
  if state.user_width then
    vim.api.nvim_win_set_width(state.winid, state.user_width)
    return true
  end
  local split_width_percentage = state.config.split_width_percentage or 0.4
  local total_width = vim.o.columns
  local width = math.floor(total_width * split_width_percentage)
  vim.api.nvim_win_set_width(state.winid, width)
  return true
end

local function create_split_window(config)
  local split_side = config.split_side or "right"
  local split_width_percentage = config.split_width_percentage or 0.4

  local width = state.user_width
  if not width then
    width = math.floor(vim.o.columns * split_width_percentage)
  end

  if split_side == "left" then
    vim.cmd("topleft vertical new")
  else
    vim.cmd("botright vertical new")
  end

  local winid = vim.api.nvim_get_current_win()

  -- Tag as ours so find_terminal_window reclaims only our window, never a
  -- user's own `:terminal` split.
  vim.w[winid].claudecode_terminal = true

  vim.api.nvim_win_set_width(winid, width)
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].signcolumn = "no"
  vim.wo[winid].winfixwidth = true
  vim.wo[winid].wrap = false
  vim.wo[winid].scrolloff = 0
  vim.wo[winid].sidescrolloff = 0

  logger.debug("window_manager", "Created split window: " .. winid .. " (width=" .. width .. ")")

  return winid
end

-- Notify the terminal of its current dimensions (SIGWINCH). Skips when
-- dimensions are unchanged (avoids TUI redraw/scroll reset) and for
-- auto-synced toggleterm buffers (see is_auto_synced_buffer).
function M.notify_resize(force)
  if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
    return
  end

  local bufnr = vim.api.nvim_win_get_buf(state.winid)
  if is_auto_synced_buffer(bufnr) then
    return
  end
  local chan = vim.bo[bufnr].channel
  if chan and chan > 0 then
    local width = vim.api.nvim_win_get_width(state.winid)
    local height = vim.api.nvim_win_get_height(state.winid)
    if not force and width == state.last_width and height == state.last_height then
      logger.debug("window_manager", string.format("Resize skipped (unchanged): %dx%d", width, height))
      return
    end
    state.last_width = width
    state.last_height = height
    pcall(vim.fn.jobresize, chan, width, height)
    logger.debug("window_manager", string.format("Resize notification: %dx%d", width, height))
  end
end

local function setup_resize_autocommands()
  local group = vim.api.nvim_create_augroup("ClaudeCodeTerminalResize", { clear = true })

  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      -- Whole-Nvim resize: the dragged pixel width is no longer meaningful,
      -- so drop it and re-apply the configured %.
      state.user_width = nil
      restore_configured_width()
      M.notify_resize(true)
    end,
  })

  -- Dragging the split border fires WinResized (not VimResized). Debounced:
  -- a SIGWINCH per pixel makes the TUI redraw mid-drag against a half-applied
  -- layout and garbles. force=true on the flush since the cache may match an
  -- intermediate size.
  local DEBOUNCE_MS = 80
  vim.api.nvim_create_autocmd("WinResized", {
    group = group,
    callback = function()
      local terminal_win = find_terminal_window()
      if not terminal_win then
        return
      end
      state.winid = terminal_win
      state.current_bufnr = vim.api.nvim_win_get_buf(terminal_win)
      state.user_width = vim.api.nvim_win_get_width(terminal_win)
      if resize_timer and not resize_timer:is_closing() then
        resize_timer:close()
      end
      resize_timer = vim.defer_fn(function()
        resize_timer = nil
        M.notify_resize(true)
      end, DEBOUNCE_MS)
    end,
  })

  -- Defer jobresize until the user enters the terminal itself, so sidebar
  -- toggles (file explorer etc.) don't trigger a SIGWINCH that resets the
  -- TUI scroll position.
  vim.api.nvim_create_autocmd("WinEnter", {
    group = group,
    callback = function()
      local terminal_win = find_terminal_window()
      if not terminal_win then
        return
      end

      state.winid = terminal_win
      state.current_bufnr = vim.api.nvim_win_get_buf(terminal_win)

      local width = vim.api.nvim_win_get_width(terminal_win)
      local height = vim.api.nvim_win_get_height(terminal_win)
      if width ~= state.last_width or height ~= state.last_height then
        local entered_win = vim.api.nvim_get_current_win()
        if entered_win == terminal_win then
          M.notify_resize()
        else
          state.resize_pending = true
          state.last_width = width
          state.last_height = height
          logger.debug("window_manager", string.format("Resize deferred (not in terminal): %dx%d", width, height))
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("TabEnter", {
    group = group,
    callback = function()
      local terminal_win = find_terminal_window()
      if terminal_win then
        state.winid = terminal_win
        state.current_bufnr = vim.api.nvim_win_get_buf(terminal_win)
        vim.defer_fn(function()
          restore_configured_width()
          M.notify_resize()
        end, 100)
      end
    end,
  })

  -- TermEnter flushes a deferred resize so the TUI gets correct dims only
  -- when the user is actively interacting with it.
  vim.api.nvim_create_autocmd("TermEnter", {
    group = group,
    callback = function()
      local terminal_win = find_terminal_window()
      if terminal_win then
        state.winid = terminal_win
        state.current_bufnr = vim.api.nvim_win_get_buf(terminal_win)
        if state.resize_pending then
          state.resize_pending = false
          M.notify_resize(true)
        else
          M.notify_resize()
        end
      end
    end,
  })
end

function M.setup(config)
  state.config = config or {}
  setup_resize_autocommands()
  logger.debug("window_manager", "Window manager initialized")
end

-- Get or create the global terminal window. If it exists anywhere, return it;
-- otherwise create one in the current tabpage.
function M.ensure_window()
  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    return state.winid
  end

  local found = find_terminal_window()
  if found then
    state.winid = found
    logger.debug("window_manager", "Recovered existing terminal window: " .. found)
    return found
  end

  if not state.config then
    state.config = {}
  end
  state.winid = create_split_window(state.config)
  return state.winid
end

function M.get_window()
  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    return state.winid
  end
  return nil
end

function M.display_buffer(bufnr, focus)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    logger.warn("window_manager", "Cannot display invalid buffer: " .. tostring(bufnr))
    return false
  end

  local winid = M.ensure_window()
  if not winid then
    logger.error("window_manager", "Failed to create terminal window")
    return false
  end

  local current_buf = vim.api.nvim_win_get_buf(winid)
  local current_bufname = vim.api.nvim_buf_get_name(current_buf)
  local is_scratch = current_bufname == "" and vim.bo[current_buf].buftype == ""

  vim.api.nvim_win_set_buf(winid, bufnr)
  state.current_bufnr = bufnr

  if is_scratch and current_buf ~= bufnr and vim.api.nvim_buf_is_valid(current_buf) then
    pcall(vim.api.nvim_buf_delete, current_buf, { force = true })
  end

  if not is_auto_synced_buffer(bufnr) then
    local chan = vim.bo[bufnr].channel
    if chan and chan > 0 then
      local width = vim.api.nvim_win_get_width(winid)
      local height = vim.api.nvim_win_get_height(winid)
      pcall(vim.fn.jobresize, chan, width, height)
      logger.debug("window_manager", string.format("Resized terminal channel %d to %dx%d", chan, width, height))
    end
  end

  if focus then
    M.focus_window(winid)
    vim.cmd("startinsert")
  end

  logger.debug("window_manager", "Displayed buffer " .. bufnr .. " in window " .. winid)
  return true
end

-- Re-apply window options + a forced SIGWINCH so the TUI can self-heal from a
-- garbled state (after close/reopen or a tab switch leaving stale PTY dims).
-- Mirrors toggleterm's per-open on_open + resize_split. NOT re-applying the
-- configured width here: the user may have dragged it, and snapping back on
-- every focus would override their preference.
function M.refresh_window(winid)
  winid = winid or state.winid
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return
  end
  vim.wo[winid].number = false
  vim.wo[winid].relativenumber = false
  vim.wo[winid].signcolumn = "no"
  vim.wo[winid].winfixwidth = true
  vim.wo[winid].wrap = false
  vim.wo[winid].scrolloff = 0
  vim.wo[winid].sidescrolloff = 0
  M.notify_resize(true)
  logger.debug("window_manager", "Refreshed window " .. winid .. " (opts + forced resize)")
end

-- The window is global but follows the user: if it lives in another tabpage,
-- migrate it into the current tab rather than yanking the user to its birth
-- tab. The buffer (job + scrollback) survives because it's owned by the
-- session, not the window.
function M.focus_window(winid)
  winid = winid or state.winid
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return
  end
  local ok_tab, win_tab = pcall(vim.api.nvim_win_get_tabpage, winid)
  if ok_tab and win_tab then
    local ok_cur, cur_tab = pcall(vim.api.nvim_get_current_tabpage)
    if ok_cur and cur_tab ~= win_tab then
      M.migrate_to_current_tab(winid)
      return
    end
  end
  pcall(vim.api.nvim_set_current_win, winid)
end

function M.migrate_to_current_tab(winid)
  if not winid or not vim.api.nvim_win_is_valid(winid) then
    return
  end
  local buf_ok, bufnr = pcall(vim.api.nvim_win_get_buf, winid)
  if not buf_ok or not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if not pcall(vim.api.nvim_win_close, winid, false) then
    return
  end
  state.winid = nil
  local new_win = create_split_window(state.config or {})
  if not new_win then
    return
  end
  pcall(vim.api.nvim_win_set_buf, new_win, bufnr)
  state.winid = new_win
  state.current_bufnr = bufnr
  if not is_auto_synced_buffer(bufnr) then
    local chan = vim.bo[bufnr].channel
    if chan and chan > 0 then
      local width = vim.api.nvim_win_get_width(new_win)
      local height = vim.api.nvim_win_get_height(new_win)
      pcall(vim.fn.jobresize, chan, width, height)
      state.last_width = width
      state.last_height = height
    end
  end
  pcall(function()
    local tabbar = require("claudecode.terminal.tabbar")
    if tabbar.attach then
      tabbar.attach(new_win, bufnr)
    end
  end)
  pcall(vim.api.nvim_set_current_win, new_win)
  logger.debug("window_manager", "Migrated terminal window to current tab: " .. new_win)
end

function M.close_window()
  if state.winid and vim.api.nvim_win_is_valid(state.winid) then
    pcall(vim.api.nvim_win_close, state.winid, false)
    logger.debug("window_manager", "Closed terminal window: " .. state.winid)
  end
  state.winid = nil
  state.current_bufnr = nil
  -- Reset cached dims so the reopen's notify_resize re-sends SIGWINCH even if
  -- the new window matches the old size (the TUI may have fallen to 0x0 while
  -- closed).
  state.last_width = nil
  state.last_height = nil
  state.resize_pending = false
end

function M.is_visible()
  return state.winid ~= nil and vim.api.nvim_win_is_valid(state.winid)
end

-- Whether the managed window lives in the current tabpage. Toggle logic uses
-- this to distinguish "visible here" (hide on toggle) from "visible in
-- another tab" (migrate here on toggle). Without it, a window shown in tab1
-- is treated as visible while the user is in tab2, so the first toggle press
-- hides it instead of bringing it over.
function M.is_in_current_tab()
  if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
    return false
  end
  local ok_win, win_tab = pcall(vim.api.nvim_win_get_tabpage, state.winid)
  if not ok_win or not win_tab then
    return false
  end
  local ok_cur, cur_tab = pcall(vim.api.nvim_get_current_tabpage)
  if not ok_cur or not cur_tab then
    return false
  end
  return win_tab == cur_tab
end

function M.get_dimensions()
  if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
    return nil
  end

  return {
    width = vim.api.nvim_win_get_width(state.winid),
    height = vim.api.nvim_win_get_height(state.winid),
  }
end

function M.get_current_buffer()
  return state.current_bufnr
end

function M.reset()
  M.close_window()
  if resize_timer and not resize_timer:is_closing() then
    resize_timer:close()
  end
  resize_timer = nil
  state = {
    winid = nil,
    current_bufnr = nil,
    config = nil,
    last_width = nil,
    last_height = nil,
    resize_pending = false,
    user_width = nil,
  }
  logger.debug("window_manager", "Reset window manager state")
end

return M
