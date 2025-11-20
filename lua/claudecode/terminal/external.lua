--- External terminal provider for Claude Code.
---Launches Claude Code in an external terminal application using a user-specified command.
---@module 'claudecode.terminal.external'

---@type ClaudeCodeTerminalProvider
local M = {}

local logger = require("claudecode.logger")

-- Multi-instance support: maintain separate jobs for each instance
local jobs = {} -- instance_id -> jobid

---@type ClaudeCodeTerminalConfig
local config

local function cleanup_state(instance_id)
  jobs[instance_id] = nil
end

local function is_valid(instance_id)
  -- For external terminals, we only track if we have a running job
  -- We don't manage terminal windows since they're external
  return jobs[instance_id] and jobs[instance_id] > 0
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

---@param term_config ClaudeCodeTerminalConfig
function M.setup(term_config)
  config = term_config or {}
end

---@param cmd_string string
---@param env_table table
function M.open(cmd_string, env_table)
  local instance_id = get_instance_id()
  logger.debug("terminal", "M.open called for instance " .. instance_id .. " (env: " .. (env_table.CLAUDE_CODE_SSE_PORT or "nil") .. ")")

  if is_valid(instance_id) then
    -- External terminal is already running, we can't focus it programmatically
    -- Just log that it's already running
    logger.debug("terminal", "External Claude terminal is already running for instance " .. instance_id)
    return
  end

  -- Get external terminal command from provider_opts
  local external_cmd = config.provider_opts and config.provider_opts.external_terminal_cmd

  if not external_cmd then
    vim.notify(
      "external_terminal_cmd not configured. Please set terminal.provider_opts.external_terminal_cmd in your config.",
      vim.log.levels.ERROR
    )
    return
  end

  local cmd_parts
  local full_command
  local cwd_for_jobstart = nil

  -- Handle both string and function types
  if type(external_cmd) == "function" then
    -- Call the function with the Claude command and env table
    local result = external_cmd(cmd_string, env_table)
    if not result then
      vim.notify("external_terminal_cmd function returned nil or false", vim.log.levels.ERROR)
      return
    end

    -- Result can be either a string or a table
    if type(result) == "string" then
      -- Parse the string into command parts
      cmd_parts = vim.split(result, " ")
      full_command = result
    elseif type(result) == "table" then
      -- Use the table directly as command parts
      cmd_parts = result
      full_command = table.concat(result, " ")
    else
      vim.notify(
        "external_terminal_cmd function must return a string or table, got: " .. type(result),
        vim.log.levels.ERROR
      )
      return
    end
  elseif type(external_cmd) == "string" then
    if external_cmd == "" then
      vim.notify("external_terminal_cmd string cannot be empty", vim.log.levels.ERROR)
      return
    end

    -- Count the number of %s placeholders and format accordingly
    -- 1 placeholder: backward compatible, just command ("alacritty -e %s")
    -- 2 placeholders: cwd and command ("alacritty --working-directory %s -e %s")
    local _, placeholder_count = external_cmd:gsub("%%s", "")

    if placeholder_count == 0 then
      vim.notify("external_terminal_cmd must contain '%s' placeholder(s) for the command.", vim.log.levels.ERROR)
      return
    elseif placeholder_count == 1 then
      -- Backward compatible: just the command
      full_command = string.format(external_cmd, cmd_string)
    elseif placeholder_count == 2 then
      -- New feature: cwd and command
      local cwd = vim.fn.getcwd()
      cwd_for_jobstart = cwd
      full_command = string.format(external_cmd, cwd, cmd_string)
    else
      vim.notify(
        string.format(
          "external_terminal_cmd must use 1 '%%s' (command) or 2 '%%s' placeholders (cwd, command); got %d",
          placeholder_count
        ),
        vim.log.levels.ERROR
      )
      return
    end

    cmd_parts = vim.split(full_command, " ")
  else
    vim.notify("external_terminal_cmd must be a string or function, got: " .. type(external_cmd), vim.log.levels.ERROR)
    return
  end

  -- Start the external terminal as a detached process
  -- Set cwd for jobstart when available to improve robustness even if the terminal ignores it
  cwd_for_jobstart = cwd_for_jobstart or (vim.fn.getcwd and vim.fn.getcwd() or nil)

  jobs[instance_id] = vim.fn.jobstart(cmd_parts, {
    detach = true,
    env = env_table,
    cwd = cwd_for_jobstart,
    on_exit = function(job_id, exit_code, _)
      vim.schedule(function()
        if job_id == jobs[instance_id] then
          cleanup_state(instance_id)
        end
      end)
    end,
  })

  if not jobs[instance_id] or jobs[instance_id] <= 0 then
    vim.notify("Failed to start external terminal with command: " .. full_command, vim.log.levels.ERROR)
    cleanup_state(instance_id)
    return
  end

  logger.info("terminal", "Started external terminal for instance " .. instance_id .. " with job ID: " .. jobs[instance_id])
