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

local state = {
  tabs = {},
  augroup = nil,
  config = nil,
}

local function get_tab_state(tabpage)
  local slot = state.tabs[tabpage]
  if not slot then
    slot = { click_regions = {}, winbar_session_ids = {} }
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

-- Build the content line + highlight ranges for a tabpage. Populates
-- slot.click_regions for mouse dispatch.
local function build_content(tabpage)
  local slot = get_tab_state(tabpage)
  local sessions = list_sessions_for(tabpage)
  local active_id = session_manager.get_active_session_id()

  slot.click_regions = {}

  if #sessions == 0 then
    return " Claude Code ", {}
  end

  local parts = {}
  local highlights = {}
  local col = 1

  for i, session in ipairs(sessions) do
    local is_active = session.id == active_id
    local name = session.name or ("Session " .. i)
    if #name > 12 then
      name = name:sub(1, 9) .. "..."
    end

    -- Slot number (not positional index) so the tabbar matches <leader>N.
    local slot_num = session.slot or i
    local label = string.format(" %d:%s ", slot_num, name)
    local hl_group = is_active and "ClaudeCodeTabActive" or "ClaudeCodeTabInactive"

    local block = label
    table.insert(slot.click_regions, {
      start_col = col,
      end_col = col + #block - 1,
      action = "switch",
      session_id = session.id,
    })
    table.insert(highlights, { col - 1, col - 1 + #block, hl_group })
    table.insert(parts, block)
    col = col + #block

    if state.config and state.config.show_close_button then
      local close_btn = "✕ "
      table.insert(slot.click_regions, {
        start_col = col,
        end_col = col + #close_btn - 1,
        action = "close",
        session_id = session.id,
      })
      table.insert(highlights, { col - 1, col - 1 + #close_btn, hl_group })
      table.insert(parts, close_btn)
      col = col + #close_btn
    end

    if i < #sessions then
      table.insert(parts, "|")
      col = col + 1
    end
  end

  if state.config and state.config.show_new_button then
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

  if slot.tabbar_win and vim.api.nvim_win_is_valid(slot.tabbar_win) then
    vim.api.nvim_win_set_config(slot.tabbar_win, win_config)
  else
    slot.tabbar_win = vim.api.nvim_open_win(slot.tabbar_buf, false, win_config)
    vim.api.nvim_win_set_option(slot.tabbar_win, "winhl", "Normal:ClaudeCodeTabBar")
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

  local content, highlights = build_content(tabpage)

  if slot.tabbar_win and vim.api.nvim_win_is_valid(slot.tabbar_win) then
    if slot.tabbar_buf and vim.api.nvim_buf_is_valid(slot.tabbar_buf) then
      vim.api.nvim_buf_set_lines(slot.tabbar_buf, 0, -1, false, { content })

      local ns = vim.api.nvim_create_namespace("claudecode_tabbar")
      vim.api.nvim_buf_clear_namespace(slot.tabbar_buf, ns, 0, -1)
      for _, hl in ipairs(highlights) do
        pcall(vim.api.nvim_buf_add_highlight, slot.tabbar_buf, ns, hl[3], 0, hl[1], hl[2])
      end
    end

    if slot.terminal_win and vim.api.nvim_win_is_valid(slot.terminal_win) then
      local win_config = calc_window_config(slot.terminal_win)
      if win_config then
        pcall(vim.api.nvim_win_set_config, slot.tabbar_win, win_config)
      end
    end
  else
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

-- Build the winbar string for split mode. Populates slot.winbar_session_ids so
-- click handlers can resolve idx → session_id.
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

  slot.winbar_session_ids = {}

  local parts = {}
  for i, session in ipairs(sessions) do
    local is_active = session.id == active_id
    local name = session.name or ("Session " .. i)
    if #name > 12 then
      name = name:sub(1, 9) .. "..."
    end

    slot.winbar_session_ids[i] = session.id

    local hl = is_active and "%#ClaudeCodeTabActive#" or "%#ClaudeCodeTabInactive#"
    local click_start = string.format("%%%d@v:lua.ClaudeCodeTabClick@", i)
    local click_end = "%X"

    local slot_num = session.slot or i
    local tab_content = hl .. " " .. slot_num .. ":" .. name .. " "

    if state.config and state.config.show_close_button then
      local close_click = string.format("%%%d@v:lua.ClaudeCodeCloseTabClick@", i)
      tab_content = tab_content .. click_end .. close_click .. hl .. "✕%X "
    end

    table.insert(parts, click_start .. tab_content .. click_end)
  end

  if state.config and state.config.show_new_button then
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

  -- Re-position float / re-render winbar when geometry changes.
  vim.api.nvim_create_autocmd({ "WinResized", "WinScrolled" }, {
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
  for _, name in ipairs({ "ClaudeCodeTabClick", "ClaudeCodeCloseTabClick", "ClaudeCodeNewTabClick" }) do
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
