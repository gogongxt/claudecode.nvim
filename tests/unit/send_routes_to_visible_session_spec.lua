require("tests.busted_setup")

-- Regression: `:ClaudeCodeSend` must route the @-mention to the session whose
-- terminal buffer is actually displayed/focused, not merely the session the
-- `active_session_id` pointer happens to name. In production there is NO
-- WinEnter/BufEnter autocmd that reconciles `active_session_id` to the focused
-- terminal buffer (see session_activation_spec.lua's header comment). So when
-- the user focuses a terminal buffer directly (`:wincmd`, click, window
-- migration, handle_term_exit's successor swap) the pointer drifts from what's
-- visible, and `send_to_active_session` (server/init.lua:426) routes by the
-- pointer alone — delivering the mention to the wrong Claude.
--
-- This test drives the REAL server/init.lua send_to_active_session against the
-- real session module. The terminal module is stubbed so get_visible_session_id
-- reports whichever buffer is "displayed". On current code routing uses only the
-- active pointer (A), so when B is the visible one the send lands on A and the
-- test FAILS. Once routing reconciles to the visible session, the send lands on
-- B and the test passes.
describe("send_at_mention routes to the visible (focused) session, not the stale pointer (#drift)", function()
  local server
  local session
  local sent_to_client_id
  local displayed_bufnr

  before_each(function()
    package.path = "./lua/?.lua;" .. package.path
    package.loaded["claudecode.server.init"] = nil
    package.loaded["claudecode.server.tcp"] = nil
    package.loaded["claudecode.server.client"] = nil
    package.loaded["claudecode.session"] = nil
    package.loaded["claudecode.terminal"] = nil
    package.loaded["claudecode.logger"] = package.loaded["claudecode.logger"]
      or {
        debug = function() end,
        warn = function() end,
        error = function() end,
        info = function() end,
      }

    sent_to_client_id = {}
    displayed_bufnr = nil

    session = require("claudecode.session")
    session.reset()

    -- Stub the terminal module: get_visible_session_id resolves the session
    -- whose terminal_bufnr is currently "displayed" (mirrors production's
    -- nvim_list_wins scan over buffer_session_map).
    package.loaded["claudecode.terminal"] = {
      get_visible_session_id = function()
        for _, s in pairs(session.sessions) do
          if s.terminal_bufnr == displayed_bufnr then
            return s.id
          end
        end
        return nil
      end,
    }

    -- Minimal vim stubs server/init.lua needs to load.
    _G.vim.json = _G.vim.json
      or {
        encode = function(d)
          return d
        end,
        decode = function()
          return {}
        end,
      }
    _G.vim.empty_dict = _G.vim.empty_dict or function()
      return {}
    end

    -- Stub the tcp layer: send_to_active_session calls
    -- tcp_server.send_to_client(M.state.server, client_id, json_message).
    -- Intercept to record which client_id each message targeted.
    package.loaded["claudecode.server.tcp"] = {
      send_to_client = function(_srv, client_id, _msg)
        table.insert(sent_to_client_id, client_id)
      end,
    }
    -- server/init.lua requires the client manager at load; stub it minimal.
    package.loaded["claudecode.server.client"] = {}

    server = require("claudecode.server.init")
    -- Plant a fake running server so send_to_active_session's `if not
    -- M.state.server then return false end` guard passes. We bypass start() to
    -- avoid binding a real TCP listener.
    server.state.server = { clients = {} }
  end)

  after_each(function()
    if session then
      session.reset()
    end
    package.loaded["claudecode.server.init"] = nil
    package.loaded["claudecode.server.tcp"] = nil
    package.loaded["claudecode.server.client"] = nil
    package.loaded["claudecode.session"] = nil
    package.loaded["claudecode.terminal"] = nil
  end)

  it("routes to the focused session even when the active pointer is stale", function()
    -- Two sessions, both with bound clients, each with a terminal buffer.
    local sid_a = session.create_session({ name = "A" })
    session.bind_client(sid_a, "client-A")
    session.update_terminal_info(sid_a, { bufnr = 200 })

    local sid_b = session.create_session({ name = "B" })
    session.bind_client(sid_b, "client-B")
    session.update_terminal_info(sid_b, { bufnr = 300 })

    -- Pointer names A (last session command targeted A).
    session.set_active_session(sid_a)

    -- But the user focused B's terminal directly (wincmd / click / migration):
    -- B's buffer is the one displayed. The pointer was NOT updated.
    displayed_bufnr = 300

    -- Sanity: the pointer and the visible session genuinely disagree.
    assert.is_equal(sid_a, session.get_active_session_id())
    assert.is_equal(sid_b, require("claudecode.terminal").get_visible_session_id())

    server.send_to_active_session("at_mentioned", { filePath = "/abs/src/foo.lua" })

    -- The mention must reach B (the focused session), NOT A (the stale pointer).
    -- On current code send_to_active_session routes by active_session_id only,
    -- so it delivers to client-A and this assertion FAILS.
    assert.is_equal(1, #sent_to_client_id)
    assert.is_equal("client-B", sent_to_client_id[1])
  end)

  it("falls back to the active pointer when no terminal buffer is visible", function()
    local sid_a = session.create_session({ name = "A" })
    session.bind_client(sid_a, "client-A")
    session.update_terminal_info(sid_a, { bufnr = 200 })

    local sid_b = session.create_session({ name = "B" })
    session.bind_client(sid_b, "client-B")
    session.update_terminal_info(sid_b, { bufnr = 300 })

    session.set_active_session(sid_a)

    -- Terminal window hidden/closed: nothing visible.
    displayed_bufnr = nil

    server.send_to_active_session("at_mentioned", { filePath = "/abs/src/foo.lua" })

    -- No visible session -> fall back to the active pointer -> client-A.
    assert.is_equal(1, #sent_to_client_id)
    assert.is_equal("client-A", sent_to_client_id[1])
  end)
end)
