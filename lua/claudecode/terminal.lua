--- Module to manage a dedicated vertical split terminal for Claude Code.
--- Supports Snacks.nvim or a native Neovim terminal fallback.
--- @module 'claudecode.terminal'

local M = {}

local claudecode_server_module = require("claudecode.server.init")

---@type ClaudeCodeTerminalConfig
local defaults = {
  split_side = "right",
  split_width_percentage = 0.30,
  diff_split_width_percentage = nil, -- optional terminal width while a diff is active; defaults to split_width_percentage
  provider = "auto",
  show_native_term_exit_tip = true,
  terminal_cmd = nil,
  provider_opts = {
    external_terminal_cmd = nil,
  },
  auto_close = true,
  auto_insert = true,
  env = {},
  snacks_win_opts = {},
  fix_streamed_paste = "auto", -- work around Neovim <0.12.2 paste fragmentation (#161): true|false|"auto"
  -- Working directory control
  cwd = nil, -- static cwd override
  git_repo_cwd = false, -- resolve to git root when spawning
  cwd_provider = nil, -- function(ctx) -> cwd string
  -- Session tab bar: shows one label per Claude session in the terminal
  -- window, click to switch. Driven by window_manager + the global session
  -- list (sessions are not scoped to tabpages).
  -- Keymaps default to false (unset) so terminal-native keys like <Tab>, <S-Tab>,
  -- <C-w> pass through to the TUI untouched — matching plain toggleterm behavior.
  -- Set any to a key string (e.g. "<C-Tab>") to opt in.
  tabs = {
    enabled = true,
    show_close_button = true,
    show_new_button = true,
    keymaps = { next_tab = false, prev_tab = false, new_tab = false, close_tab = false },
  },
}

M.defaults = defaults

-- Lazy load providers
local providers = {}

-- Buffer -> session_id map for terminals owned by a session. Lets the server
-- resolve which session an incoming selection/tool call belongs to, and lets
-- the terminal module find a session from the buffer currently in a window.
---@type table<number, string>
local buffer_session_map = {}

---Loads a terminal provider module
---@param provider_name string The name of the provider to load
---@return ClaudeCodeTerminalProvider? provider The provider module, or nil if loading failed
local function load_provider(provider_name)
  if not providers[provider_name] then
    local ok, provider = pcall(require, "claudecode.terminal." .. provider_name)
    if ok then
      providers[provider_name] = provider
    else
      return nil
    end
  end
  return providers[provider_name]
end

---Validates and enhances a custom table provider with smart defaults
---@param provider ClaudeCodeTerminalProvider The custom provider table to validate
---@return ClaudeCodeTerminalProvider? provider The enhanced provider, or nil if invalid
---@return string? error Error message if validation failed
local function validate_and_enhance_provider(provider)
  if type(provider) ~= "table" then
    return nil, "Custom provider must be a table"
  end

  -- Required functions that must be implemented
  local required_functions = {
    "setup",
    "open",
    "close",
    "simple_toggle",
    "focus_toggle",
    "get_active_bufnr",
    "is_available",
  }

  -- Validate all required functions exist and are callable
  for _, func_name in ipairs(required_functions) do
    local func = provider[func_name]
    if not func then
      return nil, "Custom provider missing required function: " .. func_name
    end
    -- Check if it's callable (function or table with __call metamethod)
    local is_callable = type(func) == "function"
      or (type(func) == "table" and getmetatable(func) and getmetatable(func).__call)
    if not is_callable then
      return nil, "Custom provider field '" .. func_name .. "' must be callable, got: " .. type(func)
    end
  end

  -- Create enhanced provider with defaults for optional functions
  -- Note: Don't deep copy to preserve spy functions in tests
  local enhanced_provider = provider

  -- Add default toggle function if not provided (calls simple_toggle for backward compatibility)
  if not enhanced_provider.toggle then
    enhanced_provider.toggle = function(cmd_string, env_table, effective_config)
      return enhanced_provider.simple_toggle(cmd_string, env_table, effective_config)
    end
  end

  -- Add default test function if not provided
  if not enhanced_provider._get_terminal_for_test then
    enhanced_provider._get_terminal_for_test = function()
      return nil
    end
  end

  return enhanced_provider, nil
end

---Gets the effective terminal provider, guaranteed to return a valid provider
---Falls back to native provider if configured provider is unavailable
---@return ClaudeCodeTerminalProvider provider The terminal provider module (never nil)
local function get_provider()
  local logger = require("claudecode.logger")

  -- Handle custom table provider
  if type(defaults.provider) == "table" then
    local custom_provider = defaults.provider --[[@as ClaudeCodeTerminalProvider]]
    local enhanced_provider, error_msg = validate_and_enhance_provider(custom_provider)
    if enhanced_provider then
      -- Check if custom provider is available
      local is_available_ok, is_available = pcall(enhanced_provider.is_available)
      if is_available_ok and is_available then
        logger.debug("terminal", "Using custom table provider")
        return enhanced_provider
      else
        local availability_msg = is_available_ok and "provider reports not available" or "error checking availability"
        logger.warn(
          "terminal",
          "Custom table provider configured but " .. availability_msg .. ". Falling back to 'native'."
        )
      end
    else
      logger.warn("terminal", "Invalid custom table provider: " .. error_msg .. ". Falling back to 'native'.")
    end
    -- Fall through to native provider
  elseif defaults.provider == "auto" then
    -- Try snacks first, then fallback to native silently
    local snacks_provider = load_provider("snacks")
    if snacks_provider and snacks_provider.is_available() then
      return snacks_provider
    end
    -- Fall through to native provider
  elseif defaults.provider == "snacks" then
    local snacks_provider = load_provider("snacks")
    if snacks_provider and snacks_provider.is_available() then
      return snacks_provider
    else
      logger.warn("terminal", "'snacks' provider configured, but Snacks.nvim not available. Falling back to 'native'.")
    end
  elseif defaults.provider == "external" then
    local external_provider = load_provider("external")
    if external_provider then
      -- Check availability based on our config instead of provider's internal state
      local external_cmd = defaults.provider_opts and defaults.provider_opts.external_terminal_cmd

      local has_external_cmd = false
      if type(external_cmd) == "function" then
        has_external_cmd = true
      elseif type(external_cmd) == "string" and external_cmd ~= "" and external_cmd:find("%%s") then
        has_external_cmd = true
      end

      if has_external_cmd then
        return external_provider
      else
        logger.warn(
          "terminal",
          "'external' provider configured, but provider_opts.external_terminal_cmd not properly set. Falling back to 'native'."
        )
      end
    end
  elseif defaults.provider == "toggleterm" then
    local toggleterm_provider = load_provider("toggleterm")
    if toggleterm_provider and toggleterm_provider.is_available() then
      return toggleterm_provider
    else
      logger.warn(
        "terminal",
        "'toggleterm' provider configured, but toggleterm.nvim not available. Falling back to 'native'."
      )
    end
  elseif defaults.provider == "native" then
    -- noop, will use native provider as default below
    logger.debug("terminal", "Using native terminal provider")
  elseif defaults.provider == "none" then
    local none_provider = load_provider("none")
    if none_provider then
      logger.debug("terminal", "Using no-op terminal provider ('none')")
      return none_provider
    else
      logger.warn("terminal", "'none' provider configured but failed to load. Falling back to 'native'.")
    end
  elseif type(defaults.provider) == "string" then
    logger.warn(
      "terminal",
      "Invalid provider configured: " .. tostring(defaults.provider) .. ". Defaulting to 'native'."
    )
  else
    logger.warn(
      "terminal",
      "Invalid provider type: " .. type(defaults.provider) .. ". Must be string or table. Defaulting to 'native'."
    )
  end

  local native_provider = load_provider("native")
  if not native_provider then
    error("ClaudeCode: Critical error - native terminal provider failed to load")
  end
  return native_provider
end

-- Multi-session is opt-in per provider: one that implements open_session /
-- close_session / focus_session / get_session_bufnr / close_session_keep_window
-- / register_terminal_for_session drives per-session terminals. Providers
-- without those (legacy snacks/native/external/none) keep single-terminal
-- behavior; we still track an "active" session for mention routing.
local session_manager_mod = require("claudecode.session")

---Register a terminal buffer as belonging to a session.
---@param bufnr number
---@param session_id string
function M.register_buffer_session(bufnr, session_id)
  if bufnr and session_id then
    buffer_session_map[bufnr] = session_id
  end
end

---Unregister a terminal buffer's session binding.
---@param bufnr number
function M.unregister_buffer_session(bufnr)
  buffer_session_map[bufnr] = nil
end

---Look up the session id bound to a terminal buffer.
---@param bufnr number
---@return string|nil session_id
function M.get_session_for_buffer(bufnr)
  return buffer_session_map[bufnr]
end

---Find the session whose terminal buffer is currently displayed in some window
---(i.e. the foreground terminal). Used by the server to bind an incoming
---Claude CLI client to the session whose terminal was just spawned/shown,
---rather than "most recently created" (which races with placeholder sessions).
---@return string|nil session_id
function M.get_visible_session_id()
  for _, win in ipairs(vim.api.nvim_list_wins() or {}) do
    local ok, buf = pcall(vim.api.nvim_win_get_buf, win)
    if ok and buf then
      local sid = buffer_session_map[buf]
      if sid then
        return sid
      end
    end
  end
  return nil
end

---Bind a freshly opened terminal buffer to its session and record terminal info.
---Called by the session-aware entry points after the provider opens a terminal.
---@param session_id string
---@param bufnr number
---@param provider table The provider instance (may expose register_terminal_for_session)
local function finalize_session_terminal(session_id, bufnr, provider)
  if not (session_id and bufnr) then
    return
  end
  M.register_buffer_session(bufnr, session_id)
  if provider and provider.register_terminal_for_session then
    provider.register_terminal_for_session(session_id, bufnr)
  end
  local sm = session_manager_mod
  sm.update_terminal_info(session_id, { bufnr = bufnr })
  -- Mark awaiting_handshake only if not already bound — toggling an
  -- already-connected session must not flip it back, or the next handshake
  -- from a different session would steal this session's identity.
  local s = sm.get_session(session_id)
  if s and not s.client_id and sm.mark_awaiting_handshake then
    sm.mark_awaiting_handshake(session_id)
  end
  -- Re-render the tabbar: providers call attach_tabbar before finalize, so
  -- the initial render missed this session's buffer binding.
  pcall(function()
    local tabbar = require("claudecode.terminal.tabbar")
    if tabbar.is_visible and tabbar.is_visible() then
      local ok_tab, current_tab = pcall(vim.api.nvim_get_current_tabpage)
      if ok_tab and current_tab then
        tabbar.render(current_tab)
      end
    end
  end)
end

function M.ensure_session()
  return session_manager_mod.ensure_session()
end

function M.get_active_session_id()
  return session_manager_mod.get_active_session_id()
end

-- The active session table (nil if none). Exposed so callers (e.g. the rename
-- command) can read its current name without reaching into the session module.
function M.get_active_session()
  return session_manager_mod.get_active_session()
end

-- Get the session id whose terminal buffer is currently focused, if any.
function M.get_current_session_id()
  local session = session_manager_mod.find_session_by_bufnr(vim.api.nvim_get_current_buf())
  return session and session.id or nil
end

-- Get the terminal buffer number backing a session, if any. Prefers the
-- provider's authoritative mapping (toggleterm keeps its own per-session
-- buffer table) and falls back to the session-manager field updated on spawn.
-- Used by the session picker to read a snapshot of the terminal's visible
-- content for its preview pane.
---@param session_id string
---@return number|nil bufnr
function M.get_session_bufnr(session_id)
  local provider = get_provider()
  if provider and provider.get_session_bufnr then
    local bufnr = provider.get_session_bufnr(session_id)
    if bufnr then
      return bufnr
    end
  end
  local session = session_manager_mod.get_session(session_id)
  return session and session.terminal_bufnr or nil
