--- Tab bar module for Claude Code terminal session switching.
--- Per-tab instances: each Neovim tabpage owns its own tabbar window/buffer.
--- @module 'claudecode.terminal.tabbar'

local M = {}

local session_manager = require("claudecode.session")

---@class TabBarTabState
---@field tabbar_win number|nil
---@field tabbar_buf number|nil
---@field terminal_win number|nil
---@field click_regions table[]
---@field winbar_session_ids table
---@field viewport_start integer|nil 1-based index (into list_sessions) of the first visible session; the sliding window. Persists across renders so it only moves when active goes out of range.
---@field last_content string|nil Last rendered float content (skip no-op rewrites)
---@field last_config table|nil Last applied float win config (skip no-op repositions)

local state = {
  tabs = {},
  augroup = nil,
  config = nil,
}

local function get_tab_state(tabpage)
  local slot = state.tabs[tabpage]
  if not slot then
    slot = {
      click_regions = {},
      winbar_session_ids = {},
      viewport_start = nil,
      last_content = nil,
      last_config = nil,
    }
    state.tabs[tabpage] = slot
  end
  return slot
end

-- Resolve a tabpage handle: explicit arg wins, else current tab.
local function resolve_tab(tabpage)
  return tabpage or vim.api.nvim_get_current_tabpage()
end

-- Sessions are global; every tabbar renders the same list. The tabpage arg is
-- kept for the per-tab render call sites but ignored.
local function list_sessions_for(_tabpage)
  return session_manager.list_sessions()
end

local function setup_highlights()
  if not vim.api.nvim_set_hl then
    return
  end

  local hl = vim.api.nvim_set_hl
  hl(0, "ClaudeCodeTabBar", { link = "StatusLine", default = true })
  -- Explicit bg/fg rather than linking TabLineSel/TabLine — those are nearly
  -- identical in many themes, so the focused session was indistinguishable.
  local active_bg = "#1e66f5"
  local inactive_bg = "#1f2937"
  hl(0, "ClaudeCodeTabActive", { bg = active_bg, fg = "#ffffff", bold = true, default = true })
  hl(0, "ClaudeCodeTabInactive", { bg = inactive_bg, fg = "#9ca3af", default = true })
  hl(0, "ClaudeCodeTabNew", { link = "Special", default = true })
  hl(0, "ClaudeCodeTabClose", { link = "Error", default = true })
end

-- Display name for a session, shown in full. The sliding window drops whole
-- tabs to fit rather than truncating names, so a session's full name is always
-- rendered when its tab is visible.
local function display_name(session, fallback_idx)
  return session.name or ("Session " .. tostring(fallback_idx))
end

-- Width (in display cells) a tab block occupies: " N:name " plus the optional
-- "✕ " close button. `slot_len` is the display width of the slot number (1 for
-- slots 1-9, 2 for 10-99, …) and `name_len` is the name length before padding.
local function tab_block_width(slot_len, name_len, with_close)
  local w = 1 + slot_len + 1 + name_len + 1 -- " " + slot + ":" + name + " "
  if with_close then
    w = w + 2 -- "✕ "
  end
  return w
end

