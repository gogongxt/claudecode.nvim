---toggleterm.nvim terminal provider for Claude Code.
---@module 'claudecode.terminal.toggleterm'

local M = {}

local logger = require("claudecode.logger")
local utils = require("claudecode.utils")

local toggleterm_available, toggleterm = pcall(require, "toggleterm")
if not toggleterm_available then
  toggleterm = nil
end

local Terminal = nil
if toggleterm_available then
  Terminal = require("toggleterm.terminal").Terminal
end

---The single managed Claude terminal instance (single-session for now).
local claude_terminal = nil

---@return boolean
local function is_available()
  return toggleterm_available and Terminal ~= nil
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

---Compute the vertical-split width (in columns) from split_width_percentage.
---@param effective_config ClaudeCodeTerminalConfig
---@return number|nil
local function resolve_split_size(effective_config)
  local pct = effective_config.split_width_percentage
  if not pct then
    return nil
  end
  local size = math.floor(vim.o.columns * pct)
  return math.max(20, math.min(size, 120))
end

---Apply split_side positioning and width to an already-opened toggleterm window.
---@param term table The toggleterm Terminal instance
---@param effective_config ClaudeCodeTerminalConfig
local function apply_split_layout(term, effective_config)
  if not (term and term.window and vim.api.nvim_win_is_valid(term.window)) then
    return
  end
  if effective_config.split_side == "left" then
    vim.api.nvim_win_call(term.window, function()
      vim.cmd("wincmd H")
    end)
  elseif effective_config.split_side == "right" then
    vim.api.nvim_win_call(term.window, function()
      vim.cmd("wincmd L")
    end)
  end
  local size = resolve_split_size(effective_config)
  if size then
    vim.api.nvim_win_call(term.window, function()
      vim.cmd("vertical resize " .. size)
    end)
  end
end

---Build (or refresh) the managed Claude toggleterm Terminal instance.
---@param cmd_string string
---@param env_table table
---@param effective_config ClaudeCodeTerminalConfig
---@return table? term The toggleterm Terminal instance
local function get_or_create_terminal(cmd_string, env_table, effective_config)
  local cwd = resolve_cwd(effective_config)

  if not claude_terminal then
    claude_terminal = Terminal:new({
      cmd = cmd_string,
      dir = cwd,
      direction = "vertical",
      env = env_table,
      display_name = "Claude Code",
      close_on_exit = effective_config.auto_close ~= false,
      auto_scroll = false,
      hidden = false,
      on_open = function(term)
        if term.bufnr then
          vim.api.nvim_buf_set_var(term.bufnr, "toggle_number", term.id)
          -- Ctrl-/ and Ctrl-_ produce the same byte in terminal mode; route to ESC
          -- so Claude's TUI sees a plain ESC (cancel input).
          vim.api.nvim_buf_set_keymap(term.bufnr, "t", "<C-/>", "<Esc>", { noremap = true, silent = true })
          vim.api.nvim_buf_set_keymap(term.bufnr, "t", "<C-_>", "<Esc>", { noremap = true, silent = true })
        end
        if term.window and vim.api.nvim_win_is_valid(term.window) then
          vim.wo[term.window].wrap = false
          vim.wo[term.window].scrolloff = 0
          vim.wo[term.window].sidescrolloff = 0
        end
        apply_split_layout(term, effective_config)
        vim.cmd("startinsert")
      end,
      on_close = function(_)
        vim.cmd("stopinsert")
      end,
    })
  else
    claude_terminal.cmd = cmd_string
    claude_terminal.env = env_table
    claude_terminal.dir = cwd
    claude_terminal.close_on_exit = effective_config.auto_close ~= false
  end

  return claude_terminal
end

function M.setup()
  -- toggleterm is configured by the user's own toggleterm.nvim setup; nothing to do.
end

---Open the Claude terminal.
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

  local term = get_or_create_terminal(cmd_string, env_table, config)
  if not term then
    return
  end

  if not term:is_open() then
    term:open()
  end
  apply_split_layout(term, config)

  if focus and term.window then
    vim.api.nvim_set_current_win(term.window)
    if config.auto_insert ~= false then
      vim.cmd("startinsert")
    end
  end
end

---Close the managed terminal.
function M.close()
  if claude_terminal and claude_terminal:is_open() then
    claude_terminal:close()
  end
end

---Simple toggle: show/hide regardless of focus.
---@param cmd_string string
---@param env_table table
---@param config ClaudeCodeTerminalConfig
function M.simple_toggle(cmd_string, env_table, config)
  if not is_available() then
    vim.notify("toggleterm.nvim provider selected but toggleterm not available.", vim.log.levels.ERROR)
    return
  end
  local term = get_or_create_terminal(cmd_string, env_table, config)
  if not term then
    return
  end
  term:toggle()
  apply_split_layout(term, config)
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
  local term = get_or_create_terminal(cmd_string, env_table, config)
  if not term then
    return
  end

  if not term:is_open() then
    term:open()
    apply_split_layout(term, config)
    if term.window then
      vim.api.nvim_set_current_win(term.window)
      if config.auto_insert ~= false then
        vim.cmd("startinsert")
      end
    end
    return
  end

  local current_win = vim.api.nvim_get_current_win()
  if term.window == current_win then
    term:close()
  else
    apply_split_layout(term, config)
    if term.window then
      vim.api.nvim_set_current_win(term.window)
      if config.auto_insert ~= false then
        vim.cmd("startinsert")
      end
    end
  end
end

---Legacy toggle alias.
function M.toggle(cmd_string, env_table, config)
  M.simple_toggle(cmd_string, env_table, config)
end

---Get the active terminal buffer number.
---@return number?
function M.get_active_bufnr()
  if claude_terminal and claude_terminal.bufnr and claude_terminal:is_open() then
    return claude_terminal.bufnr
  end
  return nil
end

---@return boolean
function M.is_available()
  return is_available()
end

---Ensure the terminal is visible (no focus change).
function M.ensure_visible()
  if claude_terminal and not claude_terminal:is_open() then
    claude_terminal:open()
  end
end

---For testing purposes.
---@return table? terminal The toggleterm Terminal instance, or nil
function M._get_terminal_for_test()
  return claude_terminal
end

---@type ClaudeCodeTerminalProvider
return M
