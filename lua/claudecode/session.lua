---Session manager for multiple Claude Code terminal sessions.
---@module 'claudecode.session'

local M = {}

local logger = require("claudecode.logger")

---@class ClaudeCodeSession
---@field id string
---@field slot number 1-based, stable across creations/destructions; gaps reused
---@field terminal_bufnr number|nil
---@field terminal_winid number|nil
---@field terminal_jobid number|nil
---@field client_id string|nil Bound WebSocket client ID
---@field selection table|nil
---@field mention_queue table
---@field created_at number
---@field name string|nil
---@field awaiting_handshake boolean|nil True between terminal spawn and client bind

---@type table<string, ClaudeCodeSession>
M.sessions = {}

---@type string|nil
M.active_session_id = nil

local session_counter = 0
local used_slots = {}

local function next_free_slot()
  local slot = 1
  while used_slots[slot] do
    slot = slot + 1
  end
  return slot
end

local function generate_session_id()
  session_counter = session_counter + 1
  return session_counter, string.format("session_%d_%d", session_counter, vim.loop.now())
end

---Fire a User autocmd safely. Server callbacks (on_message/on_disconnect) run
---in a libuv fast-event context where nvim_exec_autocmds is forbidden (E5560),
---so defer to vim.schedule in that case. In the main loop (user commands,
---tests) fire synchronously so callers observe the event before returning.
---@param pattern string User autocmd pattern
---@param data table|nil Autocmd data payload
local function fire_user_event(pattern, data)
  local function fire()
    pcall(vim.api.nvim_exec_autocmds, "User", { pattern = pattern, data = data })
  end
  if vim.in_fast_event and vim.in_fast_event() then
    vim.schedule(fire)
  else
    fire()
  end
end

---@param opts table|nil { name?: string, slot?: number }
---@return string session_id
function M.create_session(opts)
  opts = opts or {}
  local seq, session_id = generate_session_id()

  local slot = opts.slot
  if not slot or used_slots[slot] then
    slot = next_free_slot()
  end
  used_slots[slot] = true

  local session = {
    id = session_id,
    slot = slot,
    seq = seq, -- creation order; tiebreaker for created_at
    mention_queue = {},
    created_at = vim.loop.now(),
    name = opts.name or "Session",
  }

  M.sessions[session_id] = session

  if not M.active_session_id then
    M.active_session_id = session_id
  end

  logger.debug("session", "Created session: " .. session_id .. " (slot " .. slot .. ")")

  fire_user_event("ClaudeCodeSessionCreated", {
    session_id = session_id,
    name = session.name,
    slot = slot,
  })

  return session_id
end

---@return boolean success
function M.destroy_session(session_id)
  local session = M.sessions[session_id]
  if not session then
    return false
  end

  session.mention_queue = {}
  session.selection = nil

  if session.slot then
    used_slots[session.slot] = nil
  end

  M.sessions[session_id] = nil

  if M.active_session_id == session_id then
    M.active_session_id = next(M.sessions)
  end

  logger.debug("session", "Destroyed session: " .. session_id)

  fire_user_event("ClaudeCodeSessionDestroyed", { session_id = session_id })

  return true
end

function M.get_session(session_id)
  return M.sessions[session_id]
end

function M.get_active_session()
  return M.active_session_id and M.sessions[M.active_session_id] or nil
end

function M.get_active_session_id()
  return M.active_session_id
end

---@return boolean success
function M.set_active_session(session_id)
  if not M.sessions[session_id] then
    logger.warn("session", "Cannot activate non-existent session: " .. session_id)
    return false
  end

  -- No-op when already active — callers like toggle_session_by_index set
  -- active even when it's a no-op; skip the autocmd to avoid tabbar churn.
  if M.active_session_id == session_id then
    return true
  end

  local old_active = M.active_session_id
  M.active_session_id = session_id
  logger.debug("session", "Activated session: " .. session_id .. " (was " .. tostring(old_active) .. ")")

  -- Notify UI layers so they re-render the active indicator. Without this,
  -- create_session's SessionCreated autocmd fires BEFORE set_active_session
  -- runs, so that render sees the stale active.
  fire_user_event("ClaudeCodeSessionActivated", { session_id = session_id })

  return true
end

---@return ClaudeCodeSession[]
function M.list_sessions()
  local sessions = {}
  for _, session in pairs(M.sessions) do
    table.insert(sessions, session)
  end
  table.sort(sessions, function(a, b)
    return (a.slot or 0) < (b.slot or 0)
  end)
  return sessions
end

function M.get_session_by_slot(slot)
  for _, session in pairs(M.sessions) do
    if session.slot == slot then
      return session
    end
  end
  return nil
end

function M.get_slot(session_id)
  local session = M.sessions[session_id]
  return session and session.slot or nil
