---Toggleterm terminal provider for Claude Code.
---@module 'claudecode.terminal.toggleterm'

local M = {}

local toggleterm_available, toggleterm = pcall(require, "toggleterm")
local Terminal = require("toggleterm.terminal").Terminal
local utils = require("claudecode.utils")

-- Multi-instance support: maintain separate terminal instances for each instance
local terminals = {} -- instance_id -> terminal instance

--- @return boolean
local function is_available()
  return toggleterm_available and toggleterm ~= nil
end

-- Get current instance ID from environment or buffer
local function get_instance_id()
  local instance_id = 1 -- default
  local env_instance_ok, env_instance = pcall(vim.fn.getenv, "CLAUDE_INSTANCE_ID")
  if env_instance_ok and env_instance and type(env_instance) == "string" and env_instance ~= "" then
    local match = env_instance:match("claude_(%d+)")
    if match then
      instance_id = tonumber(match)
    end
  end

  -- Also check current buffer for instance marker
  local current_buf = vim.api.nvim_get_current_buf()
  local ok, buf_instance = pcall(vim.api.nvim_buf_get_var, current_buf, "claude_instance")
  if ok and buf_instance then
    -- Only use buffer instance if it's different from environment and environment is default (1)
    if not env_instance_ok or not env_instance or env_instance == "" then
      instance_id = buf_instance
    end
  end

  return instance_id
end

-- Get terminal instance for current instance
local function get_terminal(instance_id)
  instance_id = instance_id or get_instance_id()
  return terminals[instance_id], instance_id
end

-- Clean up terminal instance
local function cleanup_terminal(instance_id)
  instance_id = instance_id or get_instance_id()
  terminals[instance_id] = nil
end

---Get or create a terminal instance for the given instance
---@param cmd_string string The command to run
---@param env_table table Environment variables
---@param config table Terminal configuration
---@param instance_id number The instance ID
---@return table terminal The toggleterm terminal instance
local function get_or_create_terminal(cmd_string, env_table, config, instance_id)
  instance_id = instance_id or get_instance_id()
  local terminal = terminals[instance_id]

  -- Use config.cwd if provided, otherwise use current working directory
  local cwd = config and config.cwd or vim.fn.getcwd()

  -- Determine terminal size based on config
  local size = nil
  if config and config.split_width_percentage then
    -- For vertical splits, calculate the exact width
    size = math.floor(vim.o.columns * config.split_width_percentage)
    -- Ensure minimum size of 20 columns and maximum of 120 columns
    size = math.max(20, math.min(size, 120))
  end

  -- Determine direction based on split_side config
  -- toggleterm uses 'vertical' for both left and right splits
  local direction = "vertical"

  if not terminal then
    terminal = Terminal:new {
      cmd = cmd_string,
      dir = cwd,
      direction = direction,
      env = env_table,
      display_name = "Claude Code",
      close_on_exit = config and config.auto_close ~= false, -- Default to true unless explicitly false
      auto_scroll = false,
      hidden = false, -- Make it discoverable by normal toggleterm commands
      on_open = function(term)
        -- Set up terminal-specific keymaps if needed
        if term.bufnr then
          vim.api.nvim_buf_set_var(term.bufnr, "toggle_number", term.id)
          vim.api.nvim_buf_set_var(term.bufnr, "claude_instance", instance_id)
          -- Map Ctrl+/ to send ESC to terminal
          vim.api.nvim_buf_set_keymap(term.bufnr, "t", "<C-_>", "<Esc>", { noremap = true, silent = true })
        end
        -- Start insert mode when opening
        vim.cmd "startinsert"
      end,
      on_close = function(term)
        -- Clean up when terminal is closed
        vim.cmd "stopinsert"
        -- Note: Don't immediately cleanup on close, allow reuse
        -- cleanup_terminal(instance_id)
      end,
      float_opts = {
        width = math.floor(vim.o.columns * 0.8),
        height = math.floor(vim.o.lines * 0.8),
        border = "single",
        winblend = 3,
      },
    }
    terminals[instance_id] = terminal
  else
    -- Update command, environment, and directory if needed
    terminal.cmd = cmd_string
    terminal.env = env_table
    terminal.dir = cwd
    -- Update close_on_exit setting if it changed
    if config then terminal.close_on_exit = config.auto_close ~= false end
  end

  -- Handle split positioning and resizing (toggleterm doesn't directly support
  -- left/right positioning in the constructor, but we can move and resize after it opens)
  local original_open = terminal.open
  terminal.open = function(self, size_override, direction_override)
    -- Call the original open function
    original_open(self, size, direction_override)

    -- Move and resize window if it's a vertical split and we have config
    if self:is_open() and self.window and config then
      if config.split_side then
        if config.split_side == "left" then
          -- Move to the leftmost position
          vim.api.nvim_win_call(self.window, function() vim.cmd "wincmd H" end)
        elseif config.split_side == "right" then
          -- Move to the rightmost position
          vim.api.nvim_win_call(self.window, function() vim.cmd "wincmd L" end)
        end
      end

      -- Apply exact width resizing if specified
      if size and config.split_width_percentage then
        vim.api.nvim_win_call(self.window, function() vim.cmd("vertical resize " .. size) end)
      end
    end
  end

  return terminal
end

function M.setup()
  -- No specific setup needed for toggleterm provider
end

