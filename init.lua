-- lua/jjws/init.lua
local M = {}

local open_agent
local diff_refresh
local diff_comment

local diff_state = {
  buf = nil,
  win = nil,
  chan = nil,
}

local function reset_diff_state()
  diff_state.buf = nil
  diff_state.win = nil
  diff_state.chan = nil
end

local function trim(s)
  if not s then
    return ""
  end
  if vim.trim then
    return vim.trim(s)
  end
  return vim.fn.trim(s)
end

local function joinpath(parent, child)
  local fs = vim.fs
  if fs and fs.joinpath then
    return fs.joinpath(parent, child)
  end
  local sep = package.config:sub(1, 1)
  if parent:sub(-1) == sep then
    return parent .. child
  end
  return parent .. sep .. child
end

local function workspace_root_from_jj(cwd)
  local ok, res = pcall(function()
    return vim.system({ "bash", "-lc", "jj workspace root" }, { text = true, cwd = cwd or vim.fn.getcwd() }):wait()
  end)

  if not ok then
    return nil
  end

  if res.code ~= 0 then
    return nil
  end

  local root = trim(res.stdout)
  return root ~= "" and root or nil
end

local config_cache = nil

local function config_path()
  return vim.fn.stdpath("state") .. "/jjws_config.json"
end

local function ensure_config_loaded()
  if config_cache then
    return
  end
  config_cache = {}
  local path = config_path()
  local f = io.open(path, "r")
  if not f then
    return
  end
  local ok, data = pcall(vim.json.decode, f:read("*a"))
  f:close()
  if ok and type(data) == "table" then
    config_cache = data
  end
end

local function notify(msg, level)
  vim.notify("[jjws] " .. msg, level or vim.log.levels.INFO)
end

local function save_config()
  ensure_config_loaded()
  local path = config_path()
  local dir = vim.fn.fnamemodify(path, ":h")
  vim.fn.mkdir(dir, "p")
  local f, err = io.open(path, "w")
  if not f then
    notify("failed to open config: " .. (err or "unknown error"), vim.log.levels.ERROR)
    return false
  end
  local ok, encoded = pcall(vim.json.encode, config_cache)
  if not ok then
    notify("failed to encode config: " .. encoded, vim.log.levels.ERROR)
    f:close()
    return false
  end
  f:write(encoded)
  f:close()
  return true
end

local function workspace_config()
  ensure_config_loaded()
  return config_cache
end

local META_KEY = "__meta"

local function canonical_path(path)
  if not path or path == "" then
    return nil
  end
  local uv = vim.uv or vim.loop
  local real = uv.fs_realpath(path)
  if real and real ~= "" then
    return real
  end
  local abs = vim.fn.fnamemodify(path, ":p")
  if not abs or abs == "" then
    return nil
  end
  local sep = package.config:sub(1, 1)
  if abs ~= sep then
    abs = abs:gsub(sep .. "+$", "")
    if abs == "" then
      abs = sep
    end
  end
  return abs
end

local function parent_dir(path)
  return vim.fn.fnamemodify(path, ":h")
end

local function read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

local function repo_entry(repo, create)
  if not repo or repo == "" then
    return nil
  end
  local cfg = workspace_config()
  if create and not cfg[repo] then
    cfg[repo] = {}
  end
  return cfg[repo]
end

local function find_repo_by_path(repo_path)
  if not repo_path then
    return nil
  end
  local target = canonical_path(repo_path)
  if not target then
    return nil
  end
  for name, cfg in pairs(workspace_config()) do
    if type(cfg) == "table" then
      local meta = cfg[META_KEY]
      if meta and meta.repo_path and canonical_path(meta.repo_path) == target then
        return name
      end
    end
  end
  return nil
end

local function find_repo_by_workspace_path(path)
  local target = canonical_path(path)
  if not target then
    return nil
  end
  for name, cfg in pairs(workspace_config()) do
    if type(cfg) == "table" then
      for key, info in pairs(cfg) do
        if key ~= META_KEY and info and info.path then
          local stored = canonical_path(info.path) or trim(info.path)
          if stored == target then
            return name
          end
        end
      end
    end
  end
  return nil
end

local function ensure_repo_meta(repo, repo_path)
  if not repo or repo == "" then
    return nil
  end
  local entry = repo_entry(repo, true)
  entry[META_KEY] = entry[META_KEY] or {}
  if repo_path and repo_path ~= "" then
    entry[META_KEY].repo_path = canonical_path(repo_path)
  end
  return entry[META_KEY]