end

function M.get_session_count()
  local count = 0
  for _ in pairs(M.sessions) do
    count = count + 1
  end
  return count
end

function M.find_session_by_bufnr(bufnr)
  for _, session in pairs(M.sessions) do
    if session.terminal_bufnr == bufnr then
      return session
    end
  end
  return nil
end

-- Creation order with a deterministic tiebreaker for same-millisecond sessions.
local function created_before(a, b)
  if a.created_at ~= b.created_at then
    return a.created_at < b.created_at
  end
  return (a.seq or 0) < (b.seq or 0)
end

function M.find_unbound_session()
  local newest
  for _, session in pairs(M.sessions) do
    if not session.client_id then
      if not newest or created_before(newest, session) then
        newest = session
      end
    end
  end
  return newest
end

-- Mark a session as waiting for its Claude CLI handshake. Set at spawn so the
-- initialize handler binds the incoming client deterministically by
-- created_at order, rather than guessing from the visible buffer (which races
-- with session switches between spawn and handshake).
function M.mark_awaiting_handshake(session_id)
  local session = M.sessions[session_id]
  if session then
    session.awaiting_handshake = true
  end
end

function M.find_session_awaiting_handshake()
  local oldest
  for _, session in pairs(M.sessions) do
    if session.awaiting_handshake and not session.client_id then
      if not oldest or created_before(session, oldest) then
        oldest = session
      end
    end
  end
  return oldest
end

function M.find_session_by_client(client_id)
  for _, session in pairs(M.sessions) do
    if session.client_id == client_id then
      return session
    end
  end
  return nil
end

---@return boolean success
function M.bind_client(session_id, client_id)
  local session = M.sessions[session_id]
  if not session then
    logger.warn("session", "Cannot bind client to non-existent session: " .. session_id)
    return false
  end

  local existing = M.find_session_by_client(client_id)
  if existing and existing.id ~= session_id then
    logger.warn("session", "Client " .. client_id .. " already bound to session " .. existing.id)
    return false
  end

  session.client_id = client_id
  session.awaiting_handshake = nil
  logger.debug("session", "Bound client " .. client_id .. " to session " .. session_id)

  return true
end

---@return boolean success
function M.unbind_client(client_id)
  local session = M.find_session_by_client(client_id)
  if not session then
    return false
  end

  session.client_id = nil
  -- Re-arm while the terminal still lives so a reconnecting client re-binds to
  -- this session via find_session_awaiting_handshake, not the racy
  -- find_unbound_session. Cleared once the terminal exits.
  if session.terminal_bufnr then
    session.awaiting_handshake = true
  else
    session.awaiting_handshake = nil
  end
  logger.debug("session", "Unbound client " .. client_id .. " from session " .. session.id)

  return true
end

function M.update_terminal_info(session_id, terminal_info)
  local session = M.sessions[session_id]
  if not session then
    return
  end
  for _, k in ipairs({ "bufnr", "winid", "jobid" }) do
    if terminal_info[k] ~= nil then
      session["terminal_" .. k] = terminal_info[k]
    end
  end
end

function M.update_selection(session_id, selection)
  local session = M.sessions[session_id]
  if session then
    session.selection = selection
  end
end

function M.update_session_name(session_id, name)
  local session = M.sessions[session_id]
  if not session then
    logger.warn("session", "Cannot update name for non-existent session: " .. session_id)
    return
  end

  name = name:gsub("^[Cc]laude %- ", "")
  name = name:gsub("^%s+", ""):gsub("%s+$", "")
  if #name > 100 then
    name = name:sub(1, 97) .. "..."
  end

  if name == "" or session.name == name then
    return
  end

  local old_name = session.name
  session.name = name
  logger.debug("session", string.format("Updated session name: '%s' -> '%s' (%s)", old_name, name, session_id))

  fire_user_event("ClaudeCodeSessionNameChanged", {
    session_id = session_id,
    name = name,
    old_name = old_name,
  })
end

function M.get_selection(session_id)
  local session = M.sessions[session_id]
  return session and session.selection or nil
end

function M.queue_mention(session_id, mention)
  local session = M.sessions[session_id]
  if session then
    table.insert(session.mention_queue, mention)
  end
end

function M.flush_mention_queue(session_id)
  local session = M.sessions[session_id]
  if not session then
    return {}
  end
  local mentions = session.mention_queue
  session.mention_queue = {}
  return mentions
end

---@return string session_id
function M.ensure_session()
  if M.active_session_id and M.sessions[M.active_session_id] then
    return M.active_session_id
  end
  return M.create_session()
end

function M.reset()
  M.sessions = {}
  M.active_session_id = nil
  session_counter = 0
  used_slots = {}
end

return M
