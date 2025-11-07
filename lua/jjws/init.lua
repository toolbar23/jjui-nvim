-- lua/jjws/init.lua
local util = require("jjws.util")
local config_module = require("jjws.config")
local diff_module = require("jjws.diff")
local picker_module = require("jjws.picker")

local M = {}

local open_agent
local diff_refresh
local diff_comment
local refresh_picker
local agent_command_started
local picker_api
local strip_ansi
local is_agent_buffer

local function trim(s)
  return util.trim(s)
end

local function joinpath(parent, child)
  return util.joinpath(parent, child)
end

local function workspace_root_from_jj(cwd)
  return util.workspace_root_from_jj(cwd)
end

local function save_config()
  return config_module.save_config(notify)
end

local function workspace_config()
  return config_module.workspace_config()
end

local cfg = {
  -- Emit workspace names, one per line.
  list_cmd = [[jj workspace list -T 'name ++ "\n"']],
  repo_root_finder = function()
    local root = workspace_root_from_jj()
    if root then
      return root
    end
    -- Walk up for ".jj" directory
    local uv = vim.uv or vim.loop
    local cwd = vim.fn.getcwd()
    local function has_jj(dir)
      local st = uv.fs_stat(dir .. "/.jj")
      return st and st.type == "directory"
    end
    local dir = cwd
    while dir and dir ~= "/" do
      if has_jj(dir) then
        return dir
      end
      dir = vim.fn.fnamemodify(dir, ":h")
    end
    return cwd -- best effort
  end,
  close_unsaved = false, -- if true, force close without prompts
  agent_type = "codex", -- derive codex commands automatically unless overridden
  agent_cmd = nil, -- override to force a specific terminal command
  agent_session_cmd = nil, -- override codex session bootstrapper
  agent_resume_cmd = nil, -- override the resume command (accepts %s placeholder)
  agent_size = 40, -- split size (height or width depending on position)
  agent_position = "right", -- "bottom", "top", "left", or "right"
  diff_command = { "bash", "-lc", "jj diff -tool difftastic --color=always" },
  diff_position = "right",
  diff_size = nil,
  diff_refresh_keymap = "gr",
  diff_comment_keymap = "gc",
  diff_comment_prefix = "[JJDiff]",
  remember_last = true, -- save last workspace per repo
  agent_idle_ms = 600, -- ms of silence before we consider the response complete
  agent_prompt_patterns = nil, -- optional list of Lua patterns to detect prompts
}

local uv = vim.uv or vim.loop

local ui_state = {
  initial_restored = false,
}
local active_workspace = nil
local agent_autocmds = {}
local agent_buffers = {}
local agent_sizes = {}
local pending_agent_sessions = {}
local workspace_attention = {}
local owned_workspace_lock = nil
local current_pid = (uv and uv.os_getpid and uv.os_getpid()) or vim.fn.getpid()

local AGENT_IDLE_FALLBACK = 600
local agent_output_watchers = {}
local agent_key_state = {
  ns = vim.api.nvim_create_namespace("jjws-agent-key"),
  handler_active = false,
  buffers = {},
}

local function picker_attention_refresh()
  if picker_api and picker_api.attention_refresh then
    picker_api.attention_refresh()
  end
end

refresh_picker = function(needle)
  if picker_api and picker_api.refresh then
    picker_api.refresh(needle)
  end
end

local function workspace_key_parts(repo, name)
  if not repo or repo == "" or not name or name == "" then
    return nil
  end
  return repo .. "::" .. name
end

local function workspace_key(ctx)
  if type(ctx) ~= "table" then
    return nil
  end
  return workspace_key_parts(ctx.repo, ctx.name)
end

local function workspace_label(ctx)
  if not ctx then
    return "workspace"
  end
  if ctx.repo and ctx.name then
    return string.format("%s/%s", ctx.repo, ctx.name)
  end
  return ctx.name or (ctx.root or "workspace")
end

local function set_default_highlight(name, opts)
  local ok, current = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if ok and current and not vim.tbl_isempty(current) then
    return
  end
  vim.api.nvim_set_hl(0, name, opts)
end

local function workspace_snapshot(ctx)
  if not ctx then
    return nil
  end
  return {
    repo = ctx.repo,
    name = ctx.name,
    root = ctx.root,
    repo_path = ctx.repo_path,
    default_root = ctx.default_root,
  }
