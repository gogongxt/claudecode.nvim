require("tests.busted_setup")

-- Regression tests for the close→reopen→notify_resize SIGWINCH-skip bug.
-- window_manager caches last_width/last_height to dedupe jobresize calls;
-- close_window must reset that cache so a reopen (which recreates the window
-- at potentially the same dimensions) still delivers SIGWINCH to the TUI via
-- the follow-up notify_resize fired by TermEnter/WinEnter autocmds.

describe("claudecode.terminal.window_manager resize cache across close/reopen", function()
  local wm
  local jobresize_calls
  local term_buf
  local term_chan = 4242

  before_each(function()
    package.path = "./lua/?.lua;" .. package.path
    package.loaded["claudecode.terminal.window_manager"] = nil
    package.loaded["claudecode.logger"] = package.loaded["claudecode.logger"]
      or {
        debug = function() end,
        warn = function() end,
        error = function() end,
        info = function() end,
      }

    -- The busted vim mock lacks jobresize / win height / bo.channel / vim.w.
    -- Add them so window_manager's create_split_window + display_buffer run.
    jobresize_calls = {}
    vim.fn = vim.fn or {}
    vim.fn.jobresize = function(chan, w, h)
      table.insert(jobresize_calls, { chan = chan, width = w, height = h })
    end

    vim.api.nvim_win_get_height = function(_winid)
      return 40
    end
    vim.api.nvim_win_set_height = function() end

    -- vim.w[winid].claudecode_terminal = true — create_split_window tags the
    -- window so find_terminal_window only reclaims its own.
    local win_vars = {}
    vim.w = setmetatable({}, {
      __index = function(_, k)
        win_vars[k] = win_vars[k] or {}
        return win_vars[k]
      end,
    })

    -- vim.wo[winid].wrap = false etc. — create_split_window + refresh_window
    -- set window opts. Record assignments so refresh_window tests can assert.
    local wo_store = {}
    vim.wo = setmetatable({}, {
      __index = function(_, k)
        wo_store[k] = wo_store[k] or {}
        return wo_store[k]
      end,
    })
    vim._wo_store = wo_store

    -- vim.bo[bufnr].channel — window_manager reads it to find the PTY channel.
    -- Assigned below after term_buf is created.
    vim.bo = setmetatable({}, {
      __index = function(_, bufnr)
        return {
          channel = bufnr == term_buf and term_chan or 0,
          buftype = "",
        }
      end,
    })

    -- Create a terminal buffer the mock recognises as having a channel.
    term_buf = vim.api.nvim_create_buf(false, true)

    wm = require("claudecode.terminal.window_manager")
    wm.setup({ split_side = "right", split_width_percentage = 0.4 })
  end)

  after_each(function()
    package.loaded["claudecode.terminal.window_manager"] = nil
    wm.reset()
  end)

  it("notify_resize fires SIGWINCH after close/reopen even when dimensions match", function()
    -- Step 1: first open — display_buffer issues jobresize.
    wm.display_buffer(term_buf, false)
    assert.are.equal(1, #jobresize_calls, "display_buffer should fire jobresize")

    -- Step 2: TermEnter-style notify_resize — fires again AND caches dims.
    wm.notify_resize()
    assert.are.equal(2, #jobresize_calls, "notify_resize after open should fire jobresize")

    -- Step 3: hide — close_window must reset the cached dims.
    wm.close_window()

    -- Step 4: reopen — display_buffer issues jobresize (new window, same dims).
    wm.display_buffer(term_buf, false)
    assert.are.equal(3, #jobresize_calls, "display_buffer on reopen should fire jobresize")

    -- Step 5: notify_resize after reopen. BEFORE the fix this was SKIPPED
    -- because last_width/last_height were retained from step 2, so the TUI
    -- never got the post-reopen SIGWINCH it needed to recover from the
    -- closed-window state.
    wm.notify_resize()
    assert.are.equal(4, #jobresize_calls, "notify_resize after reopen must NOT skip — TUI needs SIGWINCH to recover")
  end)

  it("notify_resize still skips when dimensions genuinely unchanged (no close)", function()
    -- Without a close/reopen cycle, repeated notify_resize with the same dims
    -- should still dedupe — that's the optimisation the cache exists for.
    wm.display_buffer(term_buf, false)
    assert.are.equal(1, #jobresize_calls)

    wm.notify_resize()
    assert.are.equal(2, #jobresize_calls, "first notify_resize caches dims")

    wm.notify_resize()
    assert.are.equal(2, #jobresize_calls, "second notify_resize with same dims should skip")
  end)

  it("toggle close/reopen preserves the user's dragged width", function()
    -- User drags the split to a custom width, then toggles hide→show. The
    -- reopened window must keep the dragged width, not snap back to the
    -- configured split_width_percentage. We verify by tracking the width
    -- passed to nvim_win_set_width across a close/reopen cycle.
    wm.display_buffer(term_buf, false)
    local winid = wm.get_window()

    -- Track every nvim_win_set_width call so we can assert what width the
    -- reopened window was set to.
    local set_width_calls = {}
    local original_set_width = vim.api.nvim_win_set_width
    vim.api.nvim_win_set_width = function(w, width)
      set_width_calls[#set_width_calls + 1] = { win = w, width = width }
      original_set_width(w, width)
    end

    -- Simulate the user dragging the terminal narrower to 30 columns.
    local original_width = vim.api.nvim_win_get_width
    vim.api.nvim_win_get_width = function(w)
      if w == winid then
        return 30
      end
      return original_width(w)
    end
    -- Fire the WinResized autocmd so window_manager records user_width=30.
    for _, ev in ipairs(vim._autocmds["ClaudeCodeTerminalResize"].events) do
      local names = type(ev.events) == "table" and ev.events or { ev.events }
      for _, n in ipairs(names) do
        if n == "WinResized" then
          ev.opts.callback()
          break
        end
      end
    end
    vim.api.nvim_win_get_width = original_width

    -- Toggle hide then show.
    wm.close_window()
    set_width_calls = {}
    wm.display_buffer(term_buf, false)

    -- create_split_window calls nvim_win_set_width on reopen. It should use
    -- the user's dragged width (30), not the configured 48 (0.4 * 120).
    local reopen_width = set_width_calls[#set_width_calls]
    assert.is_table(reopen_width, "reopen should call nvim_win_set_width")
    assert.are.equal(30, reopen_width.width, "reopen should preserve user's dragged width (30), not configured 48")

    vim.api.nvim_win_set_width = original_set_width
  end)

  it("WinResized autocmd debounces SIGWINCH during a drag (one sync after pause)", function()
    -- Dragging fires WinResized per pixel; a SIGWINCH per pixel makes the TUI
    -- redraw mid-resize against a half-applied layout, leaving rows duplicated.
    -- Debounce: only sync once after the drag pauses.
    wm.display_buffer(term_buf, false)
    wm.notify_resize() -- cache current dims (80x40)
    local cached = #jobresize_calls

    local winid = wm.get_window()
    local original_width = vim.api.nvim_win_get_width
    vim.api.nvim_win_get_width = function(w)
      if w == winid then
        return 60
      end
      return original_width(w)
    end

    -- Replace defer_fn with a manual timer so the test controls when the
    -- debounced callback runs. Each call returns a fake timer whose :close()
    -- / :is_closing() mimic vim.loop timers.
    local pending = nil
    local original_defer_fn = vim.defer_fn
    vim.defer_fn = function(fn, _ms)
      local t = { _closed = false, _fn = fn }
      t.is_closing = function(self)
        return self._closed
      end
      t.close = function(self)
        self._closed = true
      end
      pending = t
      return t
    end

    local function find_winresized_cb()
      for _, ev in ipairs(vim._autocmds["ClaudeCodeTerminalResize"].events) do
        local names = type(ev.events) == "table" and ev.events or { ev.events }
        for _, n in ipairs(names) do
          if n == "WinResized" then
            return ev.opts.callback
          end
        end
      end
    end
    local cb = find_winresized_cb()
    assert.is_function(cb, "WinResized autocmd should be registered")

    -- Simulate 3 pixels of a drag: each fires WinResized, each cancels the
    -- previous deferred sync. No jobresize yet (deferred, not fired).
    cb()
    local first_timer = pending
    cb() -- cancels first_timer
    cb() -- cancels second timer
    assert.is_true(first_timer._closed, "second WinResized should cancel the first deferred sync")
    assert.are.equal(cached, #jobresize_calls, "no SIGWINCH during an active drag")

    -- Drag pauses → defer fires the sync.
    pending._fn()
    assert.are.equal(cached + 1, #jobresize_calls, "one SIGWINCH after the drag pauses")

    vim.defer_fn = original_defer_fn
    vim.api.nvim_win_get_width = original_width
  end)
end)

describe("claudecode.terminal.window_manager refresh_window", function()
  local wm
  local jobresize_calls
  local term_buf
  local term_chan = 4242
  local wo_store

  before_each(function()
    package.path = "./lua/?.lua;" .. package.path
    package.loaded["claudecode.terminal.window_manager"] = nil
    package.loaded["claudecode.logger"] = package.loaded["claudecode.logger"]
      or {
        debug = function() end,
        warn = function() end,
        error = function() end,
        info = function() end,
      }

    jobresize_calls = {}
    vim.fn = vim.fn or {}
    vim.fn.jobresize = function(chan, w, h)
      table.insert(jobresize_calls, { chan = chan, width = w, height = h })
    end
    vim.api.nvim_win_get_height = function()
      return 40
    end
    vim.api.nvim_win_set_height = function() end

    local win_vars = {}
    vim.w = setmetatable({}, {
      __index = function(_, k)
        win_vars[k] = win_vars[k] or {}
        return win_vars[k]
      end,
    })

    wo_store = {}
    vim.wo = setmetatable({}, {
      __index = function(_, k)
        wo_store[k] = wo_store[k] or {}
        return wo_store[k]
      end,
    })

    vim.bo = setmetatable({}, {
      __index = function(_, bufnr)
        return {
          channel = bufnr == term_buf and term_chan or 0,
          buftype = "",
        }
      end,
    })

    term_buf = vim.api.nvim_create_buf(false, true)

    wm = require("claudecode.terminal.window_manager")
    wm.setup({ split_side = "right", split_width_percentage = 0.4 })
  end)

  after_each(function()
    package.loaded["claudecode.terminal.window_manager"] = nil
    wm.reset()
  end)

  it("re-applies window options (wrap/scrolloff/etc.) for TUI cursor positioning", function()
    wm.display_buffer(term_buf, false)
    local winid = wm.get_window()
    -- Clobber one option to simulate a reused window with stale opts.
    wo_store[winid].wrap = true
    wo_store[winid].scrolloff = 5

    wm.refresh_window()

    assert.is_false(wo_store[winid].wrap, "refresh_window should reset wrap=false")
    assert.are.equal(0, wo_store[winid].scrolloff, "refresh_window should reset scrolloff=0")
    assert.are.equal(0, wo_store[winid].sidescrolloff)
    assert.is_false(wo_store[winid].number)
    assert.is_false(wo_store[winid].relativenumber)
    assert.are.equal("no", wo_store[winid].signcolumn)
  end)

  it("forces a SIGWINCH even when dimensions are unchanged (self-heal)", function()
    wm.display_buffer(term_buf, false)
    -- notify_resize once to cache the dims (so a non-forced call would skip).
    wm.notify_resize()
    local cached = #jobresize_calls

    wm.refresh_window()
    assert.are.equal(
      cached + 1,
      #jobresize_calls,
      "refresh_window should force a SIGWINCH even when dims match the cache"
    )
  end)

  it("is a no-op when no window is visible", function()
    -- No display_buffer yet — state.winid is nil.
    wm.refresh_window()
    assert.are.equal(0, #jobresize_calls, "refresh_window with no window should not fire jobresize")
  end)
end)

describe("claudecode.terminal.window_manager toggleterm buffers skip jobresize", function()
  -- toggleterm split terminals carry b:toggle_number; Neovim auto-syncs their
  -- PTY size on window resize (PR neovim/neovim #33915, 0.11+). window_manager
  -- must NOT issue a redundant jobresize — it races with the auto-sync and
  -- garbles the TUI render. native/snacks buffers have no toggle_number and
  -- still need the explicit jobresize.
  local wm
  local jobresize_calls
  local term_buf
  local term_chan = 4242
  local buf_vars
  local wo_store

  before_each(function()
    package.path = "./lua/?.lua;" .. package.path
    package.loaded["claudecode.terminal.window_manager"] = nil
    package.loaded["claudecode.logger"] = package.loaded["claudecode.logger"]
      or {
        debug = function() end,
        warn = function() end,
        error = function() end,
        info = function() end,
      }

    jobresize_calls = {}
    vim.fn = vim.fn or {}
    vim.fn.jobresize = function(chan, w, h)
      table.insert(jobresize_calls, { chan = chan, width = w, height = h })
    end
    vim.api.nvim_win_get_height = function()
      return 40
    end
    vim.api.nvim_win_set_height = function() end

    local win_vars = {}
    vim.w = setmetatable({}, {
      __index = function(_, k)
        win_vars[k] = win_vars[k] or {}
        return win_vars[k]
      end,
    })

    wo_store = {}
    vim.wo = setmetatable({}, {
      __index = function(_, k)
        wo_store[k] = wo_store[k] or {}
        return wo_store[k]
      end,
    })

    -- Buffer-local var storage so is_auto_synced_buffer can read toggle_number.
    buf_vars = {}
    vim.api.nvim_buf_set_var = function(bufnr, name, value)
      buf_vars[bufnr] = buf_vars[bufnr] or {}
      buf_vars[bufnr][name] = value
    end
    vim.api.nvim_buf_get_var = function(bufnr, name)
      if not buf_vars[bufnr] or buf_vars[bufnr][name] == nil then
        error("not found")
      end
      return buf_vars[bufnr][name]
    end

    vim.bo = setmetatable({}, {
      __index = function(_, bufnr)
        return {
          channel = bufnr == term_buf and term_chan or 0,
          buftype = "",
        }
      end,
    })

    term_buf = vim.api.nvim_create_buf(false, true)
    -- Mark as a toggleterm buffer (mirrors toggleterm.lua:270).
    vim.api.nvim_buf_set_var(term_buf, "toggle_number", 1)

    wm = require("claudecode.terminal.window_manager")
    wm.setup({ split_side = "right", split_width_percentage = 0.4 })
  end)

  after_each(function()
    package.loaded["claudecode.terminal.window_manager"] = nil
    wm.reset()
  end)

  it("display_buffer does not fire jobresize for a toggleterm buffer", function()
    wm.display_buffer(term_buf, false)
    assert.are.equal(0, #jobresize_calls, "display_buffer must skip jobresize for toggleterm buffers")
  end)

  it("notify_resize is a no-op for a toggleterm buffer (even with force)", function()
    wm.display_buffer(term_buf, false)
    wm.notify_resize()
    assert.are.equal(0, #jobresize_calls, "notify_resize must skip toggleterm buffers")

    wm.notify_resize(true)
    assert.are.equal(0, #jobresize_calls, "force notify_resize must also skip toggleterm buffers")
  end)

  it("refresh_window still re-applies window opts but skips SIGWINCH", function()
    wm.display_buffer(term_buf, false)
    local winid = wm.get_window()
    wo_store[winid].wrap = true

    wm.refresh_window()

    assert.are.equal(0, #jobresize_calls, "refresh_window must not fire jobresize for toggleterm buffers")
    assert.is_false(wo_store[winid].wrap, "refresh_window should still reset wrap=false")
  end)
end)
