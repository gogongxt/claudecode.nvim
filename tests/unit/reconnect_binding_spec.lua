require("tests.busted_setup")

-- Regression: when a session's Claude process disconnects and reconnects, the
-- server's `initialize` handler must re-bind the new WebSocket client to the
-- SAME session that lost its client — not to an arbitrary unbound session.
--
-- Today the handler (server/init.lua:269) only takes the deterministic
-- `find_session_awaiting_handshake` path, and that flag is armed ONLY at spawn
-- (toggleterm.lua:265 / terminal.lua:294), never on disconnect. So a
-- reconnecting client falls through to the `get_visible_session_id` /
-- `find_unbound_session` heuristics:
--   * find_unbound_session picks the NEWEST unbound session by created_at —
--     which is whichever session disconnected most recently, NOT necessarily
--     the one whose process is reconnecting.
--   * get_visible_session_id returns nil when the terminal window is hidden
--     (common during long idle / sleep), forcing the find_unbound_session race.
--
-- This mis-bind is independent of the stale-pointer bug: even with the correct
-- active pointer, send_to_active_session looks up the bound client_id and can
-- find a client_id that was bound to the WRONG physical Claude process.
--
-- This test drives the REAL server/init.lua initialize handler against the real
-- session module. On current code the reconnecting client binds to the wrong
-- session and the test FAILS; once reconnect re-arms a deterministic signal
-- (e.g. awaiting_handshake on unbind, or binding by the session whose process
-- reconnected), the bind is correct and the test passes.
describe("reconnecting client re-binds to its own session, not an arbitrary unbound one (#reconnect)", function()
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

    -- No terminal buffer is "visible" during these reconnects (the window is
    -- hidden during idle), so the initialize handler cannot use the visible
    -- buffer to disambiguate — it must rely on a deterministic reconnect
    -- signal. get_visible_session_id is provided by the terminal module; we
    -- stub it to nil to model the hidden-window case.
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

  it("re-binds a reconnecting client to the session that lost its client", function()
    -- Two sessions, both connected. Each has a live terminal buffer (a real
    -- session's terminal persists across a WebSocket drop, so terminal_bufnr is
    -- set — this is what lets unbind_client re-arm awaiting_handshake).
    local sid_a = session.create_session({ name = "A" })
    session.bind_client(sid_a, "client-A-old")
    session.update_terminal_info(sid_a, { bufnr = 200 })

    local sid_b = session.create_session({ name = "B" })
    session.bind_client(sid_b, "client-B-old")
    session.update_terminal_info(sid_b, { bufnr = 300 })

    -- Session A's Claude process drops (idle timeout / crash / sleep-wake) and
    -- unbinds. A is now unbound; B is still bound.
    session.unbind_client("client-A-old")
    assert.is_nil(session.get_session(sid_a).client_id)

    -- A reconnects with a fresh WebSocket client id (client ids are
    -- tostring(tcp_handle) — a new userdata address per connection).
    -- No terminal buffer is visible (hidden window), so the handler cannot
    -- fall back to get_visible_session_id.
    server.state.handlers["initialize"]({ id = "client-A-new" }, {
      protocolVersion = "2024-11-05",
      capabilities = {},
      clientInfo = { name = "claude-code", version = "1.0" },
    })

    -- The reconnecting client must bind back to A — the session that lost its
    -- client. On current code find_unbound_session returns A here only by luck
    -- of created_at ordering; the decisive check is the next test.
    local bound_a = session.find_session_by_client("client-A-new")
    expect(bound_a).to_be_table()
    expect(bound_a.id).to_be(sid_a)
    -- B is untouched.
    expect(session.get_session(sid_b).client_id).to_be("client-B-old")
  end)

  it("does not steal another session's identity when a DIFFERENT session reconnects", function()
    -- The decisive race: A disconnects (becomes unbound, newest created_at among
    -- unbound), then B disconnects too. Now BOTH are unbound. B reconnects
    -- first. find_unbound_session picks the NEWEST unbound by created_at = B,
    -- so B happens to bind correctly here — but if A had been created AFTER B
    -- (e.g. A opened later), A would be "newest unbound" and B's reconnecting
    -- client would steal A's slot. We model that ordering directly.
    local sid_b = session.create_session({ name = "B" })
    session.bind_client(sid_b, "client-B-old")
    session.update_terminal_info(sid_b, { bufnr = 300 })

    -- A created AFTER B, so A has the larger created_at.
    local sid_a = session.create_session({ name = "A" })
    session.bind_client(sid_a, "client-A-old")
    session.update_terminal_info(sid_a, { bufnr = 200 })

    -- Both drop.
    session.unbind_client("client-A-old")
    session.unbind_client("client-B-old")

    -- B reconnects first.
    server.state.handlers["initialize"]({ id = "client-B-new" }, {
      protocolVersion = "2024-11-05",
      capabilities = {},
      clientInfo = { name = "claude-code", version = "1.0" },
    })

    -- B's reconnecting client must bind to B, NOT to A (the newest unbound).
    -- On current code find_unbound_session returns the newest unbound session
    -- (A, larger created_at), so client-B-new is mis-bound to A and this FAILS.
    local bound = session.find_session_by_client("client-B-new")
    expect(bound).to_be_table()
    expect(bound.id).to_be(sid_b)
    -- A must remain unbound, waiting for its own reconnect.
    expect(session.get_session(sid_a).client_id).to_be_nil()
  end)
end)