end

---@return boolean has_open_session Whether the provider exposes per-session terminals.
local function provider_has_sessions(provider)
  return provider and type(provider.open_session) == "function"
end

function M.list_sessions()
  return session_manager_mod.list_sessions()
end

-- Called by providers.
function M.update_session_terminal_info(session_id, terminal_info)
  session_manager_mod.update_terminal_info(session_id, terminal_info)
end

-- Rename a session (defaults to the active one). Empty/whitespace names rejected.
---@return boolean success
function M.rename_session(session_id, name)
  local sm = session_manager_mod
  session_id = session_id or sm.get_active_session_id()
  if not session_id then
    return false
  end
  name = type(name) == "string" and vim.trim(name) or ""
  if name == "" then
    require("claudecode.logger").warn("terminal", "rename_session: empty name rejected")
    return false
  end
  sm.update_session_name(session_id, name)
  return true
end

---Builds the effective terminal configuration by merging defaults with overrides
---@param opts_override table? Optional overrides for terminal appearance
---@return table config The effective terminal configuration
local function build_config(opts_override)
  local effective_config = vim.deepcopy(defaults)
  if type(opts_override) == "table" then
    local validators = {
      split_side = function(val)
        return val == "left" or val == "right"
      end,
      split_width_percentage = function(val)
        return type(val) == "number" and val > 0 and val < 1
      end,
      snacks_win_opts = function(val)
        return type(val) == "table"
      end,
      cwd = function(val)
        return val == nil or type(val) == "string"
      end,
      git_repo_cwd = function(val)
        return type(val) == "boolean"
      end,
      cwd_provider = function(val)
        local t = type(val)
        if t == "function" then
          return true
        end
        if t == "table" then
          local mt = getmetatable(val)
          return mt and mt.__call ~= nil
        end
        return false
      end,
    }
    for key, val in pairs(opts_override) do
      if effective_config[key] ~= nil and validators[key] and validators[key](val) then
        effective_config[key] = val
      end
    end
  end
  -- Resolve cwd at config-build time so providers receive it directly
  local cwd_ctx = {
    file = (function()
      local path = vim.fn.expand("%:p")
      if type(path) == "string" and path ~= "" then
        return path
      end
      return nil
    end)(),
    cwd = vim.fn.getcwd(),
  }
  cwd_ctx.file_dir = cwd_ctx.file and vim.fn.fnamemodify(cwd_ctx.file, ":h") or nil

  local resolved_cwd = nil
  -- Prefer provider function, then static cwd, then git root via resolver
  if effective_config.cwd_provider then
    local ok_p, res = pcall(effective_config.cwd_provider, cwd_ctx)
    if ok_p and type(res) == "string" and res ~= "" then
      resolved_cwd = vim.fn.expand(res)
    end
  end
  if not resolved_cwd and type(effective_config.cwd) == "string" and effective_config.cwd ~= "" then
    resolved_cwd = vim.fn.expand(effective_config.cwd)
  end
  if not resolved_cwd and effective_config.git_repo_cwd then
    local ok_r, cwd_mod = pcall(require, "claudecode.cwd")
    if ok_r and cwd_mod and type(cwd_mod.git_root) == "function" then
      resolved_cwd = cwd_mod.git_root(cwd_ctx.file_dir or cwd_ctx.cwd)
    end
  end

  return {
    split_side = effective_config.split_side,
    split_width_percentage = effective_config.split_width_percentage,
    auto_close = effective_config.auto_close,
    auto_insert = effective_config.auto_insert,
    snacks_win_opts = effective_config.snacks_win_opts,
    cwd = resolved_cwd,
  }
