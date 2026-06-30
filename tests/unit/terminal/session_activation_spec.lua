require("tests.busted_setup")

-- Regression tests for active-session correctness across the programmatic
-- session flows (open / open_new_session / switch_to_session /
-- toggle_session_by_index / close_session). Each flow calls
-- set_active_session explicitly; these tests pin that the active session id
-- ends up on the expected session after the flow completes, with a fake
-- provider that simulates the buffer-swap churn (nvim_win_set_buf, focus
-- shifts) that toggleterm's real implementation drives.
--
-- There is NO BufEnter autocmd in production that syncs active to the focused
-- terminal buffer — register_buffer_session only updates an internal map. So
-- these tests do not model one. If user-focus-driven activation is added
-- later, re-add a BufEnter autocmd in terminal.lua and a corresponding test.

describe("terminal session activation regression", function()
  local session
  local terminal
  local provider_stub
  local displayed_bufnr -- bufnr currently in the fake terminal window

  before_each(function()
    package.path = "./lua/?.lua;" .. package.path
    package.loaded["claudecode.session"] = nil
    package.loaded["claudecode.terminal"] = nil
    package.loaded["claudecode.logger"] = {
      debug = function() end,
      warn = function() end,
      error = function() end,
      info = function() end,
    }
    package.loaded["claudecode.utils"] = {
      normalize_focus = function(f)
        return f == nil and true or f
      end,
    }

    -- Real session module so set_active_session / active_session_id behave.
    session = require("claudecode.session")
    session.reset()

    local next_bufnr = 100
    local next_winid = 500

    -- Fake terminal window state: one singleton window (mirrors window_manager).
    local term_winid = next_winid
    next_winid = next_winid + 1
    displayed_bufnr = nil

    _G.vim = _G.vim or {}
    _G.vim.api = _G.vim.api or {}
    _G.vim.api.nvim_create_autocmd = function()
      return 1
    end
    _G.vim.api.nvim_create_augroup = function()
      return 1
    end
    _G.vim.api.nvim_del_augroup_by_id = function() end
    _G.vim.api.nvim_buf_is_valid = function(b)
      return b ~= nil and b < 9000
    end
    _G.vim.api.nvim_win_is_valid = function()
      return true
    end
    _G.vim.api.nvim_win_get_buf = function()
      return displayed_bufnr
    end
    _G.vim.api.nvim_win_set_buf = function(_, bufnr)
      displayed_bufnr = bufnr
    end
    _G.vim.api.nvim_get_current_buf = function()
      return displayed_bufnr
    end
    _G.vim.api.nvim_get_current_win = function()
      return term_winid
    end
    _G.vim.api.nvim_set_current_win = function() end
    _G.vim.api.nvim_win_get_tabpage = function()
      return 1
    end
    _G.vim.api.nvim_tabpage_is_valid = function()
      return true
    end
    _G.vim.api.nvim_get_current_tabpage = function()
      return 1
    end
    _G.vim.api.nvim_win_get_config = function()
      return {} -- split window (no relative) -> winbar fallback path
    end
    _G.vim.api.nvim_win_get_position = function()
      return { 0, 0 }
    end
    _G.vim.api.nvim_create_buf = function()
      local b = next_bufnr
      next_bufnr = next_bufnr + 1
      return b
    end
    _G.vim.api.nvim_buf_set_lines = function() end
    _G.vim.api.nvim_buf_clear_namespace = function() end
    _G.vim.api.nvim_buf_add_highlight = function() end
    _G.vim.api.nvim_create_namespace = function()
      return 1
    end
    _G.vim.api.nvim_open_win = function()
      local w = next_winid
      next_winid = next_winid + 1
      return w
    end
    _G.vim.api.nvim_win_set_config = function() end
    _G.vim.api.nvim_win_set_option = function() end
    _G.vim.api.nvim_win_set_width = function() end
    _G.vim.api.nvim_win_get_width = function()
      return 80
    end
    _G.vim.api.nvim_win_get_height = function()
      return 24
    end
    _G.vim.api.nvim_exec_autocmds = function() end

    _G.vim.wo = setmetatable({}, {
      __index = function()
        return setmetatable({}, {
          __index = function()
            return nil
          end,
          __newindex = function() end,
        })
      end,
    })
    _G.vim.bo = setmetatable({}, {
      __index = function()
        return setmetatable({}, {
          __index = function()
            return nil
          end,
          __newindex = function() end,
        })
      end,
    })
    _G.vim.fn = {
      getcwd = function()
        return "/tmp"
      end,
      expand = function(s)
        return s or ""
      end,
      fnamemodify = function()
        return "/tmp"
      end,
    }
    _G.vim.cmd = function() end
    _G.vim.log = { levels = { ERROR = 1, WARN = 2, INFO = 3, DEBUG = 4 } }
    -- Run scheduled functions synchronously so tests see the final state
    -- immediately. toggle_session_by_index schedules a vim.notify; nothing in
    -- these flows relies on deferred active-session changes.
    _G.vim.schedule = function(f)
      f()
    end
    _G.vim.defer_fn = function(f, _ms)
      f()
    end
    _G.vim.notify = function() end
    _G.vim.o = { columns = 200 }

    -- Fake session-aware provider: open_session creates a buffer and swaps it
    -- into the singleton window, mirroring toggleterm's display_buffer call.
    provider_stub = {
      _bufnrs = {}, -- session_id -> bufnr
      setup = function() end,
      open = function() end,
      close = function() end,
      simple_toggle = function() end,
      focus_toggle = function() end,
      toggle = function() end,
      is_available = function()
        return true
      end,
      get_active_bufnr = function()
        return nil
      end,
      open_session = function(session_id, _cmd, _env, _config, _focus)
        local b = next_bufnr
        next_bufnr = next_bufnr + 1
        provider_stub._bufnrs[session_id] = b
        _G.vim.api.nvim_win_set_buf(term_winid, b)
        return b
      end,
      close_session = function(session_id)
        provider_stub._bufnrs[session_id] = nil
        provider_stub._calls = provider_stub._calls or {}
        table.insert(provider_stub._calls, { "close_session", session_id })
      end,
      close_session_keep_window = function(old_id, new_id, _config)
        provider_stub._calls = provider_stub._calls or {}
        table.insert(provider_stub._calls, { "close_session_keep_window", old_id, new_id })
        local b = provider_stub._bufnrs[new_id]
        if b then
          _G.vim.api.nvim_win_set_buf(term_winid, b)
        end
      end,
      focus_session = function(session_id, _config)
        local b = provider_stub._bufnrs[session_id]
        if b then
          _G.vim.api.nvim_win_set_buf(term_winid, b)
        end
      end,
      toggle_session = function(session_id, config, _cmd, _env)
        provider_stub.focus_session(session_id, config)
      end,
      get_session_bufnr = function(session_id)
        return provider_stub._bufnrs[session_id]
      end,
      register_terminal_for_session = function() end,
    }

    -- Inject the provider stub before loading terminal.lua.
    package.loaded["claudecode.terminal.toggleterm"] = provider_stub
    package.loaded["claudecode.terminal.snacks"] = nil
    package.loaded["claudecode.terminal.native"] = nil

    -- Stub window_manager: single window, display_buffer swaps buf.
    package.loaded["claudecode.terminal.window_manager"] = {
      setup = function() end,
      get_window = function()
        return term_winid
      end,
      ensure_window = function()
        return term_winid
      end,
      display_buffer = function(bufnr, _focus)
        displayed_bufnr = bufnr
        return true
      end,
      close_window = function()
        displayed_bufnr = nil
      end,
      is_visible = function()
        return displayed_bufnr ~= nil
      end,
      get_current_buffer = function()
        return displayed_bufnr
      end,
      focus_window = function() end,
      refresh_window = function() end,
      reset = function() end,
    }

    -- Stub tabbar (we're testing active_session_id, not rendering).
    package.loaded["claudecode.terminal.tabbar"] = {
      setup = function() end,
      attach = function() end,
      detach = function() end,
      hide = function() end,
      render = function() end,
      render_winbar = function() end,
      is_visible = function()
        return false
      end,
      get_winid = function()
        return nil
      end,
      cleanup = function() end,
      cleanup_all = function() end,
      _reset = function() end,
      _snapshot = function()
        return {}
      end,
      _build_content = function()
        return "", {}
      end,
      _build_winbar = function()
        return nil
      end,
    }

    -- Stub server module (terminal.lua requires it at load time).
    package.loaded["claudecode.server.init"] = {
      state = { port = 12345 },
    }

    -- Stub paste_fix.
    package.loaded["claudecode.terminal.paste_fix"] = {
      apply = function() end,
    }

    terminal = require("claudecode.terminal")
    terminal.setup({
      provider = "toggleterm",
      auto_close = false,
      tabs = { enabled = false },
    })
  end)

  after_each(function()
    session.reset()
    for _, k in ipairs({
      "claudecode.session",
      "claudecode.terminal",
      "claudecode.terminal.toggleterm",
      "claudecode.terminal.window_manager",
      "claudecode.terminal.tabbar",
      "claudecode.terminal.paste_fix",
      "claudecode.server.init",
      "claudecode.logger",
      "claudecode.utils",
    }) do
      package.loaded[k] = nil
    end
  end)

  it("open_new_session leaves the new session active", function()
    terminal.open({}, nil)
    local s1 = session.get_active_session_id()
    expect(s1).to_be_string()

    terminal.open_new_session({}, nil)

    local sessions = session.list_sessions()
    expect(#sessions).to_be(2)
    local s2 = sessions[2].id
    assert(s2 ~= s1, "session 2 should differ from session 1")
    expect(session.get_active_session_id()).to_be(s2)
  end)

  it("switch_to_session leaves the target session active", function()
    terminal.open({}, nil)
    terminal.open_new_session({}, nil)
    local sessions = session.list_sessions()
    local s1 = sessions[1].id
    local s2 = sessions[2].id
    expect(session.get_active_session_id()).to_be(s2)

    terminal.switch_to_session(s1, {})
    expect(session.get_active_session_id()).to_be(s1)
  end)

  it("toggle_session_by_index activates the new slot session", function()
    terminal.open({}, nil)

    -- <leader>2: create session 2 pinned to slot 2 and toggle it open.
    terminal.toggle_session_by_index(2, {})

    local sessions = session.list_sessions()
    expect(#sessions).to_be(2)
    -- Slot 2 should be active.
    local active = session.get_active_session_id()
    expect(active).to_be(sessions[2].id)
  end)

  it("close_session activates the successor", function()
    terminal.open({}, nil)
    terminal.open_new_session({}, nil)
    local sessions = session.list_sessions()
    local s1 = sessions[1].id
    local s2 = sessions[2].id

    -- Close session 2 (the active one). Successor should be session 1.
    terminal.close_session(s2)
    expect(session.get_active_session_id()).to_be(s1)
  end)

  it("close_session on a non-active session keeps the active session", function()
    terminal.open({}, nil)
    terminal.open_new_session({}, nil)
    local sessions = session.list_sessions()
    local s1 = sessions[1].id
    local s2 = sessions[2].id

    -- Switch back to session 1, so s2 is non-active. Closing s2 must not
    -- promote a successor or steal the window from the active session 1.
    terminal.switch_to_session(s1, {})
    expect(session.get_active_session_id()).to_be(s1)

    provider_stub._calls = {}
    terminal.close_session(s2)

    -- Active session unchanged.
    expect(session.get_active_session_id()).to_be(s1)
    -- The window-reuse path is only for the displayed (active) session; closing
    -- a background session must go through close_session, not keep_window.
    local called_keep_window = false
    for _, c in ipairs(provider_stub._calls or {}) do
      if c[1] == "close_session_keep_window" then
        called_keep_window = true
      end
    end
    expect(called_keep_window).to_be(false)
  end)
end)