-- Full width of a rendered tab (separator excluded), using its display name.
local function tab_width(session, with_close)
  local slot_len = #tostring(session.slot or 0)
  return tab_block_width(slot_len, #display_name(session), with_close)
end

---Compute the sliding-window layout for the session tab bar.
---
---The visible region is a *contiguous* slice of the slot-ordered session list,
---like a bufferline/tabline plugin: from `slot.viewport_start`, admit whole tabs
---(names are never shrunk to fit — a tab that doesn't fit is dropped, not
---truncated) until the window width is exhausted. The active session is always
---kept inside the window: if it falls off either edge, the window scrolls the
---minimum amount to bring it back (right edge → align active to the window's
---right; left edge → align to the left). Otherwise the window does not move, so
---switching among already-visible sessions causes no jump.
---
---Folded sides are marked: `‹` when sessions exist before the window, `›` when
---sessions exist after. Both are clickable scroll regions (handled by the
---builders). The `+` new button sits at the far right after `›`.
---
---`slot.viewport_start` is persisted on the slot so the window survives renders
---and only moves when active goes out of range (or the user clicks ‹/›).
---
---Returns:
---   { entries = { {session, slot_num, name, is_active, show_close} ... },
---     show_new = bool, left_fold = bool, right_fold = bool,
---     viewport_start = integer (updated), viewport_end = integer }
---@param slot table Tab slot (reads/writes viewport_start)
---@param sessions table[] Slot-ordered session list
---@param active_id string|nil
---@param available_width integer|nil Terminal window width; nil = no cap
---@return table
local function compute_layout(slot, sessions, active_id, available_width)
  local show_close = state.config and state.config.show_close_button
  local show_new = state.config and state.config.show_new_button

  local layout = {
    entries = {},
    show_new = show_new,
    left_fold = false,
    right_fold = false,
    viewport_start = 1,
    viewport_end = #sessions,
  }

  if #sessions == 0 then
    layout.show_new = false
    return layout
  end

  -- Uncapped (no terminal width known): render everything, no folding.
  if not available_width or available_width <= 0 then
    for i, session in ipairs(sessions) do
      layout.entries[#layout.entries + 1] = {
        session = session,
        slot_num = session.slot or i,
        name = display_name(session, i),
        is_active = session.id == active_id,
        show_close = show_close,
      }
    end
    return layout
  end

  local SEP = 1 -- "|" between adjacent rendered tabs
  local new_btn_w = show_new and 3 or 0 -- " + "
  local MARKER_W = 1 -- "‹" / "›"

  -- Width budget reserved for the fixed right-edge elements, given whether the
  -- right side will be folded. We don't know the folds yet, so we compute the
  -- window conservatively then fix up markers at the end.
  --
  -- Approach: find the largest window [start..end] (contiguous) such that the
  -- rendered width fits, then ensure active is inside it.

  -- Resolve the active session's 1-based index in `sessions`.
  local active_idx = nil
  if active_id then
    for i, s in ipairs(sessions) do
      if s.id == active_id then
        active_idx = i
        break
      end
    end
  end

  -- Width of rendering tabs [start..end] inclusive, including separators and
  -- the leading left marker / trailing right marker / new button as requested.
  local function window_width(start_idx, end_idx, left_fold, right_fold)
    local w = 0
    if left_fold then
      w = w + MARKER_W + SEP
    end
    for i = start_idx, end_idx do
      if i > start_idx then
        w = w + SEP
      end
      w = w + tab_width(sessions[i], show_close)
    end
    if right_fold then
      w = w + SEP + MARKER_W
    end
    if show_new then
      w = w + SEP + new_btn_w
    end
    return w
  end

  -- Clamp the saved viewport_start into a valid range.
  local start = slot.viewport_start or 1
  if start < 1 then
    start = 1
  end
  if start > #sessions then
    start = #sessions
  end

  -- Grow a window from `from` rightward as far as fits, accounting for the fold
  -- markers and new button that the final render will add. Returns the last
  -- index that fits (inclusive), or `from - 1` if even the first tab doesn't.
  local function fit_right(from)
    if from > #sessions then
      return from - 1
    end
    local ending = from
    -- A window [from..ending] always renders at least `from`. Grow while the
    -- full rendered width (markers + new button included) fits.
    while ending <= #sessions do
      local left_fold = from > 1
      local right_fold = ending < #sessions
      if window_width(from, ending, left_fold, right_fold) > available_width then
        ending = ending - 1
        break
      end
      if ending == #sessions then
        break
      end
      ending = ending + 1
    end
    if ending < from then
      ending = from -- force at least one tab; oversized tab is unavoidable
    end
    return ending
  end

  -- First pass: window from the saved start.
  local ending, _ = fit_right(start)
  if ending < start then
    ending = start - 1 -- nothing fit yet; will be repaired below
  end

  -- Ensure the active session is inside [start..ending], UNLESS this render
  -- follows an explicit ‹/› scroll — then the user is browsing beyond active
  -- and we must honor their scroll position (active may leave the window).
  local skip_active_clamp = slot.skip_active_clamp
  slot.skip_active_clamp = nil -- one-shot: only the render right after a scroll

  if active_idx and not skip_active_clamp then
    if active_idx > ending then
      -- active is past the right edge: slide start right until active fits.
      -- Each iteration drops the leftmost tab and re-grows rightward.
      while active_idx > ending and start <= active_idx do
        start = start + 1
        ending, _ = fit_right(start)
        if ending < start then
          ending = start
        end
      end
    elseif active_idx < start then
      -- active is before the left edge: snap the window's left to active so the
      -- active tab is the first visible one.
      start = active_idx
      ending, _ = fit_right(start)
      if ending < start then
        ending = start
      end
    end
  end

  -- Edge case: a single tab wider than the whole window. Force at least the
  -- active (or first) tab to render; its name is NOT shrunk — it simply
  -- overflows one tab, which is unavoidable and better than rendering nothing.
  if ending < start then
    start = active_idx or 1
    ending = start
  end

  -- Determine folds from what the window excludes.
  layout.left_fold = start > 1
  layout.right_fold = ending < #sessions

  -- Re-verify the window fits with the now-known folds. fit_right already
  -- reserved marker space, so these rarely fire — they're a backstop for the
  -- oversized-single-tab edge case. Never drop the active tab.
  local function total_w()
    return window_width(start, ending, layout.left_fold, layout.right_fold)
  end

  -- Overflow from the right: drop rightmost non-active tabs until it fits.
  while ending > start and total_w() > available_width do
    if active_idx and ending == active_idx then
      break -- never drop the active tab
    end
    ending = ending - 1
    layout.right_fold = ending < #sessions
  end
  -- Overflow from the left: drop leftmost non-active tabs until it fits.
  while start < ending and total_w() > available_width do
    if active_idx and start == active_idx then
      break -- never drop the active tab
    end
    start = start + 1
    layout.left_fold = start > 1
  end

  -- If the new button no longer fits, drop it rather than overflow (overflow
  -- re-triggers the winbar left-truncation we're fixing).
  if show_new and total_w() > available_width then
    layout.show_new = false
    show_new = false
    new_btn_w = 0
  end

  -- Persist the window for next render.
  slot.viewport_start = start

  for i = start, ending do
    local session = sessions[i]
    layout.entries[#layout.entries + 1] = {
      session = session,
      slot_num = session.slot or i,
      name = display_name(session, i),
      is_active = session.id == active_id,
      show_close = show_close,
    }
  end
  layout.viewport_start = start
  layout.viewport_end = ending

  return layout
end

-- Build the content line + highlight ranges for a tabpage. Populates
-- slot.click_regions for mouse dispatch (switch / close / new / scroll-left /
-- scroll-right).
local function build_content(tabpage)
  local slot = get_tab_state(tabpage)
  local sessions = list_sessions_for(tabpage)
  local active_id = session_manager.get_active_session_id()

  slot.click_regions = {}

  if #sessions == 0 then
    return " Claude Code ", {}
  end

  local available_width = nil
  if slot.terminal_win and vim.api.nvim_win_is_valid(slot.terminal_win) then
    available_width = vim.api.nvim_win_get_width(slot.terminal_win)
  end
  local layout = compute_layout(slot, sessions, active_id, available_width)

  local parts = {}
  local highlights = {}
  local col = 1

  local function add_separator()
    table.insert(parts, "|")
    col = col + 1
  end

  -- Left fold marker (clickable: scroll the window one tab left).
  if layout.left_fold then
    local marker = "‹"
    table.insert(slot.click_regions, {
      start_col = col,
      end_col = col + #marker - 1,
      action = "scroll_left",
    })
    table.insert(highlights, { col - 1, col - 1 + #marker, "ClaudeCodeTabInactive" })
    table.insert(parts, marker)
    col = col + #marker
    add_separator()
  end

  for idx, entry in ipairs(layout.entries) do
    local hl_group = entry.is_active and "ClaudeCodeTabActive" or "ClaudeCodeTabInactive"
    local label = string.format(" %d:%s ", entry.slot_num, entry.name)

    local block = label
    table.insert(slot.click_regions, {
      start_col = col,
      end_col = col + #block - 1,
      action = "switch",
      session_id = entry.session.id,
    })
    table.insert(highlights, { col - 1, col - 1 + #block, hl_group })
    table.insert(parts, block)
    col = col + #block

    if entry.show_close then
      local close_btn = "✕ "
      table.insert(slot.click_regions, {
        start_col = col,
        end_col = col + #close_btn - 1,
        action = "close",
        session_id = entry.session.id,
      })
      table.insert(highlights, { col - 1, col - 1 + #close_btn, hl_group })
      table.insert(parts, close_btn)
      col = col + #close_btn
    end

    if idx < #layout.entries or layout.right_fold then
      add_separator()
    end
  end

  -- Right fold marker (clickable: scroll the window one tab right).
  if layout.right_fold then
    local marker = "›"
    table.insert(slot.click_regions, {
      start_col = col,
      end_col = col + #marker - 1,
      action = "scroll_right",
    })
    table.insert(highlights, { col - 1, col - 1 + #marker, "ClaudeCodeTabInactive" })
    table.insert(parts, marker)
    col = col + #marker
  end

  if layout.show_new then
    if #parts > 0 then
      add_separator()
    end
    local new_btn = " + "
    table.insert(slot.click_regions, {
      start_col = col,
      end_col = col + #new_btn - 1,
      action = "new",
    })
    table.insert(parts, new_btn)
    table.insert(highlights, { col - 1, col - 1 + #new_btn, "ClaudeCodeTabNew" })
  end

  return table.concat(parts), highlights
end

---Resolve column under the mouse, scoped to the tabbar window.
---@param tabpage integer
---@return integer|nil col
local function mouse_col_in_tabbar(tabpage)
  local slot = state.tabs[tabpage]
  if not slot or not slot.tabbar_win or not vim.api.nvim_win_is_valid(slot.tabbar_win) then
    return nil
  end
  if not vim.fn.getmousepos then
    return nil
  end
  local mouse = vim.fn.getmousepos()
  if not mouse or mouse.winid ~= slot.tabbar_win then
    return nil
  end
  return mouse.wincol or mouse.column or 1
end

---Refocus the terminal window after a click on the tabbar so the user can
---type into Claude immediately.
---@param tabpage integer
local function refocus_terminal(tabpage)
  local slot = state.tabs[tabpage]
  if slot and slot.terminal_win and vim.api.nvim_win_is_valid(slot.terminal_win) then
    pcall(vim.api.nvim_set_current_win, slot.terminal_win)
  end
end

---Scroll the sliding window one tab left/right and re-render. Used by the ‹/›
---click regions (float path) and the winbar scroll handlers.
---@param tabpage integer
---@param dir "left"|"right"
local function scroll_window(tabpage, dir)
  local slot = state.tabs[tabpage]
  if not slot then
    return
  end
  local sessions = list_sessions_for(tabpage)
  local n = #sessions
  if n == 0 then
    return
  end
  local start = slot.viewport_start or 1
  if dir == "left" then
    start = start - 1
  else
    start = start + 1
  end
  if start < 1 then
    start = 1
  end
  if start > n then
    start = n
  end
  slot.viewport_start = start
  -- Honor the explicit scroll: the next render must not snap the window back
  -- to the active session even if active leaves the window.
  slot.skip_active_clamp = true
  M.render(tabpage)
end

---Dispatch a left click on the tabbar.
---@param tabpage integer
local function handle_left_click(tabpage)
  local col = mouse_col_in_tabbar(tabpage)
  if not col then
    return
  end
  local slot = state.tabs[tabpage]
  for _, region in ipairs(slot.click_regions) do
    if col >= region.start_col and col <= region.end_col then
      if region.action == "switch" and region.session_id then
        local sid = region.session_id
        vim.schedule(function()
          require("claudecode.terminal").switch_to_session(sid)
          refocus_terminal(tabpage)
        end)
      elseif region.action == "close" and region.session_id then
        local sid = region.session_id
        vim.schedule(function()
          require("claudecode.terminal").close_session(sid)
        end)
      elseif region.action == "new" then
        vim.schedule(function()
          require("claudecode.terminal").open_new_session()
          refocus_terminal(tabpage)
        end)
      elseif region.action == "scroll_left" then
        vim.schedule(function()
          scroll_window(tabpage, "left")
          refocus_terminal(tabpage)
        end)
      elseif region.action == "scroll_right" then
        vim.schedule(function()
          scroll_window(tabpage, "right")
          refocus_terminal(tabpage)
        end)
      end
      return
    end
  end
end

---Dispatch a middle click — close the session whose region was hit.
---@param tabpage integer
local function handle_middle_click(tabpage)
  local col = mouse_col_in_tabbar(tabpage)
  if not col then
    return
  end
  local slot = state.tabs[tabpage]
  for _, region in ipairs(slot.click_regions) do
    if col >= region.start_col and col <= region.end_col then
      if region.session_id then
        local sid = region.session_id
        vim.schedule(function()
          require("claudecode.terminal").close_session(sid)
        end)
      end
      return
    end
  end
end

---Cycle through sessions on the wheel.
---@param tabpage integer
---@param direction "up"|"down"
local function handle_scroll(tabpage, direction)
  local sessions = list_sessions_for(tabpage)
  if #sessions <= 1 then
    return
  end
  local active_id = session_manager.get_active_session_id()
  for i, session in ipairs(sessions) do
    if session.id == active_id then
      local next_idx
      if direction == "up" then
        next_idx = ((i - 2) % #sessions) + 1
      else
        next_idx = (i % #sessions) + 1
      end
      local target = sessions[next_idx].id
      vim.schedule(function()
        require("claudecode.terminal").switch_to_session(target)
        refocus_terminal(tabpage)
      end)
      return
    end
  end
end

---Bind buffer-local mouse mappings on the tabbar buffer for a tab.
---@param tabpage integer
---@param buf integer
local function setup_buffer_mappings(tabpage, buf)
  local map = function(lhs, fn)
    vim.keymap.set({ "n", "i" }, lhs, function()
      fn(tabpage)
    end, { buffer = buf, nowait = true, silent = true })
  end
  map("<LeftMouse>", handle_left_click)
  map("<MiddleMouse>", handle_middle_click)
  vim.keymap.set({ "n", "i" }, "<ScrollWheelUp>", function()
    handle_scroll(tabpage, "up")
  end, { buffer = buf, nowait = true, silent = true })
  vim.keymap.set({ "n", "i" }, "<ScrollWheelDown>", function()
    handle_scroll(tabpage, "down")
  end, { buffer = buf, nowait = true, silent = true })
end

---Create or reuse the per-tab tabbar buffer.
---@param tabpage integer
---@return integer bufnr
local function ensure_buffer(tabpage)
  local slot = get_tab_state(tabpage)
  if slot.tabbar_buf and vim.api.nvim_buf_is_valid(slot.tabbar_buf) then
    return slot.tabbar_buf
  end

  -- Fresh buffer: the last_content cache no longer reflects what's on screen,
  -- so clear it or render_float_content would skip writing and leave the new
  -- buffer blank (content string is unchanged from the destroyed buffer).
  slot.last_content = nil

  slot.tabbar_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[slot.tabbar_buf].buftype = "nofile"
  vim.bo[slot.tabbar_buf].bufhidden = "hide"
  vim.bo[slot.tabbar_buf].swapfile = false
  vim.bo[slot.tabbar_buf].modifiable = true

  setup_buffer_mappings(tabpage, slot.tabbar_buf)

  return slot.tabbar_buf
end

---Compute the float window config for the tabbar.
---@param term_win number
---@return table|nil
local function calc_window_config(term_win)
  if not term_win or not vim.api.nvim_win_is_valid(term_win) then
    return nil
  end
  local term_config = vim.api.nvim_win_get_config(term_win)
  local term_pos = vim.api.nvim_win_get_position(term_win)
  local term_width = vim.api.nvim_win_get_width(term_win)

  if term_config.relative and term_config.relative ~= "" then
    return {
      relative = "editor",
      row = term_pos[1],
      col = term_pos[2],
      width = term_width,
      height = 1,
      style = "minimal",
      border = "none",
      zindex = (term_config.zindex or 50) + 1,
      focusable = false, -- click via buffer-local <LeftMouse> map; no focus theft
    }
  end
  -- Splits use the winbar fallback path
  return nil
end

-- Write the float content + highlights into the tabbar buffer, skipping the
-- rewrite entirely when the content is unchanged from the last render. Terminal
-- scrolling fires the resize autocmd frequently; without this cache every
-- scroll would re-set the buffer lines and clear+re-add all highlights.
local function render_float_content(tabpage, slot, content, highlights)
  if not slot.tabbar_buf or not vim.api.nvim_buf_is_valid(slot.tabbar_buf) then
    return
  end
  if content == slot.last_content then
    return
  end
  vim.api.nvim_buf_set_lines(slot.tabbar_buf, 0, -1, false, { content })
  local ns = vim.api.nvim_create_namespace("claudecode_tabbar")
  vim.api.nvim_buf_clear_namespace(slot.tabbar_buf, ns, 0, -1)
  for _, hl in ipairs(highlights) do
    pcall(vim.api.nvim_buf_add_highlight, slot.tabbar_buf, ns, hl[3], 0, hl[1], hl[2])
  end
  slot.last_content = content
end

-- Reposition the float only when its config actually changed. calc_window_config
-- returns the same table shape every call during a scroll storm; re-applying an
-- identical nvim_win_set_config marks the float (and the terminal region it
-- overlaps) for redraw each time.
local function apply_float_config(slot, win_config)
  if not win_config then
    return
  end
  local prev = slot.last_config
  if
    prev
    and prev.row == win_config.row
    and prev.col == win_config.col
    and prev.width == win_config.width
    and prev.height == win_config.height
  then
    return
  end
  if slot.tabbar_win and vim.api.nvim_win_is_valid(slot.tabbar_win) then
    pcall(vim.api.nvim_win_set_config, slot.tabbar_win, win_config)
  end
  slot.last_config = win_config
end

---Show the tabbar for a tab.
---@param tabpage integer|nil
function M.show(tabpage)
  if not state.config or not state.config.enabled then
    return
  end
  tabpage = resolve_tab(tabpage)
  if not tabpage then
    return
  end
  local slot = get_tab_state(tabpage)
  if not slot.terminal_win or not vim.api.nvim_win_is_valid(slot.terminal_win) then
    return
  end

  local win_config = calc_window_config(slot.terminal_win)
  if not win_config then
    M.render_winbar(tabpage)
    return
  end

  ensure_buffer(tabpage)

  if not (slot.tabbar_win and vim.api.nvim_win_is_valid(slot.tabbar_win)) then
    slot.tabbar_win = vim.api.nvim_open_win(slot.tabbar_buf, false, win_config)
    vim.api.nvim_win_set_option(slot.tabbar_win, "winhl", "Normal:ClaudeCodeTabBar")
    slot.last_config = win_config
    slot.last_content = nil -- fresh window: content not yet written
  else
    apply_float_config(slot, win_config)
  end

  M.render(tabpage)
end

---Hide the tabbar for a tab.
---@param tabpage integer|nil
function M.hide(tabpage)
  tabpage = resolve_tab(tabpage)
  if not tabpage then
    return
  end
  local slot = state.tabs[tabpage]
  if not slot then
    return
  end
  if slot.tabbar_win and vim.api.nvim_win_is_valid(slot.tabbar_win) then
    pcall(vim.api.nvim_win_close, slot.tabbar_win, true)
  end
  slot.tabbar_win = nil
  slot.last_config = nil
  slot.last_content = nil
  if slot.terminal_win and vim.api.nvim_win_is_valid(slot.terminal_win) then
    pcall(function()
      vim.wo[slot.terminal_win].winbar = nil
    end)
  end
end

---Render tab bar content for a tab.
---@param tabpage integer|nil
function M.render(tabpage)
  if not state.config or not state.config.enabled then
    return
  end
  tabpage = resolve_tab(tabpage)
  if not tabpage then
    return
  end
  local slot = state.tabs[tabpage]
  if not slot then
    return
  end

  if slot.tabbar_win and vim.api.nvim_win_is_valid(slot.tabbar_win) then
    -- Float path: build the single-line content + highlights and write them.
    local content, highlights = build_content(tabpage)
    render_float_content(tabpage, slot, content, highlights)

    if slot.terminal_win and vim.api.nvim_win_is_valid(slot.terminal_win) then
      apply_float_config(slot, calc_window_config(slot.terminal_win))
    end
  else
    -- Winbar path: build_winbar_string runs compute_layout itself. Do NOT also
    -- call build_content here — that would run compute_layout twice and let the
    -- first invocation consume the one-shot skip_active_clamp flag (set by an
    -- explicit ‹/› scroll), snapping the window back to the active session.
    M.render_winbar(tabpage)
  end
end

-- Resolve a winbar click index to a session id in the current tab. Click
-- handlers only carry the index; the user clicks winbar in their focused tab.
local function current_tab_winbar_session(idx)
  local ok, tab = pcall(vim.api.nvim_get_current_tabpage)
  if not ok or not tab then
    return nil
  end
  local slot = state.tabs[tab]
  if not slot then
    return nil
  end
  return slot.winbar_session_ids[idx]
end

function _G.ClaudeCodeTabClick(session_idx, _, button, _)
  local session_id = current_tab_winbar_session(session_idx)
  if not session_id then
    return
  end
  vim.schedule(function()
    if button == "l" then
      require("claudecode.terminal").switch_to_session(session_id)
    elseif button == "m" then
      require("claudecode.terminal").close_session(session_id)
    end
  end)
end

function _G.ClaudeCodeCloseTabClick(session_idx, _, button, _)
  if button ~= "l" then
    return
  end
  local session_id = current_tab_winbar_session(session_idx)
  if not session_id then
    return
  end
  vim.schedule(function()
    require("claudecode.terminal").close_session(session_id)
  end)
end

function _G.ClaudeCodeNewTabClick(_, _, button, _)
  if button == "l" then
    vim.schedule(function()
      require("claudecode.terminal").open_new_session()
    end)
  end
end

-- Winbar scroll: ‹/› use a fixed click id (0 = left, -1 = right) since they
-- don't map to a session. Resolve the current tab and scroll its window.
function _G.ClaudeCodeTabScrollClick(_, _, button, _)
  if button ~= "l" then
    return
  end
  local ok, tab = pcall(vim.api.nvim_get_current_tabpage)
  if not ok or not tab then
    return
  end
  vim.schedule(function()
    scroll_window(tab, "left")
  end)
end

function _G.ClaudeCodeTabScrollRightClick(_, _, button, _)
  if button ~= "l" then
    return
  end
  local ok, tab = pcall(vim.api.nvim_get_current_tabpage)
  if not ok or not tab then
    return
  end
  vim.schedule(function()
    scroll_window(tab, "right")
  end)
end

-- Build the winbar string for split mode. Populates slot.winbar_session_ids so
-- click handlers can resolve idx → session_id. Uses the sliding-window layout:
-- a contiguous slice of sessions with ‹/› fold markers on folded sides.
local function build_winbar_string(tabpage)
  local slot = state.tabs[tabpage]
  if not slot or not slot.terminal_win or not vim.api.nvim_win_is_valid(slot.terminal_win) then
    return nil
  end

  local sessions = list_sessions_for(tabpage)
  local active_id = session_manager.get_active_session_id()
  if #sessions == 0 then
    return nil
  end

  local available_width = vim.api.nvim_win_get_width(slot.terminal_win)
  local layout = compute_layout(slot, sessions, active_id, available_width)

  slot.winbar_session_ids = {}

  local parts = {}

  if layout.left_fold then
    -- %0@...@ is the winbar id reserved for non-session clicks (the new button
    -- uses it too, but each clickable region is self-contained by %X).
    local click = "%0@v:lua.ClaudeCodeTabScrollClick@"
    table.insert(parts, click .. "%#ClaudeCodeTabInactive#‹%X")
  end

  for i, entry in ipairs(layout.entries) do
    -- Click handler index must match the position in winbar_session_ids, which
    -- only contains the *rendered* tabs (so a dropped tab never steals a click).
    slot.winbar_session_ids[i] = entry.session.id

    local hl = entry.is_active and "%#ClaudeCodeTabActive#" or "%#ClaudeCodeTabInactive#"
    local click_start = string.format("%%%d@v:lua.ClaudeCodeTabClick@", i)
    local click_end = "%X"

    local tab_content = hl .. " " .. entry.slot_num .. ":" .. entry.name .. " "

    if entry.show_close then
      local close_click = string.format("%%%d@v:lua.ClaudeCodeCloseTabClick@", i)
      tab_content = tab_content .. click_end .. close_click .. hl .. "✕%X "
    end

    table.insert(parts, click_start .. tab_content .. click_end)
  end

  if layout.right_fold then
    local click = "%0@v:lua.ClaudeCodeTabScrollRightClick@"
    table.insert(parts, click .. "%#ClaudeCodeTabInactive#›%X")
  end

  if layout.show_new then
    local click_start = "%0@v:lua.ClaudeCodeNewTabClick@"
    local click_end = "%X"
    table.insert(parts, click_start .. "%#ClaudeCodeTabNew# + " .. click_end)
  end

  return table.concat(parts, "%#StatusLine#|") .. "%#Normal#"
end

---Render the tabbar as a winbar on the terminal window (split mode).
---@param tabpage integer|nil
function M.render_winbar(tabpage)
  tabpage = resolve_tab(tabpage)
  if not tabpage then
    return
  end
  local winbar = build_winbar_string(tabpage)
  if not winbar then
    return
  end
  local slot = state.tabs[tabpage]
  pcall(function()
    vim.wo[slot.terminal_win].winbar = winbar
  end)
end

function M.setup_keymaps(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local keymaps = state.config and state.config.keymaps or {}
  local terminal = require("claudecode.terminal")

  -- Cycle to the next/prev session. `dir` is 1 (next) or -1 (prev).
  local function cycle_session(dir)
    local sessions = list_sessions_for(vim.api.nvim_get_current_tabpage())
    if #sessions <= 1 then
      return
    end
    local active_id = session_manager.get_active_session_id()
    for i, session in ipairs(sessions) do
      if session.id == active_id then
        local idx = ((i - 1 + dir) % #sessions) + 1
        terminal.switch_to_session(sessions[idx].id)
        return
      end
    end
  end

  if keymaps.next_tab then
    vim.keymap.set({ "n", "t" }, keymaps.next_tab, function()
      cycle_session(1)
    end, { buffer = bufnr, desc = "Next Claude session" })
  end

  if keymaps.prev_tab then
    vim.keymap.set({ "n", "t" }, keymaps.prev_tab, function()
      cycle_session(-1)
    end, { buffer = bufnr, desc = "Previous Claude session" })
  end

  if keymaps.new_tab then
    vim.keymap.set({ "n", "t" }, keymaps.new_tab, function()
      terminal.open_new_session()
    end, { buffer = bufnr, desc = "New Claude session" })
  end

  if keymaps.close_tab then
    vim.keymap.set({ "n", "t" }, keymaps.close_tab, function()
      local active_id = session_manager.get_active_session_id()
      if active_id then
        terminal.close_session(active_id)
      end
    end, { buffer = bufnr, desc = "Close Claude session" })
  end
end

-- Iterate every per-tab slot. Drops slots whose tabpage is no longer valid.
local function for_each_tab(fn)
  for tab, slot in pairs(state.tabs) do
    if not vim.api.nvim_tabpage_is_valid(tab) then
      state.tabs[tab] = nil
    else
      fn(tab, slot)
    end
  end
end

local function tab_for_terminal_win(winid)
  for tab, slot in pairs(state.tabs) do
    if slot.terminal_win == winid then
      return tab
    end
  end
  return nil
end

local function setup_autocmds()
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
  end
  state.augroup = vim.api.nvim_create_augroup("ClaudeCodeTabBar", { clear = true })

  -- Re-position float / re-render winbar when window GEOMETRY changes.
  -- WinResized fires on split/terminal-window size changes. We deliberately
  -- do NOT listen to WinScrolled: that fires on every line of terminal scroll
  -- (Claude TUI streaming output), and the float's geometry is unaffected by
  -- scrolling — re-running show/render on each scroll line caused a redraw
  -- storm over the terminal and made Claude's TUI feel sluggish.
  vim.api.nvim_create_autocmd({ "WinResized" }, {
    group = state.augroup,
    callback = function()
      for_each_tab(function(tab, slot)
        if slot.tabbar_win and vim.api.nvim_win_is_valid(slot.tabbar_win) then
          M.show(tab)
        elseif slot.terminal_win and vim.api.nvim_win_is_valid(slot.terminal_win) then
          M.render_winbar(tab)
        end
      end)
    end,
  })

  -- Session-state events touch every tab's tabbar so the active indicator and
  -- session list stay correct.
  vim.api.nvim_create_autocmd("User", {
    group = state.augroup,
    pattern = {
      "ClaudeCodeSessionCreated",
      "ClaudeCodeSessionDestroyed",
      "ClaudeCodeSessionNameChanged",
      "ClaudeCodeSessionActivated",
    },
    callback = function()
      for_each_tab(function(tab, slot)
        if slot.tabbar_win and vim.api.nvim_win_is_valid(slot.tabbar_win) then
          M.render(tab)
        elseif slot.terminal_win and vim.api.nvim_win_is_valid(slot.terminal_win) then
          M.render_winbar(tab)
        end
      end)
    end,
  })

  -- Terminal window closed → clear that tab's tabbar slot.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = state.augroup,
    callback = function(args)
      local win = tonumber(args.match)
      if not win then
        return
      end
      local tab = tab_for_terminal_win(win)
      if tab then
        M.hide(tab)
        state.tabs[tab].terminal_win = nil
      end
    end,
  })

  -- Tab closed → drop the slot entirely.
  vim.api.nvim_create_autocmd("TabClosed", {
    group = state.augroup,
    callback = function()
      for tab, _ in pairs(state.tabs) do
        if not vim.api.nvim_tabpage_is_valid(tab) then
          state.tabs[tab] = nil
        end
      end
    end,
  })

  -- Tab entered: re-attach the tabbar if the terminal window is in this tab
  -- but the float was lost (user :close'd it, or the slot was never created).
  vim.api.nvim_create_autocmd("TabEnter", {
    group = state.augroup,
    callback = function()
      local ok, tab = pcall(vim.api.nvim_get_current_tabpage)
      if not ok or not tab then
        return
      end
      local sid = session_manager.get_active_session_id()
      if not sid then
        return
      end
      local sess = session_manager.get_session(sid)
      if not sess or not sess.terminal_bufnr or not vim.api.nvim_buf_is_valid(sess.terminal_bufnr) then
        return
      end
      for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
        if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == sess.terminal_bufnr then
          local slot = get_tab_state(tab)
          if not slot.tabbar_win or not vim.api.nvim_win_is_valid(slot.tabbar_win) then
            slot.terminal_win = w
            M.show(tab)
          end
          return
        end
      end
    end,
  })
end

---Initialize the tab bar module.
---@param config table Tabs configuration
function M.setup(config)
  state.config = config
  setup_highlights()
  if config and config.enabled then
    setup_autocmds()
  end
end

---Attach the tabbar to a terminal window. The tab is resolved from the
---window's tabpage so callers don't need to pass it.
---@param terminal_win integer Terminal window ID
---@param terminal_bufnr integer|nil Terminal buffer (for keymaps)
---@param _ any Unused (kept for API compatibility)
function M.attach(terminal_win, terminal_bufnr, _)
  if not state.config or not state.config.enabled then
    return
  end
  if not terminal_win or not vim.api.nvim_win_is_valid(terminal_win) then
    return
  end
  local ok, tab = pcall(vim.api.nvim_win_get_tabpage, terminal_win)
  if not ok or not tab then
    return
  end

  local slot = get_tab_state(tab)
  slot.terminal_win = terminal_win

  if terminal_bufnr then
    M.setup_keymaps(terminal_bufnr)
  end

  M.show(tab)
end

---Detach the tabbar from a tab. Defaults to the current tab.
---@param tabpage integer|nil
function M.detach(tabpage)
  tabpage = resolve_tab(tabpage)
  if not tabpage then
    return
  end
  M.hide(tabpage)
  local slot = state.tabs[tabpage]
  if slot then
    slot.terminal_win = nil
  end
end

---Whether the tabbar is visible in the current tab.
---@return boolean
function M.is_visible()
  local ok, tab = pcall(vim.api.nvim_get_current_tabpage)
  if not ok then
    return false
  end
  local slot = state.tabs[tab]
  if not slot then
    return false
  end
  if slot.tabbar_win and vim.api.nvim_win_is_valid(slot.tabbar_win) then
    return true
  end
  if slot.terminal_win and vim.api.nvim_win_is_valid(slot.terminal_win) then
    return vim.wo[slot.terminal_win].winbar ~= ""
  end
  return false
end

---Get the tabbar window id for the current tab (nil if none).
---@return integer|nil
function M.get_winid()
  local ok, tab = pcall(vim.api.nvim_get_current_tabpage)
  if not ok then
    return nil
  end
  local slot = state.tabs[tab]
  if slot and slot.tabbar_win and vim.api.nvim_win_is_valid(slot.tabbar_win) then
    return slot.tabbar_win
  end
  return nil
end

---Cleanup state for one tab (or current tab if omitted).
---@param tabpage integer|nil
function M.cleanup(tabpage)
  tabpage = resolve_tab(tabpage)
  if not tabpage then
    return
  end
  M.hide(tabpage)
  local slot = state.tabs[tabpage]
  if slot and slot.tabbar_buf and vim.api.nvim_buf_is_valid(slot.tabbar_buf) then
    pcall(vim.api.nvim_buf_delete, slot.tabbar_buf, { force = true })
  end
  state.tabs[tabpage] = nil
end

---Cleanup every tab's tabbar (plugin reload / VimLeavePre).
function M.cleanup_all()
  for tab, _ in pairs(state.tabs) do
    M.cleanup(tab)
  end
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    state.augroup = nil
  end
  -- Drop the global winbar click handlers so a plugin reload doesn't leave
  -- stale function refs on _G.
  for _, name in ipairs({
    "ClaudeCodeTabClick",
    "ClaudeCodeCloseTabClick",
    "ClaudeCodeNewTabClick",
    "ClaudeCodeTabScrollClick",
    "ClaudeCodeTabScrollRightClick",
  }) do
    _G[name] = nil
  end
end

---Snapshot of per-tab state for tests / debugging.
---@return table<integer, TabBarTabState>
function M._snapshot()
  local out = {}
  for tab, slot in pairs(state.tabs) do
    out[tab] = {
      tabbar_win = slot.tabbar_win,
      tabbar_buf = slot.tabbar_buf,
      terminal_win = slot.terminal_win,
      click_regions = vim.deepcopy(slot.click_regions),
      winbar_session_ids = vim.deepcopy(slot.winbar_session_ids),
      viewport_start = slot.viewport_start,
    }
  end
  return out
end

---Reset module state (tests).
function M._reset()
  for tab, _ in pairs(state.tabs) do
    state.tabs[tab] = nil
  end
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    state.augroup = nil
  end
  state.config = nil
end

---Expose build_content for tests. Renders the float-path content string and
---highlight ranges for the sessions in a tabpage without requiring a real
---tabbar window/buffer.
M._build_content = build_content

---Expose the winbar string builder for tests. The production render_winbar
---sets vim.wo[...].winbar directly (unsupported in the busted mock), so tests
---assert on this return value instead. Resolves the tabpage first.
M._build_winbar = function(tabpage)
  tabpage = resolve_tab(tabpage)
  if not tabpage then
    return nil
  end
  return build_winbar_string(tabpage)
end

return M
