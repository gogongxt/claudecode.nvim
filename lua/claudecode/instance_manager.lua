---@brief [[
--- Claude Code Instance Manager - Unified Multi-Instance Support
--- Manages multiple Claude Code instances with independent servers and terminals.
--- Each instance is completely independent with its own port, auth token, and terminal.
--- This module handles all instance-related operations including @ mentions and connections.
---@brief ]]

---@module 'claudecode.instance_manager'
local M = {}

local logger = require("claudecode.logger")

-- Instance management state
local instances = {} -- instance_number -> ClaudeInstance
local active_instance = nil -- Currently visible/active instance

---@class ClaudeInstance
---@field number number Instance number (1, 2, 3...)
---@field port number Port number for this instance's server
---@field auth_token string Authentication token
---@field instance_name string Unique instance identifier for lock files
---@field server table|nil Server instance
---@field visible boolean Whether terminal is currently visible
---@field terminal table|nil Terminal instance

-- Find available port starting from base port
---@param base_port number Starting port number
---@return number|nil port Available port or nil
local function find_available_port(base_port)
  local max_attempts = 50
  for i = 0, max_attempts - 1 do
    local port = base_port + i
    local socket = vim.loop.new_tcp()
    if socket then
      local bind_success = socket:bind("127.0.0.1", port)
      socket:close()
      if bind_success then
        return port
      end
    end
  end
  return nil
end

-- Create dedicated server for instance
---@param instance_number number Instance number
---@return boolean success
---@return number|nil port Port number
---@return string|nil auth_token Authentication token
---@return string|nil instance_name Instance name
local function create_instance_server(instance_number)
  local server = require("claudecode.server.init")
  local lockfile = require("claudecode.lockfile")
  local config = require("claudecode.config").defaults

  -- Find available port for this instance
  local base_port = 8100 + (instance_number - 1) * 10  -- 8100, 8110, 8120, etc.
  local port = find_available_port(base_port)
  if not port then
    return false, nil, nil, nil
  end

  logger.info("instance_manager", "Starting server for instance " .. instance_number .. " on port " .. port)

  -- Generate auth token
  local auth_success, auth_token = pcall(lockfile.generate_auth_token)
  if not auth_success then
    return false, port, nil, nil
  end

  -- Create unique instance name
  local instance_name = "claudecode_instance_" .. instance_number

  -- Create lock file
  local lock_success, lock_result = lockfile.create_instance(port, auth_token, instance_name)
  if not lock_success then
    return false, port, nil, nil
  end

  -- Start server
  local server_success, server_result = server.start(config, auth_token, port, "0.2.0", true)
  if not server_success then
    lockfile.remove_instance(port, instance_name)
    return false, port, nil, nil
  end

  logger.info("instance_manager", "Server started for instance " .. instance_number .. " on port " .. port)
  return true, port, auth_token, instance_name
end