end

---Checks if a terminal buffer is currently visible in any window
---@param bufnr number? The buffer number to check
---@return boolean True if the buffer is visible in any window, false otherwise
local function is_terminal_visible(bufnr)
  if not bufnr then
    return false
  end

  local bufinfo = vim.fn.getbufinfo(bufnr)
  if not (bufinfo and #bufinfo > 0) then
    return false
  end
  -- A config-hidden window (e.g. a Snacks float parked via
  -- nvim_win_set_config({hide=true}) to dodge the climbing-cursor bug #240/#183)
  -- still lists the buffer but is not actually on screen; don't count it.
  for _, win in ipairs(bufinfo[1].windows or {}) do
    if vim.api.nvim_win_is_valid(win) then
      local ok, cfg = pcall(vim.api.nvim_win_get_config, win)
      if not (ok and cfg and cfg.hide == true) then
        return true
      end
    end
  end
  return false
end

---Builds a no_proxy value that is guaranteed to exclude the loopback hosts
---(localhost, 127.0.0.1, ::1) from any proxy, merging the given existing values
---(each a comma-separated list, nils allowed) order-preserving and de-duplicated.
---See issue #70: Claude must never proxy its loopback IDE WebSocket connection.
---@param ... string? Existing no_proxy/NO_PROXY values to merge ahead of the loopback hosts
---@return string combined The merged no_proxy value with loopback hosts guaranteed present
local function no_proxy_with_loopback(...)
  local entries = {}
  local seen = {}

  local function add_entry(entry)
    entry = entry:gsub("^%s+", ""):gsub("%s+$", "")
    if entry ~= "" and not seen[entry] then
      seen[entry] = true
      entries[#entries + 1] = entry
    end
  end

  -- select() (not ipairs over {...}) so a nil source does not truncate the rest.
  for i = 1, select("#", ...) do
    local value = select(i, ...)
    if type(value) == "string" then
      for entry in value:gmatch("[^,]+") do
        add_entry(entry)
      end
    end
  end

  for _, host in ipairs({ "localhost", "127.0.0.1", "::1" }) do
    add_entry(host)
  end

  return table.concat(entries, ",")
end

---Gets the claude command string and necessary environment variables
---@param cmd_args string? Optional arguments to append to the command
---@return string cmd_string The command string
---@return table env_table The environment variables table
local function get_claude_command_and_env(cmd_args)
  -- Inline get_claude_command logic
  local cmd_from_config = defaults.terminal_cmd
  local base_cmd
  if not cmd_from_config or cmd_from_config == "" then
    base_cmd = "claude" -- Default if not configured
  else
    base_cmd = cmd_from_config
  end

  local cmd_string
  if cmd_args and cmd_args ~= "" then
    cmd_string = base_cmd .. " " .. cmd_args
  else
    cmd_string = base_cmd
  end

  local sse_port_value = claudecode_server_module.state.port
  local env_table = {
    ENABLE_IDE_INTEGRATION = "true",
    FORCE_CODE_TERMINAL = "true",
  }

  if sse_port_value then
    env_table["CLAUDE_CODE_SSE_PORT"] = tostring(sse_port_value)
  end

  -- Merge custom environment variables from config
  for key, value in pairs(defaults.env) do
    env_table[key] = value
  end

  -- Issue #70: Claude honors http_proxy/all_proxy (proxy-from-env semantics) and, without a
  -- localhost exclusion, tunnels even its ws://127.0.0.1:<port> IDE connection through the
  -- proxy, so the handshake never reaches our server and queued @ mentions time out. Guarantee
  -- the loopback hosts bypass the proxy. This runs LAST -- after the config merge above and
  -- regardless of the inherited env (termopen layers env_table over the parent env) -- so the
  -- loopback exclusion always holds. We merge, rather than clobber, every existing source: the
  -- inherited shell no_proxy/NO_PROXY and any value the user set via the `env` config option.
  local combined_no_proxy =
    no_proxy_with_loopback(os.getenv("no_proxy"), os.getenv("NO_PROXY"), env_table["no_proxy"], env_table["NO_PROXY"])
  env_table["no_proxy"] = combined_no_proxy
  env_table["NO_PROXY"] = combined_no_proxy

  return cmd_string, env_table
end

---Common helper to open terminal without focus if not already visible
---@param opts_override table? Optional config overrides
---@param cmd_args string? Optional command arguments
---@return boolean visible True if terminal was opened or already visible
local function ensure_terminal_visible_no_focus(opts_override, cmd_args)
  local provider = get_provider()

  -- Check if provider has an ensure_visible method
  if provider.ensure_visible then
    provider.ensure_visible()
    return true
  end

  local active_bufnr = provider.get_active_bufnr()

  if is_terminal_visible(active_bufnr) then
    -- Terminal is already visible, do nothing
    return true
  end

  -- Terminal is not visible, open it without focus
  local effective_config = build_config(opts_override)
  local cmd_string, claude_env_table = get_claude_command_and_env(cmd_args)
  local session_id = M.ensure_session()

  if provider_has_sessions(provider) then
    provider.open_session(session_id, cmd_string, claude_env_table, effective_config, false)
    finalize_session_terminal(
      session_id,
      provider.get_session_bufnr and provider.get_session_bufnr(session_id),
      provider
    )
  else
    provider.open(cmd_string, claude_env_table, effective_config, false) -- false = don't focus
    finalize_session_terminal(session_id, provider.get_active_bufnr(), provider)
  end
  return true
end

---Configures the terminal module.
---Merges user-provided terminal configuration with defaults and sets the terminal command.
---@param user_term_config ClaudeCodeTerminalConfig? Configuration options for the terminal.
---@param p_terminal_cmd string? The command to run in the terminal (from main config).
---@param p_env table? Custom environment variables to pass to the terminal (from main config).
function M.setup(user_term_config, p_terminal_cmd, p_env)
  if user_term_config == nil then -- Allow nil, default to empty table silently
    user_term_config = {}
  elseif type(user_term_config) ~= "table" then -- Warn if it's not nil AND not a table
    vim.notify("claudecode.terminal.setup expects a table or nil for user_term_config", vim.log.levels.WARN)
    user_term_config = {}
  end

  if p_terminal_cmd == nil or type(p_terminal_cmd) == "string" then
    defaults.terminal_cmd = p_terminal_cmd
  else
    vim.notify(
      "claudecode.terminal.setup: Invalid terminal_cmd provided: " .. tostring(p_terminal_cmd) .. ". Using default.",
      vim.log.levels.WARN
    )
    defaults.terminal_cmd = nil -- Fallback to default behavior
  end

  if p_env == nil or type(p_env) == "table" then
    defaults.env = p_env or {}
  else
    vim.notify(
      "claudecode.terminal.setup: Invalid env provided: " .. tostring(p_env) .. ". Using empty table.",
      vim.log.levels.WARN
    )
    defaults.env = {}
  end

  for k, v in pairs(user_term_config) do
    if k == "split_side" then
      if v == "left" or v == "right" then
        defaults.split_side = v
      else
        vim.notify("claudecode.terminal.setup: Invalid value for split_side: " .. tostring(v), vim.log.levels.WARN)
      end
    elseif k == "split_width_percentage" then
      if type(v) == "number" and v > 0 and v < 1 then
        defaults.split_width_percentage = v
      else
        vim.notify(
          "claudecode.terminal.setup: Invalid value for split_width_percentage: " .. tostring(v),
          vim.log.levels.WARN
        )
      end
    elseif k == "diff_split_width_percentage" then
      if v == nil or (type(v) == "number" and v > 0 and v < 1) then
        defaults.diff_split_width_percentage = v
      else
        vim.notify(
          "claudecode.terminal.setup: Invalid value for diff_split_width_percentage: " .. tostring(v),
          vim.log.levels.WARN
        )
      end
    elseif k == "provider" then
      if
        type(v) == "table"
        or v == "snacks"
        or v == "native"
        or v == "external"
        or v == "toggleterm"
        or v == "auto"
        or v == "none"
      then
        defaults.provider = v
      else
        vim.notify(
          "claudecode.terminal.setup: Invalid value for provider: " .. tostring(v) .. ". Defaulting to 'native'.",
          vim.log.levels.WARN
        )
      end
    elseif k == "provider_opts" then
      -- Handle nested provider options
      if type(v) == "table" then
        defaults[k] = defaults[k] or {}
        for opt_k, opt_v in pairs(v) do
          if opt_k == "external_terminal_cmd" then
            if opt_v == nil or type(opt_v) == "string" or type(opt_v) == "function" then
              defaults[k][opt_k] = opt_v
            else
              vim.notify(
                "claudecode.terminal.setup: Invalid value for provider_opts.external_terminal_cmd: " .. tostring(opt_v),
                vim.log.levels.WARN
              )
            end
          else
            -- For other provider options, just copy them
            defaults[k][opt_k] = opt_v
          end
        end
      else
        vim.notify("claudecode.terminal.setup: Invalid value for provider_opts: " .. tostring(v), vim.log.levels.WARN)
      end
    elseif k == "show_native_term_exit_tip" then
      if type(v) == "boolean" then
        defaults.show_native_term_exit_tip = v
      else
        vim.notify(
          "claudecode.terminal.setup: Invalid value for show_native_term_exit_tip: " .. tostring(v),
          vim.log.levels.WARN
        )
      end
    elseif k == "auto_close" then
      if type(v) == "boolean" then
        defaults.auto_close = v
      else
        vim.notify("claudecode.terminal.setup: Invalid value for auto_close: " .. tostring(v), vim.log.levels.WARN)
      end
    elseif k == "auto_insert" then
      if type(v) == "boolean" then
        defaults.auto_insert = v
      else
        vim.notify("claudecode.terminal.setup: Invalid value for auto_insert: " .. tostring(v), vim.log.levels.WARN)
      end
    elseif k == "snacks_win_opts" then
      if type(v) == "table" then
        defaults.snacks_win_opts = v
      else
        vim.notify("claudecode.terminal.setup: Invalid value for snacks_win_opts", vim.log.levels.WARN)
      end
    elseif k == "fix_streamed_paste" then
      if type(v) == "boolean" or v == "auto" then
        defaults.fix_streamed_paste = v
      else
        vim.notify(
          "claudecode.terminal.setup: Invalid value for fix_streamed_paste: "
            .. tostring(v)
            .. " (expected true, false, or 'auto')",
          vim.log.levels.WARN
        )
      end
    elseif k == "tabs" then
      if type(v) == "table" then
        defaults.tabs = vim.tbl_deep_extend("force", defaults.tabs, v)
      else
        vim.notify("claudecode.terminal.setup: Invalid value for tabs (expected table)", vim.log.levels.WARN)
      end
    elseif k == "cwd" then
      if v == nil or type(v) == "string" then
        defaults.cwd = v
      else
        vim.notify("claudecode.terminal.setup: Invalid value for cwd: " .. tostring(v), vim.log.levels.WARN)
      end
    elseif k == "git_repo_cwd" then
      if type(v) == "boolean" then
        defaults.git_repo_cwd = v
      else
        vim.notify("claudecode.terminal.setup: Invalid value for git_repo_cwd: " .. tostring(v), vim.log.levels.WARN)
      end
    elseif k == "cwd_provider" then
      local t = type(v)
      if t == "function" then
        defaults.cwd_provider = v
      elseif t == "table" then
        local mt = getmetatable(v)
        if mt and mt.__call then
          defaults.cwd_provider = v
        else
          vim.notify(
            "claudecode.terminal.setup: cwd_provider table is not callable (missing __call)",
            vim.log.levels.WARN
          )
        end
      else
        vim.notify("claudecode.terminal.setup: Invalid cwd_provider type: " .. tostring(t), vim.log.levels.WARN)
      end
    else
      if k ~= "terminal_cmd" then
        vim.notify("claudecode.terminal.setup: Unknown configuration key: " .. k, vim.log.levels.WARN)
      end
    end
  end

  -- Setup providers with config
  get_provider().setup(defaults)

  -- Single-window-multi-buffer infra: window_manager owns THE global terminal
  -- window (singleton across all tabpages); providers create per-session
  -- buffers and swap them via display_buffer. tabbar renders the global
  -- session list. pcall-guarded so minimal test stubs without a full vim.api
  -- still load the terminal module.
  pcall(function()
    require("claudecode.terminal.window_manager").setup(defaults)
  end)
  pcall(function()
    require("claudecode.terminal.tabbar").setup(defaults.tabs or { enabled = true })
  end)

  -- Streamed-paste compatibility shim for #161 (no-op on Neovim >= 0.12.2).
  require("claudecode.terminal.paste_fix").apply(defaults.fix_streamed_paste)
end

-- Common backend for open/simple_toggle/focus_toggle. `session_method` is the
-- provider method to call on session-aware providers ("open_session" or
-- "toggle_session"); `legacy_method` is the fallback for non-session providers.
-- `focus` is forwarded to open_session; toggle_session takes none.
local function run_terminal_action(opts_override, cmd_args, session_method, legacy_method, focus)
  local effective_config = build_config(opts_override)
  local provider = get_provider()
  local session_id = M.ensure_session()

  -- Spawn-time args (--resume, --continue, --model, …) only take effect on a
  -- fresh `claude` process; open_session/toggle_session short-circuit when the
  -- session already has a live buffer and would silently drop cmd_args. When
  -- cmd_args is non-empty AND the active session already has a terminal, open a
  -- brand-new session with those args instead of toggling the existing one.
  -- Without this, `:ClaudeCode --resume <id>` toggles the live session and
  -- never passes --resume to claude (issue introduced by multi-session).
  local has_args = cmd_args ~= nil and cmd_args ~= ""
  if
    has_args
    and provider_has_sessions(provider)
    and provider.get_session_bufnr
    and provider.get_session_bufnr(session_id) ~= nil
  then
    M.open_new_session(opts_override, cmd_args)
    return
  end

  local cmd_string, claude_env_table = get_claude_command_and_env(cmd_args)

  if provider_has_sessions(provider) then
    if session_method == "toggle_session" and provider.toggle_session then
      provider.toggle_session(session_id, effective_config, cmd_string, claude_env_table)
    else
      provider.open_session(session_id, cmd_string, claude_env_table, effective_config, focus)
    end
    finalize_session_terminal(
      session_id,
      provider.get_session_bufnr and provider.get_session_bufnr(session_id),
      provider
    )
    return
  end

  provider[legacy_method](cmd_string, claude_env_table, effective_config)
  finalize_session_terminal(session_id, provider.get_active_bufnr(), provider)
end

---Opens or focuses the Claude terminal.
function M.open(opts_override, cmd_args)
  run_terminal_action(opts_override, cmd_args, "open_session", "open", true)
end

---Closes the managed Claude terminal if it's open and valid.
function M.close()
  get_provider().close()
end

---Simple toggle: always show/hide the Claude terminal regardless of focus.
function M.simple_toggle(opts_override, cmd_args)
  run_terminal_action(opts_override, cmd_args, "toggle_session", "simple_toggle", false)
end

---Smart focus toggle: switches to terminal if not focused, hides if currently focused.
function M.focus_toggle(opts_override, cmd_args)
  run_terminal_action(opts_override, cmd_args, "open_session", "focus_toggle", true)
end

-- Open a brand-new Claude terminal session and focus it. For legacy providers
-- this behaves like M.open.
function M.open_new_session(opts_override, cmd_args)
  local effective_config = build_config(opts_override)
  local provider = get_provider()

  if not provider_has_sessions(provider) then
    M.open(opts_override, cmd_args)
    return
  end

  local sm = session_manager_mod
  -- Create + activate the new session BEFORE building the env, so the env
  -- carries THIS session's identity (not the previous active session's).
  local session_id = sm.create_session()
  sm.set_active_session(session_id)
  local cmd_string, claude_env_table = get_claude_command_and_env(cmd_args)
  provider.open_session(session_id, cmd_string, claude_env_table, effective_config, true)
  finalize_session_terminal(session_id, provider.get_session_bufnr and provider.get_session_bufnr(session_id), provider)
end

-- Switch the active session to `session_id` and focus its terminal.
function M.switch_to_session(session_id, opts_override)
  local sm = session_manager_mod
  if not sm.get_session(session_id) then
    require("claudecode.logger").warn("terminal", "Cannot switch to non-existent session: " .. tostring(session_id))
    return
  end

  sm.set_active_session(session_id)
  local provider = get_provider()

  if provider.focus_session then
    provider.focus_session(session_id, build_config(opts_override))
  else
    M.open(opts_override, nil)
  end
end

-- Toggle a session's terminal visibility (toggleterm-style). For providers
-- without per-session toggle_session, delegate to simple_toggle so the
-- legacy provider's own show/hide semantics apply — NOT M.open, which only
-- ever shows and would make "toggle" a no-op on the second call.
function M.toggle_session(session_id, opts_override)
  local sm = session_manager_mod
  if not sm.get_session(session_id) then
    require("claudecode.logger").warn("terminal", "Cannot toggle non-existent session: " .. tostring(session_id))
    return
  end

  sm.set_active_session(session_id)
  local provider = get_provider()
  local effective_config = build_config(opts_override)
  local cmd_string, claude_env_table = get_claude_command_and_env(nil)

  if provider.toggle_session then
    provider.toggle_session(session_id, effective_config, cmd_string, claude_env_table)
  else
    -- Legacy single-terminal provider: route through its simple_toggle so the
    -- window actually hides when already visible. M.open would only ever show.
    provider.simple_toggle(cmd_string, claude_env_table, effective_config)
  end

  -- Bind the session so the tabbar lists it. toggle_session_by_index creates
  -- placeholder sessions without a terminal; provider.toggle_session may spawn
  -- one on first open.
  finalize_session_terminal(session_id, provider.get_session_bufnr and provider.get_session_bufnr(session_id), provider)
end

-- Toggle the session at a 1-based slot index. If the slot is occupied, toggle
-- that session; if empty, create a new session pinned to slot N.
function M.toggle_session_by_index(n, opts_override)
  local sm = session_manager_mod
  if type(n) ~= "number" or n < 1 then
    return
  end

  local existing = sm.get_session_by_slot(n)
  local session_id
  if existing then
    session_id = existing.id
  else
    session_id = sm.create_session({ slot = n })
    sm.set_active_session(session_id)
  end

  local target = sm.get_session(session_id)
  if not target then
    return
  end

  vim.schedule(function()
    vim.notify(string.format("Claude session %d: %s", n, target.name or target.id), vim.log.levels.INFO)
  end)

  M.toggle_session(target.id, opts_override)
end

-- Close a session by id (or the active one when nil). When other sessions
-- remain, the window is reused for a successor if the provider supports it.
function M.close_session(session_id)
  local sm = session_manager_mod
  session_id = session_id or sm.get_active_session_id()
  if not session_id then
    return
  end

  local provider = get_provider()
  local effective_config = build_config(nil)
  local session_count = sm.get_session_count()

  -- Drop the buffer<->session mapping before the provider deletes the buffer,
  -- so a recycled bufnr can't resolve to a dead session via get_visible_session_id.
  local closing_bufnr = provider.get_session_bufnr and provider.get_session_bufnr(session_id)
  if closing_bufnr then
    M.unregister_buffer_session(closing_bufnr)
  end

  local was_active = sm.get_active_session_id() == session_id

  if session_count > 1 then
    -- Successor is only needed when the closed session was the active (and thus
    -- displayed) one; closing a non-active session leaves the window untouched.
    local new_active_id
    if was_active then
      for _, s in ipairs(sm.list_sessions()) do
        if s.id ~= session_id then
          new_active_id = s.id
          break
        end
      end
    end

    if was_active and new_active_id and provider.close_session_keep_window then
      -- Closing the displayed (active) session: reuse its window for the successor.
      provider.close_session_keep_window(session_id, new_active_id, effective_config)
      sm.destroy_session(session_id)
      sm.set_active_session(new_active_id)
    elseif was_active and new_active_id then
      -- No window-reuse support: stop, destroy, then focus the successor.
      if provider.close_session then
        provider.close_session(session_id)
      else
        provider.close()
      end
      sm.destroy_session(session_id)
      if provider.focus_session then
        provider.focus_session(new_active_id, effective_config)
      end
      sm.set_active_session(new_active_id)
    else
      -- Closing a non-active session: its buffer isn't in the window. Stop its
      -- terminal and destroy; leave the window and the active session untouched.
      if provider.close_session then
        provider.close_session(session_id)
      else
        provider.close()
      end
      sm.destroy_session(session_id)
    end
  else
    -- Last session: close everything.
    if provider.close_session then
      provider.close_session(session_id)
    else
      provider.close()
    end
    sm.destroy_session(session_id)
  end
end

---Toggle open terminal without focus if not already visible, otherwise do nothing.
---@param opts_override table? Overrides for terminal appearance (split_side, split_width_percentage).
---@param cmd_args string? Arguments to append to the claude command.
function M.toggle_open_no_focus(opts_override, cmd_args)
  ensure_terminal_visible_no_focus(opts_override, cmd_args)
end

---Ensures terminal is visible without changing focus. Creates if necessary, shows if hidden.
---@param opts_override table? Overrides for terminal appearance (split_side, split_width_percentage).
---@param cmd_args string? Arguments to append to the claude command.
function M.ensure_visible(opts_override, cmd_args)
  ensure_terminal_visible_no_focus(opts_override, cmd_args)
end

---Toggles the Claude terminal open or closed (legacy function - use simple_toggle or focus_toggle).
---@param opts_override table? Overrides for terminal appearance (split_side, split_width_percentage).
---@param cmd_args string? Arguments to append to the claude command.
function M.toggle(opts_override, cmd_args)
  -- Default to simple toggle for backward compatibility
  M.simple_toggle(opts_override, cmd_args)
end

---Gets the buffer number of the currently active Claude Code terminal.
---Prefers the active session's buffer for session-aware providers, then falls
---back to the provider's active buffer.
---@return number|nil The buffer number if an active terminal is found, otherwise nil.
function M.get_active_terminal_bufnr()
  local provider = get_provider()
  local active_id = M.get_active_session_id()
  if active_id and provider.get_session_bufnr then
    local bufnr = provider.get_session_bufnr(active_id)
    if bufnr then
      return bufnr
    end
  end
  return provider.get_active_bufnr()
end

---Sends raw text to the running Claude Code terminal's job channel, as if it were
---typed at the prompt. By default a trailing carriage return submits the line.
---
---Only works for the in-editor providers ("native"/"snacks"). The "external" and
---"none" providers run Claude outside Neovim and expose no buffer, so this warns and
---returns false. This function is synchronous and does NOT open the terminal: it
---requires one to already be running, otherwise it warns and returns false. The
---`:ClaudeCodeSendText` command is a thin wrapper around this.
---
---Multi-line text is wrapped in bracketed-paste markers (ESC[200~ ... ESC[201~) so
---embedded newlines arrive as one literal pasted block rather than several premature
---submits; the submit carriage return is sent after the closing marker so it still
---triggers submission. `chansend` writes straight to the PTY and bypasses `vim.paste`,
---so the `fix_streamed_paste` shim is irrelevant here.
---@param text string The text to send. Must be a non-empty string.
---@param opts { submit?: boolean, focus?: boolean }? `submit` (default true) appends a carriage return so Claude submits the line; `focus` (default false) focuses the terminal after a successful send.
---@return boolean success Whether the text was written to a terminal channel.
function M.send_to_terminal(text, opts)
  local logger = require("claudecode.logger")

  if type(text) ~= "string" or text == "" then
    logger.warn("terminal", "send_to_terminal: no text provided")
    return false
  end

  opts = opts or {}
  local submit = opts.submit ~= false

  local bufnr = M.get_active_terminal_bufnr()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    local provider_name = type(defaults.provider) == "string" and defaults.provider or "custom"
    if provider_name == "none" or provider_name == "external" then
      logger.warn(
        "terminal",
        string.format(
          "Cannot send text: terminal.provider=%q runs Claude outside Neovim, so there is no pane to "
            .. "write to. Use the 'native' or 'snacks' provider to send text programmatically.",
          provider_name
        )
      )
    else
      logger.warn("terminal", "Cannot send text: no Claude terminal is currently running.")
    end
    return false
  end

  -- termopen() sets b:terminal_job_id; bo.channel is the robust fallback that also
  -- survives a recovered terminal whose module-level job id was lost (native.lua).
  local chan = vim.b[bufnr] and vim.b[bufnr].terminal_job_id
  if not chan or chan == 0 then
    chan = vim.bo[bufnr].channel
  end
  if not chan or chan == 0 then
    logger.warn("terminal", "Cannot send text: no terminal job channel for buffer " .. tostring(bufnr))
    return false
  end

  -- Normalize line endings so the ONLY submit byte is the trailing CR added below.
  -- A bare "\r" is Enter at Claude's prompt, so any interior CR (e.g. CRLF or old-Mac
  -- text from a programmatic caller) would otherwise fire one or more premature submits
  -- -- the exact failure mode the bracketed-paste wrapping exists to prevent.
  local normalized = (text:gsub("\r\n", "\n"):gsub("\r", "\n"))

  local payload = normalized
  if string.find(normalized, "\n", 1, true) then
    -- Multi-line: bracketed paste so the newlines arrive as one literal block.
    payload = "\27[200~" .. normalized .. "\27[201~"
  end
  if submit then
    payload = payload .. "\r"
  end

  -- chansend can reject (0 bytes) or error if the channel is closed -- e.g. a recovered
  -- terminal whose process already exited but whose buffer is still valid. Honor that
  -- instead of reporting a false success.
  local ok_send, written = pcall(vim.fn.chansend, chan, payload)
  if not ok_send or written == 0 then
    logger.warn("terminal", "Cannot send text: the Claude terminal channel is closed (the process may have exited).")
    return false
  end
  logger.debug(
    "terminal",
    string.format(
      "send_to_terminal: wrote %d byte(s) to channel %s (submit=%s)",
      #payload,
      tostring(chan),
      tostring(submit)
    )
  )

  if opts.focus then
    M.open()
  end

  return true
end

---Gets the managed terminal instance for testing purposes.
-- NOTE: This function is intended for use in tests to inspect internal state.
-- The underscore prefix indicates it's not part of the public API for regular use.
---@return table|nil terminal The managed terminal instance, or nil.
function M._get_managed_terminal_for_test()
  local provider = get_provider()
  if provider and provider._get_terminal_for_test then
    return provider._get_terminal_for_test()
  end
  return nil
end

return M