end

local function repo_storage_path(root)
  if not root or root == "" then
    return nil
  end
  local spec = joinpath(root, ".jj/repo")
  local uv = vim.uv or vim.loop
  local st = uv.fs_stat(spec)
  if not st then
    return nil
  end
  if st.type == "file" then
    local target = trim(read_file(spec) or "")
    if target ~= "" then
      return canonical_path(target)
    end
    return nil
  end
  return canonical_path(spec)
end

local function repo_default_root(repo_path)
  if not repo_path then
    return nil
  end
  local root = vim.fn.fnamemodify(repo_path, ":h:h")
  if root and root ~= "" then
    return canonical_path(root)
  end
  return nil
end

local function repo_from_root(root)
  if not root or root == "" then
    return nil
  end
  local repo_path = repo_storage_path(root)
  if repo_path then
    local existing = find_repo_by_path(repo_path)
    if existing then
      return existing
    end
    local workspace_match = find_repo_by_workspace_path(root)
    if workspace_match then
      ensure_repo_meta(workspace_match, repo_path)
      return workspace_match
    end
    local default_name = vim.fn.fnamemodify(repo_path, ":h:h:t")
    if default_name and default_name ~= "" then
      return default_name
    end
  end
  return vim.fn.fnamemodify(root, ":t")
end

local function find_workspace(repo, path)
  local cfg = workspace_config()[repo]
  if not cfg then
    return nil
  end
  local target = canonical_path(path) or trim(path)
  for name, info in pairs(cfg) do
    if name ~= META_KEY and info then
      local stored = canonical_path(info.path or "") or trim(info.path)
      if stored == target then
        return name, info
      end
    end
  end
  return nil
end

local function current_workspace()
  local root = workspace_root_from_jj()
  if not root then
    return nil
  end
  local canonical_root = canonical_path(root) or root
  local repo_path = repo_storage_path(canonical_root)
  local repo = repo_from_root(canonical_root)
  local default_root = repo_default_root(repo_path)
  local name, info = find_workspace(repo, canonical_root)
  if not name then
    local workspace_name = vim.fn.fnamemodify(canonical_root, ":t")
    if default_root and canonical_root == default_root then
      name = "default"
    else
      name = workspace_name ~= "" and workspace_name or "default"
    end
    info = { path = canonical_root }
  end
  return {
    root = canonical_root,
    repo = repo,
    repo_path = repo_path,
    name = name,
    info = info,
    default_root = default_root,
    raw_root = root,
    workspace_name = vim.fn.fnamemodify(canonical_root, ":t"),
  }
end

local function update_workspace(repo, name, path, repo_path)
  if not repo or repo == "" or not name or name == "" or not path or path == "" then
    return
  end
  local entry = repo_entry(repo, true)
  ensure_repo_meta(repo, repo_path)
  entry[name] = { path = canonical_path(path) or path }
  save_config()
end

local function delete_workspace(repo, name)
  local entry = repo_entry(repo)
  if not entry then
    return
  end
  entry[name] = nil
  local has_any = false
  for key, value in pairs(entry) do
    if key ~= META_KEY and value ~= nil then
      has_any = true
      break
    end
  end
  if not has_any then
    workspace_config()[repo] = nil
  end
  save_config()
end

local function repo_any_path(repo)
  local entry = repo_entry(repo)
  if not entry then
    return nil
  end
  local default = entry.default
  if default and default.path then
    return default.path
  end
  for key, info in pairs(entry) do
    if key ~= META_KEY and info and info.path then
      return info.path
    end
  end
  local meta = entry[META_KEY]
  if meta and meta.repo_path then
    return repo_default_root(meta.repo_path)
  end
  return nil
end

local function workspace_layout_path(repo_path, workspace_name, workspace_root)
  if not workspace_name or workspace_name == "" then
    return nil
  end
  local base = canonical_path(repo_path) or canonical_path(workspace_root)
  if not base or base == "" then
    base = workspace_name
  end
  local key = base .. "::" .. workspace_name
  return vim.fn.stdpath("state") .. "/jjws_layout_" .. vim.fn.sha256(key) .. ".json"
end

