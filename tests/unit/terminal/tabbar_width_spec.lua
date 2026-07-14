require("tests.busted_setup")

-- Regression tests for the tab bar sliding-window layout (compute_layout).
--
-- Bug being guarded against: with multiple sessions in a narrow terminal, the
-- winbar path right-aligns overflow, truncating from the LEFT and hiding early
-- sessions. The fix renders a contiguous *slice* of the slot-ordered list (a
-- sliding window), with ‹/› markers on folded sides, never shrinking names.
-- The active session is always kept inside the window (it scrolls in only when
-- it leaves the visible range); explicit ‹/› clicks move the window and may
-- scroll the active tab off-screen until the next session switch.

describe("tabbar sliding-window layout", function()
  local session
  local tabbar
  local term_winid = 1000
  -- Last winbar string set on the terminal window (render_winbar target).
  local last_winbar

  local function set_win_width(w)
    _G.vim._windows[term_winid] = _G.vim._windows[term_winid] or {}
    _G.vim._windows[term_winid].width = w
  end

  -- Strip winbar %...# / %N@...@ / %X markup to get the visible text.
  local function visible(s)
    if not s then
      return ""
    end
    s = s:gsub("%%#[%w_]+#", "")
    s = s:gsub("%%%-?%d+@v:lua%.[%w_]+@", "")
    s = s:gsub("%%X", "")
    return s
  end

  -- Display-cell count (ASCII + the multi-byte glyphs we use, each 1 cell).
  local function cells(s)
    s = visible(s)
    local bytes = #s
    local _, n_x = s:gsub("✕", "")
    local _, n_l = s:gsub("‹", "")
    local _, n_r = s:gsub("›", "")
    local _, n_e = s:gsub("…", "")
    return bytes - 2 * (n_x + n_l + n_r + n_e)
  end

  before_each(function()
    package.path = "./lua/?.lua;" .. package.path
    package.loaded["claudecode.session"] = nil
    package.loaded["claudecode.terminal.tabbar"] = nil
    package.loaded["claudecode.logger"] = {
      debug = function() end,
      warn = function() end,
      error = function() end,
      info = function() end,
    }

    session = require("claudecode.session")
    session.reset()

    -- calc_window_config calls nvim_win_get_position before the split/float
    -- branch; the busted vim mock doesn't implement it.
    if not _G.vim.api.nvim_win_get_position then
      _G.vim.api.nvim_win_get_position = function()
        return { 0, 0 }
      end
    end
    -- Capture the winbar string render_winbar sets, so tests can assert on the
    -- exact production output rather than re-invoking the builder (a fresh
    -- build re-runs compute_layout and would re-clamp, masking scroll state).
    last_winbar = nil
    _G.vim.wo = setmetatable({}, {
      __index = function(_, k)
        return setmetatable({}, {
          __index = function()
            return nil
          end,
          __newindex = function(_, kk, vv)
            if kk == "winbar" then
              last_winbar = vv
            end
          end,
        })
      end,
    })

    tabbar = require("claudecode.terminal.tabbar")
    tabbar._reset()
    tabbar.setup({
      enabled = true,
      show_close_button = true,
      show_new_button = true,
      keymaps = { next_tab = false, prev_tab = false, new_tab = false, close_tab = false },
    })

    set_win_width(80)
    tabbar.attach(term_winid, 9000)
  end)

  after_each(function()
    session.reset()
    tabbar._reset()
    package.loaded["claudecode.session"] = nil
    package.loaded["claudecode.terminal.tabbar"] = nil
    package.loaded["claudecode.logger"] = nil
  end)

  local function make_sessions(n, active_slot)
    for i = 1, n do
      session.create_session({ name = "Sess" .. i, slot = i })
    end
    local s = session.get_session_by_slot(active_slot or 1)
    session.set_active_session(s.id)
  end

  describe("active visibility", function()
    it("keeps the active session visible when content overflows", function()
      set_win_width(36)
      make_sessions(5, 3) -- active is the middle session
      local v = visible(tabbar._build_winbar(1))
      assert.truthy(v:find("3:", 1, true), "active slot 3 should be visible: " .. v)
    end)

    it("scrolls the window right when active is past the right edge", function()
      set_win_width(36)
      make_sessions(5, 5) -- active is the last session
      local v = visible(tabbar._build_winbar(1))
      assert.truthy(v:find("5:", 1, true), "active slot 5 should be visible: " .. v)
      assert.truthy(v:find("‹", 1, true), "left side should be folded: " .. v)
    end)

    it("scrolls the window left when active is before the left edge", function()
      set_win_width(36)
      make_sessions(5, 5)
      tabbar._build_winbar(1) -- window now ends around slot 5
      local before = tabbar._snapshot()[1].viewport_start
      assert.is_true(before > 1, "window should have scrolled right for active=5: " .. tostring(before))
      -- Switch active back to slot 1: window must snap left so slot 1 is first.
      session.set_active_session(session.get_session_by_slot(1).id)
      tabbar._build_winbar(1)
      expect(tabbar._snapshot()[1].viewport_start).to_be(1)
      local v = visible(tabbar._build_winbar(1))
      assert.truthy(v:find("1:", 1, true), "active slot 1 should be visible after snap: " .. v)
      assert.truthy(v:find("›", 1, true), "right side should be folded: " .. v)
    end)

    it("does not move the window when active is already visible", function()
      set_win_width(60) -- fits ~3-4 tabs
      make_sessions(5, 1)
      tabbar._build_winbar(1)
      local before = tabbar._snapshot()[1].viewport_start
      -- Switch to another visible session; viewport_start must not change.
      session.set_active_session(session.get_session_by_slot(2).id)
      tabbar.render(1)
      local after = tabbar._snapshot()[1].viewport_start
      expect(after).to_be(before)
    end)
  end)

  describe("width fitting", function()
    it("never exceeds the window width", function()
      for _, w in ipairs({ 20, 28, 30, 36, 40, 50 }) do
        set_win_width(w)
        session.reset()
        make_sessions(8, 4)
        local c = cells(tabbar._build_winbar(1))
        assert.is_true(c <= w, string.format("width %d: rendered %d cells overflowed", w, c))
      end
    end)

    it("renders every session and no fold markers when the window is wide", function()
      set_win_width(200)
      make_sessions(3, 2)
      local v = visible(tabbar._build_winbar(1))
      assert.truthy(v:find("1:", 1, true))
      assert.truthy(v:find("2:", 1, true))
      assert.truthy(v:find("3:", 1, true))
      assert.falsy(v:find("‹", 1, true))
      assert.falsy(v:find("›", 1, true))
      assert.truthy(v:find("+", 1, true))
    end)

    it("does not shrink session names with … to fit", function()
      set_win_width(36)
      make_sessions(5, 1)
      local v = visible(tabbar._build_winbar(1))
      assert.falsy(v:find("…", 1, true), "names must not be truncated to fit: " .. v)
      assert.truthy(v:find("Sess1", 1, true), "full name should be intact: " .. v)
    end)

    it("renders long names in full, never truncating with …", function()
      set_win_width(200)
      session.reset()
      session.create_session({ name = "Refactor-auth-module", slot = 1 })
      session.create_session({ name = "A very long session name that exceeds twelve", slot = 2 })
      session.set_active_session(session.get_session_by_slot(1).id)
      local v = visible(tabbar._build_winbar(1))
      assert.truthy(v:find("Refactor-auth-module", 1, true), "long name 1 should be whole: " .. v)
      assert.truthy(
        v:find("A very long session name that exceeds twelve", 1, true),
        "long name 2 should be whole: " .. v
      )
      assert.falsy(v:find("…", 1, true), "no truncation marker expected: " .. v)
    end)

    it("marks both sides when the window is in the middle", function()
      set_win_width(36)
      make_sessions(5, 3)
      local v = visible(tabbar._build_winbar(1))
      assert.truthy(v:find("‹", 1, true), "left fold expected: " .. v)
      assert.truthy(v:find("›", 1, true), "right fold expected: " .. v)
    end)
  end)

  describe("‹/› scroll", function()
    it("scrolls the window right by one tab on ›", function()
      set_win_width(30)
      make_sessions(6, 1)
      tabbar._build_winbar(1)
      expect(tabbar._snapshot()[1].viewport_start).to_be(1)
      _G.ClaudeCodeTabScrollRightClick(0, 0, "l", "")
      -- viewport_start must advance by one; do NOT re-invoke _build_winbar
      -- here — a fresh build re-runs compute_layout and re-clamps active back
      -- into view (the one-shot skip flag is already consumed by the scroll's
      -- own render), which would mask the scroll.
      expect(tabbar._snapshot()[1].viewport_start).to_be(2)
      -- The winbar rendered during the scroll reflects the scrolled window.
      assert.truthy(
        visible(last_winbar):find("2:", 1, true),
        "slot 2 should be visible after ›: " .. tostring(last_winbar)
      )
    end)

    it("scrolls the window left by one tab on ‹", function()
      set_win_width(30)
      make_sessions(6, 1)
      tabbar._build_winbar(1)
      _G.ClaudeCodeTabScrollRightClick(0, 0, "l", "") -- to start=2
      _G.ClaudeCodeTabScrollRightClick(0, 0, "l", "") -- to start=3
      expect(tabbar._snapshot()[1].viewport_start).to_be(3)
      _G.ClaudeCodeTabScrollClick(0, 0, "l", "")
      expect(tabbar._snapshot()[1].viewport_start).to_be(2)
    end)

    it("clamps scroll at the first and last session", function()
      set_win_width(30)
      make_sessions(6, 1)
      tabbar._build_winbar(1)
      -- Scrolling left at the start is a no-op.
      _G.ClaudeCodeTabScrollClick(0, 0, "l", "")
      expect(tabbar._snapshot()[1].viewport_start).to_be(1)
      -- Scroll right past the end; clamp at the last viable start.
      for _ = 1, 20 do
        _G.ClaudeCodeTabScrollRightClick(0, 0, "l", "")
      end
      local final = tabbar._snapshot()[1].viewport_start
      assert.is_true(final <= 6, "viewport_start must not exceed session count: " .. tostring(final))
    end)

    it("re-clamps active into view on the next session switch after a scroll", function()
      set_win_width(30)
      make_sessions(6, 1)
      tabbar._build_winbar(1)
      _G.ClaudeCodeTabScrollRightClick(0, 0, "l", "") -- browse right, active=1 leaves window
      expect(tabbar._snapshot()[1].viewport_start).to_be(2)
      -- Switching active snaps the window back to include the active session.
      session.set_active_session(session.get_session_by_slot(1).id)
      tabbar.render(1)
      expect(tabbar._snapshot()[1].viewport_start).to_be(1)
    end)
  end)

  describe("winbar click index mapping", function()
    it("maps winbar click indices only to rendered sessions", function()
      set_win_width(30)
      make_sessions(6, 1) -- only ~1-2 sessions fit
      tabbar._build_winbar(1)
      local slot = tabbar._snapshot()[1]
      assert.is_true(#slot.winbar_session_ids <= 2, "only rendered tabs should be mapped")
      local s1 = session.get_session_by_slot(1)
      expect(slot.winbar_session_ids[1]).to_be(s1.id)
    end)
  end)

  describe("float path (build_content)", function()
    it("keeps active visible and fits width in the float content", function()
      set_win_width(36)
      make_sessions(5, 3)
      local content = tabbar._build_content(1)
      assert.truthy(content:find("3:", 1, true), "active slot 3 should be visible: " .. content)
      local c = cells(content)
      assert.is_true(c <= 36, string.format("float content %d cells overflowed: %s", c, content))
    end)

    it("emits scroll_left/scroll_right click regions for the fold markers", function()
      set_win_width(36)
      make_sessions(5, 3)
      tabbar._build_content(1)
      local slot = tabbar._snapshot()[1]
      local actions = {}
      for _, region in ipairs(slot.click_regions) do
        actions[region.action] = true
      end
      assert.is_true(actions.scroll_left, "‹ should have a scroll_left region")
      assert.is_true(actions.scroll_right, "› should have a scroll_right region")
    end)
  end)
end)
