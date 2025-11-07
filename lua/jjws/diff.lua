local M = {}

function M.setup(env)
  local cfg = env.cfg
  local notify = env.notify
  local trim = env.trim
  local strip_ansi = env.strip_ansi
  local is_valid_buf = env.is_valid_buf
  local is_valid_win = env.is_valid_win
  local workspace_key = env.workspace_key
  local current_workspace = env.current_workspace
  local get_active_workspace = env.get_active_workspace
  local open_agent = env.open_agent
  local agent_buffers = env.agent_buffers
  local attach_agent_autocmds = env.attach_agent_autocmds

  local state = {
    buf = nil,
    win = nil,
    chan = nil,
  }

  local function reset_state()
    state.buf = nil
    state.win = nil
    state.chan = nil
  end

  local function configure_diff_window(win)
    if not is_valid_win(win) then
      return
    end
    pcall(vim.api.nvim_win_set_option, win, "wrap", false)
    pcall(vim.api.nvim_win_set_option, win, "signcolumn", "no")
    pcall(vim.api.nvim_win_set_option, win, "number", false)
    pcall(vim.api.nvim_win_set_option, win, "relativenumber", false)
    pcall(vim.api.nvim_win_set_option, win, "foldcolumn", "0")
    pcall(vim.api.nvim_win_set_option, win, "winhighlight", "Normal:Normal,FloatBorder:Normal")
  end

  local function diff_split_command()
    local position = (cfg.diff_position or "right"):lower()
    local size = cfg.diff_size
    if position == "left" then
      if size then
        return string.format("topleft %d vsplit", size)
      end
      return "topleft vsplit"
    elseif position == "top" then
      if size then
        return string.format("topleft %d split", size)
      end
      return "topleft split"
    elseif position == "bottom" then
      if size then
        return string.format("botright %d split", size)
      end
      return "botright split"
    end
    if size then
      return string.format("botright %d vsplit", size)
    end
    return "botright vsplit"
  end

  local function ensure_diff_window()
    if is_valid_win(state.win) then
      return state.win
    end
    vim.cmd(diff_split_command())
    local win = vim.api.nvim_get_current_win()
    configure_diff_window(win)
    state.win = win
    return win
  end

  local diff_refresh
  local diff_comment

  local function attach_diff_keymaps(buf)
    local refresh_key = cfg.diff_refresh_keymap or "gr"
    local comment_key = cfg.diff_comment_keymap or "gc"
    vim.keymap.set("n", refresh_key, function()
      diff_refresh()
    end, { buffer = buf, silent = true, desc = "Refresh jj difftastic diff" })
    vim.keymap.set("n", comment_key, function()
      diff_comment({ mode = "line" })
    end, { buffer = buf, silent = true, desc = "Comment on current diff line" })
    vim.keymap.set("v", comment_key, function()
      diff_comment({ mode = "visual" })
    end, { buffer = buf, silent = true, desc = "Comment on selected diff lines" })
  end

  local function ensure_diff_buffer()
    local win = ensure_diff_window()
    if not is_valid_buf(state.buf) then
      local buf = vim.api.nvim_create_buf(false, true)
      vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
      vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
      vim.api.nvim_buf_set_option(buf, "swapfile", false)
      vim.api.nvim_buf_set_option(buf, "modifiable", false)
      vim.api.nvim_buf_set_option(buf, "filetype", "jjwsdiff")
      vim.api.nvim_win_set_buf(win, buf)
      local chan = vim.api.nvim_open_term(buf, {})
      state.buf = buf
      state.chan = chan
      attach_diff_keymaps(buf)
      vim.api.nvim_buf_set_var(buf, "jjws_diff_buffer", true)
      vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buf,
        callback = function()
          reset_state()
        end,
      })
    elseif vim.api.nvim_win_get_buf(win) ~= state.buf then
      vim.api.nvim_win_set_buf(win, state.buf)
    end
    configure_diff_window(win)
    return state.buf, state.chan, win
  end

  local function active_workspace()
    if get_active_workspace then
      return get_active_workspace()
    end
    return nil
  end

  local function current_or_active_workspace()
    return active_workspace() or current_workspace()
  end

  local function find_agent_terminal()
    local ctx = current_or_active_workspace()
    local target_key = workspace_key(ctx)
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) then
        local ok, is_agent = pcall(vim.api.nvim_buf_get_var, buf, "jjws_agent")
        if ok and is_agent then
          local ok_key, buf_key = pcall(function()
            return vim.b[buf].jjws_workspace_key
          end)
          if target_key and buf_key ~= target_key then
            goto continue
          end
          local job = nil
          local ok_job, stored = pcall(vim.api.nvim_buf_get_var, buf, "jjws_agent_job")
          if ok_job and type(stored) == "number" then
            job = stored
          else
            local term_ok, term_job = pcall(vim.api.nvim_buf_get_var, buf, "terminal_job_id")
            if term_ok and type(term_job) == "number" then
              job = term_job
            else
              local fallback = vim.fn.getbufvar(buf, "terminal_job_id", 0)
              if type(fallback) == "number" and fallback > 0 then
                job = fallback
              end
            end
          end
          if job then
            if ok_key and buf_key then
              agent_buffers[buf_key] = buf
            end
            attach_agent_autocmds(buf)
            return buf, job
          end
        end
      end
      ::continue::
    end
    return nil, nil
  end

  local function ensure_agent_channel()
    local buf, job = find_agent_terminal()
    if job then
      return buf, job
    end
    local prev_win = vim.api.nvim_get_current_win()
    local new_buf = open_agent()
    if not new_buf then
      return nil, nil
    end
    if prev_win and vim.api.nvim_win_is_valid(prev_win) then
      vim.api.nvim_set_current_win(prev_win)
    end
    return find_agent_terminal()
  end

  local function diff_header_for_line(buf, line_nr)
    for idx = line_nr, 1, -1 do
      local line = vim.api.nvim_buf_get_lines(buf, idx - 1, idx, false)[1]
      if not line then
        break
      end
      line = strip_ansi(line)
      local path = line:match("^%+%+%+%s+(.+)$") or line:match("^%-%-%-%s+(.+)$")
      if path and path ~= "" then
        return path
      end
      local a, b = line:match("^diff%s+%-%-git%s+a/(%S+)%s+b/(%S+)")
      if a and b then
        return b
      end
      local dt = line:match("^Path:%s+(.+)$")
      if dt and dt ~= "" then
        return dt
      end
    end
    return nil
  end

  local function normalize_diff_command(cmd, ctx)
    local value = cmd
    if type(value) == "function" then
      value = value(ctx)
    end
    if type(value) == "string" then
      value = trim(value)
      if value == "" then
        return nil
      end
      return { "bash", "-lc", value }
    elseif type(value) == "table" then
      if vim.tbl_isempty(value) then
        return nil
      end
      return value
    end
    return nil
  end

  local function render_diff_output(chan, output)
    if type(chan) ~= "number" or chan <= 0 then
      return false
    end
    vim.api.nvim_chan_send(chan, "\27[2J\27[H")
    vim.api.nvim_chan_send(chan, output)
    return true
  end

  diff_refresh = function(opts)
    opts = opts or {}
    local ctx = current_or_active_workspace()
    if not ctx or not ctx.root then
      notify("open a JJ workspace before showing diffs", vim.log.levels.WARN)
      return
    end
    local command = normalize_diff_command(cfg.diff_command, ctx)
    if not command then
      notify("diff command is not configured", vim.log.levels.ERROR)
      return
    end
    local prev_win = vim.api.nvim_get_current_win()
    local ok, res = pcall(function()
      return vim.system(command, { cwd = ctx.root, text = false }):wait()
    end)
    if not ok or not res then
      notify("failed to run difftastic: " .. tostring(res), vim.log.levels.ERROR)
      return
    end
    local code = res.code or 0
    if code ~= 0 and code ~= 1 then
      notify(string.format("diff command exited with code %d", code), vim.log.levels.WARN)
    end
    local stdout = res.stdout or ""
    local stderr = res.stderr or ""
    local output = stdout
    if output == "" then
      output = stderr
    elseif stderr ~= "" then
      output = output .. "\n" .. stderr
    end
    if output == "" then
      output = "No changes (jj diff clean).\n"
    end
    if output:sub(-1) ~= "\n" then
      output = output .. "\n"
    end
    local buf, chan, win = ensure_diff_buffer()
    if not buf or type(chan) ~= "number" or chan <= 0 then
      notify("unable to initialise diff buffer", vim.log.levels.ERROR)
      return
    end
    render_diff_output(chan, output)
    if opts.focus == false then
      if prev_win and vim.api.nvim_win_is_valid(prev_win) then
        vim.api.nvim_set_current_win(prev_win)
      end
    else
      if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_set_current_win(win)
      end
    end
  end

  local function gather_diff_selection(buf, win, opts)
    local mode = opts.mode or "line"
    local start_line
    local end_line
    if mode == "visual" then
      local start_pos = vim.fn.getpos("'<")
      local end_pos = vim.fn.getpos("'>")
      start_line = math.min(start_pos[2], end_pos[2])
      end_line = math.max(start_pos[2], end_pos[2])
      local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
      vim.api.nvim_feedkeys(esc, "nx", false)
    else
      local cursor = vim.api.nvim_win_get_cursor(win)
      start_line = cursor[1]
      end_line = cursor[1]
    end
    if not start_line or not end_line then
      return nil
    end
    if start_line > end_line then
      start_line, end_line = end_line, start_line
    end
    local lines = vim.api.nvim_buf_get_lines(buf, start_line - 1, end_line, false)
    if not lines or #lines == 0 then
      return nil
    end
    return {
      start_line = start_line,
      end_line = end_line,
      lines = lines,
    }
  end

  local function format_diff_comment(ctx, file_hint, selection, comment)
    local prefix = cfg.diff_comment_prefix or "[JJDiff]"
    local workspace_label
    if ctx.repo and ctx.name then
      workspace_label = string.format("%s/%s", ctx.repo, ctx.name)
    else
      workspace_label = ctx.name or (ctx.root or "workspace")
    end
    local location = workspace_label
    if file_hint and file_hint ~= "" then
      location = location .. " · " .. file_hint
    end
    local header = string.format("%s %s (lines %d-%d)", prefix, location, selection.start_line, selection.end_line)
    local sanitized = {}
    for _, line in ipairs(selection.lines) do
      local clean = strip_ansi(line or "")
      if clean == "" then
        clean = " "
      end
      table.insert(sanitized, "> " .. clean)
    end
    local body = trim(comment)
    local parts = { header, body }
    if #sanitized > 0 then
      table.insert(parts, table.concat(sanitized, "\n"))
    end
    return table.concat(parts, "\n") .. "\n"
  end

  diff_comment = function(opts)
    opts = opts or {}
    if not is_valid_buf(state.buf) then
      notify("open a JJ diff buffer before adding comments", vim.log.levels.WARN)
      return
    end
    local win = state.win
    if not is_valid_win(win) or vim.api.nvim_win_get_buf(win) ~= state.buf then
      win = vim.api.nvim_get_current_win()
    end
    local selection = gather_diff_selection(state.buf, win, opts)
    if not selection then
      notify("select diff lines to comment on", vim.log.levels.WARN)
      return
    end
    local ctx = current_or_active_workspace()
    if not ctx then
      notify("open a JJ workspace before adding comments", vim.log.levels.WARN)
      return
    end
    local file_hint = diff_header_for_line(state.buf, selection.start_line)
    vim.ui.input({ prompt = "Diff comment: " }, function(input)
      if not input or trim(input) == "" then
        notify("diff comment cancelled", vim.log.levels.INFO)
        return
      end
      local payload = format_diff_comment(ctx, file_hint, selection, input)
      local _, job = ensure_agent_channel()
      if not job then
        notify("agent terminal is not available", vim.log.levels.ERROR)
        return
      end
      local ok_send, err = pcall(vim.api.nvim_chan_send, job, payload)
      if not ok_send then
        notify("failed to send comment to agent: " .. err, vim.log.levels.ERROR)
        return
      end
      notify("diff comment sent to agent", vim.log.levels.INFO)
      if state.win and vim.api.nvim_win_is_valid(state.win) then
        vim.api.nvim_set_current_win(state.win)
      end
    end)
  end

  return {
    refresh = diff_refresh,
    comment = diff_comment,
    reset = reset_state,
    state = state,
  }
end

return M