local function collect_normal_buffers()
  local files = {}
  local seen = {}
  local current_file = nil
  local curbuf = vim.api.nvim_get_current_buf()
  if vim.api.nvim_buf_is_loaded(curbuf) and vim.api.nvim_buf_get_option(curbuf, "buftype") == "" then
    local name = vim.api.nvim_buf_get_name(curbuf)
    if name ~= "" then
      local path = canonical_path(name)
      if path and path ~= "" then
        current_file = path
      end
    end
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_option(buf, "buftype") == "" then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" then
        local path = canonical_path(name)
        if path and path ~= "" and not seen[path] and (vim.loop.fs_stat(path) ~= nil) then
          table.insert(files, path)
          seen[path] = true
        end
      end
    end
  end
  return files, current_file
end

local function workspace_agent_state()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_option(buf, "buftype") == "terminal" then
      local ok, is_agent = pcall(vim.api.nvim_buf_get_var, buf, "jjws_agent")
      if ok and is_agent then
        local session = nil
        local ok_session, session_id = pcall(function()
          return vim.b[buf].jjws_codex_session
        end)
        if ok_session and type(session_id) == "string" and session_id ~= "" then
          session = session_id
        end
        return {
          open = true,
          session = session,
        }
      end
    end
  end
  return { open = false }
end

local function strip_ansi(text)
  if not text or text == "" then
    return text
  end
  return text:gsub("\27%[[%d;]*m", "")
end

local function is_valid_buf(buf)
  return type(buf) == "number" and buf > 0 and vim.api.nvim_buf_is_valid(buf)
end

local function is_valid_win(win)
  return type(win) == "number" and win > 0 and vim.api.nvim_win_is_valid(win)
end

local function configure_diff_window(win)
  if not is_valid_win(win) then
    return
  end
  pcall(vim.api.nvim_win_set_option, win, "wrap", false)
  pcall(vim.api.nvim_win_set_option, win, "signcolumn", "no")
  pcall(vim.api.nvim_win_set_option, win, "number", false)
  pcall(vim.api.nvim_win_set_option, win, "relativenumber", false)
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
  if is_valid_win(diff_state.win) then
    return diff_state.win
  end
  vim.cmd(diff_split_command())
  local win = vim.api.nvim_get_current_win()
  configure_diff_window(win)
  diff_state.win = win
  return win
end

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
  if not is_valid_buf(diff_state.buf) then
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
    vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
    vim.api.nvim_buf_set_option(buf, "swapfile", false)
    vim.api.nvim_buf_set_option(buf, "modifiable", false)
    vim.api.nvim_buf_set_option(buf, "filetype", "jjwsdiff")
    vim.api.nvim_win_set_buf(win, buf)
    local chan = vim.api.nvim_open_term(buf, {})
    diff_state.buf = buf
    diff_state.chan = chan
    attach_diff_keymaps(buf)
    vim.api.nvim_buf_set_var(buf, "jjws_diff_buffer", true)
    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      callback = function()
        reset_diff_state()
      end,
    })
  elseif vim.api.nvim_win_get_buf(win) ~= diff_state.buf then
    vim.api.nvim_win_set_buf(win, diff_state.buf)
  end
  configure_diff_window(win)
  return diff_state.buf, diff_state.chan, win
end

local function find_agent_terminal()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local ok, is_agent = pcall(vim.api.nvim_buf_get_var, buf, "jjws_agent")
      if ok and is_agent then
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
          return buf, job
        end
      end
    end
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
  local ctx = active_workspace or current_workspace()
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
  if not is_valid_buf(diff_state.buf) then
    notify("open a JJ diff buffer before adding comments", vim.log.levels.WARN)
    return
  end
  local win = diff_state.win
  if not is_valid_win(win) or vim.api.nvim_win_get_buf(win) ~= diff_state.buf then
    win = vim.api.nvim_get_current_win()
  end
  local selection = gather_diff_selection(diff_state.buf, win, opts)
  if not selection then
    notify("select diff lines to comment on", vim.log.levels.WARN)
    return
  end
  local ctx = active_workspace or current_workspace()
  if not ctx then
    notify("open a JJ workspace before adding comments", vim.log.levels.WARN)
    return
  end
  local file_hint = diff_header_for_line(diff_state.buf, selection.start_line)
  vim.ui.input({ prompt = "Diff comment: " }, function(input)
    if not input or trim(input) == "" then
      notify("diff comment cancelled", vim.log.levels.INFO)
      return
    end
    local payload = format_diff_comment(ctx, file_hint, selection, input)
    local agent_buf, job = ensure_agent_channel()
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
    if diff_state.win and vim.api.nvim_win_is_valid(diff_state.win) then
      vim.api.nvim_set_current_win(diff_state.win)
    end
  end)
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

