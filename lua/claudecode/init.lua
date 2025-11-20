---@brief [[
--- Claude Code Neovim Integration
--- This plugin integrates Claude Code CLI with Neovim, enabling
--- seamless AI-assisted coding experiences directly in Neovim.
--- Supports multiple independent Claude Code instances.
---@brief ]]

---@module 'claudecode'
local M = {}

local logger = require("claudecode.logger")

--- Current plugin version
---@type ClaudeCodeVersion
M.version = {
  major = 0,
  minor = 2,
  patch = 0,
  prerelease = nil,
  string = function(self)
    local version = string.format("%d.%d.%d", self.major, self.minor, self.patch)
    if self.prerelease then
      version = version .. "-" .. self.prerelease
    end
    return version
  end,
}

-- Module state (simplified - delegates to instance manager)
---@type ClaudeCodeState
M.state = {
  config = require("claudecode.config").defaults,
  initialized = false,
  instance_manager = nil, -- Lazy-loaded instance manager
}

---Get the instance manager (lazy-loaded to avoid circular dependency)
---@return table instance_manager The instance manager module
local function get_instance_manager()
  if not M.state.instance_manager then
    M.state.instance_manager = require("claudecode.instance_manager")
  end
  return M.state.instance_manager
end

---Check if Claude Code is connected to WebSocket server
---@return boolean connected Whether Claude Code has active connections
function M.is_claude_connected()
  local instance_manager = get_instance_manager()
  return instance_manager.is_active_instance_connected()
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
  local instance_manager = get_instance_manager()

  return instance_manager.send_at_mention(file_path, start_line, end_line, context, instance_number)
end

---Start Claude Code integration (shows default instance)
---@param show_startup_notification boolean|nil Whether to show startup notification
---@return boolean success Whether the operation succeeded
---@return string message Success message
function M.start(show_startup_notification)
  if show_startup_notification == nil then
    show_startup_notification = true
  end

  local instance_manager = get_instance_manager()
  local success = instance_manager.show_instance(1) -- Default to instance 1

  if success and show_startup_notification then
    logger.info("init", "Claude Code started. Use <leader>a1-9 to toggle instances.")
  end

  return success, success and "Claude Code started" or "Failed to start Claude Code"
end

---Stop Claude Code integration
---@return boolean success Whether the operation succeeded
---@return string|nil error Error message if failed
function M.stop()
  local instance_manager = get_instance_manager()
  instance_manager.shutdown_all()
  logger.info("init", "All Claude Code instances stopped")
  return true, nil
end

---Toggle default Claude Code instance (instance 1)
---@return boolean success Whether the operation succeeded
function M.toggle_terminal()
  local instance_manager = get_instance_manager()
  return instance_manager.toggle_instance(1)
end

---Open Claude Code with specific model
---@param additional_args string|nil Additional arguments for Claude CLI
function M.open_with_model(additional_args)
  -- Create default instance with model arguments
  local instance_manager = get_instance_manager()
  local success = instance_manager.toggle_instance(M.state.default_instance)
  if success and additional_args then
    -- TODO: Pass model arguments to the instance
    -- This would need to be implemented in instance_manager
    logger.debug("init", "Model arguments not yet implemented: " .. additional_args)
  end
end

---Setup Claude Code plugin
---@param opts ClaudeCodeConfig|nil Configuration options
function M.setup(opts)
  if M.state.initialized then
    logger.warn("setup", "Claude Code plugin already initialized")
    return
  end

  if opts then
    M.state.config = vim.tbl_deep_extend("force", M.state.config, opts)
  end

  -- Setup terminal module with terminal configuration
  local terminal = require("claudecode.terminal")
  terminal.setup(M.state.config.terminal, M.state.config.terminal_cmd, M.state.config.env)

  -- Setup instance manager
  get_instance_manager().setup(M.state.config)

  -- Enable selection tracking
  local selection = require("claudecode.selection")
  selection.enable(M, M.state.config.visual_demotion_delay_ms or 50)

  -- Autocmd for cleanup
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      get_instance_manager().shutdown_all()
    end,
    desc = "Cleanup Claude Code instances on exit",
  })

  M.state.initialized = true

  -- Auto-start if enabled (create default instance)
  if M.state.config.auto_start then
    local instance_manager = get_instance_manager()
    instance_manager.show_instance(1)
  end

  M._create_commands()
  M._setup_autocmds()

  logger.info("setup", "Claude Code plugin setup complete")
