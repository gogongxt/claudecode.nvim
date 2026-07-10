require("tests.busted_setup")

-- Multi-session binding race: rapid spawns leave several sessions awaiting their
-- WebSocket handshake at once. Handshakes arrive in arbitrary order (whichever
-- Claude process boots fastest), but the server binds each to the OLDEST
-- awaiter — so a late-spawned process that connects first steals an earlier
-- session's slot, and sends land on the wrong Claude ("focused A, sent to C").
-- Fix: serialize spawns (spawn_when_handshake_free) so ≤1 session awaits at a
-- time, making the "oldest" rule exact. These tests cover the session-layer
-- primitives the guard uses + the handler's correctness under that invariant.

describe("multi-spawn binding race (#race)", function()
  local server
  local session

  before_each(function()
    package.path = "./lua/?.lua;" .. package.path
    package.loaded["claudecode.server.init"] = nil
    package.loaded["claudecode.session"] = nil
    package.loaded["claudecode.terminal"] = nil
    package.loaded["claudecode.logger"] = package.loaded["claudecode.logger"]
      or {
        debug = function() end,
        warn = function() end,
        error = function() end,
        info = function() end,
      }

    session = require("claudecode.session")
    session.reset()
    _G.vim.empty_dict = _G.vim.empty_dict or function()
      return {}
    end
    server = require("claudecode.server.init")
    server.start({ port_range = { min = 10000, max = 65535 } })
    server.register_handlers()

    -- No terminal buffer visible during these handshakes, so the handler
    -- cannot fall back to get_visible_session_id.
    package.loaded["claudecode.terminal"] = {
      get_visible_session_id = function()
        return nil
      end,
    }
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
    package.loaded["claudecode.terminal"] = nil
  end)

  describe("is_handshake_in_flight", function()
    it("returns nil when no session is awaiting", function()
      local sid = session.create_session()
      assert.is_nil(session.is_handshake_in_flight())
      session.mark_awaiting_handshake(sid)
      assert.is_equal(sid, session.is_handshake_in_flight())
    end)

    it("returns the single in-flight session id", function()
      local sid = session.create_session()
      session.mark_awaiting_handshake(sid)
      assert.is_equal(sid, session.is_handshake_in_flight())
    end)

    it("clears once the session binds a client", function()
      local sid = session.create_session()
      session.mark_awaiting_handshake(sid)
      assert.is_equal(sid, session.is_handshake_in_flight())
      session.bind_client(sid, "client-1")
      assert.is_nil(session.is_handshake_in_flight())
    end)

    it("ignores sessions that already have a client", function()
      local sid = session.create_session()
      session.bind_client(sid, "client-1")
      session.mark_awaiting_handshake(sid)
      -- Already-bound sessions are not "in flight" (the guard only waits on
      -- unbound awaiters, exactly like find_session_awaiting_handshake).
      assert.is_nil(session.is_handshake_in_flight())
    end)
  end)

  describe("clear_awaiting_handshake", function()
    it("clears the flag so the slot frees without binding a client", function()
      local sid = session.create_session()
      session.mark_awaiting_handshake(sid)
      assert.is_equal(sid, session.is_handshake_in_flight())
      session.clear_awaiting_handshake(sid)
      assert.is_nil(session.is_handshake_in_flight())
      assert.is_nil(session.get_session(sid).awaiting_handshake)
    end)
  end)

  describe("handler binds correctly under the single-awaiter invariant", function()
    -- With serialization ≤1 session awaits at a time, so the "oldest awaiting"
    -- rule is exact. These pin that by binding one session at a time.

    it("binds the sole awaiter's client to that session, in any arrival position", function()
      local sid_a = session.create_session({ name = "A" })
      local sid_b = session.create_session({ name = "B" })
      local sid_c = session.create_session({ name = "C" })

      -- Serialized spawn: only C is awaiting when C's process handshakes.
      -- (A and B already bound during their own serialized spawn windows.)
      session.bind_client(sid_a, "client-A")
      session.bind_client(sid_b, "client-B")
      session.mark_awaiting_handshake(sid_c)

      server.state.handlers["initialize"]({ id = "client-C" }, {
        protocolVersion = "2024-11-05",
        capabilities = {},
        clientInfo = { name = "claude-code", version = "1.0" },
      })

      assert.is_equal(sid_c, session.find_session_by_client("client-C").id)
      assert.is_equal(sid_a, session.find_session_by_client("client-A").id)
      assert.is_equal(sid_b, session.find_session_by_client("client-B").id)
    end)

    it("the serialized sequence A->B->C never scrambles regardless of which awaits", function()
      -- Model three serialized spawns: each awaits alone, then binds.
      local sid_a = session.create_session({ name = "A" })
      session.mark_awaiting_handshake(sid_a)
      server.state.handlers["initialize"]({ id = "client-A" }, {
        protocolVersion = "2024-11-05",
        capabilities = {},
        clientInfo = { name = "claude-code", version = "1.0" },
      })
      assert.is_equal(sid_a, session.find_session_by_client("client-A").id)
      assert.is_nil(session.is_handshake_in_flight())

      local sid_b = session.create_session({ name = "B" })
      session.mark_awaiting_handshake(sid_b)
      server.state.handlers["initialize"]({ id = "client-B" }, {
        protocolVersion = "2024-11-05",
        capabilities = {},
        clientInfo = { name = "claude-code", version = "1.0" },
      })
      assert.is_equal(sid_b, session.find_session_by_client("client-B").id)
      assert.is_nil(session.is_handshake_in_flight())

      local sid_c = session.create_session({ name = "C" })
      session.mark_awaiting_handshake(sid_c)
      server.state.handlers["initialize"]({ id = "client-C" }, {
        protocolVersion = "2024-11-05",
        capabilities = {},
        clientInfo = { name = "claude-code", version = "1.0" },
      })
      assert.is_equal(sid_c, session.find_session_by_client("client-C").id)
      assert.is_nil(session.is_handshake_in_flight())
    end)
  end)

  describe("the un-serialized multi-await case is the documented bug", function()
    -- Documents why serialization is required: with >1 awaiter, out-of-order
    -- handshakes scramble bindings (the bug). Production never reaches this
    -- state because spawn_when_handshake_free serializes; this pending case
    -- pins the bug's shape. The assertions encode the WRONG mapping.
    pending("out-of-order handshakes scramble multi-await bindings (prevented in production)", function()
      local sid_a = session.create_session({ name = "A" })
      local sid_b = session.create_session({ name = "B" })
      local sid_c = session.create_session({ name = "C" })
      session.mark_awaiting_handshake(sid_a)
      session.mark_awaiting_handshake(sid_b)
      session.mark_awaiting_handshake(sid_c)

      -- C's process handshakes first (boots fastest), then A, then B.
      server.state.handlers["initialize"]({ id = "client-C" }, {
        protocolVersion = "2024-11-05",
        capabilities = {},
        clientInfo = { name = "claude-code", version = "1.0" },
      })
      server.state.handlers["initialize"]({ id = "client-A" }, {
        protocolVersion = "2024-11-05",
        capabilities = {},
        clientInfo = { name = "claude-code", version = "1.0" },
      })
      server.state.handlers["initialize"]({ id = "client-B" }, {
        protocolVersion = "2024-11-05",
        capabilities = {},
        clientInfo = { name = "claude-code", version = "1.0" },
      })

      -- Under multi-await the first handshake binds to the OLDEST awaiter (A),
      -- NOT to C. So client-C is mis-bound to session A — the bug. This
      -- assertion encodes the WRONG mapping the un-serialized handler produces.
      assert.is_equal(sid_a, session.find_session_by_client("client-C").id)
      assert.is_not_equal(sid_c, session.find_session_by_client("client-C").id)
    end)
  end)
end)