local function build_codex_resume_command(session_id, agent_cmd)
  if not session_id or session_id == "" then
    return nil
  end
  local cmd = agent_cmd or cfg.agent_cmd
  if type(cmd) == "table" and cmd[1] == "bash" and cmd[2] == "-lc" then
    return { "bash", "-lc", "codex resume " .. session_id }
  end
  return { "codex", "resume", session_id }
end

local function create_codex_session(cwd)
  local uv = vim.uv or vim.loop
  if not vim.system then
    return nil, "vim.system unavailable"
  end

  local output_chunks = {}
  local session_id = nil

  local launcher = { "bash", "-lc", [[codex exec "say ready"]] }

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

local function save_workspace_layout(ctx)
  if not ctx or not ctx.name then
    return
  end
  local layout_path = workspace_layout_path(ctx.repo_path, ctx.name, ctx.root)
  if not layout_path then
    return
  end

  local files, current_file = collect_normal_buffers()
  local agent_state = workspace_agent_state()

  if current_file and vim.loop.fs_stat(current_file) ~= nil then
    local found = false
    for _, path in ipairs(files) do
      if path == current_file then
        found = true
        break
      end
    end
    if not found then
      table.insert(files, 1, current_file)
    end
  end

  local data = {
    files = files,
    current = current_file,
    agent = agent_state.open and agent_state or nil,
  }

  local dir = vim.fn.fnamemodify(layout_path, ":h")
  vim.fn.mkdir(dir, "p")
  local f = io.open(layout_path, "w")
  if not f then
    return
  end
  local ok, encoded = pcall(vim.json.encode, data)
  if ok then
    f:write(encoded)
  end
  f:close()
end

local function restore_workspace_layout(ctx)
  if not ctx or not ctx.name then
    return
  end
  local layout_path = workspace_layout_path(ctx.repo_path, ctx.name, ctx.root)
  if not layout_path then
    return
  end
  local f = io.open(layout_path, "r")
  if not f then
    return
  end
  local content = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, content or "")
  if not ok or type(data) ~= "table" then
    return
  end

  local files = {}
  local seen = {}
  local function add_file(path)
    if not path or path == "" then
      return
    end
    local canon = canonical_path(path)
    if not canon or canon == "" then
      return
    end
    if seen[canon] then
      return
    end
    if vim.loop.fs_stat(canon) then
      table.insert(files, canon)
      seen[canon] = true
    end
  end

  if type(data.files) == "table" then
    for _, path in ipairs(data.files) do
      add_file(path)
    end
  end

  local primary = data.current
  if primary then
    primary = canonical_path(primary)
    if not (primary and seen[primary]) then
      primary = nil
    end
  end
  if not primary and #files > 0 then
    primary = files[1]
  end

  if primary then
    vim.cmd(string.format("silent keepalt edit %s", vim.fn.fnameescape(primary)))
  end

  for _, path in ipairs(files) do
    if not primary or path ~= primary then
      vim.cmd(string.format("silent keepalt badd %s", vim.fn.fnameescape(path)))
    end
  end

  if type(data.agent) == "table" and data.agent.open then
    local opts = {}
    if data.agent.session then
      opts.session_id = data.agent.session
    end
    open_agent(opts)
  end
end

local active_workspace = nil

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
  agent_cmd = { "bash", "-lc", "devagent" }, -- replace with your CLI agent
  agent_size = 14, -- split size (height or width depending on position)
  agent_position = "bottom", -- "bottom", "top", "left", or "right"
  diff_command = { "bash", "-lc", "jj diff -tool difftastic --color=always" },
  diff_position = "right",
  diff_size = nil,
  diff_refresh_keymap = "gr",
  diff_comment_keymap = "gc",
  diff_comment_prefix = "[JJDiff]",
  remember_last = true, -- save last workspace per repo
}

local function systemlist(cmd, cwd)
  local ok, res = pcall(function()
    return vim.system({ "bash", "-lc", cmd }, { text = true, cwd = cwd }):wait()
  end)

  if not ok then
    error(res) -- Lua error in vim.system itself
  end

  if res.code ~= 0 then
    local err = trim(res.stderr)
    if err ~= "" then
      vim.notify(err, vim.log.levels.ERROR)
    end
    return nil, err ~= "" and err or ("command failed: " .. cmd)
  end

  local lines = {}
  for s in string.gmatch(res.stdout or "", "([^\n]*)\n?") do
    if s == "" then
      break
    end
    table.insert(lines, s)
  end
  return lines, nil
