---Snacks.nvim terminal provider for Claude Code.
---@module 'claudecode.terminal.snacks'

local M = {}

local snacks_available, Snacks = pcall(require, "snacks")
local utils = require("claudecode.utils")

-- Multi-instance support: maintain separate terminal instances for each instance
local terminals = {} -- instance_id -> terminal instance

--- @return boolean
local function is_available()
  return snacks_available and Snacks and Snacks.terminal ~= nil
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

---Setup event handlers for terminal instance
---@param term_instance table The Snacks terminal instance
---@param config table Configuration options
---@param instance_id number The instance ID for this terminal
local function setup_terminal_events(term_instance, config, instance_id)
  local logger = require("claudecode.logger")

  -- Handle command completion/exit - only if auto_close is enabled
  if config.auto_close then
    term_instance:on("TermClose", function()
      if vim.v.event.status ~= 0 then
        logger.error("terminal", "Claude exited with code " .. vim.v.event.status .. ".\nCheck for any errors.")
      end

      -- Clean up instance-specific terminal
      cleanup_terminal(instance_id)
      vim.schedule(function()
        term_instance:close({ buf = true })
        vim.cmd.checktime()
      end)
    end, { buf = true })
  end

  -- Handle buffer deletion
  term_instance:on("BufWipeout", function()
    logger.debug("terminal", "Terminal buffer wiped for instance " .. instance_id)
    cleanup_terminal(instance_id)
  end, { buf = true })
end

---Builds Snacks terminal options with focus control
---@param config ClaudeCodeTerminalConfig Terminal configuration
---@param env_table table Environment variables to set for the terminal process
---@param focus boolean|nil Whether to focus the terminal when opened (defaults to true)
---@return snacks.terminal.Opts opts Snacks terminal options with start_insert/auto_insert controlled by focus parameter
local function build_opts(config, env_table, focus)
  focus = utils.normalize_focus(focus)
  return {
    env = env_table,
    cwd = config.cwd,
    start_insert = focus,
    auto_insert = focus,
    auto_close = false,
    win = vim.tbl_deep_extend("force", {
      position = config.split_side,
      width = config.split_width_percentage,
      height = 0,
      relative = "editor",
      keys = {
        claude_new_line = {
          "<S-CR>",
          function()
            vim.api.nvim_feedkeys("\\", "t", true)
            vim.defer_fn(function()
              vim.api.nvim_feedkeys("\r", "t", true)
            end, 10)
          end,
          mode = "t",
          desc = "New line",
        },
      },
    } --[[@as snacks.win.Config]], config.snacks_win_opts or {}),
  } --[[@as snacks.terminal.Opts]]
end

function M.setup()
  -- No specific setup needed for Snacks provider
end

---Open a terminal using Snacks.nvim
---@param cmd_string string
---@param env_table table
---@param config ClaudeCodeTerminalConfig
---@param focus boolean?
function M.open(cmd_string, env_table, config, focus)
  if not is_available() then
    vim.notify("Snacks.nvim terminal provider selected but Snacks.terminal not available.", vim.log.levels.ERROR)
    return
  end

  focus = utils.normalize_focus(focus)
  local terminal, instance_id = get_terminal()
  local logger = require("claudecode.logger")

  logger.debug("terminal", "M.open called for instance " .. instance_id .. " (env: " .. (env_table.CLAUDE_CODE_SSE_PORT or "nil") .. ")")

  if terminal and terminal:buf_valid() then
    -- Check if terminal exists but is hidden (no window)
    if not terminal.win or not vim.api.nvim_win_is_valid(terminal.win) then
      -- Terminal is hidden, show it using snacks toggle
      logger.debug("terminal", "Instance " .. instance_id .. " terminal exists but hidden, showing it")
      terminal:toggle()
      if focus then
        terminal:focus()
        local term_buf_id = terminal.buf
        if term_buf_id and vim.api.nvim_buf_get_option(term_buf_id, "buftype") == "terminal" then
          if terminal.win and vim.api.nvim_win_is_valid(terminal.win) then
            vim.api.nvim_win_call(terminal.win, function()
              vim.cmd("startinsert")
            end)
          end
        end
      end
    else
      -- Terminal is already visible
      logger.debug("terminal", "Instance " .. instance_id .. " terminal already visible")
      if focus then
        terminal:focus()
        local term_buf_id = terminal.buf
        if term_buf_id and vim.api.nvim_buf_get_option(term_buf_id, "buftype") == "terminal" then
          -- Check if window is valid before calling nvim_win_call
          if terminal.win and vim.api.nvim_win_is_valid(terminal.win) then
            vim.api.nvim_win_call(terminal.win, function()
              vim.cmd("startinsert")
            end)
          end
        end
      end
    end
    return
  end

  -- No valid terminal exists for this instance, create new one
  logger.debug("terminal", "Creating new terminal for instance " .. instance_id .. " with command: " .. cmd_string)
  local opts = build_opts(config, env_table, focus)
  local term_instance = Snacks.terminal.open(cmd_string, opts)
  if term_instance and term_instance:buf_valid() then
    setup_terminal_events(term_instance, config, instance_id)
    terminals[instance_id] = term_instance

    -- Mark buffer with instance ID for identification
    if term_instance.buf then
      pcall(function()
        vim.api.nvim_buf_set_var(term_instance.buf, "claude_instance", instance_id)
      end)
    end
  else
    cleanup_terminal(instance_id)
    local error_details = {}
    if not term_instance then
      table.insert(error_details, "Snacks.terminal.open() returned nil")
    elseif not term_instance:buf_valid() then
      table.insert(error_details, "terminal instance is invalid")
      if term_instance.buf and not vim.api.nvim_buf_is_valid(term_instance.buf) then
        table.insert(error_details, "buffer is invalid")
      end
      if term_instance.win and not vim.api.nvim_win_is_valid(term_instance.win) then
        table.insert(error_details, "window is invalid")
      end
    end

    local context = string.format("cmd='%s', opts=%s", cmd_string, vim.inspect(opts))
    local error_msg = string.format(
      "Failed to open Claude terminal using Snacks. Details: %s. Context: %s",
      table.concat(error_details, ", "),
      context
    )
    vim.notify(error_msg, vim.log.levels.ERROR)
    logger.debug("terminal", error_msg)
  end