-- Show terminal for instance
---@param instance_number number Instance number
---@param port number Port for Claude CLI
---@return boolean success
local function show_instance_terminal(instance_number, port)
  local terminal_module = require("claudecode.terminal")
  local config = require("claudecode.config").defaults

  -- Set instance context BEFORE any terminal operations
  -- This ensures terminal providers know which instance they're handling
  local provider = terminal_module.get_provider()
  if provider and provider.set_current_instance then
    provider.set_current_instance(instance_number)
  end

  -- Set environment variable globally for this process
  vim.fn.setenv("CLAUDE_INSTANCE_ID", "claude_" .. instance_number)

  -- Prepare terminal configuration with instance-specific environment
  local terminal_config = vim.deepcopy(config.terminal or {})
  terminal_config.env = vim.tbl_extend("force", terminal_config.env or {}, {
    ENABLE_IDE_INTEGRATION = "true",
    FORCE_CODE_TERMINAL = "true",
    CLAUDE_CODE_SSE_PORT = tostring(port),
    CLAUDE_INSTANCE_ID = "claude_" .. instance_number,
  })

  logger.debug("instance_manager", "Opening terminal for instance " .. instance_number .. " with port " .. port)

  -- Use simple_toggle to ensure terminal is shown (creates if doesn't exist, shows if hidden)
  local success = pcall(terminal_module.simple_toggle, terminal_config, nil)

  if success then
    logger.info("instance_manager", "Terminal shown for instance " .. instance_number)
  else
    logger.warn("instance_manager", "Failed to show terminal for instance " .. instance_number)
  end
  return success
end

-- Hide terminal for instance
---@param instance_number number Instance number
---@return boolean success
local function hide_instance_terminal(instance_number)
  local terminal_module = require("claudecode.terminal")

  -- Set instance context BEFORE any terminal operations
  -- This ensures terminal providers know which instance they're handling
  local provider = terminal_module.get_provider()
  if provider and provider.set_current_instance then
    provider.set_current_instance(instance_number)
  end

  -- Set environment variable globally for this process
  vim.fn.setenv("CLAUDE_INSTANCE_ID", "claude_" .. instance_number)

  logger.debug("instance_manager", "Hiding terminal for instance " .. instance_number)

  -- Try to use hide_window method if available (keeps terminal running in background)
  if provider and provider.hide_window then
    local success = pcall(provider.hide_window)
    if success then
      logger.info("instance_manager", "Terminal hidden using hide_window for instance " .. instance_number)
      return true
    else
      logger.warn("instance_manager", "hide_window failed for instance " .. instance_number .. ", falling back to simple_toggle")
    end
  end

  -- Fallback: Use simple_toggle to hide the terminal (toggles visibility)
  local config = require("claudecode.config").defaults
  local terminal_config = vim.deepcopy(config.terminal or {})
  terminal_config.env = vim.tbl_extend("force", terminal_config.env or {}, {
    CLAUDE_INSTANCE_ID = "claude_" .. instance_number,
  })

  local success = pcall(terminal_module.simple_toggle, terminal_config, nil)

  logger.info("instance_manager", "Terminal hide operation completed for instance " .. instance_number)
  return true
end

-- Toggle instance by number
---@param instance_number number Instance number (1, 2, 3...)
---@return boolean success
function M.toggle_instance(instance_number)
  logger.info("instance_manager", "Toggling instance " .. instance_number .. " (current active: " .. tostring(active_instance) .. ")")

  local instance = instances[instance_number]

  if not instance then
    -- Create new instance
    local success, port, auth_token, instance_name = create_instance_server(instance_number)
    if not success then
      logger.error("instance_manager", "Failed to create server for instance " .. instance_number)
      return false
    end

    instance = {
      number = instance_number,
      port = port,
      auth_token = auth_token,
      instance_name = instance_name,
      server = {
        port = port,
        auth_token = auth_token,
        instance_name = instance_name,
        broadcast = function(event, data)
          local server = require("claudecode.server.init")
          return server.broadcast_multi_instance(port, event, data)
        end,
        stop = function()
          local server = require("claudecode.server.init")
          local lockfile = require("claudecode.lockfile")

          logger.debug("instance_manager", "Stopping server for instance " .. instance_number)
          local stop_success, stop_error = server.stop_multi_instance_server(port)
          if not stop_success then
            logger.error("instance_manager", "Failed to stop server for instance " .. instance_number .. ": " .. (stop_error or "unknown"))
          end

          lockfile.remove_instance(port, instance_name)
          return stop_success
        end,
      },
      visible = false,
    }

    instances[instance_number] = instance
    logger.info("instance_manager", "Created new instance " .. instance_number)
  end

  -- Simple toggle logic: if this is the current active instance, hide it, otherwise show it
  if active_instance == instance_number then
    -- Check if actually visible first
    local terminal_module = require("claudecode.terminal")
    local provider = terminal_module.get_provider()

    -- Set instance context to check the right terminal
    if provider and provider.set_current_instance then
      provider.set_current_instance(instance_number)
    end
    vim.fn.setenv("CLAUDE_INSTANCE_ID", "claude_" .. instance_number)

    local is_actually_visible = false
    if provider and provider.get_active_bufnr then
      local bufnr = provider.get_active_bufnr()
      if bufnr then
        local bufinfo = vim.fn.getbufinfo(bufnr)
        if bufinfo and #bufinfo > 0 and #bufinfo[1].windows > 0 then
          is_actually_visible = true
        end
      end
    end

    if is_actually_visible then
      -- Hide this instance
      logger.info("instance_manager", "Hiding currently visible instance " .. instance_number)
      hide_instance_terminal(instance_number)
      instance.visible = false
      active_instance = nil

      -- Clear selection tracking
      local selection = require("claudecode.selection")
      selection.update_server(nil)
    else
      -- Instance is active but not visible, show it
      logger.info("instance_manager", "Instance " .. instance_number .. " is active but hidden, showing it")
      local show_success = show_instance_terminal(instance_number, instance.port)
      instance.visible = show_success
      if not show_success then
        active_instance = nil
      end
    end
  else
    -- Switch to this instance from another instance (or from no instance)
    logger.info("instance_manager", "Switching from instance " .. tostring(active_instance) .. " to instance " .. instance_number)

    -- Hide current active instance first (if any)
    if active_instance then
      logger.debug("instance_manager", "Hiding current active instance " .. active_instance)
      hide_instance_terminal(active_instance)
      if instances[active_instance] then
        instances[active_instance].visible = false
      end
    end

    -- Show the new instance
    active_instance = instance_number
    local show_success = show_instance_terminal(instance_number, instance.port)
    instance.visible = show_success

    if show_success then
      logger.info("instance_manager", "Successfully switched to instance " .. instance_number)
      -- Update selection tracking
      local selection = require("claudecode.selection")
      selection.update_server(instance.server)
    else
      logger.error("instance_manager", "Failed to show terminal for instance " .. instance_number)
      active_instance = nil
    end
  end

  return true
end

-- Show specific instance
---@param instance_number number Instance number
---@return boolean success
function M.show_instance(instance_number)
  local instance = instances[instance_number]
  if not instance then
    return M.toggle_instance(instance_number)
  end

  if not instance.visible then
    -- Hide other instances first
    for num, inst in pairs(instances) do
      if inst.visible and num ~= instance_number then
        hide_instance_terminal(num)
        inst.visible = false
      end
    end

    -- Set this as active instance first
    active_instance = instance_number

    -- Show this instance
    local show_success = show_instance_terminal(instance_number, instance.port)
    if show_success then
      instance.visible = true
      logger.info("instance_manager", "Set active instance to " .. instance_number)
    else
      -- Terminal show failed, but keep instance as active for @mention purposes
      instance.visible = false
      logger.warn("instance_manager", "Terminal show failed, but keeping instance " .. instance_number .. " as active")
    end

    -- Update selection tracking regardless of terminal success
    local selection = require("claudecode.selection")
    selection.update_server(instance.server)
  end

  return true
end

-- Hide specific instance
---@param instance_number number Instance number
---@return boolean success
function M.hide_instance(instance_number)
  local instance = instances[instance_number]
  if not instance or not instance.visible then
    return true
  end

  hide_instance_terminal(instance_number)
  instance.visible = false
  if active_instance == instance_number then
    active_instance = nil

    -- Clear selection tracking
    local selection = require("claudecode.selection")
    selection.update_server(nil)
  end

  return true
end

-- Get instance by number
---@param instance_number number Instance number
---@return ClaudeInstance|nil instance
function M.get_instance(instance_number)
  return instances[instance_number]
end

-- Get all instances
---@return table instances Copy of all instances
function M.get_all_instances()
  return vim.deepcopy(instances)
end

-- Get active instance number
---@return number|nil instance_number
function M.get_active_instance_number()
  logger.info("instance_manager", "get_active_instance_number returning: " .. tostring(active_instance))
  return active_instance
end

-- Get active instance
---@return ClaudeInstance|nil instance
function M.get_active_instance()
  if not active_instance then
    return nil
  end
  return instances[active_instance]
end

-- Destroy instance
---@param instance_number number Instance number
---@return boolean success
function M.destroy_instance(instance_number)
  local instance = instances[instance_number]
  if not instance then
    return false
  end

  -- Hide if visible
  if instance.visible then
    M.hide_instance(instance_number)
  end

  -- Stop server
  if instance.server and instance.server.stop then
    instance.server.stop()
  end

  -- Remove from instances
  instances[instance_number] = nil

  -- Clear active if this was active
  if active_instance == instance_number then
    active_instance = nil
  end

  logger.info("instance_manager", "Destroyed instance " .. instance_number)
  return true
end

-- Setup key bindings for instance toggles
---@param opts table Configuration options
function M.setup_keybindings(opts)
  local leader = opts.leader or "<leader>a"

  -- Setup mappings for instances 1-9
  for i = 1, 9 do
    vim.keymap.set("n", leader .. i, function()
      M.toggle_instance(i)
    end, {
      desc = "Toggle Claude Code instance " .. i,
      silent = true,
    })
  end

  logger.info("instance_manager", "Setup keybindings: " .. leader .. "1-9 for instances 1-9")
end

---Check if specific instance is connected to Claude
---@param instance_number number The instance number to check
---@return boolean connected Whether Claude Code has active connections
function M.is_instance_connected(instance_number)
  local instance = instances[instance_number]
  if not instance then
    logger.debug("instance_manager", "Instance not found: " .. instance_number)
    return false
  end

  if not instance.server then
    logger.debug("instance_manager", "Instance " .. instance_number .. " has no server")
    return false
  end

  -- Check server status
  local server_module = require("claudecode.server.init")
  local status = server_module.get_multi_instance_status(instance.port)

  logger.debug("instance_manager", "Instance " .. instance_number .. " server status - running: " .. tostring(status.running) .. ", clients: " .. tostring(status.client_count))
  return status.running and status.client_count and status.client_count > 0
end

---Check if active instance is connected to Claude
---@return boolean connected Whether Claude Code has active connections
function M.is_active_instance_connected()
  if not active_instance then
    logger.debug("instance_manager", "No active instance")
    return false
  end

  return M.is_instance_connected(active_instance)
end

---Send @ mention to Claude Code with optional line numbers
---@param file_path string The file path to send
---@param start_line number|nil Start line (0-indexed for Claude)
---@param end_line number|nil End line (0-indexed for Claude)
---@param context string|nil Context for logging
---@param instance_number number|nil Optional instance number to send to
---@return boolean success Whether the operation was successful
---@return string|nil error Error message if failed
function M.send_at_mention(file_path, start_line, end_line, context, instance_number)
  context = context or "command"
  local target_instance_number = instance_number

  -- If no specific instance provided, use active instance
  if not target_instance_number then
    target_instance_number = active_instance
    logger.info(context, "No instance specified, using active instance: " .. tostring(target_instance_number))
    if not target_instance_number then
      logger.error(context, "No active Claude Code instance found")
      return false, "No active Claude Code instance found"
    end
  else
    logger.info(context, "Using specified instance: " .. tostring(target_instance_number))
  end

  local instance = instances[target_instance_number]
  if not instance then
    logger.error(context, "Claude Code instance " .. target_instance_number .. " not found")
    return false, "Claude Code instance " .. target_instance_number .. " not found"
  end

  -- Check if target instance is connected
  if M.is_instance_connected(target_instance_number) then
    -- Claude is connected, send immediately
    local success, error_msg = M._broadcast_at_mention(target_instance_number, file_path, start_line, end_line, context)
    if success then
      local config = require("claudecode.config").defaults
      if config.focus_after_send then
        -- Show the instance terminal with focus
        M.show_instance(target_instance_number)
      end
    end
    return success, error_msg
  else
    -- Claude not connected, show instance to establish connection
    M.show_instance(target_instance_number)
    logger.info(context, "Claude Code instance " .. target_instance_number .. " launched for @ mention: " .. file_path)
    return true, nil
  end
end

---Broadcast @ mention to connected clients for specific instance
---@param instance_number number The instance number
---@param file_path string The file path to send
---@param start_line number|nil Start line (0-indexed for Claude)
---@param end_line number|nil End line (0-indexed for Claude)
---@param context string|nil Context for logging
---@return boolean success Whether the operation was successful
---@return string|nil error Error message if failed
function M._broadcast_at_mention(instance_number, file_path, start_line, end_line, context)
  context = context or "command"

  local instance = instances[instance_number]
  if not instance or not instance.server then
    local error_msg = "Claude Code instance " .. instance_number .. " is not running"
    logger.error(context, error_msg)
    return false, error_msg
  end

  -- Format the path
  local formatted_path, is_directory = M._format_path_for_at_mention(file_path)

  if is_directory and (start_line or end_line) then
    logger.debug(context, "Line numbers ignored for directory: " .. formatted_path)
    start_line = nil
    end_line = nil
  end

  local params = {
    filePath = formatted_path,
    lineStart = start_line,
    lineEnd = end_line,
  }

  -- Broadcast to the instance's server
  local success = instance.server.broadcast("at_mentioned", params)
  logger.debug(context, "Broadcast result for instance " .. instance_number .. ": " .. tostring(success))

  if success then
    return true, nil
  else
    local error_msg = "Failed to broadcast " .. (is_directory and "directory" or "file") .. " " .. formatted_path
    logger.error(context, error_msg)
    return false, error_msg
  end
end

---Format path for @ mention
---@param file_path string The file path to format
---@return string formatted_path The formatted path
---@return boolean is_directory Whether the path is a directory
function M._format_path_for_at_mention(file_path)
  -- Input validation
  if not file_path or type(file_path) ~= "string" or file_path == "" then
    error("format_path_for_at_mention: file_path must be a non-empty string")
  end

  -- Only check path existence in production (not tests)
  if not package.loaded["busted"] then
    if vim.fn.filereadable(file_path) == 0 and vim.fn.isdirectory(file_path) == 0 then
      error("format_path_for_at_mention: path does not exist: " .. file_path)
    end
  end

  local is_directory = vim.fn.isdirectory(file_path) == 1
  local cwd = vim.fn.getcwd()

  -- Use simple relative path logic
  local formatted_path = file_path
  if string.find(file_path, cwd, 1, true) == 1 then
    local relative_path = string.sub(file_path, #cwd + 2)
    if relative_path and not relative_path:match("/") then
      formatted_path = relative_path
    else
      formatted_path = relative_path or file_path:match("([^/]+)$") or file_path
    end
  else
    formatted_path = file_path:match("([^/]+)$") or file_path
  end

  -- Ensure directory paths end with a slash for Claude
  if is_directory and formatted_path:sub(-1) ~= "/" then
    formatted_path = formatted_path .. "/"
  end

  return formatted_path, is_directory
end

---Clear mention queue for active instance
function M.clear_mention_queue()
  -- Legacy function - now handled by terminal providers
  if active_instance and instances[active_instance] then
    local terminal_module = require("claudecode.terminal")
    local provider = terminal_module.get_provider()
    if provider and provider.clear_mention_queue then
      provider.clear_mention_queue()
    end
  end
end

---Process mention queue for active instance
---@param from_new_connection boolean|nil Whether this is triggered by a new connection
function M.process_mention_queue(from_new_connection)
  -- Legacy function - now handled by terminal providers
  if active_instance and instances[active_instance] then
    local terminal_module = require("claudecode.terminal")
    local provider = terminal_module.get_provider()
    if provider and provider.process_mention_queue then
      provider.process_mention_queue(from_new_connection)
    end
  end
end

---Setup instance manager
---@param opts table Configuration options
function M.setup(opts)
  M.setup_keybindings(opts)

  -- Setup tools and handlers
  local tools = require("claudecode.tools.init")
  tools.setup(require("claudecode"))

  local server = require("claudecode.server.init")
  server.register_handlers()
end

-- Clean shutdown of all instances
function M.shutdown_all()
  local terminal_module = require("claudecode.terminal")

  -- Cleanup terminal
  local provider = terminal_module.get_provider()
  if provider and provider._cleanup_all then
    provider._cleanup_all()
  end

  -- Stop all servers
  for instance_number, instance in pairs(instances) do
    if instance.server then
      logger.info("instance_manager", "Stopping server for instance " .. instance_number)

      local server = require("claudecode.server.init")
      local lockfile = require("claudecode.lockfile")

      local stop_success, stop_error = server.stop_multi_instance_server(instance.port)
      if not stop_success then
        logger.error("instance_manager", "Failed to stop server for instance " .. instance_number .. ": " .. (stop_error or "unknown"))
      end

      if instance.instance_name then
        lockfile.remove_instance(instance.port, instance.instance_name)
      end
    end
  end

  -- Stop global server (if any)
  local server = require("claudecode.server.init")
  server.stop()

  -- Clear all instances
  instances = {}
  active_instance = nil

  logger.info("instance_manager", "All instances shut down")
end

return M