end

function M.close()
  local instance_id = get_instance_id()
  if is_valid(instance_id) then
    -- Try to stop the job gracefully
    local job_id = jobs[instance_id]
    logger.debug("terminal", "Closing external terminal for instance " .. instance_id .. " (job ID: " .. job_id .. ")")
    vim.fn.jobstop(job_id)
    cleanup_state(instance_id)
  end
end

--- Simple toggle: always start external terminal (can't hide external terminals)
---@param cmd_string string
---@param env_table table
---@param effective_config table
function M.simple_toggle(cmd_string, env_table, effective_config)
  local instance_id = get_instance_id()
  if is_valid(instance_id) then
    -- External terminal is running, stop it
    logger.debug("terminal", "Simple toggle: stopping external terminal for instance " .. instance_id)
    M.close()
  else
    -- Start external terminal
    logger.debug("terminal", "Simple toggle: starting external terminal for instance " .. instance_id)
    M.open(cmd_string, env_table, effective_config)
  end
end

--- Smart focus toggle: same as simple toggle for external terminals
---@param cmd_string string
---@param env_table table
---@param effective_config table
function M.focus_toggle(cmd_string, env_table, effective_config)
  -- For external terminals, focus toggle behaves the same as simple toggle
  -- since we can't detect or control focus of external windows
  local instance_id = get_instance_id()
  logger.debug("terminal", "Focus toggle: delegating to simple toggle for instance " .. instance_id)
  M.simple_toggle(cmd_string, env_table, effective_config)
end

--- Legacy toggle function for backward compatibility
---@param cmd_string string
---@param env_table table
---@param effective_config table
function M.toggle(cmd_string, env_table, effective_config)
  M.simple_toggle(cmd_string, env_table, effective_config)
end

---@return number?
function M.get_active_bufnr()
  -- External terminals don't have associated Neovim buffers
  return nil
end

--- No-op function for external terminals since we can't ensure visibility of external windows
function M.ensure_visible() end

---Set the current instance ID for multi-instance support
---@param instance_id number The instance number
function M.set_current_instance(instance_id)
  -- Set environment variable for child processes
  vim.fn.setenv("CLAUDE_INSTANCE_ID", "claude_" .. instance_id)
  logger.debug("terminal", "Set current instance to " .. instance_id .. " (External provider)")
end

---Hide terminal window but keep process running (for multi-instance support)
function M.hide_window()
  -- External terminals cannot be hidden, so this is a no-op
  -- The external terminal process continues running independently
  local instance_id = get_instance_id()
  logger.debug("terminal", "Hide window called for instance " .. instance_id .. " (no-op for external provider)")
end

---@return boolean
function M.is_available()
  -- Availability is checked by terminal.lua before this provider is selected
  return true
end

---@return table?
function M._get_terminal_for_test()
  -- For testing purposes, return job info if available
  local instance_id = get_instance_id()
  if is_valid(instance_id) then
    return { jobid = jobs[instance_id], instance_id = instance_id }
  end
  return nil
end

---Clean up all terminal instances (for shutdown)
function M._cleanup_all()
  local logger = require("claudecode.logger")
  for instance_id, job_id in pairs(jobs) do
    if job_id and job_id > 0 then
      logger.debug("terminal", "Stopping external terminal job for instance " .. instance_id .. " (job ID: " .. job_id .. ")")
      vim.fn.jobstop(job_id)
    end
  end
  jobs = {}
end

return M
