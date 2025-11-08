local Agent = {}

function Agent.setup(env)
  local cfg = env.cfg
  local notify = env.notify
  local trim = env.trim
  local strip_ansi = env.strip_ansi
  local clone_cmd = env.clone_cmd
  local normalize_system_cmd = env.normalize_system_cmd
  local workspace_label = env.workspace_label
  local workspace_snapshot = env.workspace_snapshot
  local workspace_key = env.workspace_key
  local mark_workspace_attention = env.mark_workspace_attention
  local get_active_workspace = env.get_active_workspace
  local current_workspace = env.current_workspace
  local save_workspace_layout = env.save_workspace_layout

  local uv = vim.uv or vim.loop
  local fn = vim.fn

  local agent_autocmds = {}
  local agent_buffers = {}
  local agent_sizes = {}
  local pending_agent_sessions = {}

  local AGENT_IDLE_FALLBACK = 600
  local agent_output_watchers = {}
  local agent_key_state = {
    ns = vim.api.nvim_create_namespace("jjws-agent-key"),
    handler_active = false,
    buffers = {},
  }

  local open_agent

  local function active_workspace()
    if get_active_workspace then
      return get_active_workspace()
    end
    return current_workspace and current_workspace() or nil
  end

  local function stamp_agent_workspace(buf, ctx)
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
      return
    end
    local snapshot = workspace_snapshot and workspace_snapshot(ctx) or ctx
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
      local ctx = active_workspace()
      if ctx and workspace_key(ctx) == key then
        return ctx
      end
    end
    return nil
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
    if mark_workspace_attention then
      mark_workspace_attention(ctx, {
        command = command,
        message = message,
        reason = reason,
      })
    end
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
    local timer = (vim.loop or vim.uv).new_timer()
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

  local agent_command_started

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
    if byte == 21 then
      state.input = ""
      return
    end
    if byte == 23 then
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

  local function desired_agent_cols()
    local cols = tonumber(cfg.agent_term_cols)
    if cols and cols > 0 then
      return math.max(1, math.floor(cols))
    end
    return nil
  end

  local function agent_window_height(buf)
    local wins = fn.win_findbuf(buf)
    for _, win in ipairs(wins) do
      if vim.api.nvim_win_is_valid(win) then
        local ok_height, height = pcall(vim.api.nvim_win_get_height, win)
        if ok_height and type(height) == "number" and height > 0 then
          return height
        end
      end
    end
    local fallback = tonumber(vim.o.lines) or 0
    if fallback <= 0 then
      fallback = 40
    end
    return fallback
  end

  local function enforce_agent_job_size(buf)
    local cols = desired_agent_cols()
    if not cols then
      return
    end
    local job = agent_term_job(buf)
    if not job then
      return
    end
    local height = agent_window_height(buf)
    if height < 2 then
      height = 2
    end
    local previous = nil
    if vim.api.nvim_buf_is_valid(buf) then
      local ok_prev, stored = pcall(function()
        return vim.b[buf].jjws_agent_term_size
      end)
      if ok_prev then
        previous = stored
      end
    end
    if previous and previous.cols == cols and previous.height == height then
      return
    end
    pcall(fn.jobresize, job, cols, height)
    if vim.api.nvim_buf_is_valid(buf) then
      vim.b[buf].jjws_agent_term_size = { cols = cols, height = height }
      vim.b[buf].jjws_agent_term_cols = cols
    end
  end

  local function enforce_all_agent_sizes()
    for buf in pairs(agent_autocmds) do
      if vim.api.nvim_buf_is_valid(buf) then
        enforce_agent_job_size(buf)
      end
    end
  end

  local agent_term_size_group = vim.api.nvim_create_augroup("JJWSAgentTermSize", { clear = true })
  vim.api.nvim_create_autocmd("VimResized", {
    group = agent_term_size_group,
    callback = function()
      if not desired_agent_cols() then
        return
      end
      enforce_all_agent_sizes()
    end,
  })

  local function agent_send_escape(buf)
    local job = agent_term_job(buf)
    if not job then
      return false
    end
    pcall(vim.fn.chansend, job, "\27")
    return true
  end

  local function is_agent_buffer(buf)
    if not buf or not vim.api.nvim_buf_is_valid(buf) then
      return false
    end
    local ok, flag = pcall(vim.api.nvim_buf_get_var, buf, "jjws_agent")
    return ok and flag and true or false
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

  local function agent_abbrev_target(cmd)
    local ok_type, cmdtype = pcall(vim.fn.getcmdtype)
    if not ok_type or cmdtype ~= ":" then
      return cmd
    end
    local ok_line, line = pcall(vim.fn.getcmdline)
    if not ok_line then
      return cmd
    end
    local pattern = string.format("^%s!?%s$", cmd, "%s*")
    if not line:match(pattern) then
      return cmd
    end
    if not is_agent_buffer(vim.api.nvim_get_current_buf()) then
      return cmd
    end
    return "JJWSAgentHide"
  end

  local function attach_agent_autocmds(buf)
    if type(buf) ~= "number" or buf <= 0 or not vim.api.nvim_buf_is_valid(buf) or agent_autocmds[buf] then
      return
    end
    local group = vim.api.nvim_create_augroup("JJWSAgent" .. buf, { clear = true })
    local function maybe_startinsert()
      if not vim.api.nvim_buf_is_valid(buf) then
        return
      end
      if vim.api.nvim_buf_get_option(buf, "buftype") ~= "terminal" then
        return
      end
      local ok, is_agent = pcall(vim.api.nvim_buf_get_var, buf, "jjws_agent")
      if not ok or not is_agent then
        return
      end
      apply_agent_keymaps(buf)
      enforce_agent_job_size(buf)
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(buf) then
          pcall(vim.cmd, "startinsert")
        end
      end)
    end
    vim.api.nvim_create_autocmd({ "BufEnter", "WinEnter", "TermEnter" }, {
      group = group,
      buffer = buf,
      callback = maybe_startinsert,
    })
    vim.api.nvim_create_autocmd("TermLeave", {
      group = group,
      buffer = buf,
      callback = function()
        reset_agent_key_buffer(buf)
      end,
    })
    vim.api.nvim_create_autocmd("BufHidden", {
      group = group,
      buffer = buf,
      callback = function()
        local wins = vim.fn.win_findbuf(buf)
        for _, win in ipairs(wins) do
          if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) ~= buf then
            pcall(vim.api.nvim_win_close, win, true)
          end
        end
      end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
      group = group,
      buffer = buf,
      callback = function()
        stop_agent_key_capture(buf)
        stop_agent_output_watch(buf)
        local ok_key, buf_key = pcall(function()
          return vim.b[buf].jjws_workspace_key
        end)
        if ok_key and buf_key then
          agent_buffers[buf_key] = nil
        end
        agent_autocmds[buf] = nil
      end,
    })
    vim.api.nvim_create_autocmd("BufDelete", {
      group = group,
      buffer = buf,
      callback = function()
        stop_agent_key_capture(buf)
        stop_agent_output_watch(buf)
        local ok_key, key = pcall(function()
          return vim.b[buf].jjws_workspace_key
        end)
        if ok_key and key then
          agent_buffers[key] = nil
          local session = nil
          local ok_session, stored = pcall(function()
            return vim.b[buf].jjws_codex_session
          end)
          if ok_session and type(stored) == "string" and stored ~= "" then
            session = stored
            pending_agent_sessions[key] = stored
          end
          local wins = vim.fn.win_findbuf(buf)
          vim.schedule(function()
            for _, win in ipairs(wins) do
              if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) ~= buf then
                pcall(vim.api.nvim_win_close, win, true)
              end
            end
          end)
          local ctx = active_workspace() or (current_workspace and current_workspace())
          local ctx = active_workspace() or (current_workspace and current_workspace())
          if ctx and workspace_key(ctx) == key and session then
            vim.schedule(function()
              open_agent({
                session_id = session,
                force_new = true,
                ignore_guard = true,
                visible = false,
                workspace = ctx,
              })
            end)
          end
        end
      end,
    })
    vim.api.nvim_create_autocmd("TermClose", {
      group = group,
      buffer = buf,
      callback = function()
        stop_agent_key_capture(buf)
        stop_agent_output_watch(buf)
        local ok_key, key = pcall(function()
          return vim.b[buf].jjws_workspace_key
        end)
        if ok_key and key then
          pending_agent_sessions[key] = nil
          agent_buffers[key] = nil
        end
      end,
    })
    agent_autocmds[buf] = group
  end

  local function create_agent_split(size_override, position_override)
    local size = size_override or cfg.agent_size or cfg.agent_height or 40
    local position = position_override or cfg.agent_position
    if not position or position == "" then
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
    return win
  end

  local function focus_agent_window(buf)
    if not (buf and vim.api.nvim_buf_is_valid(buf)) then
      return false
    end
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
        vim.api.nvim_set_current_win(win)
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

  local function place_agent_buffer(buf, key, size_override)
    local win = create_agent_split(size_override or (key and agent_sizes[key]))
    vim.api.nvim_win_set_buf(win, buf)
    pcall(vim.api.nvim_buf_set_option, buf, "buflisted", false)
    pcall(vim.api.nvim_buf_set_option, buf, "bufhidden", "hide")
    pcall(vim.api.nvim_buf_set_option, buf, "swapfile", false)
    attach_agent_autocmds(buf)
    pcall(vim.cmd, "startinsert")
    remember_agent_size(key, win)
    return buf
  end

  local function workspace_agent_state(ctx)
    local target_key = workspace_key(ctx)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_option(buf, "buftype") == "terminal" then
        local ok, is_agent = pcall(vim.api.nvim_buf_get_var, buf, "jjws_agent")
        if ok and is_agent then
          local ok_key, buf_key = pcall(function()
            return vim.b[buf].jjws_workspace_key
          end)
          if target_key and buf_key ~= target_key then
            goto continue
          end
          local session = nil
          local ok_session, session_id = pcall(function()
            return vim.b[buf].jjws_codex_session
          end)
          if ok_session and type(session_id) == "string" and session_id ~= "" then
            session = session_id
          end
          agent_buffers[buf_key or target_key or buf] = buf
          return {
            open = true,
            session = session,
            buf = buf,
          }
        end
      end
      ::continue::
    end
    return { open = false }
  end

  local function format_session_command(cmd, session_id)
    if not cmd or not session_id or session_id == "" then
      return nil
    end
    local placeholder_literal = "%s"
    local placeholder_pattern = "%%s"
    if type(cmd) == "string" then
      if cmd:find(placeholder_literal, 1, true) then
        return cmd:gsub(placeholder_pattern, session_id)
      end
      return cmd .. " " .. session_id
    elseif type(cmd) == "table" then
      local out = {}
      local replaced = false
      for i, part in ipairs(cmd) do
        if type(part) == "string" and part:find(placeholder_literal, 1, true) then
          out[i] = part:gsub(placeholder_pattern, session_id)
          replaced = true
        else
          out[i] = part
        end
      end
      if not replaced then
        table.insert(out, session_id)
      end
      return out
    end
    return nil
  end

  local function is_codex_command(cmd)
    if type(cmd) == "string" then
      return cmd:find("codex", 1, true) ~= nil
    elseif type(cmd) == "table" then
      for _, part in ipairs(cmd) do
        if type(part) == "string" and part:find("codex", 1, true) then
          return true
        end
      end
    end
    return false
  end

  local function shellescape_path(path)
    if path and path ~= "" then
      local ok, escaped = pcall(fn.shellescape, path)
      if ok and escaped and escaped ~= "" then
        return escaped
      end
    end
    return "$(pwd)"
  end

  local function codex_cd_flag(cwd)
    return "--cd " .. shellescape_path(cwd)
  end

  local function build_codex_resume_command(session_id, agent_cmd, cwd)
    if not session_id or session_id == "" then
      return nil
    end
    local cmd = agent_cmd or cfg.agent_cmd
    local cd_flag = codex_cd_flag(cwd)
    if type(cmd) == "table" and cmd[1] == "bash" and cmd[2] == "-lc" then
      return format_session_command({ "bash", "-lc", string.format("codex %s --search resume %%s", cd_flag) }, session_id)
    end
    local cd_arg = cwd or fn.getcwd()
    return format_session_command({ "codex", "--cd", cd_arg, "--search", "resume", "%s" }, session_id)
  end

  local function resolved_agent_type()
    local t = cfg.agent_type
    if type(t) == "string" then
      local normalized = trim(t):lower()
      if normalized ~= "" then
        return normalized
      end
    end
    if cfg.agent_cmd and is_codex_command(cfg.agent_cmd) then
      return "codex"
    end
    return nil
  end

  local function is_codex_agent()
    return resolved_agent_type() == "codex"
  end

  local function resolved_agent_cmd(cwd)
    local cmd = cfg.agent_cmd
    if type(cmd) == "function" then
      local ok, result = pcall(cmd)
      if not ok then
        notify("agent_cmd callback failed: " .. result, vim.log.levels.ERROR)
        return nil
      end
      cmd = result
    end
    if cmd then
      return clone_cmd(cmd)
    end
    local agent_type = resolved_agent_type() or "codex"
    if agent_type == "codex" then
      local cd_flag = codex_cd_flag(cwd)
      return { "bash", "-lc", string.format("codex %s --search", cd_flag) }
    end
    return nil
  end

  local function resolved_agent_session_cmd(cwd)
    local cmd = cfg.agent_session_cmd
    if type(cmd) == "function" then
      local ok, result = pcall(cmd)
      if not ok then
        notify("agent_session_cmd callback failed: " .. result, vim.log.levels.ERROR)
        return nil
      end
      cmd = result
    end
    if cmd then
      return clone_cmd(cmd)
    end
    if is_codex_agent() then
      local cd_flag = codex_cd_flag(cwd)
      return { "bash", "-lc", string.format([[codex %s --search exec "say ready"]], cd_flag) }
    end
    return nil
  end

  local function build_resume_command(session_id, base_cmd, cwd)
    if not session_id or session_id == "" then
      return nil
    end
    if cfg.agent_resume_cmd then
      if type(cfg.agent_resume_cmd) == "function" then
        local ok, result = pcall(cfg.agent_resume_cmd, session_id, base_cmd)
        if not ok then
          notify("agent_resume_cmd failed: " .. result, vim.log.levels.ERROR)
          return nil
        end
        return result
      end
      return format_session_command(cfg.agent_resume_cmd, session_id)
    end
    if is_codex_agent() then
      return build_codex_resume_command(session_id, base_cmd, cwd)
    end
    return nil
  end

  local function create_codex_session(cwd, launcher_cmd)
    if not vim.system then
      return nil, "vim.system unavailable"
    end

    local output_chunks = {}
    local session_id = nil

    local launcher = normalize_system_cmd(launcher_cmd)
    if not launcher or not launcher[1] then
      launcher = { "bash", "-lc", [[codex exec "say ready"]] }
    end

    local job = vim.system(launcher, {
      cwd = cwd,
      text = true,
      pty = false,
      env = { TERM = "xterm-256color" },
      stdout = function(_, data)
        if not data or data == "" then
          return
        end
        data = strip_ansi(data)
        table.insert(output_chunks, data)
        local found = data:match("codex resume%s+([%w%-]+)") or data:match("session id:%s*([%w%-]+)")
        if found and found ~= "" then
          session_id = found
        end
      end,
      stderr = function(_, data)
        if not data or data == "" then
          return
        end
        data = strip_ansi(data)
        table.insert(output_chunks, data)
        local found = data:match("codex resume%s+([%w%-]+)") or data:match("session id:%s*([%w%-]+)")
        if found and found ~= "" then
          session_id = found
        end
      end,
    })

    local result = job:wait(10000)
    if not result then
      pcall(job.kill, job, uv.constants.SIGTERM)
      return nil, "timed out creating codex session"
    end

    local text = table.concat(output_chunks)
    if (not session_id or session_id == "") then
      local fallback = text:match("codex resume%s+([%w%-]+)")
      if fallback and fallback ~= "" then
        session_id = fallback
      else
        local explicit = text:match("session id:%s*([%w%-]+)")
        if explicit and explicit ~= "" then
          session_id = explicit
        end
      end
    end

    if result.code ~= 0 and not session_id then
      local text_snippet = strip_ansi(text):gsub("\n+", " ")
      if #text_snippet > 160 then
        text_snippet = text_snippet:sub(1, 157) .. "..."
      end
      local msg = string.format("codex exited with code %d (output: %s)", result.code, text_snippet)
      local f = io.open("/tmp/jjws-last-err.txt", "w")
      if f then
        f:write(msg .. "\n")
        f:close()
      end
      return nil, msg
    end

    if session_id and session_id ~= "" then
      return session_id, nil
    end

    local text_snippet = strip_ansi(text):gsub("\n+", " ")
    if #text_snippet > 160 then
      text_snippet = text_snippet:sub(1, 157) .. "..."
    end
    local msg = "failed to capture codex session id (output: " .. text_snippet .. ")"
    local f = io.open("/tmp/jjws-last-err.txt", "w")
    if f then
      f:write(msg .. "\n")
      f:close()
    end
    return nil, msg
  end

  local revive_agent_buffer

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
    opts = opts or {}
    local ctx = opts.workspace or active_workspace() or (current_workspace and current_workspace())
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
    local base_cmd = resolved_agent_cmd(cwd)
    if not base_cmd then
      notify("configure jjws.agent_cmd or jjws.agent_type", vim.log.levels.ERROR)
      return nil
    end
    local term_cmd = base_cmd
    if session_id and session_id ~= "" then
      local resume_cmd = build_resume_command(session_id, base_cmd, cwd)
        if resume_cmd then
          term_cmd = resume_cmd
        end
    elseif is_codex_agent() then
      local session_cmd = resolved_agent_session_cmd(cwd)
      local session, err = create_codex_session(cwd, session_cmd)
      if session then
        session_id = session
        local resume_cmd = build_resume_command(session_id, base_cmd, cwd)
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
      enforce_agent_job_size(buf)
    end
    if session_id and session_id ~= "" then
      vim.b[buf].jjws_codex_session = session_id
    else
      vim.b[buf].jjws_codex_session = nil
    end

    if key then
      remember_agent_size(key, win)
    end
    if ctx and save_workspace_layout then
      save_workspace_layout(ctx)
    end

    return buf
  end

  return {
    open = open_agent,
    hide = hide_agent_buffer,
    is_agent_buffer = is_agent_buffer,
    attach_autocmds = attach_agent_autocmds,
    buffers = agent_buffers,
    sizes = agent_sizes,
    workspace_state = workspace_agent_state,
    revive = revive_agent_buffer,
    remember_size = remember_agent_size,
    window_size = agent_window_size,
    abbrev_target = agent_abbrev_target,
  }
end

return Agent