end

local function parse_workspace_names(lines)
  local items = {}
  for _, l in ipairs(lines) do
    local name = trim(l)
    if name ~= "" then
      table.insert(items, name)
    end
  end
  return items
end

local function collect_repo_workspaces(repo, opts)
  opts = opts or {}
  if not repo or repo == "" then
    return {}
  end
  local items = {}
  local by_name = {}
  local repo_cfg = repo_entry(repo)
  if repo_cfg then
    for name, info in pairs(repo_cfg) do
      if name ~= META_KEY and info and info.path then
        local path = canonical_path(info.path) or trim(info.path)
        table.insert(items, {
          kind = "workspace",
          repo = repo,
          name = name,
          path = path,
          managed = true,
        })
        by_name[name] = true
      end
    end
  end

  local cwd = opts.cwd
  if cwd then
    local lines = select(1, systemlist(cfg.list_cmd, cwd))
    if lines then
      local base = parent_dir(cwd)
      for _, name in ipairs(parse_workspace_names(lines)) do
        if not by_name[name] then
          table.insert(items, {
            kind = "workspace",
            repo = repo,
            name = name,
            path = canonical_path(joinpath(base, name)) or joinpath(base, name),
            managed = false,
          })
          by_name[name] = true
        end
      end
    end
  end

  table.sort(items, function(a, b)
    if a.name == b.name then
      return a.path < b.path
    end
    return a.name < b.name
  end)
  return items
end

local function known_repos()
  local repos = {}
  local seen = {}
  for repo, _ in pairs(workspace_config()) do
    table.insert(repos, repo)
    seen[repo] = true
  end
  local ctx = current_workspace()
  if ctx and ctx.repo and not seen[ctx.repo] then
    table.insert(repos, ctx.repo)
    seen[ctx.repo] = true
  end
  table.sort(repos)
  return repos, seen, ctx
end

local function build_picker_entries()
  local entries = {}
  local repos, _, ctx = known_repos()
  local cfg_tbl = workspace_config()
  for _, repo in ipairs(repos) do
    local repo_cfg = cfg_tbl[repo]
    local managed = repo_cfg ~= nil
    local meta = repo_cfg and repo_cfg[META_KEY] or nil
    local repo_path = meta and meta.repo_path
    if not repo_path and ctx and ctx.repo == repo then
      repo_path = ctx.repo_path
    end
    local default_entry = repo_cfg and repo_cfg.default
    local default_path = default_entry and default_entry.path
    if not default_path and repo_path then
      default_path = repo_default_root(repo_path)
    end
    local cwd
    if ctx and ctx.repo == repo then
      cwd = ctx.root
      if not default_path then
        default_path = ctx.default_root or ctx.root
      end
    else
      cwd = repo_any_path(repo)
    end
    if not default_path then
      default_path = cwd
    end

    table.insert(entries, {
      kind = "repo",
      repo = repo,
      managed = managed,
      cwd = cwd,
      default_path = default_path,
      repo_path = repo_path,
    })

    local workspaces = collect_repo_workspaces(repo, { cwd = cwd })
    if (not managed) and ctx and ctx.repo == repo and #workspaces == 0 and ctx.root then
      workspaces = {
        {
          kind = "workspace",
          repo = repo,
          name = "default",
          path = ctx.root,
          managed = false,
          is_current = true,
        },
      }
    end
    for _, ws in ipairs(workspaces) do
      if ctx and ctx.repo == repo then
        local canonical = canonical_path(ws.path)
        local is_current = canonical and canonical == ctx.root
        ws.is_current = is_current
      end
      table.insert(entries, ws)
    end
  end
  return entries
end

local picker_state = {}

local function close_picker()
  if picker_state.win and vim.api.nvim_win_is_valid(picker_state.win) then
    vim.api.nvim_win_close(picker_state.win, true)
  end
  if picker_state.buf and vim.api.nvim_buf_is_valid(picker_state.buf) then
    vim.api.nvim_buf_delete(picker_state.buf, { force = true })
  end
  picker_state = {}
end

