-- Integration tests for the initialize handler's session-binding fallback.
-- The handler resolves the incoming client to a session via a 4-level
-- precedence: awaiting_handshake (oldest) → visible buffer → unbound (newest)
-- → none. These tests pin each branch so a regression in the routing order
-- (e.g. binding B's client to A because A is visible) is caught.
-- luacheck: globals expect describe it before_each after_each
require("tests.busted_setup")

describe("server initialize client-to-session binding", function()
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
  end)

  it("prefers the oldest awaiting_handshake session over an unbound one", function()
    local a = session.create_session()
    local b = session.create_session()
    session.mark_awaiting_handshake(b)

    server.state.handlers["initialize"]({ id = "client-b" }, {})

    local bound = session.find_session_by_client("client-b")
    expect(bound).to_be_table()
    expect(bound.id).to_be(b)
    assert.are_not.equal(bound.id, a)
  end)

  it("binds to the unbound session when none is awaiting handshake", function()
    local a = session.create_session()
    session.bind_client(a, "client-a")
    local b = session.create_session()

    server.state.handlers["initialize"]({ id = "client-b" }, {})

    local bound = session.find_session_by_client("client-b")
    expect(bound).to_be_table()
    expect(bound.id).to_be(b)
  end)

  it("does not steal a client already bound to another session", function()
    local a = session.create_session()
    local b = session.create_session()
    session.bind_client(a, "client-x")

    server.state.handlers["initialize"]({ id = "client-x" }, {})

    expect(session.find_session_by_client("client-x").id).to_be(a)
    expect(session.get_session(b).client_id).to_be_nil()
  end)

  it("clears awaiting_handshake flag once bound", function()
    local a = session.create_session()
    session.mark_awaiting_handshake(a)
    expect(session.get_session(a).awaiting_handshake).to_be(true)

    server.state.handlers["initialize"]({ id = "client-a" }, {})

    expect(session.get_session(a).awaiting_handshake).to_be_nil()
    expect(session.get_session(a).client_id).to_be("client-a")
  end)

  it("binds nothing when every session already has a client", function()
    local a = session.create_session()
    local b = session.create_session()
    session.bind_client(a, "client-a")
    session.bind_client(b, "client-b")

    server.state.handlers["initialize"]({ id = "client-c" }, {})

    expect(session.find_session_by_client("client-c")).to_be_nil()
  end)

  it("handles the no-sessions case without error", function()
    server.state.handlers["initialize"]({ id = "client-lonely" }, {})
    expect(session.find_session_by_client("client-lonely")).to_be_nil()
  end)
end)
