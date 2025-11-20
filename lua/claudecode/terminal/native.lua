---Native Neovim terminal provider for Claude Code.
---@module 'claudecode.terminal.native'

local M = {}

local logger = require("claudecode.logger")
local utils = require("claudecode.utils")

-- Multi-instance support: maintain separate state for each instance
local instances = {} -- instance_id -> {bufnr, winid, jobid, tip_shown}
local tip_shown_global = false

---@type ClaudeCodeTerminalConfig
local config = require("claudecode.terminal").defaults

local function get_instance_id()
  -- Try to get instance from environment or buffer variable
  local instance_id = 1 -- default
  local env_instance_ok, env_instance = pcall(vim.fn.getenv, "CLAUDE_INSTANCE_ID")
  if env_instance_ok and env_instance and type(env_instance) == "string" and env_instance ~= "" then
    local match = env_instance:match("claude_(%d+)")
    if match then
      instance_id = tonumber(match)
    end
  end

  -- Also check current buffer for instance marker - but environment variable takes priority
  local current_buf = vim.api.nvim_get_current_buf()
  local ok, buf_instance = pcall(vim.api.nvim_buf_get_var, current_buf, "claude_instance")
  if ok and buf_instance then
    -- Only use buffer instance if it's different from environment and environment is default (1)
    if not env_instance_ok or not env_instance or env_instance == "" then
      instance_id = buf_instance
    end
  end

  logger.debug("terminal", "get_instance_id returning: " .. instance_id .. " (env: " .. (env_instance or "nil") .. ", buf: " .. (ok and buf_instance or "nil") .. ")")
  return instance_id
end

local function get_instance_state(instance_id)
  instance_id = instance_id or get_instance_id()
  if not instances[instance_id] then
    instances[instance_id] = {
      bufnr = nil,
      winid = nil,
      jobid = nil,
      tip_shown = false,
    }
  end
  return instances[instance_id], instance_id
end

local function cleanup_state(instance_id)
  instance_id = instance_id or get_instance_id()
  if instances[instance_id] then
    instances[instance_id].bufnr = nil
    instances[instance_id].winid = nil
    instances[instance_id].jobid = nil
  end
end

local function is_valid(instance_id)
  local state, actual_id = get_instance_state(instance_id)

  -- First check if we have a valid buffer
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    cleanup_state(actual_id)
    return false
  end

  -- If buffer is valid but window is invalid, try to find a window displaying this buffer
  if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
    -- Search all windows for our terminal buffer
    local windows = vim.api.nvim_list_wins()
    for _, win in ipairs(windows) do
      if vim.api.nvim_win_get_buf(win) == state.bufnr then
        -- Found a window displaying our terminal buffer, update the tracked window ID
        state.winid = win
        logger.debug("terminal", "Recovered terminal window ID for instance " .. actual_id .. ":", win)
        return true
      end
    end
    -- Buffer exists but no window displays it - this is normal for hidden terminals
    return true -- Buffer is valid even though not visible
  end

  -- Both buffer and window are valid
  return true
end

