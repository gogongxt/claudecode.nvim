---@brief WebSocket server for Claude Code Neovim integration
local claudecode_main = require("claudecode") -- Added for version access
local logger = require("claudecode.logger")
local tcp_server = require("claudecode.server.tcp")
local tools = require("claudecode.tools.init") -- Added: Require the tools module

local MCP_PROTOCOL_VERSION = "2024-11-05"

local M = {}

---@class ServerState
---@field server table|nil The TCP server instance
---@field port number|nil The port server is running on
---@field auth_token string|nil The authentication token for validating connections
---@field handlers table Message handlers by method name
---@field ping_timer table|nil Timer for sending pings
M.state = {
  server = nil,
  port = nil,
  auth_token = nil,
  handlers = {},
  ping_timer = nil,
}

---Initialize the WebSocket server
---@param config ClaudeCodeConfig Configuration options
---@param auth_token string|nil The authentication token for validating connections
---@return boolean success Whether server started successfully
---@return number|string port_or_error Port number or error message
function M.start(config, auth_token)
  if M.state.server then
    return false, "Server already running"
  end

  M.state.auth_token = auth_token

  -- Log authentication state
  if auth_token then
    logger.debug("server", "Starting WebSocket server with authentication enabled")
    logger.debug("server", "Auth token length:", #auth_token)
  else
    logger.debug("server", "Starting WebSocket server WITHOUT authentication (insecure)")
  end

  M.register_handlers()

  tools.setup(M)

  local callbacks = {
    on_message = function(client, message)
      M._handle_message(client, message)
    end,
    on_connect = function(client)
      -- Log connection with auth status
      if M.state.auth_token then
        logger.debug("server", "Authenticated WebSocket client connected:", client.id)
      else
        logger.debug("server", "WebSocket client connected (no auth):", client.id)
      end

      -- Notify main module about new connection for queue processing
      local main_module = require("claudecode")
      if main_module.process_mention_queue then
        vim.schedule(function()
          main_module.process_mention_queue(true)
        end)
      end
    end,
    on_disconnect = function(client, code, reason)
      logger.debug(
        "server",
        "WebSocket client disconnected:",
        client.id,
        "(code:",
        code,
        ", reason:",
        (reason or "N/A") .. ")"
      )

      -- Unbind so the session slot can be reused by a fresh Claude CLI process.
      local ok_sm, sm = pcall(require, "claudecode.session")
      if ok_sm and sm and client and client.id then
        sm.unbind_client(client.id)
      end

      -- Close diffs this client opened but never resolved (#248). Scheduled:
      -- diff cleanup touches window APIs.
      local diff = package.loaded["claudecode.diff"]
      if diff then
        local client_id = client.id
        vim.schedule(function()
          diff.close_diffs_for_client(client_id, "client disconnected")
        end)
      end
    end,
    on_error = function(error_msg)
      logger.error("server", "WebSocket server error:", error_msg)
    end,
  }

  local server, error_msg = tcp_server.create_server(config, callbacks, M.state.auth_token)
  if not server then
    return false, error_msg or "Unknown server creation error"
  end

  M.state.server = server
  M.state.port = server.port

  M.state.ping_timer = tcp_server.start_ping_timer(server, 30000) -- Start ping timer to keep connections alive

  return true, server.port
end

---Stop the WebSocket server
---@return boolean success Whether server stopped successfully
---@return string|nil error_message Error message if any
function M.stop()
  if not M.state.server then
    return false, "Server not running"
  end

  if M.state.ping_timer then
    M.state.ping_timer:stop()
    M.state.ping_timer:close()
    M.state.ping_timer = nil
  end

  -- Reject pending diffs before teardown — stop_server bypasses on_disconnect
  -- (#248). Saved-but-unflushed edits survive; only pending diffs close.
  local diff = package.loaded["claudecode.diff"]
  if diff then
    diff.close_pending_diffs("server stopping")
  end

  tcp_server.stop_server(M.state.server)

  if _G.claude_deferred_responses then
    _G.claude_deferred_responses = {}
  end

  M.state.server = nil
  M.state.port = nil
  M.state.auth_token = nil
  return true
end

---Handle incoming WebSocket message
---@param client table The client that sent the message
---@param message string The JSON-RPC message
function M._handle_message(client, message)
  local success, parsed = pcall(vim.json.decode, message)
  if not success then
    M.send_response(client, nil, nil, {
      code = -32700,
      message = "Parse error",
      data = "Invalid JSON",
    })
    return
  end

  if type(parsed) ~= "table" or parsed.jsonrpc ~= "2.0" then
    M.send_response(client, parsed.id, nil, {
      code = -32600,
      message = "Invalid Request",
      data = "Not a valid JSON-RPC 2.0 request",
    })
    return
  end

  if parsed.id then
    M._handle_request(client, parsed)
  else
    M._handle_notification(client, parsed)
  end
end

---Handle JSON-RPC request (requires response)
---@param client table The client that sent the request
---@param request table The parsed JSON-RPC request
function M._handle_request(client, request)
  local method = request.method
  local params = request.params or {}
  local id = request.id

  local handler = M.state.handlers[method]
  if not handler then
    M.send_response(client, id, nil, {
      code = -32601,
      message = "Method not found",
      data = "Unknown method: " .. tostring(method),
    })
    return
  end

  local success, result, error_data = pcall(handler, client, params)
  if success then
    if result and result._deferred then
      M._setup_deferred_response({
        client = result.client,
        id = id,
        coroutine = result.coroutine,
        method = method,
        params = result.params,
      })
      return
    end

    if error_data then
      M.send_response(client, id, nil, error_data)
    else
      M.send_response(client, id, result, nil)
    end
  else
    M.send_response(client, id, nil, {
      code = -32603,
      message = "Internal error",
      data = tostring(result),
    })
  end
end

function M._setup_deferred_response(deferred_info)
  local co = deferred_info.coroutine
  logger.debug("server", "Setting up deferred response for coroutine:", tostring(co))

  local response_sender = function(result)
    if result and result.content then
      M.send_response(deferred_info.client, deferred_info.id, result, nil)
    elseif result and result.error then
      M.send_response(deferred_info.client, deferred_info.id, nil, result.error)
    else
      M.send_response(deferred_info.client, deferred_info.id, nil, {
        code = -32603,
        message = "Internal error",
        data = "Deferred response completed with unexpected format",
      })
    end
  end

  -- Global so the response sender survives module reloads.
  if not _G.claude_deferred_responses then
    _G.claude_deferred_responses = {}
  end
  _G.claude_deferred_responses[tostring(co)] = response_sender
end

---Handle JSON-RPC notification (no response)
---@param client table The client that sent the notification
---@param notification table The parsed JSON-RPC notification
function M._handle_notification(client, notification)
  local method = notification.method
  local params = notification.params or {}

  local handler = M.state.handlers[method]
  if handler then
    pcall(handler, client, params)
  end
end

---Register message handlers for the server
function M.register_handlers()
  M.state.handlers = {
    ["initialize"] = function(client, params)
      -- Bind the incoming client to its session. Prefer the spawn-order signal
      -- (awaiting_handshake) over the visible buffer: if the user spawned B
      -- then switched back to A before B's Claude process handshakes, the
      -- visible buffer is A's — binding by visible would route B's client to A
      -- and break :ClaudeCodeSend.
      local ok_sm, sm = pcall(require, "claudecode.session")
      if ok_sm and sm and client and client.id then
        local target_id
        local awaiting = sm.find_session_awaiting_handshake()
        if awaiting then
          target_id = awaiting.id
        end
        if not target_id then
          local ok_t, terminal = pcall(require, "claudecode.terminal")
          if ok_t and terminal and terminal.get_visible_session_id then
            target_id = terminal.get_visible_session_id()
          end
        end
        if not target_id then
          local unbound = sm.find_unbound_session()
          target_id = unbound and unbound.id or nil
        end
        if target_id then
          sm.bind_client(target_id, client.id)
        end
      end

      return {
        protocolVersion = MCP_PROTOCOL_VERSION,
        capabilities = {
          logging = vim.empty_dict(), -- Ensure this is an object {} not an array []
          prompts = { listChanged = true },
          tools = { listChanged = true },
        },
        serverInfo = {
          name = "claudecode-neovim",
          version = claudecode_main.version:string(),
        },
      }
    end,

    ["notifications/initialized"] = function(client, params) end,

    ["prompts/list"] = function(client, params)
      return {
        prompts = {},
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

      if result_or_error_table and result_or_error_table._deferred then
        logger.debug("server", "Tool is blocking - setting up deferred response")
        return result_or_error_table
      end

      logger.debug("server", "Response - tools/call", params and params.name .. ":", vim.inspect(result_or_error_table))

      if result_or_error_table.error then
        return nil, result_or_error_table.error
      elseif result_or_error_table.result then
        return result_or_error_table.result, nil
      else
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
    return false
  end

  local message = {
    jsonrpc = "2.0",
    method = method,
    params = params or vim.empty_dict(),
  }

  local json_message = vim.json.encode(message)
  tcp_server.broadcast(M.state.server, json_message)
  return true
end

-- Send to the client bound to the active session only. Used for per-session
-- routing (e.g. @ mentions). When the active session has no bound client yet
-- (handshake pending), drop instead of broadcast — broadcasting would leak to
-- other sessions' Claude processes. The caller's mention-queue retry handles
-- re-delivery once the client binds.
---@return boolean success
function M.send_to_active_session(method, params)
  if not M.state.server then
    return false
  end

  local json_message = vim.json.encode({
    jsonrpc = "2.0",
    method = method,
    params = params or vim.empty_dict(),
  })

  local ok_sm, sm = pcall(require, "claudecode.session")
  if ok_sm and sm then
    local active_id = sm.get_active_session_id()
    local session = active_id and sm.get_session(active_id) or nil
    local client_id = session and session.client_id or nil
    if client_id then
      tcp_server.send_to_client(M.state.server, client_id, json_message)
      return true
    end
    logger.debug("server", "send_to_active_session: no bound client for active session ", tostring(active_id))
    return false
  end

  -- No session module: return false so the caller's mention-queue retry
  -- handles re-delivery. Broadcasting here would silently leak @mentions to
  -- every connected Claude process in a multi-session setup — exactly the
  -- leak this function exists to prevent.
  logger.debug("server", "send_to_active_session: session module unavailable, dropping")
  return false
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

return M
