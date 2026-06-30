-- luacheck: globals expect describe it before_each after_each
require("tests.busted_setup")

-- Regression: `:ClaudeCodeSend` must route the @-mention to the client bound
-- to the *active* session, not whichever session was previously active.
-- Reproduces the user-reported bug where switching sessions then sending still
-- delivered to the prior session's Claude.
describe("send_at_mention routes to the active session (#switch)", function()
  local saved_require
  local claudecode
  local session
  local mock_terminal
  local sent_to_client_id

  local function setup_mocks()
    sent_to_client_id = {}
    mock_terminal = {
      setup = function() end,
      open = spy.new(function() end),
      ensure_visible = spy.new(function() end),
    }
    local mock_logger = {
      setup = function() end,
      debug = function() end,
      info = function() end,
      warn = function() end,
      error = function() end,
    }
    local mock_config = {
      apply = function()
        return {
          auto_start = false,
          terminal_cmd = nil,
          env = {},
          log_level = "info",
          track_selection = false,
          focus_after_send = false,
          diff_opts = {
            layout = "vertical",
            open_in_new_tab = false,
            keep_terminal_focus = false,
            on_new_file_reject = "keep_empty",
          },
          models = { { name = "Test", value = "test" } },
          -- Bypass the debouncer so send_to_active_session is called inline.
          disable_broadcast_debouncing = true,
        }
      end,
    }

    saved_require = _G.require
    _G.require = function(mod)
      if mod == "claudecode.config" then
        return mock_config
      elseif mod == "claudecode.logger" then
        return mock_logger
      elseif mod == "claudecode.diff" then
        return { setup = function() end }
      elseif mod == "claudecode.terminal" then
        return mock_terminal
      elseif mod == "claudecode.server.init" then
        return {
          get_status = function()
            return { running = true, client_count = 2 }
          end,
        }
      else
        return saved_require(mod)
      end
    end

    claudecode = require("claudecode")
    claudecode.setup({})
    -- Real session module + a stub server whose send_to_active_session
    -- mirrors server/init.lua's real routing (resolve active session's
    -- client_id, hand to tcp_server.send_to_client). We stub the tcp layer
    -- to record which client_id received each message.
    session = require("claudecode.session")
    session.reset()
    claudecode.state.server = {
      broadcast = function()
        return true
      end,
      send_to_active_session = function(method, params)
        local active_id = session.get_active_session_id()
        local s = active_id and session.get_session(active_id) or nil
        local client_id = s and s.client_id or nil
        if client_id then
          table.insert(sent_to_client_id, { method = method, client_id = client_id, params = params })
          return true
        end
        return false
      end,
    }
  end

  before_each(function()
    _G.vim._exec_autocmds = {}
    _G.vim.fn = _G.vim.fn or {}
    _G.vim.fn.isdirectory = function()
      return 0
    end
    _G.vim.fn.getcwd = function()
      return "/Users/test/project"
    end
    _G.vim.fn.fnamemodify = function(p, _m)
      return p
    end
    _G.vim.loop = _G.vim.loop or {}
    _G.vim.loop.cwd = function()
      return "/Users/test/project"
    end
  end)

  after_each(function()
    if saved_require then
      _G.require = saved_require
    end
    if session then
      session.reset()
    end
    package.loaded["claudecode"] = nil
    package.loaded["claudecode.session"] = nil
    package.loaded["claudecode.config"] = nil
    package.loaded["claudecode.logger"] = nil
    package.loaded["claudecode.diff"] = nil
    package.loaded["claudecode.terminal"] = nil
    package.loaded["claudecode.server.init"] = nil
  end)

  it("routes to the currently active session's client after a switch", function()
    setup_mocks()

    -- Two sessions, both with bound clients (handshake complete).
    local sid_a = session.create_session({ name = "A" })
    session.bind_client(sid_a, "client-A")
    local sid_b = session.create_session({ name = "B" })
    session.bind_client(sid_b, "client-B")

    -- User switches to A, sends. Then switches to B, sends.
    session.set_active_session(sid_a)
    claudecode.send_at_mention("/abs/src/foo.lua", nil, nil, "ClaudeCodeSend")
    session.set_active_session(sid_b)
    claudecode.send_at_mention("/abs/src/bar.lua", nil, nil, "ClaudeCodeSend")

    -- Both sends should have routed via send_to_active_session (not broadcast),
    -- and each must have landed on the client_id of the session that was active
    -- AT THE TIME of the send — not the same client both times.
    assert.is_equal(2, #sent_to_client_id)
    assert.is_equal("client-A", sent_to_client_id[1].client_id)
    assert.is_equal("client-B", sent_to_client_id[2].client_id)
    assert.is_equal("at_mentioned", sent_to_client_id[1].method)
    assert.is_equal("at_mentioned", sent_to_client_id[2].method)
  end)

  it("does NOT route to a session whose client was just unbound (e.g. closed)", function()
    setup_mocks()

    local sid_a = session.create_session({ name = "A" })
    session.bind_client(sid_a, "client-A")
    local sid_b = session.create_session({ name = "B" })
    session.bind_client(sid_b, "client-B")

    -- User switches to B, but B's terminal was just closed (client unbound).
    session.set_active_session(sid_b)
    session.unbind_client("client-B")
    claudecode.send_at_mention("/abs/src/foo.lua", nil, nil, "ClaudeCodeSend")

    -- Active session B has no bound client — send_to_active_session returns
    -- false, so the mention is NOT delivered (and NOT leaked to client-A).
    assert.is_equal(0, #sent_to_client_id)
  end)
end)

-- Regression for the race the user hit: spawn session B, switch back to A
-- before B's Claude process handshakes. B's handshake must still bind to B
-- (not to A, whose buffer is visible at handshake time).
describe("initialize handshake binds by spawn order, not visible buffer (#race)", function()
  local server
  local session

  before_each(function()
    package.path = "./lua/?.lua;" .. package.path
    package.loaded["claudecode.server.init"] = nil
    package.loaded["claudecode.session"] = nil
    package.loaded["claudecode.logger"] = package.loaded["claudecode.logger"]
      or {
        debug = function() end,
        warn = function() end,
        error = function() end,
        info = function() end,
      }

    session = require("claudecode.session")
    session.reset()
    -- server/init.lua's initialize handler returns vim.empty_dict() for
    -- capabilities; the busted vim mock doesn't provide it.
    _G.vim.empty_dict = _G.vim.empty_dict or function()
      return {}
    end
    server = require("claudecode.server.init")
    server.start({ port_range = { min = 10000, max = 65535 } })
    server.register_handlers()
  end)

  after_each(function()
    if server and server.state.server then
      server.stop()
    end
    if session then
      session.reset()
    end
    package.loaded["claudecode.server.init"] = nil
    package.loaded["claudecode.session"] = nil
  end)

  it("binds an incoming client to the oldest awaiting session, not the visible one", function()
    -- A is already connected.
    local sid_a = session.create_session({ name = "A" })
    session.bind_client(sid_a, "client-A")

    -- User spawns B (plugin marks it awaiting_handshake at terminal spawn).
    local sid_b = session.create_session({ name = "B" })
    session.mark_awaiting_handshake(sid_b)

    -- User switches back to A before B's Claude process handshakes. A's buffer
    -- is now the visible one — the old get_visible_session_id probe would
    -- route B's client to A.
    session.set_active_session(sid_a)

    -- B's Claude process finally handshakes.
    server.state.handlers["initialize"]({ id = "client-B" }, {
      protocolVersion = "2024-11-05",
      capabilities = {},
      clientInfo = { name = "claude-code", version = "1.0" },
    })

    -- B's client must be bound to B, not A.
    expect(session.find_session_by_client("client-B").id).to_be(sid_b)
    expect(session.get_session(sid_b).awaiting_handshake).to_be_nil()
    -- A is untouched.
    expect(session.find_session_by_client("client-A").id).to_be(sid_a)
  end)

  it("falls back to find_unbound_session when no session is awaiting_handshake", function()
    local sid_a = session.create_session({ name = "A" })
    session.bind_client(sid_a, "client-A")
    local sid_b = session.create_session({ name = "B" })
    -- No mark_awaiting_handshake (e.g. legacy provider). Should fall back to
    -- find_unbound_session → newest unbound → B.
    server.state.handlers["initialize"]({ id = "client-B" }, {
      protocolVersion = "2024-11-05",
      capabilities = {},
      clientInfo = { name = "claude-code", version = "1.0" },
    })
    expect(session.find_session_by_client("client-B").id).to_be(sid_b)
  end)
end)