---Open a terminal using toggleterm
---@param cmd_string string
---@param env_table table
---@param config ClaudeCodeTerminalConfig
---@param focus boolean?
function M.open(cmd_string, env_table, config, focus)
  if not is_available() then
    vim.notify("Toggleterm provider selected but toggleterm not available.", vim.log.levels.ERROR)
    return
  end

  focus = utils.normalize_focus(focus)
  local logger = require("claudecode.logger")
  local terminal, instance_id = get_terminal()

  logger.debug("terminal", "M.open called for instance " .. instance_id .. " (env: " .. (env_table.CLAUDE_CODE_SSE_PORT or "nil") .. ")")

  terminal = get_or_create_terminal(cmd_string, env_table, config, instance_id)

  if not terminal:is_open() then
    terminal:open()
  end

  if focus and terminal.window then
    vim.api.nvim_set_current_win(terminal.window)
    vim.cmd "startinsert"
  end
end

---Close the terminal
function M.close()
  if not is_available() then
    return
  end
  local terminal, instance_id = get_terminal()
  if terminal and terminal:is_open() then
    terminal:close()
    -- Don't cleanup immediately to allow re-opening the same terminal
  end
end

---Simple toggle: always show/hide terminal regardless of focus
---@param cmd_string string
---@param env_table table
---@param config table
function M.simple_toggle(cmd_string, env_table, config)
  if not is_available() then
    vim.notify("Toggleterm provider selected but toggleterm not available.", vim.log.levels.ERROR)
    return
  end

  local logger = require("claudecode.logger")
  local terminal, instance_id = get_terminal()

  -- Check if terminal exists and is visible
  if terminal and terminal:is_open() then
    -- Terminal is visible, hide it
    logger.debug("terminal", "Simple toggle: hiding visible terminal for instance " .. instance_id)
    terminal:close()
  else
    -- No terminal exists or not visible, create/show it
    logger.debug("terminal", "Simple toggle: creating/showing terminal for instance " .. instance_id)
    terminal = get_or_create_terminal(cmd_string, env_table, config, instance_id)
    terminal:toggle()
  end
end

---Smart focus toggle: switches to terminal if not focused, hides if currently focused
---@param cmd_string string
---@param env_table table
---@param config table
function M.focus_toggle(cmd_string, env_table, config)
  if not is_available() then
    vim.notify("Toggleterm provider selected but toggleterm not available.", vim.log.levels.ERROR)
    return
  end

  local logger = require("claudecode.logger")
  local terminal, instance_id = get_terminal()

  -- Get or create terminal first
  if not terminal then
    logger.debug("terminal", "Focus toggle: creating new terminal for instance " .. instance_id)
    terminal = get_or_create_terminal(cmd_string, env_table, config, instance_id)
  end

  if not terminal:is_open() then
    -- Terminal is not open, open it and focus
    logger.debug("terminal", "Focus toggle: opening terminal for instance " .. instance_id)
    terminal:open()
    if terminal.window then
      vim.api.nvim_set_current_win(terminal.window)
      vim.cmd "startinsert"
    end
  else
    -- Terminal is open, check if it's focused
    local current_win = vim.api.nvim_get_current_win()
    if terminal.window == current_win then
      -- Terminal is focused, close it
      logger.debug("terminal", "Focus toggle: closing terminal (currently focused) for instance " .. instance_id)
      terminal:close()
    else
      -- Terminal is open but not focused, focus it
      logger.debug("terminal", "Focus toggle: focusing terminal for instance " .. instance_id)
      if terminal.window then
        vim.api.nvim_set_current_win(terminal.window)
        vim.cmd "startinsert"
      end
    end
  end
end

---Legacy toggle function for backward compatibility (defaults to simple_toggle)
---@param cmd_string string
---@param env_table table
---@param config table
function M.toggle(cmd_string, env_table, config)
  M.simple_toggle(cmd_string, env_table, config)
end

---Get the active terminal buffer number
---@return number?
function M.get_active_bufnr()
  local terminal = get_terminal()
  if terminal and terminal.bufnr and terminal:is_open() then
    return terminal.bufnr
  end
  return nil
end

---Set the current instance ID for multi-instance support
---@param instance_id number The instance number
function M.set_current_instance(instance_id)
  -- Set environment variable for child processes
  vim.fn.setenv("CLAUDE_INSTANCE_ID", "claude_" .. instance_id)
  local logger = require("claudecode.logger")
  logger.debug("terminal", "Set current instance to " .. instance_id .. " (Toggleterm provider)")
end

---Hide terminal window but keep process running (for multi-instance support)
function M.hide_window()
  local terminal, instance_id = get_terminal()
  if terminal and terminal:is_open() then
    terminal:close()
    local logger = require("claudecode.logger")
    logger.debug("terminal", "Hide window called for instance " .. instance_id)
  end
end

---Is the terminal provider available?
---@return boolean
function M.is_available()
  return is_available()
end

---For testing purposes
---@return table? terminal The terminal instance, or nil
function M._get_terminal_for_test()
  local terminal = get_terminal()
  return terminal
end

---Clean up all terminal instances (for shutdown)
function M._cleanup_all()
  local logger = require("claudecode.logger")
  for instance_id, terminal in pairs(terminals) do
    if terminal then
      logger.debug("terminal", "Cleaning up terminal for instance " .. instance_id)
      if terminal:is_open() then
        terminal:close()
      end
    end
  end
  terminals = {}
end

---Ensure terminal is visible without changing focus
function M.ensure_visible()
  local logger = require("claudecode.logger")
  local terminal, instance_id = get_terminal()
  if not terminal then
    logger.debug("terminal", "ensure_visible: no terminal exists for instance " .. instance_id)
    return
  end

  if not terminal:is_open() then
    terminal:open()
    logger.debug("terminal", "ensure_visible: opened terminal for instance " .. instance_id)
  end
end

---@type ClaudeCodeTerminalProvider
return M