local function render_picker()
  if not picker_state.buf or not vim.api.nvim_buf_is_valid(picker_state.buf) then
    return
  end
  local lines = {}
  for _, entry in ipairs(picker_state.entries or {}) do
    if entry.kind == "repo" then
      local suffix = entry.managed and "" or " [unregistered]"
      table.insert(lines, "  " .. entry.repo .. "/" .. suffix)
    elseif entry.kind == "workspace" then
      local label = entry.name
      local path = entry.path or ""
      local prefix = "  "
      if entry.is_current then
        prefix = "→ "
      end
      table.insert(lines, string.format("%s%-12s %s", prefix, label, path))
    end
  end
  if #lines == 0 then
    lines = { "(no workspaces configured)" }
  end
  vim.api.nvim_buf_set_option(picker_state.buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(picker_state.buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(picker_state.buf, "modifiable", false)
end

local function find_entry_index(target)
  if not target or not picker_state.entries then
    return nil
  end
  for idx, entry in ipairs(picker_state.entries) do
    if entry.kind == target.kind and entry.repo == target.repo then
      if entry.kind == "repo" then
        return idx
      elseif entry.name == target.name then
        return idx
      end
    end
  end
  return nil
end

local function refresh_picker(needle)
  if not picker_state.win or not vim.api.nvim_win_is_valid(picker_state.win) then
    return
  end
  picker_state.entries = build_picker_entries()
  local ctx = current_workspace()
  picker_state.current = ctx
      and {
        kind = "workspace",
        repo = ctx.repo,
        name = ctx.name,
        path = ctx.root,
      }
    or nil
  render_picker()
  local idx = find_entry_index(needle)
  if not idx then
    if picker_state.current then
      idx = find_entry_index(picker_state.current)
    end
  end
  if not idx then
    idx = math.min(#picker_state.entries, 1)
  end
  vim.api.nvim_win_set_cursor(picker_state.win, { math.max(idx, 1), 0 })
end

local function current_picker_entry()
  if not picker_state.win or not vim.api.nvim_win_is_valid(picker_state.win) then
    return nil
  end
  local cursor = vim.api.nvim_win_get_cursor(picker_state.win)
  local idx = cursor[1]
  return picker_state.entries and picker_state.entries[idx] or nil
end

local function open_picker_window()
  picker_state.entries = build_picker_entries()
  local ctx = current_workspace()
  picker_state.current = ctx
      and {
        kind = "workspace",
        repo = ctx.repo,
        name = ctx.name,
        path = ctx.root,
      }
    or nil
  local active_idx = picker_state.current and find_entry_index(picker_state.current)
  local buf = vim.api.nvim_create_buf(false, true)
  picker_state.buf = buf
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(buf, "swapfile", false)
  vim.api.nvim_buf_set_option(buf, "filetype", "jjws")

  local width = 0
  for _, entry in ipairs(picker_state.entries) do
    local text
    if entry.kind == "repo" then
      local suffix = entry.managed and "" or " [unregistered]"
      text = entry.repo .. "/" .. suffix
    else
      text = string.format("  %-12s %s", entry.name, entry.path or "")
    end
    width = math.max(width, vim.api.nvim_strwidth(text))
  end
  width = math.min(math.max(width + 2, 30), math.floor(vim.o.columns * 0.8))
  local height = math.min(#picker_state.entries + 2, math.floor(vim.o.lines * 0.6))
  if height < 3 then
    height = 3
  end

  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)
  picker_state.win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    row = row,
    col = col,
    width = width,
    height = height,
  })

  render_picker()
  local idx = active_idx or 1
  vim.api.nvim_win_set_cursor(picker_state.win, { idx, 0 })

  vim.keymap.set("n", "<CR>", function()
    local entry = current_picker_entry()
    if entry then
      M._switch_from_picker(entry)
    end
  end, { buffer = buf, nowait = true })

  vim.keymap.set("n", "q", close_picker, { buffer = buf, nowait = true })

  vim.keymap.set("n", "r", function()
    M._register_repo()
  end, { buffer = buf, nowait = true })

  vim.keymap.set("n", "w", function()
    M._create_workspace()
  end, { buffer = buf, nowait = true })

  vim.keymap.set("n", "x", function()
    M._remove_workspace()
  end, { buffer = buf, nowait = true })

  vim.keymap.set("n", "<Esc>", close_picker, { buffer = buf, nowait = true })

  vim.api.nvim_buf_set_option(buf, "modifiable", false)
end

local function ensure_picker_open()
  if not picker_state.win or not vim.api.nvim_win_is_valid(picker_state.win) then
    open_picker_window()
  end
end

local function switch_from_picker(entry)
  if not entry then
    return
  end
  if entry.kind == "repo" then
    local repo = entry.repo
    local cfg_tbl = workspace_config()
    local repo_cfg = cfg_tbl[repo]
    local path = entry.default_path
    if repo_cfg and repo_cfg.default and repo_cfg.default.path then
      path = repo_cfg.default.path
    end
    local ctx = current_workspace()
    if (not path) and ctx and ctx.repo == repo then
      path = ctx.default_root or ctx.root
    end
    if not path then
      path = repo_any_path(repo)
    end
    if not path and entry.repo_path then
      path = repo_default_root(entry.repo_path)
    end
    if not path or path == "" then
      notify("no default workspace registered for " .. repo, vim.log.levels.WARN)
      return
    end
    local canonical = canonical_path(path) or path
    local name = find_workspace(repo, canonical)
    if not name then
      if ctx and ctx.repo == repo and ctx.default_root and canonical == ctx.default_root then
        name = "default"
      else
        local basename = vim.fn.fnamemodify(canonical, ":t")
        name = basename ~= "" and basename or "default"
      end
    end
    close_picker()
    M.use_workspace({ name = name, path = canonical })
    return
  end

  if entry.kind == "workspace" then
    close_picker()
    M.use_workspace({ name = entry.name, path = entry.path })
  end
end

local function register_repo()
  local ctx = current_workspace()
  if not ctx or not ctx.repo then
    notify("not inside a jj workspace", vim.log.levels.WARN)
    return
  end
  if ctx.name ~= "default" then
    notify("registration only allowed from default workspace", vim.log.levels.ERROR)
    return
  end
  local repo_path = ctx.repo_path or repo_storage_path(ctx.root)
  update_workspace(ctx.repo, "default", ctx.default_root or ctx.root, repo_path)
  notify("registered repo " .. ctx.repo, vim.log.levels.INFO)
  refresh_picker({ kind = "repo", repo = ctx.repo })
end

local function run_jj(cmd, cwd)
  local ok, res = pcall(function()
    return vim.system({ "bash", "-lc", cmd }, { text = true, cwd = cwd }):wait()
  end)
  if not ok then
    notify(res, vim.log.levels.ERROR)
    return false
  end
  if res.code ~= 0 then
    local err = trim(res.stderr)
    notify(err ~= "" and err or ("command failed: " .. cmd), vim.log.levels.ERROR)
    return false
  end
  return true
end

local function create_workspace()
  local ctx = current_workspace()
  if not ctx or not ctx.repo or not ctx.root then
    notify("not inside a jj workspace", vim.log.levels.WARN)
    return
  end
  local repo_cfg = repo_entry(ctx.repo)
  local name = trim(vim.fn.input("New workspace name: "))
  if name == "" then
    return
  end
  if name == "default" and repo_cfg and repo_cfg.default then
    notify("default workspace already registered", vim.log.levels.WARN)
    return
  end
  if repo_cfg and repo_cfg[name] then
    notify("workspace already configured: " .. name, vim.log.levels.WARN)
    return
  end
  local repo_path = ctx.repo_path or repo_storage_path(ctx.root)
  local base = parent_dir(ctx.root)
  local dest = joinpath(base, name)
  local cmd = string.format("jj workspace add %s", vim.fn.shellescape(dest))
  if not run_jj(cmd, ctx.root) then
    return
  end
  update_workspace(ctx.repo, name, dest, repo_path)
  notify("created workspace " .. name .. " for " .. ctx.repo, vim.log.levels.INFO)
  refresh_picker({ kind = "workspace", repo = ctx.repo, name = name })
end

local function remove_workspace()
  local entry = current_picker_entry()
  if not entry or entry.kind ~= "workspace" then
    notify("select a workspace first", vim.log.levels.WARN)
    return
  end
  if entry.name == "default" then
    notify("cannot remove default workspace", vim.log.levels.ERROR)
    return
  end
  local choice = vim.fn.confirm("Forget workspace '" .. entry.name .. "'?", "&Yes\n&No", 2)
  if choice ~= 1 then
    return
  end
  local ctx = current_workspace()
  local cwd = (ctx and ctx.repo == entry.repo and ctx.root) or repo_any_path(entry.repo) or entry.path
  local cmd = string.format("jj workspace forget %s", vim.fn.shellescape(entry.name))
  if not run_jj(cmd, cwd) then
    return
  end
  delete_workspace(entry.repo, entry.name)
  notify("removed workspace " .. entry.name, vim.log.levels.INFO)
  refresh_picker({ kind = "repo", repo = entry.repo })
end

M._switch_from_picker = switch_from_picker
M._register_repo = function()
  ensure_picker_open()
  register_repo()
end
M._create_workspace = function()
  ensure_picker_open()
  create_workspace()
end
M._remove_workspace = function()
  ensure_picker_open()
  remove_workspace()
end

local function wipe_all()
  -- Close floating windows and terminals cleanly, then wipe other buffers and tabs.
  -- Optionally protect unsaved buffers.
  local bufs = vim.api.nvim_list_bufs()
  for _, b in ipairs(bufs) do
    if vim.api.nvim_buf_is_loaded(b) then
      local modified = vim.bo[b].modified
      if cfg.close_unsaved or not modified then
        pcall(vim.api.nvim_buf_delete, b, { force = cfg.close_unsaved })
      end
    end
  end
  -- Ensure a clean tabpage
  vim.cmd("tabonly")
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

open_agent = function(opts)
  -- Open a terminal split and start the configured agent in repo cwd
  opts = opts or {}
  if not active_workspace and not opts.ignore_guard then
    notify("open a JJ workspace before starting the agent", vim.log.levels.WARN)
    return nil
  end
  local cwd = vim.fn.getcwd()
  local size = cfg.agent_size or cfg.agent_height or 14
  local position = cfg.agent_position
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
  vim.cmd("enew")
  local buf = vim.api.nvim_get_current_buf()
  vim.b[buf].jjws_agent = true
  local session_id = opts.session_id
  local term_cmd = cfg.agent_cmd
  if session_id and session_id ~= "" and is_codex_command(cfg.agent_cmd) then
    local resume_cmd = build_codex_resume_command(session_id, cfg.agent_cmd)
    if resume_cmd then
      term_cmd = resume_cmd
    end
  elseif not session_id and is_codex_command(cfg.agent_cmd) then
    local session, err = create_codex_session(cwd)
    if session then
      session_id = session
      local resume_cmd = build_codex_resume_command(session_id, cfg.agent_cmd)
      if resume_cmd then
        term_cmd = resume_cmd
        notify("codex session " .. session_id .. " ready", vim.log.levels.DEBUG)
      end
    else
      notify("codex session setup failed: " .. (err or "unknown error"), vim.log.levels.WARN)
    end
  end

  local job_id = vim.fn.termopen(term_cmd, { cwd = cwd })
  vim.cmd("startinsert")
  if type(job_id) == "number" and job_id > 0 then
    pcall(vim.api.nvim_buf_set_var, buf, "jjws_agent_job", job_id)
  end
  if session_id and session_id ~= "" then
    vim.b[buf].jjws_codex_session = session_id
  else
    vim.b[buf].jjws_codex_session = nil
  end

  -- Persist the updated layout so the agent/session are recorded immediately.
  local ctx = active_workspace or current_workspace()
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
  local ctx = current_workspace()
  local target_repo = repo or (ctx and ctx.repo)
  if not target_repo then
    notify("not inside a jj workspace and no repo specified", vim.log.levels.WARN)
    return {}
  end

  local cwd = nil
  if ctx and ctx.repo == target_repo then
    cwd = ctx.root
  else
    cwd = repo_any_path(target_repo)
  end

  local items = collect_repo_workspaces(target_repo, { cwd = cwd })
  if #items == 0 and not repo_entry(target_repo) then
    notify("no workspaces tracked for repo: " .. target_repo, vim.log.levels.WARN)
  end
  return items
end

function M.pick_workspace()
  if picker_state.win and vim.api.nvim_win_is_valid(picker_state.win) then
    close_picker()
  else
    open_picker_window()
  end
end

function M.use_workspace(ws)
  -- 1) wipe UI state  2) chdir  3) reopen an empty buffer  4) save state
  local previous = current_workspace()
  if previous then
    save_workspace_layout(previous)
  end
  wipe_all()
  set_cwd(ws.path)
  vim.cmd("enew")
  local new_ctx = current_workspace()
  if new_ctx then
    active_workspace = new_ctx
    restore_workspace_layout(new_ctx)
  else
    active_workspace = nil
  end
  local repo_root = cfg.repo_root_finder()
  save_last(repo_root, ws)
  notify("workspace → " .. ws.name)
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
      local ok, ctx = pcall(current_workspace)
      if ok and ctx then
        save_workspace_layout(ctx)
      end
    end,
  })
end

return M