end

local function stamp_agent_workspace(buf, ctx)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  local snapshot = workspace_snapshot(ctx)
  if snapshot then
    vim.b[buf].jjws_workspace_snapshot = snapshot
  end
end

local function agent_buffer_workspace(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return nil
  end
  local ok_snapshot, snapshot = pcall(function()
    return vim.b[buf].jjws_workspace_snapshot
  end)
  if ok_snapshot and snapshot then
    return snapshot
  end
  local ok_key, key = pcall(function()
    return vim.b[buf].jjws_workspace_key
  end)
  if ok_key and key then
    local ctx = active_workspace
    if ctx and workspace_key(ctx) == key then
      return ctx
    end
  end
  return nil
end

local function workspace_has_attention(repo, name)
  local key = workspace_key_parts(repo, name)
  if not key then
    return false
  end
  local state = workspace_attention[key]
  return state and state.pending or false
end

local function mark_workspace_attention(ctx, payload)
  local key = workspace_key(ctx)
  if not key then
    return false
  end
  local active_key = active_workspace and workspace_key(active_workspace) or nil
  if active_key and active_key == key then
    workspace_attention[key] = nil
    picker_attention_refresh()
    return false
  end
  workspace_attention[key] = {
    pending = true,
    last_event = payload,
    last_command = payload and payload.command or nil,
    message = payload and payload.message or nil,
  }
  picker_attention_refresh()
  return true
end

local function clear_workspace_attention(ctx)
  local key = workspace_key(ctx)
  if not key then
    return false
  end
  local state = workspace_attention[key]
  if not state then
    return false
  end
  workspace_attention[key] = nil
  picker_attention_refresh()
  return true, state
end

local default_prompt_patterns = {
  "codex>%s*$",
  "%$%s*$",
  "#%s*$",
  "[%]%)]%s*$",
  ">%s*$",
}

local function get_agent_prompt_patterns()
  if type(cfg.agent_prompt_patterns) == "table" and #cfg.agent_prompt_patterns > 0 then
    return cfg.agent_prompt_patterns
  end
  return default_prompt_patterns
end

local function agent_idle_timeout()
  local timeout = tonumber(cfg.agent_idle_ms)
  if timeout and timeout > 0 then
    return timeout
  end
  return AGENT_IDLE_FALLBACK
end

local function stop_agent_idle_timer(state)
  if state and state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
end

local function detect_prompt_in_lines(lines)
  if not lines then
    return false
  end
  local patterns = get_agent_prompt_patterns()
  for idx = #lines, 1, -1 do
    local line = lines[idx]
    if line and line ~= "" then
      local stripped = trim(strip_ansi(line))
      if stripped ~= "" then
        for _, pattern in ipairs(patterns) do
          if stripped:match(pattern) then
            return true
          end
        end
        break
      end
    end
  end
  return false
end

local function agent_completion_message(ctx, command)
  local label = workspace_label(ctx)
  if command and command ~= "" then
    return string.format("agent finished (%s): %s", label, command)
  end
  return string.format("agent finished (%s)", label)
end

local function agent_command_ready(buf, reason)
  local state = agent_output_watchers[buf]
  if not state or not state.awaiting_ready then
    return
  end
  local command = state.pending_command
  state.pending_command = nil
  state.awaiting_ready = false
  stop_agent_idle_timer(state)
  local ctx = agent_buffer_workspace(buf)
  if not ctx then
    return
  end
  local message = agent_completion_message(ctx, command)
  notify(message)
  vim.api.nvim_exec_autocmds("User", {
    pattern = "JJWSAgentReady",
    modeline = false,
    data = {
      workspace = ctx,
      command = command,
      reason = reason,
    },
  })
  mark_workspace_attention(ctx, {
    command = command,
    message = message,
    reason = reason,
  })
end

local function schedule_agent_idle_timer(buf, state)
  if not state then
    return
  end
  stop_agent_idle_timer(state)
  local timeout = agent_idle_timeout()
  if timeout <= 0 or not state.awaiting_ready then
    return
  end
  local timer = vim.loop.new_timer()
  state.timer = timer
  timer:start(timeout, 0, vim.schedule_wrap(function()
    state.timer = nil
    if state.awaiting_ready then
      agent_command_ready(buf, "idle")
    end
  end))
end

local function handle_agent_output_lines(buf, first, new_last)
  local state = agent_output_watchers[buf]
  if not state or not state.awaiting_ready then
    return
  end
  schedule_agent_idle_timer(buf, state)
  if not (new_last and new_last > first) then
    return
  end
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, buf, first, new_last, false)
  if not ok or not lines or #lines == 0 then
    return
  end
  if detect_prompt_in_lines(lines) then
    agent_command_ready(buf, "prompt")
  end