end

---Close the terminal
function M.close()
  if not is_available() then
    return
  end
  local terminal, instance_id = get_terminal()
  if terminal and terminal:buf_valid() then
    terminal:close()
    cleanup_terminal(instance_id)
  end
end

---Simple toggle: always show/hide terminal regardless of focus
---@param cmd_string string
---@param env_table table
---@param config table
function M.simple_toggle(cmd_string, env_table, config)
  if not is_available() then
    vim.notify("Snacks.nvim terminal provider selected but Snacks.terminal not available.", vim.log.levels.ERROR)
    return
  end

  local logger = require("claudecode.logger")
  local terminal, instance_id = get_terminal()

  -- Check if terminal exists and is visible
  if terminal and terminal:buf_valid() and terminal:win_valid() then
    -- Terminal is visible, hide it
    logger.debug("terminal", "Simple toggle: hiding visible terminal for instance " .. instance_id)
    terminal:toggle()
  elseif terminal and terminal:buf_valid() and not terminal:win_valid() then
    -- Terminal exists but not visible, show it
    logger.debug("terminal", "Simple toggle: showing hidden terminal for instance " .. instance_id)
    terminal:toggle()
  else
    -- No terminal exists, create new one
    logger.debug("terminal", "Simple toggle: creating new terminal for instance " .. instance_id)
    M.open(cmd_string, env_table, config)
  end
end

---Smart focus toggle: switches to terminal if not focused, hides if currently focused
---@param cmd_string string
---@param env_table table
---@param config table
function M.focus_toggle(cmd_string, env_table, config)
  if not is_available() then
    vim.notify("Snacks.nvim terminal provider selected but Snacks.terminal not available.", vim.log.levels.ERROR)
    return
  end

  local logger = require("claudecode.logger")
  local terminal, instance_id = get_terminal()

  -- Terminal exists, is valid, but not visible
  if terminal and terminal:buf_valid() and not terminal:win_valid() then
    logger.debug("terminal", "Focus toggle: showing hidden terminal for instance " .. instance_id)
    terminal:toggle()
  -- Terminal exists, is valid, and is visible
  elseif terminal and terminal:buf_valid() and terminal:win_valid() then
    local claude_term_neovim_win_id = terminal.win
    local current_neovim_win_id = vim.api.nvim_get_current_win()

    -- you're IN it
    if claude_term_neovim_win_id == current_neovim_win_id then
      logger.debug("terminal", "Focus toggle: hiding terminal (currently focused) for instance " .. instance_id)
      terminal:toggle()
    -- you're NOT in it
    else
      logger.debug("terminal", "Focus toggle: focusing terminal for instance " .. instance_id)
      vim.api.nvim_set_current_win(claude_term_neovim_win_id)
      if terminal.buf and vim.api.nvim_buf_is_valid(terminal.buf) then
        if vim.api.nvim_buf_get_option(terminal.buf, "buftype") == "terminal" then
          vim.api.nvim_win_call(claude_term_neovim_win_id, function()
            vim.cmd("startinsert")
          end)
        end
      end
    end
  -- No terminal exists
  else
    logger.debug("terminal", "Focus toggle: creating new terminal for instance " .. instance_id)
    M.open(cmd_string, env_table, config)
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
  if terminal and terminal:buf_valid() and terminal.buf then
    if vim.api.nvim_buf_is_valid(terminal.buf) then
      return terminal.buf
    end
  end
  return nil
end

---Set the current instance ID for multi-instance support
---@param instance_id number The instance number
function M.set_current_instance(instance_id)
  -- Set environment variable for child processes
  vim.fn.setenv("CLAUDE_INSTANCE_ID", "claude_" .. instance_id)
  local logger = require("claudecode.logger")
  logger.debug("terminal", "Set current instance to " .. instance_id .. " (Snacks provider)")
end

---Hide terminal window but keep process running (for multi-instance support)
function M.hide_window()
  local terminal, instance_id = get_terminal()
  if terminal and terminal:buf_valid() and terminal:win_valid() then
    -- Hide the terminal window but keep process running
    terminal:toggle()
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
    if terminal and terminal:buf_valid() then
      logger.debug("terminal", "Cleaning up terminal for instance " .. instance_id)
      terminal:close()
    end
  end
  terminals = {}
end

---@type ClaudeCodeTerminalProvider
return M