local function open_terminal(cmd_string, env_table, effective_config, focus)
  local state, instance_id = get_instance_state()
  focus = utils.normalize_focus(focus)

  if is_valid(instance_id) then -- Should not happen if called correctly, but as a safeguard
    if focus then
      -- Focus existing terminal: switch to terminal window and enter insert mode
      vim.api.nvim_set_current_win(state.winid)
      vim.cmd("startinsert")
    end
    -- If focus=false, preserve user context by staying in current window
    return true
  end

  local original_win = vim.api.nvim_get_current_win()
  local width = math.floor(vim.o.columns * effective_config.split_width_percentage)
  local full_height = vim.o.lines
  local placement_modifier

  if effective_config.split_side == "left" then
    placement_modifier = "topleft "
  else
    placement_modifier = "botright "
  end

  vim.cmd(placement_modifier .. width .. "vsplit")
  local new_winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_height(new_winid, full_height)

  vim.api.nvim_win_call(new_winid, function()
    vim.cmd("enew")
  end)

  local term_cmd_arg
  if cmd_string:find(" ", 1, true) then
    term_cmd_arg = vim.split(cmd_string, " ", { plain = true, trimempty = false })
  else
    term_cmd_arg = { cmd_string }
  end

  local jobid = vim.fn.termopen(term_cmd_arg, {
    env = env_table,
    cwd = effective_config.cwd,
    on_exit = function(job_id, _, _)
      vim.schedule(function()
        if job_id == jobid then
          logger.debug("terminal", "Terminal process exited, cleaning up", instance_id)

          -- Ensure we are operating on the correct window and buffer before closing
          local current_winid_for_job = state.winid
          local current_bufnr_for_job = state.bufnr

          cleanup_state(instance_id) -- Clear our managed state first

          if not effective_config.auto_close then
            return
          end

          if current_winid_for_job and vim.api.nvim_win_is_valid(current_winid_for_job) then
            if current_bufnr_for_job and vim.api.nvim_buf_is_valid(current_bufnr_for_job) then
              -- Optional: Check if the window still holds the same terminal buffer
              if vim.api.nvim_win_get_buf(current_winid_for_job) == current_bufnr_for_job then
                vim.api.nvim_win_close(current_winid_for_job, true)
              end
            else
              -- Buffer is invalid, but window might still be there (e.g. if user changed buffer in term window)
              -- Still try to close the window we tracked.
              vim.api.nvim_win_close(current_winid_for_job, true)
            end
          end
        end
      end)
    end,
  })

  if not jobid or jobid == 0 then
    vim.notify("Failed to open native terminal.", vim.log.levels.ERROR)
    vim.api.nvim_win_close(new_winid, true)
    vim.api.nvim_set_current_win(original_win)
    cleanup_state(instance_id)
    return false
  end

  state.winid = new_winid
  state.bufnr = vim.api.nvim_get_current_buf()
  state.jobid = jobid
  vim.bo[state.bufnr].bufhidden = "hide"
  -- buftype=terminal is set by termopen

  -- Mark buffer with instance ID
  pcall(function()
    vim.api.nvim_buf_set_var(state.bufnr, "claude_instance", instance_id)
  end)

  if focus then
    -- Focus the terminal: switch to terminal window and enter insert mode
    vim.api.nvim_set_current_win(state.winid)
    vim.cmd("startinsert")
  else
    -- Preserve user context: return to the window they were in before terminal creation
    vim.api.nvim_set_current_win(original_win)
  end

  if config.show_native_term_exit_tip and not state.tip_shown then
    vim.notify("Native terminal opened. Press Ctrl-\\ Ctrl-N to return to Normal mode.", vim.log.levels.INFO)
    state.tip_shown = true
  end
  return true
end

local function close_terminal()
  local state = get_instance_state()
  if is_valid() then
    -- Closing the window should trigger on_exit of the job if the process is still running,
    -- which then calls cleanup_state.
    -- If the job already exited, on_exit would have cleaned up.
    -- This direct close is for user-initiated close.
    vim.api.nvim_win_close(state.winid, true)
    cleanup_state() -- Cleanup after explicit close
  end
end

local function focus_terminal()
  local state = get_instance_state()
  if is_valid() then
    vim.api.nvim_set_current_win(state.winid)
    vim.cmd("startinsert")
  end
end

local function is_terminal_visible()
  local state = get_instance_state()
  -- Check if our terminal buffer exists and is displayed in any window
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    return false
  end

  local windows = vim.api.nvim_list_wins()
  for _, win in ipairs(windows) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == state.bufnr then
      -- Update our tracked window ID if we find the buffer in a different window
      state.winid = win
      return true
    end
  end

  -- Buffer exists but no window displays it
  state.winid = nil
  return false
end

local function hide_terminal()
  local state = get_instance_state()
  -- Hide the terminal window but keep the buffer and job alive
  if state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) and state.winid and vim.api.nvim_win_is_valid(state.winid) then
    -- Close the window - this preserves the buffer and job
    vim.api.nvim_win_close(state.winid, false)
    state.winid = nil -- Clear window reference

    logger.debug("terminal", "Terminal window hidden, process preserved")
  end
end