end

local function start_agent_output_watch(buf)
  if agent_output_watchers[buf] then
    return agent_output_watchers[buf]
  end
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return nil
  end
  local state = {
    pending_command = nil,
    awaiting_ready = false,
    timer = nil,
  }
  agent_output_watchers[buf] = state
  local ok = vim.api.nvim_buf_attach(buf, false, {
    on_lines = function(_, b, _, first, _, new_last)
      handle_agent_output_lines(b or buf, first, new_last)
    end,
    on_detach = function()
      stop_agent_idle_timer(state)
      agent_output_watchers[buf] = nil
    end,
  })
  if not ok then
    agent_output_watchers[buf] = nil
    return nil
  end
  return state
end

local function stop_agent_output_watch(buf)
  local state = agent_output_watchers[buf]
  if not state then
    return
  end
  stop_agent_idle_timer(state)
  agent_output_watchers[buf] = nil
end

local function reset_agent_key_buffer(buf)
  local state = agent_key_state.buffers[buf]
  if state then
    state.input = ""
  end
end

local function handle_agent_key_char(buf, ch)
  local state = agent_key_state.buffers[buf]
  if not state or not ch then
    return
  end
  if ch == "\n" then
    ch = "\r"
  end
  if ch == "\r" then
    local text = trim(state.input or "")
    if text ~= "" then
      agent_command_started(buf, text)
    end
    state.input = ""
    return
  end
  local byte = string.byte(ch)
  if not byte then
    return
  end
  if byte == 8 or byte == 127 then
    local current = state.input or ""
    if #current > 0 then
      state.input = current:sub(1, #current - 1)
    end
    return
  end
  if byte == 21 then -- Ctrl-U
    state.input = ""
    return
  end
  if byte == 23 then -- Ctrl-W
    local current = state.input or ""
    state.input = current:gsub("%s*%S+$", "")
    return
  end
  if byte < 32 then
    return
  end
  state.input = (state.input or "") .. ch
end

local function ensure_agent_key_listener()
  if agent_key_state.handler_active then
    return
  end
  agent_key_state.handler_active = true
  vim.on_key(function(ch)
    local mode = vim.api.nvim_get_mode().mode
    if mode ~= "t" then
      return
    end
    local buf = vim.api.nvim_get_current_buf()
    if not buf or buf == 0 then
      return
    end
    if not agent_key_state.buffers[buf] then
      return
    end
    handle_agent_key_char(buf, ch)
  end, agent_key_state.ns)
end

local function start_agent_key_capture(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return
  end
  if agent_key_state.buffers[buf] then
    return
  end
  agent_key_state.buffers[buf] = { input = "" }
  ensure_agent_key_listener()
end

local function stop_agent_key_capture(buf)
  if buf then
    agent_key_state.buffers[buf] = nil
  end
  if agent_key_state.handler_active and next(agent_key_state.buffers) == nil then
    vim.on_key(nil, agent_key_state.ns)
    agent_key_state.handler_active = false
  end
end

local function agent_term_job(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return nil
  end
  local ok_job, job = pcall(vim.api.nvim_buf_get_var, buf, "jjws_agent_job")
  if ok_job and type(job) == "number" and job > 0 then
    return job
  end
  local fallback = vim.fn.getbufvar(buf, "terminal_job_id", 0)
  if type(fallback) == "number" and fallback > 0 then
    return fallback
  end
  return nil
end

local function agent_send_escape(buf)
  local job = agent_term_job(buf)
  if not job then
    return false
  end
  pcall(vim.fn.chansend, job, "\27")
  return true
end

local function apply_agent_keymaps(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf) and is_agent_buffer(buf)) then
    return
  end
  if vim.b[buf].jjws_agent_keymaps then
    return
  end
  local opts = { buffer = buf, silent = true }
  vim.keymap.set("t", "<Esc>", [[<C-\><C-n>]], opts)
  vim.keymap.set("t", "<S-Esc>", function()
    if not agent_send_escape(buf) then
      notify("agent terminal is not ready to receive <Esc>", vim.log.levels.WARN)
    end
  end, opts)
  vim.b[buf].jjws_agent_keymaps = true
end

agent_command_started = function(buf, text)
  local command = trim(text or "")
  if command == "" then
    return
  end
  local state = start_agent_output_watch(buf)
  if not state then
    return
  end
  state.pending_command = command
  state.awaiting_ready = true
  schedule_agent_idle_timer(buf, state)
  local ctx = agent_buffer_workspace(buf)
  if ctx then
    vim.api.nvim_exec_autocmds("User", {
      pattern = "JJWSAgentCommand",
      modeline = false,
      data = {
        workspace = ctx,
        command = command,
      },
    })
  end
end

local function ensure_agent_buffer_watchers(buf, ctx)
  if ctx then
    stamp_agent_workspace(buf, ctx)
  end
  start_agent_key_capture(buf)
  start_agent_output_watch(buf)
  apply_agent_keymaps(buf)
end

is_agent_buffer = function(buf)
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    return false
  end
  local ok, flag = pcall(vim.api.nvim_buf_get_var, buf, "jjws_agent")
  return ok and flag and true or false
end

local function hide_agent_buffer(buf, opts)
  buf = buf or vim.api.nvim_get_current_buf()
  if not is_agent_buffer(buf) then
    return false
  end
  opts = opts or {}
  local ok_key, buf_key = pcall(function()
    return vim.b[buf].jjws_workspace_key
  end)
  if ok_key and buf_key then
    agent_buffers[buf_key] = buf
  end
  pcall(vim.api.nvim_buf_set_option, buf, "buflisted", false)
  pcall(vim.api.nvim_buf_set_option, buf, "bufhidden", "hide")
  local wins = vim.fn.win_findbuf(buf)
  for _, win in ipairs(wins) do
    if vim.api.nvim_win_is_valid(win) then
      if ok_key and buf_key then
        local size = agent_window_size(win)
        if size then
          agent_sizes[buf_key] = size
        end
      end
      vim.api.nvim_win_call(win, function()
        pcall(vim.cmd, "stopinsert")
      end)
      local total_wins = #vim.api.nvim_list_wins()
      if total_wins > 1 and not opts.keep_window then
        pcall(vim.api.nvim_win_close, win, true)
      else
        vim.api.nvim_win_call(win, function()
          vim.cmd("enew")
        end)
      end
    end
  end
  return true
end

local function agent_orientation(pos)
  pos = (pos or cfg.agent_position or "right"):lower()
  if pos == "left" or pos == "right" then
    return "vertical"
  end
  return "horizontal"
end

local function agent_window_size(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return nil
  end
  local orientation = agent_orientation()
  if orientation == "vertical" then
    return vim.api.nvim_win_get_width(win)
  else
    return vim.api.nvim_win_get_height(win)
  end
end

local function remember_agent_size(key, win)
  if not key or not win then
    return
  end
  local size = agent_window_size(win)
  if size and size > 0 then
    agent_sizes[key] = size
  end
end


M._switch_from_picker = function(entry)
  if picker_api and picker_api.switch then
    return picker_api.switch(entry)
  end
end
M._register_repo = function()
  if picker_api and picker_api.register_repo then
    picker_api.register_repo()
  else
    notify("workspace picker is not available", vim.log.levels.ERROR)
  end
end
M._create_workspace = function()
  if picker_api and picker_api.create_workspace then
    picker_api.create_workspace()
  else
    notify("workspace picker is not available", vim.log.levels.ERROR)
  end
end
M._remove_workspace = function()
  if picker_api and picker_api.remove_workspace then
    picker_api.remove_workspace()
  else
    notify("workspace picker is not available", vim.log.levels.ERROR)
  end
end

local function wipe_all()
  -- Close floating windows and terminals cleanly, then wipe other buffers and tabs.
  -- Optionally protect unsaved buffers.
  local bufs = vim.api.nvim_list_bufs()
  for _, b in ipairs(bufs) do
    if vim.api.nvim_buf_is_loaded(b) then
      if is_agent_buffer(b) then
        hide_agent_buffer(b, { keep_window = true })
      else
        local modified = vim.bo[b].modified
        if cfg.close_unsaved or not modified then
          pcall(vim.api.nvim_buf_delete, b, { force = cfg.close_unsaved })
        end
      end
    end
  end
  -- Ensure a clean tabpage
  vim.cmd("tabonly")
  pcall(vim.cmd, "only")
end

local function set_cwd(path)
  vim.cmd.cd(path)
  -- Notify LSP rooters that rely on cwd
  for _, client in pairs(vim.lsp.get_clients()) do
    pcall(function()
      client.config.root_dir = path
    end)
  end
  notify("cwd → " .. path)
end

local function create_agent_split(size_override, position_override)
  local size = size_override or cfg.agent_size or cfg.agent_height or 40
  local position = position_override or cfg.agent_position
  if not position or position == "" then
    -- backward compatibility with deprecated agent_direction
    local direction = cfg.agent_direction
    if direction == "vertical" or direction == "vert" then
      position = "right"
    else
      position = "bottom"
    end
  end
  position = position:lower()
  local cmd
  if position == "top" then
    cmd = string.format("topleft %d split", size)
  elseif position == "left" then
    cmd = string.format("topleft %d vsplit", size)
  elseif position == "right" then
    cmd = string.format("botright %d vsplit", size)
  else
    position = "bottom"
    cmd = string.format("botright %d split", size)
  end
  vim.cmd(cmd)
  local win = vim.api.nvim_get_current_win()
  configure_agent_window(win)
  return win
end

local function focus_agent_window(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return false
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
      vim.api.nvim_set_current_win(win)
      configure_agent_window(win)
      attach_agent_autocmds(buf)
      local ok_key, key = pcall(function()
        return vim.b[buf].jjws_workspace_key
      end)
      if ok_key and key then
        remember_agent_size(key, win)
      end
      pcall(vim.cmd, "startinsert")
      return true
    end
  end
  return false
end

local function place_agent_buffer(buf, key)
  local size_override = key and agent_sizes[key] or nil
  local win = create_agent_split(size_override)
  vim.api.nvim_win_set_buf(win, buf)
  configure_agent_window(win)
  pcall(vim.api.nvim_buf_set_option, buf, "buflisted", false)
  pcall(vim.api.nvim_buf_set_option, buf, "bufhidden", "hide")
  pcall(vim.api.nvim_buf_set_option, buf, "swapfile", false)
  attach_agent_autocmds(buf)
  pcall(vim.cmd, "startinsert")
  remember_agent_size(key, win)
  return buf
end

revive_agent_buffer = function(ctx)
  if ctx and ctx.detached then
    return nil
  end
  local key = workspace_key(ctx)
  if not key then
    return nil
  end
  local buf = agent_buffers[key]
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.b[buf].jjws_workspace_key = key
    ensure_agent_buffer_watchers(buf, ctx)
    if not focus_agent_window(buf) then
      place_agent_buffer(buf, key)
    end
    return buf
  end
  agent_buffers[key] = nil
  local pending = pending_agent_sessions[key]
  if pending then
    pending_agent_sessions[key] = nil
    return open_agent({
      workspace = ctx,
      session_id = pending,
      force_new = true,
      ignore_guard = true,
      visible = false,
      size_override = agent_sizes[key],
    })
  end
  return nil
end

open_agent = function(opts)
  -- Open a terminal split and start the configured agent in repo cwd
  opts = opts or {}
  local ctx = opts.workspace or active_workspace or current_workspace()
  if not ctx and not opts.ignore_guard then
    notify("open a JJ workspace before starting the agent", vim.log.levels.WARN)
    return nil
  end
  if ctx and ctx.detached then
    notify("workspace is in detached mode; agent disabled", vim.log.levels.WARN)
    return nil
  end
  if not opts.force_new then
    local revived = revive_agent_buffer(ctx)
    if revived then
      return revived
    end
  end
  local cwd = (ctx and ctx.root) or vim.fn.getcwd()
  local key = workspace_key(ctx)
  local size_pref = opts.size_override or (key and agent_sizes[key])
  local win = create_agent_split(size_pref)
  vim.cmd("enew")
  local buf = vim.api.nvim_get_current_buf()
  vim.b[buf].jjws_agent = true
  pcall(vim.api.nvim_buf_set_option, buf, "buflisted", false)
  pcall(vim.api.nvim_buf_set_option, buf, "bufhidden", "hide")
  pcall(vim.api.nvim_buf_set_option, buf, "swapfile", false)
  pcall(vim.api.nvim_buf_set_option, buf, "filetype", "jjws-agent")
  attach_agent_autocmds(buf)
  if key then
    vim.b[buf].jjws_workspace_key = key
    agent_buffers[key] = buf
  end
  ensure_agent_buffer_watchers(buf, ctx)
  local session_id = opts.session_id
  local base_cmd = resolved_agent_cmd()
  if not base_cmd then
    notify("configure jjws.agent_cmd or jjws.agent_type", vim.log.levels.ERROR)
    return nil
  end
  local term_cmd = base_cmd
  if session_id and session_id ~= "" then
    local resume_cmd = build_resume_command(session_id, base_cmd)
    if resume_cmd then
      term_cmd = resume_cmd
    end
  elseif is_codex_agent() then
    local session_cmd = resolved_agent_session_cmd()
    local session, err = create_codex_session(cwd, session_cmd)
    if session then
      session_id = session
      local resume_cmd = build_resume_command(session_id, base_cmd)
      if resume_cmd then
        term_cmd = resume_cmd
        notify("codex session " .. session_id .. " ready", vim.log.levels.DEBUG)
      end
    elseif err then
      notify("codex session setup failed: " .. err, vim.log.levels.WARN)
    end
  end

  local job_id = vim.fn.termopen(term_cmd, { cwd = cwd })
  if opts.visible ~= false then
    vim.cmd("startinsert")
  else
    vim.schedule(function()
      if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
        pcall(vim.api.nvim_win_close, win, true)
      end
    end)
  end
  if type(job_id) == "number" and job_id > 0 then
    pcall(vim.api.nvim_buf_set_var, buf, "jjws_agent_job", job_id)
  end
  if session_id and session_id ~= "" then
    vim.b[buf].jjws_codex_session = session_id
  else
    vim.b[buf].jjws_codex_session = nil
  end

  -- Persist the updated layout so the agent/session are recorded immediately.
  if key then
    remember_agent_size(key, win)
  end
  if ctx then
    save_workspace_layout(ctx)
  end

  return buf
end

local function statefile(repo_root)
  return vim.fn.stdpath("state") .. "/jjws_last_" .. vim.fn.sha256(repo_root) .. ".json"
end

local function save_last(repo_root, ws)
  if not cfg.remember_last then
    return
  end
  local path = statefile(repo_root)
  local data = vim.json.encode(ws)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = io.open(path, "w")
  if f then
    f:write(data)
    f:close()
  end
end

local function load_last(repo_root)
  local path = statefile(repo_root)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local ok, data = pcall(vim.json.decode, f:read("*a"))
  f:close()
  return ok and data or nil
end

function M.list_workspaces(repo)
  if picker_api and picker_api.list_workspaces then
    return picker_api.list_workspaces(repo)
  end
  notify("workspace picker is not available", vim.log.levels.ERROR)
  return {}
end

function M.pick_workspace()
  if picker_api and picker_api.toggle then
    picker_api.toggle()
  else
    notify("workspace picker is not available", vim.log.levels.ERROR)
  end
end

function M.use_workspace(ws, opts)
  -- 1) wipe UI state  2) chdir  3) reopen an empty buffer  4) save state
  opts = opts or {}
  if not ws or not ws.path then
    notify("workspace path missing", vim.log.levels.ERROR)
    return false
  end
  if not ws.name or ws.name == "" then
    ws.name = vim.fn.fnamemodify(ws.path, ":t")
  end
  if not maybe_handle_locked_workspace(ws, { on_cancel = opts.on_cancel }) then
    return false
  end
  local previous = active_workspace or current_workspace()
  if previous and not previous.detached then
    save_workspace_layout(previous)
  end
  if not (previous and previous.detached) then
    release_workspace_lock()
  end
  wipe_all()
  set_cwd(ws.path)
  vim.cmd("enew")
  local new_ctx = current_workspace()
  if new_ctx then
    new_ctx.detached = ws.detached or false
    if ws.repo and ws.repo ~= "" then
      new_ctx.repo = ws.repo
    end
    if ws.repo_path then
      new_ctx.repo_path = ws.repo_path
    end
    active_workspace = new_ctx
    if not new_ctx.detached then
      local lock_ok = acquire_workspace_lock(new_ctx)
      if not lock_ok then
        new_ctx.detached = true
        notify(
          string.format("%s locked elsewhere; continuing without agent/layout.", workspace_label(new_ctx)),
          vim.log.levels.WARN
        )
      end
    end
    if not new_ctx.detached then
      restore_workspace_layout(new_ctx)
      local cleared, state = clear_workspace_attention(new_ctx)
      if cleared then
        local message = (state and state.message) or string.format("agent has finished in %s", workspace_label(new_ctx))
        notify(message)
      end
    else
      notify(
        string.format("%s is in detached edit-only mode.", workspace_label(new_ctx)),
        vim.log.levels.WARN
      )
    end
  else
    active_workspace = nil
  end
  local repo_root = cfg.repo_root_finder()
  local snapshot = new_ctx and workspace_snapshot(new_ctx)
  save_last(repo_root, snapshot or ws)
  notify("workspace → " .. (new_ctx and workspace_label(new_ctx) or ws.name))
  return new_ctx ~= nil
