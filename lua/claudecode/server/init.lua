---@brief WebSocket server for Claude Code Neovim integration
local claudecode_main = require("claudecode") -- Added for version access
local logger = require("claudecode.logger")
local tcp_server = require("claudecode.server.tcp")
local tools = require("claudecode.tools.init") -- Added: Require the tools module

local MCP_PROTOCOL_VERSION = "2024-11-05"

local M = {}

-- Server state is now simplified - we only support multi-instance mode
-- Multi-instance server support: maintain separate server instances by port
---@class MultiInstanceServerState
---@field server table The TCP server instance
---@field port number The port server is running on
---@field auth_token string The authentication token for validating connections
---@field clients table<string, WebSocketClient> A list of connected clients
---@field ping_timer table|nil Timer for sending pings
local multi_instance_servers = {} -- port -> server_instance

-- Message handlers are shared across all instances
---@class ServerHandlers
---@field initialize function
---@field notifications_initialized function
---@field prompts_list function
---@field tools_list function
---@field tools_call function
local handlers = {}

---Initialize the WebSocket server (always multi-instance mode)
---@param config ClaudeCodeConfig Configuration options
---@param auth_token string|nil The authentication token for validating connections
---@param specific_port number|nil Optional specific port to use
---@param version_string string|nil Version string (optional)
---@param multi_instance boolean|nil Always true for multi-instance (kept for compatibility)
---@return boolean success Whether server started successfully
---@return number|string port_or_error Port number or error message
function M.start(config, auth_token, specific_port, version_string, multi_instance)
  multi_instance = multi_instance or true

  -- Check if server already running on this port
  local target_port = specific_port or config.port
  if multi_instance_servers[target_port] then
    return false, "Server already running on port " .. target_port
  end

  return M._start_server(config, auth_token, specific_port, version_string)
end