end

---Create user commands
function M._create_commands()
  -- Core commands
  vim.api.nvim_create_user_command("ClaudeCodeStart", function()
    M.start()
  end, { desc = "Start Claude Code integration" })

  vim.api.nvim_create_user_command("ClaudeCodeStop", function()
    M.stop()
  end, { desc = "Stop Claude Code integration" })

  vim.api.nvim_create_user_command("ClaudeCodeToggle", function()
    M.toggle_terminal()
  end, { desc = "Toggle Claude Code terminal" })

  vim.api.nvim_create_user_command("ClaudeCodeRestart", function()
    M.stop()
    vim.defer_fn(function()
      M.start()
    end, 1000)
  end, { desc = "Restart Claude Code integration" })

  vim.api.nvim_create_user_command("ClaudeCodeStatus", function()
    local instance_manager = get_instance_manager()
    local instances = instance_manager.get_all_instances()
    local active_instance = instance_manager.get_active_instance()
    local server_module = require("claudecode.server.init")
    local server_status = server_module.get_status()

    if vim.tbl_isempty(instances) then
      vim.notify("No Claude Code instances. Use <leader>a1-9 to create instances.", vim.log.levels.INFO)
    else
      local message = "Claude Code Status:\n"
      message = message .. "Server Status: " .. (server_status.running and "Running" or "Stopped") .. "\n"
      message = message .. "Connected Clients: " .. (server_status.client_count or 0) .. "\n"
      message = message .. "Claude Connected: " .. (M.is_claude_connected() and "Yes" or "No") .. "\n\n"
      message = message .. "Instances:\n"

      for num, instance in pairs(instances) do
        local status = instance.visible and "Visible" or "Hidden"
        local active = (active_instance and active_instance.number == num) and " [ACTIVE]" or ""
        message = message .. string.format("  Instance %d%s: %s\n", num, active, status)
      end

      vim.notify(message, vim.log.levels.INFO)
    end
  end, { desc = "Show Claude Code status" })

  -- File addition command (sends to active instance or default instance)
  vim.api.nvim_create_user_command("ClaudeCodeAdd", function(opts)
    if not opts.args or opts.args == "" then
      logger.error("command", "ClaudeCodeAdd requires a file path")
      return
    end

    -- Parse arguments: file_path [start_line] [end_line]
    local args = vim.split(opts.args, " ", { trimempty = true })
    local file_path = args[1]
    local start_line = args[2] and tonumber(args[2]) or nil
    local end_line = args[3] and tonumber(args[3]) or nil

    if not file_path then
      logger.error("command", "ClaudeCodeAdd requires a file path")
      return
    end

    -- Convert 1-indexed user input to 0-indexed for Claude
    local start_line_0indexed = start_line and start_line - 1 or nil
    local end_line_0indexed = end_line and end_line - 1 or nil

    -- Send to active instance, or create instance 1 if none active
    local instance_manager = get_instance_manager()
    local active_instance_num = instance_manager.get_active_instance_number()

    if not active_instance_num then
      -- No active instance, create and show instance 1
      instance_manager.show_instance(1)
      active_instance_num = 1
    end

    local success, error_msg = M.send_at_mention(file_path, start_line_0indexed, end_line_0indexed, "ClaudeCodeAdd", active_instance_num)

    if not success then
      logger.error("command", "Failed to add file: " .. (error_msg or "unknown error"))
    end
  end, {
    nargs = "+",
    complete = "file",
    desc = "Add file to Claude Code context with optional line range (start_line end_line)",
  })

  -- ClaudeCodeSend command - sends to active instance
  vim.api.nvim_create_user_command("ClaudeCodeSend", function(opts)
    local selection = require("claudecode.selection")

    -- Pass range information if available (for :'<,'> commands)
    local line1, line2 = nil, nil
    if opts and opts.range and opts.range > 0 then
      line1, line2 = opts.line1, opts.line2
    end

    -- Send selection to active instance
    local sent_successfully = selection.send_at_mention_for_visual_selection(line1, line2)
    if sent_successfully then
      -- Exit any potential visual mode (for consistency)
      pcall(function()
        if vim.api and vim.api.nvim_feedkeys then
          local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
          vim.api.nvim_feedkeys(esc, "i", true)
        end
      end)
    end
  end, {
    desc = "Send current visual selection as an at_mention to Claude Code (sends to active instance)",
    range = true,
  })

  -- Instance management command
  vim.api.nvim_create_user_command("ClaudeCodeInstance", function(opts)
    if not opts.args or opts.args == "" then
      logger.error("command", "ClaudeCodeInstance requires an instance number")
      return
    end

    local instance_number = tonumber(opts.args)
    if not instance_number or instance_number < 1 or instance_number > 9 then
      logger.error("command", "Invalid instance number: " .. opts.args .. ". Use 1-9.")
      return
    end

    get_instance_manager().toggle_instance(instance_number)
  end, {
    nargs = 1,
    complete = function()
      return {"1", "2", "3", "4", "5", "6", "7", "8", "9"}
    end,
    desc = "Toggle Claude Code instance by number (1-9)",
  })