end

function M.diff(opts)
  diff_refresh(opts)
end

function M.diff_comment(opts)
  diff_comment(opts)
end

function M.agent()
  open_agent()
end

function M.resume_last()
  local repo_root = cfg.repo_root_finder()
  local ws = load_last(repo_root)
  if not ws or not ws.path then
    notify("no saved workspace for this repo", vim.log.levels.WARN)
    return
  end
  M.use_workspace(ws)
end

function M.setup(opts)
  cfg = vim.tbl_deep_extend("force", cfg, opts or {})
  vim.api.nvim_create_user_command("JJWSAgentHide", function(o)
    if hide_agent_buffer() then
      return
    end
    if o.bang then
      vim.cmd("bdelete!")
    else
      vim.cmd("bdelete")
    end
  end, { bang = true })
  vim.api.nvim_create_user_command("JJWorkspaces", function()
    M.pick_workspace()
  end, {})
  vim.api.nvim_create_user_command("JJUseWorkspace", function(o)
    -- :JJUseWorkspace <name>  or prompts if missing
    local name = o.args ~= "" and o.args or nil
    local items = M.list_workspaces()
    if name then
      for _, it in ipairs(items) do
        if it.name == name then
          return M.use_workspace(it)
        end
      end
      notify("workspace not found: " .. name, vim.log.levels.ERROR)
      return
    end
    vim.ui.select(items, { prompt = "Select jj workspace" }, function(ch)
      if ch then
        M.use_workspace(ch)
      end
    end)
  end, { nargs = "?" })
  vim.api.nvim_create_user_command("JJAgent", function()
    M.agent()
  end, {})
  vim.api.nvim_create_user_command("JJDiff", function(o)
    M.diff({ focus = not o.bang })
  end, { bang = true })
  vim.api.nvim_create_user_command("JJResume", function()
    M.resume_last()
  end, {})
  vim.api.nvim_create_autocmd("VimLeavePre", {
    callback = function()
      local ctx = active_workspace
      if not ctx then
        local ok, current = pcall(current_workspace)
        if ok then
          ctx = current
        end
      end
      if ctx then
        save_workspace_layout(ctx)
      end
      release_workspace_lock()
    end,
  })

  if vim.v.vim_did_enter == 1 then
    ensure_initial_restore()
  else
    vim.api.nvim_create_autocmd("VimEnter", {
      once = true,
      callback = ensure_initial_restore,
    })
  end

  for _, name in ipairs({ "bdelete", "Bdelete", "bd", "Bd" }) do
    vim.cmd(string.format(
      "cnoreabbrev <expr> %s luaeval(\"require('jjws')._agent_abbrev('%s')\")",
      name,
      name
    ))
  end
end

function M._agent_abbrev(cmd)
  local ok, res = pcall(agent_abbrev_target, cmd)
  if not ok then
    return cmd
  end
  return res
end

return M
