-- luacheck: globals expect
require("tests.busted_setup")

-- Tests for claudecode.session_picker: the Snacks.picker-based session
-- switcher behind `:ClaudeCodeSessions`. Covers the fallback path (no
-- Snacks.picker → vim.ui.select), the Snacks path (item shape + confirm),
-- and the terminal-snapshot preview reader.

describe("claudecode.session_picker", function()
  local picker
  local terminal_stub
  local saved_ui_select
  local ui_select_calls
  local saved_buf_set_var
  local saved_buf_get_var
  local saved_buf_del_var

  before_each(function()
    package.path = "./lua/?.lua;" .. package.path
    package.loaded["claudecode.logger"] = package.loaded["claudecode.logger"]
      or {
        debug = function() end,
        warn = function() end,
        error = function() end,
        info = function() end,
      }
    package.loaded["claudecode.session_picker"] = nil
    package.loaded["claudecode.terminal"] = nil
    package.loaded["snacks"] = nil

    -- Capture vim.ui.select invocations so the fallback path is testable
    -- without a real UI. The mock vim has no vim.ui at all, so install one.
    saved_ui_select = vim.ui and vim.ui.select
    ui_select_calls = {}
    vim.ui = vim.ui or {}
    vim.ui.select = function(items, opts, on_choice)
      table.insert(ui_select_calls, { items = items, opts = opts })
      -- Simulate the user picking the first item.
      if items and items[1] then
        on_choice(items[1])
      else
        on_choice(nil)
      end
    end

    -- The mock vim has no buffer-var API; add lightweight stubs backed by
    -- vim._buffers[bufnr].vars so the camouflage (toggle_number) path is
    -- testable. Restore originals in after_each.
    local api = vim.api
    saved_buf_set_var = api.nvim_buf_set_var
    saved_buf_get_var = api.nvim_buf_get_var
    saved_buf_del_var = api.nvim_buf_del_var
    api.nvim_buf_set_var = function(bufnr, name, value)
      local b = vim._buffers[bufnr]
      if not b then
        return
      end
      b.vars = b.vars or {}
      b.vars[name] = value
    end
    api.nvim_buf_get_var = function(bufnr, name)
      local b = vim._buffers[bufnr]
      return b and b.vars and b.vars[name] or nil
    end
    -- nvim_buf_get_var raises on missing var in real Neovim; emulate by
    -- returning nil (our code pcalls it anyway).
    api.nvim_buf_del_var = function(bufnr, name)
      local b = vim._buffers[bufnr]
      if b and b.vars then
        b.vars[name] = nil
      end
    end
  end)

  after_each(function()
    if saved_ui_select ~= nil then
      vim.ui.select = saved_ui_select
    end
    local api = vim.api
    if saved_buf_set_var ~= nil then
      api.nvim_buf_set_var = saved_buf_set_var
    end
    if saved_buf_get_var ~= nil then
      api.nvim_buf_get_var = saved_buf_get_var
    end
    if saved_buf_del_var ~= nil then
      api.nvim_buf_del_var = saved_buf_del_var
    end
    package.loaded["claudecode.session_picker"] = nil
    package.loaded["claudecode.terminal"] = nil
    package.loaded["snacks"] = nil
  end)

  local function make_sessions()
    return {
      { id = "session_1", slot = 1, name = "Alpha" },
      { id = "session_2", slot = 2, name = "Beta" },
    }
  end

  describe("fallback (no Snacks.picker)", function()
    it("routes through vim.ui.select when snacks is not installed", function()
      package.loaded["snacks"] = nil
      terminal_stub = {}
      package.loaded["claudecode.terminal"] = terminal_stub
      picker = require("claudecode.session_picker")
      picker._reset_availability()

      local chosen
      picker.open(make_sessions(), "session_2", function(id)
        chosen = id
      end)

      expect(#ui_select_calls).to_be(1)
      expect(chosen).to_be("session_1") -- first item was auto-picked by the stub
      local items = ui_select_calls[1].items
      expect(#items).to_be(2)
      expect(items[1].session_id).to_be("session_1")
      -- active marker lands on the active session's label
      expect(items[2].label).to_match("Beta *")
    end)

    it("calls on_choice(nil) for an empty session list", function()
      package.loaded["snacks"] = nil
      package.loaded["claudecode.terminal"] = {}
      picker = require("claudecode.session_picker")
      picker._reset_availability()

      local chosen = "untouched"
      picker.open({}, nil, function(id)
        chosen = id
      end)
      expect(chosen).to_be_nil()
      expect(#ui_select_calls).to_be(0)
    end)
  end)

  describe("Snacks.picker path", function()
    local pick_calls
    local last_picker_opts

    before_each(function()
      pick_calls = {}
      package.loaded["snacks"] = {
        picker = function(opts)
          pick_calls[#pick_calls + 1] = opts
          last_picker_opts = opts
          -- Return a fake picker object (Snacks.picker returns the picker).
          return { close = function() end }
        end,
      }
    end)

    it("builds items with slot, name, session_id, and active flag", function()
      package.loaded["claudecode.terminal"] = {}
      picker = require("claudecode.session_picker")
      picker._reset_availability()

      picker.open(make_sessions(), "session_2", function() end)

      expect(#pick_calls).to_be(1)
      local items = last_picker_opts.items
      expect(#items).to_be(2)
      expect(items[1].session_id).to_be("session_1")
      expect(items[1].slot).to_be(1)
      expect(items[1].name).to_be("Alpha")
      expect(items[1].is_active).to_be(false)
      expect(items[2].is_active).to_be(true)
      -- `text` drives the matcher search.
      expect(items[1].text).to_match("Alpha")
    end)

    it("confirm action closes the picker and fires on_choice with the session id", function()
      package.loaded["claudecode.terminal"] = {}
      picker = require("claudecode.session_picker")
      picker._reset_availability()

      local chosen
      picker.open(make_sessions(), nil, function(id)
        chosen = id
      end)

      local confirm = last_picker_opts.actions.confirm
      expect(confirm).to_be_function()
      local closed = false
      local fake_picker = {
        close = function()
          closed = true
        end,
      }
      confirm(fake_picker, last_picker_opts.items[2])
      expect(closed).to_be(true)
      -- vim.schedule in the mock runs synchronously.
      expect(chosen).to_be("session_2")
    end)

    it("confirm action is a no-op when there is no item", function()
      package.loaded["claudecode.terminal"] = {}
      picker = require("claudecode.session_picker")
      picker._reset_availability()

      local chosen = "untouched"
      picker.open(make_sessions(), nil, function(id)
        chosen = id
      end)
      local confirm = last_picker_opts.actions.confirm
      confirm({ close = function() end }, nil)
      expect(chosen).to_be("untouched")
    end)

    it("format returns highlight chunks and marks the active row", function()
      package.loaded["claudecode.terminal"] = {}
      picker = require("claudecode.session_picker")
      picker._reset_availability()

      picker.open(make_sessions(), "session_1", function() end)
      local format = last_picker_opts.format
      local active_chunks = format(last_picker_opts.items[1])
      expect(active_chunks).to_be_table()
      expect(#active_chunks).to_be_at_least(1)
      -- Each chunk is { text, hl_group }
      expect(type(active_chunks[1][1])).to_be("string")
      expect(type(active_chunks[1][2])).to_be("string")
    end)

    it("preview shows the session's live terminal buffer via set_buf (colored)", function()
      -- Two terminal buffers with distinct content; the previewer should hand
      -- the buffer itself to preview:set_buf so its ANSI colors render.
      local buf_a = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf_a, 0, -1, false, { "old line", "Alpha prompt >" })
      local buf_b = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf_b, 0, -1, false, { "Beta output", "Beta prompt >" })

      terminal_stub = {
        get_session_bufnr = function(id)
          if id == "session_1" then
            return buf_a
          elseif id == "session_2" then
            return buf_b
          end
          return nil
        end,
      }
      package.loaded["claudecode.terminal"] = terminal_stub
      picker = require("claudecode.session_picker")
      picker._reset_availability()

      picker.open(make_sessions(), nil, function() end)
      local preview = last_picker_opts.preview
      expect(preview).to_be_function()

      -- Capture the buffer handed to set_buf. Methods are called with `:`
      -- (self) syntax, so each stub takes self first.
      local set_buf_arg
      local ctx = {
        item = last_picker_opts.items[2], -- session_2 / Beta
        preview = {
          reset = function() end,
          set_title = function() end,
          notify = function() end,
          set_buf = function(_, buf)
            set_buf_arg = buf
          end,
        },
        win = 0,
      }
      preview(ctx)
      expect(set_buf_arg).to_be(buf_b)
      -- The buffer is marked so snacks knows it's been previewed.
      expect(vim.b[buf_b].snacks_previewed).to_be(true)
    end)

    it("preview camouflages a toggleterm buffer (strips toggle_number) and restores on next item", function()
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Alpha prompt >" })
      -- Mark it as a toggleterm buffer (the auto-sync trigger).
      vim.api.nvim_buf_set_var(buf, "toggle_number", 42)

      terminal_stub = {
        get_session_bufnr = function(id)
          return id == "session_1" and buf or nil
        end,
      }
      package.loaded["claudecode.terminal"] = terminal_stub
      picker = require("claudecode.session_picker")
      picker._reset_availability()
      picker.open(make_sessions(), nil, function() end)
      local preview = last_picker_opts.preview

      local ctx = {
        item = last_picker_opts.items[1],
        preview = {
          reset = function() end,
          set_title = function() end,
          notify = function() end,
          set_buf = function() end,
        },
        win = 0,
      }
      preview(ctx)
      -- Camouflaged while shown: toggle_number stripped.
      local tn_during = vim.api.nvim_buf_get_var(buf, "toggle_number")
      expect(tn_during).to_be_nil()

      -- Previewing the same session again (or another) restores first.
      preview(ctx)
      -- Still nil because we re-camouflage for the new display.
      local tn_again = vim.api.nvim_buf_get_var(buf, "toggle_number")
      expect(tn_again).to_be_nil()

      -- on_close restores the var.
      last_picker_opts.on_close()
      local tn_after = vim.api.nvim_buf_get_var(buf, "toggle_number")
      expect(tn_after).to_be(42)
    end)

    it("preview shows a 'no terminal yet' notice for sessions without a buffer", function()
      terminal_stub = {
        get_session_bufnr = function()
          return nil
        end,
      }
      package.loaded["claudecode.terminal"] = terminal_stub
      picker = require("claudecode.session_picker")
      picker._reset_availability()

      picker.open(make_sessions(), nil, function() end)
      local preview = last_picker_opts.preview

      local notified
      local ctx = {
        item = last_picker_opts.items[1],
        preview = {
          reset = function() end,
          set_title = function() end,
          notify = function(_, msg)
            notified = msg
          end,
          set_buf = function() end,
        },
        win = 0,
      }
      preview(ctx)
      expect(notified).to_match("no terminal")
    end)
  end)
end)
