require("tests.busted_setup")

-- Tests for claudecode.session: creation, destruction, client binding, and
-- the rename path (update_session_name) that the tabbar listens to.

describe("claudecode.session", function()
  local session

  before_each(function()
    package.path = "./lua/?.lua;" .. package.path
    package.loaded["claudecode.session"] = nil
    package.loaded["claudecode.logger"] = package.loaded["claudecode.logger"]
      or {
        debug = function() end,
        warn = function() end,
        error = function() end,
        info = function() end,
      }
    -- busted_setup already installed a vim mock; patch its loop.now with a
    -- monotonic counter so created_at differs across sessions created in the
    -- same os.time() second (table.sort isn't stable, so equal timestamps
    -- would make list_sessions ordering nondeterministic).
    local now_counter = 1000
    _G.vim.loop.now = function()
      now_counter = now_counter + 1
      return now_counter
    end

    session = require("claudecode.session")
    session.reset()
  end)

  after_each(function()
    if session then
      session.reset()
    end
  end)

  describe("create_session", function()
    it("creates a session with a unique id and default name", function()
      local id = session.create_session()
      expect(id).to_be_string()
      local s = session.get_session(id)
      expect(s).to_be_table()
      expect(s.name).to_be_string()
      expect(session.get_active_session_id()).to_be(id)
    end)

    it("first session becomes active", function()
      local id1 = session.create_session()
      expect(session.get_active_session_id()).to_be(id1)
      session.create_session()
      -- Active unchanged when creating a second session.
      expect(session.get_active_session_id()).to_be(id1)
    end)

    it("accepts a custom name", function()
      local id = session.create_session({ name = "my-session" })
      expect(session.get_session(id).name).to_be("my-session")
    end)
  end)

  describe("destroy_session", function()
    it("removes the session", function()
      local id = session.create_session()
      expect(session.destroy_session(id)).to_be(true)
      expect(session.get_session(id)).to_be_nil()
    end)

    it("returns false for an already-destroyed session (idempotent)", function()
      local id = session.create_session()
      session.destroy_session(id)
      expect(session.destroy_session(id)).to_be(false)
    end)

    it("promotes another session to active when the active one is destroyed", function()
      local id1 = session.create_session()
      local id2 = session.create_session()
      session.set_active_session(id2)
      expect(session.get_active_session_id()).to_be(id2)
      session.destroy_session(id2)
      expect(session.get_active_session_id()).to_be(id1)
    end)
  end)

  describe("bind_client / unbind_client", function()
    it("binds a client to a session and looks it up", function()
      local id = session.create_session()
      expect(session.bind_client(id, "client-1")).to_be(true)
      expect(session.find_session_by_client("client-1").id).to_be(id)
    end)

    it("refuses to bind a client already bound to another session", function()
      local id1 = session.create_session()
      local id2 = session.create_session()
      session.bind_client(id1, "client-1")
      expect(session.bind_client(id2, "client-1")).to_be(false)
      expect(session.find_session_by_client("client-1").id).to_be(id1)
    end)

    it("unbind clears the client binding", function()
      local id = session.create_session()
      session.bind_client(id, "client-1")
      expect(session.unbind_client("client-1")).to_be(true)
      expect(session.find_session_by_client("client-1")).to_be_nil()
    end)
  end)

  describe("update_session_name", function()
    it("updates the name and strips the 'Claude - ' prefix", function()
      local id = session.create_session()
      session.update_session_name(id, "Claude - refactor auth")
      expect(session.get_session(id).name).to_be("refactor auth")
    end)

    it("trims leading/trailing whitespace", function()
      local id = session.create_session()
      session.update_session_name(id, "  spaced  ")
      expect(session.get_session(id).name).to_be("spaced")
    end)

    it("rejects empty names (after trim) without changing the session", function()
      local id = session.create_session()
      local original = session.get_session(id).name
      session.update_session_name(id, "   ")
      expect(session.get_session(id).name).to_be(original)
    end)

    it("rejects a name identical to the current name", function()
      local id = session.create_session({ name = "same" })
      session.update_session_name(id, "same")
      expect(session.get_session(id).name).to_be("same")
    end)

    it("truncates very long names with an ellipsis", function()
      local id = session.create_session()
      local long = string.rep("x", 150)
      session.update_session_name(id, long)
      local name = session.get_session(id).name
      expect(#name).to_be(100)
      expect(name:sub(-3)).to_be("...")
    end)

    it("is a no-op for a non-existent session (no error)", function()
      session.update_session_name("does-not-exist", "whatever")
      -- just must not throw
    end)
  end)

  describe("find_unbound_session", function()
    it("returns the newest session without a bound client", function()
      local id1 = session.create_session()
      local id2 = session.create_session()
      session.bind_client(id1, "client-1")
      expect(session.find_unbound_session().id).to_be(id2)
    end)

    it("returns nil when every session has a bound client", function()
      local id = session.create_session()
      session.bind_client(id, "client-1")
      expect(session.find_unbound_session()).to_be_nil()
    end)
  end)

  describe("list_sessions", function()
    it("returns sessions ordered by slot", function()
      local id1 = session.create_session()
      local id2 = session.create_session()
      local slots = {}
      for _, s in ipairs(session.list_sessions()) do
        table.insert(slots, s.slot)
      end
      expect(slots[1]).to_be(1)
      expect(slots[2]).to_be(2)
      expect(session.get_slot(id1)).to_be(1)
      expect(session.get_slot(id2)).to_be(2)
    end)
  end)

  describe("slots", function()
    it("assigns the smallest free slot by default", function()
      session.create_session({ slot = 1 })
      session.create_session({ slot = 3 })
      -- No explicit slot → smallest gap = 2.
      local id3 = session.create_session()
      expect(session.get_slot(id3)).to_be(2)
    end)

    it("releases a slot on destroy so it gets reused", function()
      local id1 = session.create_session() -- slot 1
      session.create_session() -- slot 2
      session.destroy_session(id1) -- slot 1 freed
      local id3 = session.create_session() -- should reuse slot 1
      expect(session.get_slot(id3)).to_be(1)
    end)

    it("get_session_by_slot looks up by stable slot", function()
      local id = session.create_session({ slot = 5 })
      expect(session.get_session_by_slot(5).id).to_be(id)
      expect(session.get_session_by_slot(1)).to_be_nil()
    end)

    it("falls back to next_free_slot when requested slot is taken", function()
      session.create_session({ slot = 2 })
      local id = session.create_session({ slot = 2 }) -- 2 taken → 1
      expect(session.get_slot(id)).to_be(1)
    end)

    it("default name is 'Session' (no number)", function()
      local id = session.create_session()
      expect(session.get_session(id).name).to_be("Session")
    end)
  end)
end)