local function show_hidden_terminal(effective_config, focus)
  local state = get_instance_state()
  -- Show an existing hidden terminal buffer in a new window
  if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    return false
  end

  -- Check if it's already visible
  if is_terminal_visible() then
    if focus then
      focus_terminal()
    end
    return true
  end

  local original_win = vim.api.nvim_get_current_win()

  -- Create a new window for the existing buffer
  local width = math.floor(vim.o.columns * effective_config.split_width_percentage)
  local full_height = vim.o.lines
  local placement_modifier

  if effective_config.split_side == "left" then
    placement_modifier = "topleft "
  else
    placement_modifier = "botright "
  end

  vim.cmd(placement_modifier .. width .. "vsplit")
  local new_winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_height(new_winid, full_height)

  -- Set the existing buffer in the new window
  vim.api.nvim_win_set_buf(new_winid, state.bufnr)
  state.winid = new_winid

  if focus then
    -- Focus the terminal: switch to terminal window and enter insert mode
    vim.api.nvim_set_current_win(state.winid)
    vim.cmd("startinsert")
  else
    -- Preserve user context: return to the window they were in before showing terminal
    vim.api.nvim_set_current_win(original_win)
  end

  logger.debug("terminal", "Showed hidden terminal in new window")
  return true
end

local function find_existing_claude_terminal()
  local current_instance_id = get_instance_id()
  local buffers = vim.api.nvim_list_bufs()
  for _, buf in ipairs(buffers) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_option(buf, "buftype") == "terminal" then
      -- Check if this is a Claude Code terminal by examining the buffer name or terminal job
      local buf_name = vim.api.nvim_buf_get_name(buf)
      -- Terminal buffers often have names like "term://..." that include the command
      if buf_name:match("claude") then
        -- Check if this buffer belongs to the current instance
        local ok, buf_instance = pcall(vim.api.nvim_buf_get_var, buf, "claude_instance")
        if ok and buf_instance == current_instance_id then
          -- Additional check: see if there's a window displaying this buffer
          local windows = vim.api.nvim_list_wins()
          for _, win in ipairs(windows) do
            if vim.api.nvim_win_get_buf(win) == buf then
              logger.debug("terminal", "Found existing Claude terminal for instance " .. current_instance_id .. " in buffer", buf, "window", win)
              return buf, win
            end
          end
        end
      end
    end
  end
  return nil, nil
end

---Setup the terminal module
---@param term_config ClaudeCodeTerminalConfig
function M.setup(term_config)
  config = term_config
end

--- @param cmd_string string
--- @param env_table table
--- @param effective_config table
--- @param focus boolean|nil
function M.open(cmd_string, env_table, effective_config, focus)
  local state, instance_id = get_instance_state()
  focus = utils.normalize_focus(focus)

  logger.debug("terminal", "M.open called for instance " .. instance_id .. " (env: " .. (env_table.CLAUDE_CODE_SSE_PORT or "nil") .. ")")

  if is_valid(instance_id) then
    -- Check if terminal exists but is hidden (no window)
    if not state.winid or not vim.api.nvim_win_is_valid(state.winid) then
      -- Terminal is hidden, show it by calling show_hidden_terminal
      logger.debug("terminal", "Instance " .. instance_id .. " terminal exists but hidden, showing it")
      show_hidden_terminal(effective_config, focus)
    else
      -- Terminal is already visible
      logger.debug("terminal", "Instance " .. instance_id .. " terminal already visible")
      if focus then
        focus_terminal()
      end
    end
  else
    -- Check if there's an existing Claude terminal we lost track of
    local existing_buf, existing_win = find_existing_claude_terminal()
    if existing_buf and existing_win then
      -- Recover the existing terminal
      state.bufnr = existing_buf
      state.winid = existing_win
      -- Note: We can't recover the job ID easily, but it's less critical
      logger.debug("terminal", "Recovered existing Claude terminal for instance " .. instance_id)
      if focus then
        focus_terminal() -- Focus recovered terminal
      end
      -- If focus=false, preserve user context by staying in current window
    else
      logger.debug("terminal", "Creating new terminal for instance " .. instance_id .. " with command: " .. cmd_string)
      if not open_terminal(cmd_string, env_table, effective_config, focus) then
        vim.notify("Failed to open Claude terminal using native fallback.", vim.log.levels.ERROR)
      end
    end
  end
end

function M.close()
  close_terminal()
end