---Start a server instance (unified multi-instance approach)
---@param config ClaudeCodeConfig Configuration options
---@param auth_token string|nil The authentication token for validating connections
---@param specific_port number|nil Optional specific port to use
---@param version_string string|nil Version string (optional)
---@return boolean success Whether server started successfully
---@return number|string port_or_error Port number or error message
local function start_server(config, auth_token, specific_port, version_string)
  local target_port = specific_port or config.port

  -- Log authentication state
  if auth_token then
    logger.debug("server", "Starting WebSocket server on port " .. target_port .. " with authentication")
    logger.debug("server", "Auth token length:", #auth_token)
  else
    logger.debug("server", "Starting WebSocket server on port " .. target_port .. " WITHOUT authentication (insecure)")
  end

  -- Create a copy of config with the specific port
  local instance_config = vim.deepcopy(config)
  instance_config.port = target_port

  -- Create instance-specific client storage
  local instance_clients = {}

  local callbacks = {
    on_message = function(client, message)
      M._handle_message(client, message, target_port)
    end,
    on_connect = function(client)
      instance_clients[client.id] = client

      -- Log connection with auth status
      if auth_token then
        logger.debug("server", "Authenticated WebSocket client connected to server on port " .. target_port .. ":", client.id)
      else
        logger.debug("server", "WebSocket client connected (no auth) to server on port " .. target_port .. ":", client.id)
      end

      -- Notify instance manager about new connection for queue processing
      vim.schedule(function()
        local instance_manager = require("claudecode.instance_manager")
        if instance_manager.process_mention_queue and type(instance_manager.process_mention_queue) == "function" then
          instance_manager.process_mention_queue(true)
        end
      end)
    end,
    on_disconnect = function(client, code, reason)
      instance_clients[client.id] = nil
      logger.debug(
        "server",
        "WebSocket client disconnected from server on port " .. target_port .. ":",
        client.id,
        "(code:",
        code,
        ", reason:",
        (reason or "N/A") .. ")"
      )
    end,
    on_error = function(error_msg)
      logger.error("server", "WebSocket server error on port " .. target_port .. ":", error_msg)
    end,
  }

  local server, error_msg = tcp_server.create_server(instance_config, callbacks, auth_token)
  if not server then
    return false, error_msg or "Unknown server creation error"
  end

  local ping_timer = tcp_server.start_ping_timer(server, 30000)

  -- Store the server instance
  multi_instance_servers[target_port] = {
    server = server,
    port = target_port,
    auth_token = auth_token,
    clients = instance_clients,
    ping_timer = ping_timer,
  }

  logger.info("server", "Server started successfully on port " .. target_port)
  return true, target_port
end

M._start_server = start_server

---Stop all WebSocket servers (cleanup function)
---@return boolean success Whether servers stopped successfully
---@return string|nil error_message Error message if any
function M.stop()
  -- Stop all multi-instance servers
  for port, server_instance in pairs(multi_instance_servers) do
    M.stop_multi_instance_server(port)
  end

  -- CRITICAL: Clear global deferred responses to prevent memory leaks and hanging
  if _G.claude_deferred_responses then
    _G.claude_deferred_responses = {}
  end

  return true
end

---Handle incoming WebSocket message (unified handler)
---@param client table The client that sent the message
---@param message string The JSON-RPC message
---@param server_port number The port of the server instance
function M._handle_message(client, message, server_port)
  local success, parsed = pcall(vim.json.decode, message)
  if not success then
    M.send_response_multi_instance(client, server_port, nil, nil, {
      code = -32700,
      message = "Parse error",
      data = "Invalid JSON",
    })
    return
  end

  if type(parsed) ~= "table" or parsed.jsonrpc ~= "2.0" then
    M.send_response_multi_instance(client, server_port, parsed.id, nil, {
      code = -32600,
      message = "Invalid Request",
      data = "Not a valid JSON-RPC 2.0 request",
    })
    return
  end

  if parsed.id then
    M._handle_request(client, parsed, server_port)
  else
    M._handle_notification(client, parsed, server_port)
  end
end

---Handle JSON-RPC request (unified handler)
---@param client table The client that sent the request
---@param request table The parsed JSON-RPC request
---@param server_port number The port of the server instance
function M._handle_request(client, request, server_port)
  local method = request.method
  local params = request.params or {}
  local id = request.id

  local handler = handlers[method]
  if not handler then
    M.send_response_multi_instance(client, server_port, id, nil, {
      code = -32601,
      message = "Method not found",
      data = "Unknown method: " .. tostring(method),
    })
    return
  end

  local success, result, error_data = pcall(handler, client, params)
  if success then
    -- Check if this is a deferred response (blocking tool)
    if result and result._deferred then
      logger.debug("server", "Handler returned deferred response - storing for later")
      -- Store the request info for later response
      local deferred_info = {
        client = result.client,
        id = id,
        coroutine = result.coroutine,
        method = method,
        params = result.params,
        server_port = server_port,
      }
      -- Set up the completion callback
      M._setup_deferred_response(deferred_info)
      return -- Don't send response now
    end

    if error_data then
      M.send_response_multi_instance(client, server_port, id, nil, error_data)
    else
      M.send_response_multi_instance(client, server_port, id, result, nil)
    end
  else
    M.send_response_multi_instance(client, server_port, id, nil, {
      code = -32603,
      message = "Internal error",
      data = tostring(result), -- result contains error message when pcall fails
    })
  end
end

-- Add a unique module ID to detect reloading
local module_instance_id = math.random(10000, 99999)
logger.debug("server", "Server module loaded with instance ID:", module_instance_id)

-- Note: debug_deferred_table function removed as deferred_responses table is no longer used

function M._setup_deferred_response(deferred_info)
  local co = deferred_info.coroutine

  logger.debug("server", "Setting up deferred response for coroutine:", tostring(co))
  logger.debug("server", "Storage happening in module instance:", module_instance_id)

  -- Create a response sender function that captures the current server instance
  local response_sender = function(result)
    logger.debug("server", "Deferred response triggered for coroutine:", tostring(co))

    if result and result.content then
      -- MCP-compliant response
      M.send_response(deferred_info.client, deferred_info.id, result, nil)
    elseif result and result.error then
      -- Error response
      M.send_response(deferred_info.client, deferred_info.id, nil, result.error)
    else
      -- Fallback error
      M.send_response(deferred_info.client, deferred_info.id, nil, {
        code = -32603,
        message = "Internal error",
        data = "Deferred response completed with unexpected format",
      })
    end
  end

  -- Store the response sender in a global location that won't be affected by module reloading
  if not _G.claude_deferred_responses then
    _G.claude_deferred_responses = {}
  end
  _G.claude_deferred_responses[tostring(co)] = response_sender

  logger.debug("server", "Stored response sender in global table for coroutine:", tostring(co))
end

---Handle JSON-RPC notification (no response)
---@param client table The client that sent the notification
---@param notification table The parsed JSON-RPC notification
---@param server_port number The port of the server instance
function M._handle_notification(client, notification, server_port)
  local method = notification.method
  local params = notification.params or {}

  local handler = handlers[method]
  if handler then
    pcall(handler, client, params)
  end
end

---Register message handlers for the server
function M.register_handlers()
  handlers = {
    ["initialize"] = function(client, params)
      return {
        protocolVersion = MCP_PROTOCOL_VERSION,
        capabilities = {
          logging = vim.empty_dict(), -- Ensure this is an object {} not an array []
          prompts = { listChanged = true },
          resources = { subscribe = true, listChanged = true },
          tools = { listChanged = true },
        },
        serverInfo = {
          name = "claudecode-neovim",
          version = claudecode_main.version:string(),
        },
      }
    end,

    ["notifications/initialized"] = function(client, params) -- Added handler for initialized notification
    end,

    ["prompts/list"] = function(client, params) -- Added handler for prompts/list
      return {
        prompts = {}, -- This will be encoded as an empty JSON array
      }
    end,

    ["tools/list"] = function(client, params)
      return {
        tools = tools.get_tool_list(),
      }
    end,

    ["tools/call"] = function(client, params)
      logger.debug(
        "server",
        "Received tools/call. Tool: ",
        params and params.name,
        " Arguments: ",
        vim.inspect(params and params.arguments)
      )
      local result_or_error_table = tools.handle_invoke(client, params)

      -- Check if this is a deferred response (blocking tool)
      if result_or_error_table and result_or_error_table._deferred then
        logger.debug("server", "Tool is blocking - setting up deferred response")
        -- Return the deferred response directly - _handle_request will process it
        return result_or_error_table
      end

      -- Log the response for debugging
      logger.debug("server", "Response - tools/call", params and params.name .. ":", vim.inspect(result_or_error_table))

      if result_or_error_table.error then
        return nil, result_or_error_table.error
      elseif result_or_error_table.result then
        return result_or_error_table.result, nil
      else
        -- Should not happen if tools.handle_invoke behaves correctly
        return nil,
          {
            code = -32603,
            message = "Internal error",
            data = "Tool handler returned unexpected format",
          }
      end
    end,
  }
end

---Send a message to a client
---@param client table The client to send to
---@param method string The method name
---@param params table|nil The parameters to send
---@return boolean success Whether message was sent successfully
function M.send(client, method, params)
  if not M.state.server then
    return false
  end

  local message = {
    jsonrpc = "2.0",
    method = method,
    params = params or vim.empty_dict(),
  }

  local json_message = vim.json.encode(message)
  tcp_server.send_to_client(M.state.server, client.id, json_message)
  return true
end

---Send a response to a client
---@param client WebSocketClient The client to send to
---@param id number|string|nil The request ID to respond to
---@param result any|nil The result data if successful
---@param error_data table|nil The error data if failed
---@return boolean success Whether response was sent successfully
function M.send_response(client, id, result, error_data)
  if not M.state.server then
    return false
  end

  local response = {
    jsonrpc = "2.0",
    id = id,
  }

  if error_data then
    response.error = error_data
  else
    response.result = result
  end

  local json_response = vim.json.encode(response)
  tcp_server.send_to_client(M.state.server, client.id, json_response)
  return true
end

---Broadcast a message to all connected clients
---@param method string The method name
---@param params table|nil The parameters to send
---@return boolean success Whether broadcast was successful
function M.broadcast(method, params)
  if not M.state.server then
    logger.debug("server", "Broadcast failed: no server")
    return false
  end

  local client_count = tcp_server.get_client_count(M.state.server)
  logger.debug("server", "Broadcasting method '" .. method .. "' to " .. client_count .. " clients")

  local message = {
    jsonrpc = "2.0",
    method = method,
    params = params or vim.empty_dict(),
  }

  local json_message = vim.json.encode(message)
  logger.debug("server", "Broadcasting message: " .. json_message)
  tcp_server.broadcast(M.state.server, json_message)
  return true
end

---Get server status information
---@return table status Server status information
function M.get_status()
  if not M.state.server then
    return {
      running = false,
      port = nil,
      client_count = 0,
    }
  end

  return {
    running = true,
    port = M.state.port,
    client_count = tcp_server.get_client_count(M.state.server),
    clients = tcp_server.get_clients_info(M.state.server),
  }
end

---Send a response to a client for multi-instance server
---@param client WebSocketClient The client to send to
---@param server_port number The port of the server instance
---@param id number|string|nil The request ID to respond to
---@param result any|nil The result data if successful
---@param error_data table|nil The error data if failed
---@return boolean success Whether response was sent successfully
function M.send_response_multi_instance(client, server_port, id, result, error_data)
  local server_instance = multi_instance_servers[server_port]
  if not server_instance then
    return false
  end

  local response = {
    jsonrpc = "2.0",
    id = id,
  }

  if error_data then
    response.error = error_data
  else
    response.result = result
  end

  local json_response = vim.json.encode(response)
  tcp_server.send_to_client(server_instance.server, client.id, json_response)
  return true
end

---Setup deferred response for multi-instance server
---@param deferred_info table Deferred response information
function M._setup_deferred_response_multi_instance(deferred_info)
  local co = deferred_info.coroutine
  local server_port = deferred_info.server_port

  logger.debug("server", "Setting up multi-instance deferred response for coroutine:", tostring(co))
  logger.debug("server", "Storage happening in module instance:", module_instance_id)

  -- Create a response sender function that captures the current server instance
  local response_sender = function(result)
    logger.debug("server", "Multi-instance deferred response triggered for coroutine:", tostring(co))

    local server_instance = multi_instance_servers[server_port]
    if not server_instance then
      logger.error("server", "Server instance not found for deferred response on port:", server_port)
      return
    end

    if result and result.content then
      -- MCP-compliant response
      M.send_response_multi_instance(deferred_info.client, server_port, deferred_info.id, result, nil)
    elseif result and result.error then
      -- Error response
      M.send_response_multi_instance(deferred_info.client, server_port, deferred_info.id, nil, result.error)
    else
      -- Fallback error
      M.send_response_multi_instance(deferred_info.client, server_port, deferred_info.id, nil, {
        code = -32603,
        message = "Internal error",
        data = "Deferred response completed with unexpected format",
      })
    end
  end

  -- Store the response sender in a global location that won't be affected by module reloading
  if not _G.claude_deferred_responses then
    _G.claude_deferred_responses = {}
  end
  _G.claude_deferred_responses[tostring(co)] = response_sender

  logger.debug("server", "Stored multi-instance response sender in global table for coroutine:", tostring(co))
end

---Stop a specific multi-instance server
---@param server_port number The port of the server to stop
---@return boolean success Whether server stopped successfully
---@return string|nil error_message Error message if any
function M.stop_multi_instance_server(server_port)
  local server_instance = multi_instance_servers[server_port]
  if not server_instance then
    return false, "No server running on port " .. server_port
  end

  if server_instance.ping_timer then
    server_instance.ping_timer:stop()
    server_instance.ping_timer:close()
  end

  tcp_server.stop_server(server_instance.server)

  -- Clear from multi-instance servers
  multi_instance_servers[server_port] = nil

  logger.info("server", "Multi-instance server stopped on port " .. server_port)
  return true
end

---Broadcast a message to all connected clients on a specific multi-instance server
---@param server_port number The port of the server instance
---@param method string The method name
---@param params table|nil The parameters to send
---@return boolean success Whether broadcast was successful
function M.broadcast_multi_instance(server_port, method, params)
  local server_instance = multi_instance_servers[server_port]
  if not server_instance then
    logger.debug("server", "Multi-instance broadcast failed: no server on port " .. server_port)
    return false
  end

  local client_count = tcp_server.get_client_count(server_instance.server)
  logger.debug("server", "Broadcasting method '" .. method .. "' to " .. client_count .. " clients on port " .. server_port)

  local message = {
    jsonrpc = "2.0",
    method = method,
    params = params or vim.empty_dict(),
  }

  local json_message = vim.json.encode(message)
  logger.debug("server", "Broadcasting message: " .. json_message)
  tcp_server.broadcast(server_instance.server, json_message)
  return true
end

---Get status of a specific multi-instance server
---@param server_port number The port of the server instance
---@return table status Server status information
function M.get_multi_instance_status(server_port)
  local server_instance = multi_instance_servers[server_port]
  if not server_instance then
    return {
      running = false,
      port = server_port,
      client_count = 0,
    }
  end

  return {
    running = true,
    port = server_port,
    client_count = tcp_server.get_client_count(server_instance.server),
    clients = tcp_server.get_clients_info(server_instance.server),
  }
end

---Get status of all multi-instance servers
---@return table status Server status information for all instances
function M.get_all_multi_instance_status()
  local status = {
    total_instances = 0,
    total_clients = 0,
    instances = {},
  }

  for port, server_instance in pairs(multi_instance_servers) do
    local client_count = tcp_server.get_client_count(server_instance.server)
    status.instances[port] = {
      running = true,
      port = port,
      client_count = client_count,
      clients = tcp_server.get_clients_info(server_instance.server),
    }
    status.total_instances = status.total_instances + 1
    status.total_clients = status.total_clients + client_count
  end

  return status
end

return M
