---Snacks.picker-based session switcher for the multi-session terminal.
---
---Left pane: one row per Claude session (slot, name, active marker).
---Right pane: a read-only snapshot of the selected session's terminal buffer
---(what Claude is currently showing there), so you can scan sessions and pick
---the one to switch to without toggling each one open.
---
---Falls back to `vim.ui.select` when `Snacks.picker` is unavailable, so the
---command still works on minimal installs / in the test harness.
---@module 'claudecode.session_picker'

local M = {}

local logger = require("claudecode.logger")

-- Whether Snacks.nvim exposes its picker. Cached after first resolution; the
-- availability doesn't change within a session.
local snacks_picker_available

---@return boolean
local function has_snacks_picker()
  if snacks_picker_available == nil then
    local ok, Snacks = pcall(require, "snacks")
    snacks_picker_available = ok and Snacks ~= nil and Snacks.picker ~= nil
  end
  return snacks_picker_available
end

-- Resolve the terminal buffer for a session, if it has a live one.
---@param session_id string
---@return number? bufnr
local function get_session_terminal_buf(session_id)
  local terminal = require("claudecode.terminal")
  local bufnr = terminal.get_session_bufnr(session_id)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    return bufnr
  end
  return nil
end

-- Camouflage a toggleterm terminal buffer so Neovim 0.11+ doesn't auto-sync
-- its PTY when we display the buffer in the (smaller) preview window. Without
-- this, showing the live terminal in the preview sends a SIGWINCH that garbles
-- the session's TUI render (same hazard the spawn path guards against via
-- with_other_sessions_camouflaged). Returns a restore closure or nil.
--
-- We only strip the `toggle_number` buffer var (the auto-sync trigger); the
-- filetype is left as "toggleterm" so the buffer still renders with terminal
-- colors. The var is restored when the returned closure runs (on the next
-- preview item or when the picker closes).
---@param bufnr number
---@return fun()|nil restore
local function camouflage_for_preview(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  local ok, tn = pcall(vim.api.nvim_buf_get_var, bufnr, "toggle_number")
  if not ok or tn == nil then
    return nil
  end
  pcall(vim.api.nvim_buf_del_var, bufnr, "toggle_number")
  return function()
    if vim.api.nvim_buf_is_valid(bufnr) then
      pcall(vim.api.nvim_buf_set_var, bufnr, "toggle_number", tn)
    end
  end
end

-- A pending camouflage restore for the terminal buffer currently shown in the
-- preview. Run when a different item is previewed or the picker closes, so a
-- toggleterm buffer is only de-synced while it's the one on screen.
local pending_restore

local function restore_camouflage()
  if pending_restore then
    pending_restore()
    pending_restore = nil
  end
end

-- Build the previewer callback. Returns a function matching snacks'
-- `preview fun(ctx)` signature. Renders the selected session's LIVE terminal
-- buffer (with full color) into the preview pane via preview:set_buf, so the
-- user sees exactly what Claude is showing in that session.
local function build_previewer()
  return function(ctx)
    local item = ctx.item
    local session_id = item and item.session_id
    local preview = ctx.preview

    -- Always restore the previous item's camouflage before handling the next,
    -- so a toggleterm buffer is only de-synced while it's the one on screen.
    restore_camouflage()

    if not session_id then
      preview:reset()
      preview:notify("no session", "warn")
      return
    end

    local bufnr = get_session_terminal_buf(session_id)
    preview:reset()
    if not bufnr then
      preview:set_title(item.label or "session")
      preview:notify("session has no terminal yet", "info", { item = false })
      return
    end

    preview:set_title(item.label or "session")

    -- Camouflage so displaying in the preview window doesn't trigger an
    -- auto-sync PTY resize on the live session. Held until the next preview
    -- call / picker close.
    pending_restore = camouflage_for_preview(bufnr)

    -- Show the live terminal buffer. Terminal buffers render their ANSI
    -- colors at the window level, so this is the only way to get a colored
    -- preview — plain nvim_buf_get_lines strips all color.
    vim.b[bufnr].snacks_previewed = true
    preview:set_buf(bufnr)

    -- Terminal buffers keep their cursor at the bottom (the prompt). Land the
    -- preview there so the latest output is in view. Deferred so the window
    -- has the buffer before we move its cursor.
    vim.schedule(function()
      pcall(function()
        local win = ctx.win
        if win and vim.api.nvim_win_is_valid(win) then
          local count = vim.api.nvim_buf_line_count(bufnr)
          if count and count > 0 then
            vim.api.nvim_win_set_cursor(win, { count, 0 })
          end
        end
      end)
    end)
  end
end

-- Render the list label for a session item. Returns a snacks highlight chunk
-- array when supported, else a plain string.
local function format_session(item)
  local active = item.is_active
  -- Use the slot number as the icon-like prefix and color the active row.
  local slot_str = string.format("%2d", item.slot or 0)
  local name = item.name or item.session_id
  if active then
    return {
      { slot_str .. " ", "SnacksPickerSpecial" },
      { "● ", "SnacksPickerSpecial" },
      { name, "SnacksPickerSpecial" },
      { "  (active)", "SnacksPickerComment" },
    }
  end
  return {
    { slot_str .. " ", "SnacksPickerDir" },
    { "○ ", "SnacksPickerComment" },
    { name, "SnacksPickerLabel" },
  }
end

-- Open the Snacks.picker session switcher.
---@param sessions table[] List of session tables (from terminal.list_sessions)
---@param active_id string|nil Currently active session id
---@param on_choice fun(session_id: string|nil) Called with the chosen session id (nil on cancel)
local function open_snacks_picker(sessions, active_id, on_choice)
  local ok, Snacks = pcall(require, "snacks")
  if not ok or not Snacks or not Snacks.picker then
    on_choice(nil)
    return
  end

  -- finder returns the static item list. Each item carries the session id and
  -- enough fields for format/preview; `text` is what the matcher searches.
  local items = {}
  for _, s in ipairs(sessions) do
    local label = string.format("%d. %s", s.slot or 0, s.name or s.id)
    table.insert(items, {
      text = label,
      label = label,
      session_id = s.id,
      slot = s.slot,
      name = s.name,
      is_active = s.id == active_id,
    })
  end

  Snacks.picker({
    source = "claudecode_sessions",
    title = "Claude Code sessions",
    items = items,
    format = function(item, _picker)
      return format_session(item)
    end,
    preview = build_previewer(),
    layout = {
      -- Left list, right preview — the "default" horizontal split.
      layout = {
        box = "horizontal",
        width = 0.8,
        min_width = 100,
        height = 0.8,
        {
          box = "vertical",
          border = true,
          title = "{title} {live} {flags}",
          title_pos = "center",
          { win = "input", height = 1, border = "bottom" },
          { win = "list", border = "none" },
        },
        { win = "preview", title = "{preview}", border = true, width = 0.55 },
      },
    },
    actions = {
      -- Override confirm (Enter / double-click) to toggle the picked session
      -- rather than the default jump/edit.
      confirm = function(picker, item)
        if not item then
          return
        end
        local session_id = item.session_id
        picker:close()
        vim.schedule(function()
          on_choice(session_id)
        end)
      end,
    },
    on_close = function()
      -- Drop the camouflage on the last-previewed terminal buffer so its
      -- session resumes normal auto-sync behavior.
      restore_camouflage()
    end,
  })
end

-- Fallback used when Snacks.picker isn't installed: the original vim.ui.select
-- behavior. Picking a session toggles it.
local function open_ui_select(sessions, active_id, on_choice)
  local items = {}
  for i, s in ipairs(sessions) do
    local marker = (s.id == active_id) and " *" or ""
    local slot_num = s.slot or i
    table.insert(items, {
      label = string.format("%d. %s%s", slot_num, s.name or s.id, marker),
      session_id = s.id,
    })
  end
  vim.ui.select(items, {
    prompt = "Claude Code sessions (toggle):",
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    on_choice(choice and choice.session_id or nil)
  end)
end

---Open the session switcher. Uses Snacks.picker (left list + right terminal
---preview) when available, otherwise falls back to `vim.ui.select`.
---@param sessions table[] Session tables from `terminal.list_sessions()`
---@param active_id string|nil The active session id
---@param on_choice fun(session_id: string|nil) Invoked with the chosen session id, or nil if cancelled
function M.open(sessions, active_id, on_choice)
  if type(on_choice) ~= "function" then
    logger.warn("session_picker", "open called without on_choice callback")
    return
  end
  if not sessions or #sessions == 0 then
    on_choice(nil)
    return
  end

  if has_snacks_picker() then
    open_snacks_picker(sessions, active_id, on_choice)
  else
    open_ui_select(sessions, active_id, on_choice)
  end
end

-- Test-only: reset the cached snacks availability so a stub installed after
-- the first call is picked up.
function M._reset_availability()
  snacks_picker_available = nil
end

return M