---Simple toggle: always show/hide terminal regardless of focus
---@param cmd_string string
---@param env_table table
---@param effective_config ClaudeCodeTerminalConfig
function M.simple_toggle(cmd_string, env_table, effective_config)
  local state = get_instance_state()
  -- Check if we have a valid terminal buffer (process running)
  local has_buffer = state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr)
  local is_visible = has_buffer and is_terminal_visible()

  if is_visible then
    -- Terminal is visible, hide it (but keep process running)
    hide_terminal()
  else
    -- Terminal is not visible
    if has_buffer then
      -- Terminal process exists but is hidden, show it
      if show_hidden_terminal(effective_config, true) then
        logger.debug("terminal", "Showing hidden terminal")
      else
        logger.error("terminal", "Failed to show hidden terminal")
      end
    else
      -- No terminal process exists, check if there's an existing one we lost track of
      local existing_buf, existing_win = find_existing_claude_terminal()
      if existing_buf and existing_win then
        -- Recover the existing terminal
        state.bufnr = existing_buf
        state.winid = existing_win
        logger.debug("terminal", "Recovered existing Claude terminal")
        focus_terminal()
      else
        -- No existing terminal found, create a new one
        if not open_terminal(cmd_string, env_table, effective_config) then
          vim.notify("Failed to open Claude terminal using native fallback (simple_toggle).", vim.log.levels.ERROR)
        end
      end
    end
  end
end

---Smart focus toggle: switches to terminal if not focused, hides if currently focused
---@param cmd_string string
---@param env_table table
---@param effective_config ClaudeCodeTerminalConfig
function M.focus_toggle(cmd_string, env_table, effective_config)
  local state = get_instance_state()
  -- Check if we have a valid terminal buffer (process running)
  local has_buffer = state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr)
  local is_visible = has_buffer and is_terminal_visible()

  if has_buffer then
    -- Terminal process exists
    if is_visible then
      -- Terminal is visible - check if we're currently in it
      local current_win_id = vim.api.nvim_get_current_win()
      if state.winid == current_win_id then
        -- We're in the terminal window, hide it (but keep process running)
        hide_terminal()
      else
        -- Terminal is visible but we're not in it, focus it
        focus_terminal()
      end
    else
      -- Terminal process exists but is hidden, show it
      if show_hidden_terminal(effective_config, true) then
        logger.debug("terminal", "Showing hidden terminal")
      else
        logger.error("terminal", "Failed to show hidden terminal")
      end
    end
  else
    -- No terminal process exists, check if there's an existing one we lost track of
    local existing_buf, existing_win = find_existing_claude_terminal()
    if existing_buf and existing_win then
      -- Recover the existing terminal
      state.bufnr = existing_buf
      state.winid = existing_win
      logger.debug("terminal", "Recovered existing Claude terminal")

      -- Check if we're currently in this recovered terminal
      local current_win_id = vim.api.nvim_get_current_win()
      if existing_win == current_win_id then
        -- We're in the recovered terminal, hide it
        hide_terminal()
      else
        -- Focus the recovered terminal
        focus_terminal()
      end
    else
      -- No existing terminal found, create a new one
      if not open_terminal(cmd_string, env_table, effective_config) then
        vim.notify("Failed to open Claude terminal using native fallback (focus_toggle).", vim.log.levels.ERROR)
      end
    end
  end
end

--- Legacy toggle function for backward compatibility (defaults to simple_toggle)
--- @param cmd_string string
--- @param env_table table
--- @param effective_config ClaudeCodeTerminalConfig
function M.toggle(cmd_string, env_table, effective_config)
  M.simple_toggle(cmd_string, env_table, effective_config)
end

--- @return number|nil
function M.get_active_bufnr()
  local state = get_instance_state()
  if is_valid() then
    return state.bufnr
  end
  return nil
end

--- Set the current instance ID for multi-instance support
---@param instance_id number The instance number
function M.set_current_instance(instance_id)
  -- Set environment variable for child processes
  vim.fn.setenv("CLAUDE_INSTANCE_ID", "claude_" .. instance_id)
  logger.debug("terminal", "Set current instance to " .. instance_id)
end

---Hide terminal window but keep process running (for multi-instance support)
function M.hide_window()
  hide_terminal()
end

--- @return boolean
function M.is_available()
  return true -- Native provider is always available
end

--- @type ClaudeCodeTerminalProvider
return M