end

---Setup autocmds for Claude Code integration
function M._setup_autocmds()
  local group = vim.api.nvim_create_augroup("ClaudeCode", { clear = true })

  -- Auto-save files before sending @ mentions (optional)
  if M.state.config.auto_save_before_mention then
    vim.api.nvim_create_autocmd("BufWritePre", {
      group = group,
      callback = function()
        -- Could implement auto-save logic here if needed
      end,
      desc = "Auto-save before @ mentions",
    })
  end
end


-- Legacy methods for backward compatibility (now delegate to instance manager)
function M.clear_mention_queue()
  local instance_manager = get_instance_manager()
  if instance_manager.clear_mention_queue then
    instance_manager.clear_mention_queue()
  end
end

function M.process_mention_queue(from_new_connection)
  local instance_manager = get_instance_manager()
  if instance_manager.process_mention_queue then
    instance_manager.process_mention_queue(from_new_connection)
  end
end

---Format path for @ mention, using absolute paths to avoid working directory confusion
---@param file_path string The file path to format
---@return string formatted_path The formatted path
---@return boolean is_directory Whether the path is a directory
function M._format_path_for_at_mention(file_path)
  -- Input validation
  if not file_path or type(file_path) ~= "string" or file_path == "" then
    error("format_path_for_at_mention: file_path must be a non-empty string")
  end

  -- Only check path existence in production (not tests)
  -- This allows tests to work with mock paths while still providing validation in real usage
  if not package.loaded["busted"] then
    if vim.fn.filereadable(file_path) == 0 and vim.fn.isdirectory(file_path) == 0 then
      error("format_path_for_at_mention: path does not exist: " .. file_path)
    end
  end

  local is_directory = vim.fn.isdirectory(file_path) == 1

  -- In multi-instance mode, simplify to just basename if file is in current directory
  -- This avoids complex relative path calculations that can go wrong
  if M.state.multi_instance_enabled then
    local formatted_path = file_path
    local cwd = vim.fn.getcwd()

    -- Simple logic: if file is in current working directory, use basename
    if string.find(file_path, cwd, 1, true) == 1 then
      local relative_path = string.sub(file_path, #cwd + 2)
      -- If it's directly in cwd (no subdirectories), use just the filename
      if relative_path and not relative_path:match("/") then
        formatted_path = relative_path
      else
        -- Otherwise use the full relative path
        formatted_path = relative_path or file_path:match("([^/]+)$") or file_path
      end
    else
      -- If file is not under cwd, use just the basename to avoid complex relative paths
      formatted_path = file_path:match("([^/]+)$") or file_path
    end

    -- Ensure directory paths end with a slash for Claude
    if is_directory and formatted_path:sub(-1) ~= "/" then
      formatted_path = formatted_path .. "/"
    end

    return formatted_path, is_directory
  end

  -- Single-instance mode: Use relative paths if file is under current working directory
  local formatted_path = file_path
  local cwd = vim.fn.getcwd()

  if is_directory then
    if string.find(file_path, cwd, 1, true) == 1 then
      local relative_path = string.sub(file_path, #cwd + 2)
      if relative_path ~= "" then
        formatted_path = relative_path
      else
        formatted_path = "./"
      end
    end
    if not string.match(formatted_path, "/$") then
      formatted_path = formatted_path .. "/"
    end
  else
    if string.find(file_path, cwd, 1, true) == 1 then
      local relative_path = string.sub(file_path, #cwd + 2)
      if relative_path ~= "" then
        formatted_path = relative_path
      end
    end
  end

  return formatted_path, is_directory
end


-- Expose internal functions for testing
M._internal = {
  format_path_for_at_mention = M._format_path_for_at_mention,
}

return M