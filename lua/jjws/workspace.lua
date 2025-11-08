local Workspace = {}

function Workspace.setup(env)
  local cfg = env.cfg or {}
  local notify = env.notify
  local trim = env.trim
  local workspace_label = env.workspace_label
  local workspace_key = env.workspace_key
  local canonical_path = env.canonical_path
  local repo_storage_path = env.repo_storage_path
  local repo_default_root = env.repo_default_root
  local workspace_config = env.workspace_config or function()
    return {}
  end
  local repo_entry = env.repo_entry
  local dir_exists = env.dir_exists
  local joinpath = env.joinpath
  local parent_dir = env.parent_dir
  local META_KEY = env.META_KEY or "__meta"
  local attention_refresh = env.attention_refresh
  local get_active_workspace = env.get_active_workspace or function()
    return nil
  end
  local current_workspace_fn = env.current_workspace
  local agent_buffers = env.agent_buffers or {}
  local agent_sizes = env.agent_sizes or {}
  local agent_window_size = env.agent_window_size
  local open_agent = env.open_agent
  local revive_agent_buffer = env.revive_agent_buffer
  local uv = env.uv or vim.uv or vim.loop
  local current_pid = env.current_pid or ((uv and uv.os_getpid and uv.os_getpid()) or vim.fn.getpid())

  local owned_workspace_lock = nil
  local workspace_attention = {}
  local missing_repo_dirs_warned = {}

  local function notify_user(msg, level)
    if notify then
      notify(msg, level)
    else
      vim.notify(msg, level or vim.log.levels.INFO)
    end
  end

  local function trim_text(text)
    if trim then
      return trim(text)
    end
    if vim.trim then
      return vim.trim(text)
    end
    return vim.fn.trim(text)
  end

  local function label_for_workspace(ctx)
    if workspace_label then
      return workspace_label(ctx)
    end
    if not ctx then
      return "workspace"
    end
    if ctx.repo and ctx.name then
      return string.format("%s/%s", ctx.repo, ctx.name)
    end
    return ctx.name or (ctx.root or "workspace")
  end

  local function canonical_path_fn(path)
    if not path or path == "" then
      return nil
    end
    if canonical_path then
      local resolved = canonical_path(path)
      if resolved and resolved ~= "" then
        return resolved
      end
    end
    local uv_local = uv or vim.loop or vim.uv
    if uv_local and uv_local.fs_realpath then
      local real = uv_local.fs_realpath(path)
      if real and real ~= "" then
        return real
      end
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

  local function dir_exists_fn(path)
    if dir_exists then
      return dir_exists(path)
    end
    if not path or path == "" then
      return false
    end
    local uv_local = uv or vim.loop or vim.uv
    local st = uv_local and uv_local.fs_stat and uv_local.fs_stat(path)
    return st and st.type == "directory"
  end

  local function joinpath_fn(parent, child)
    if joinpath then
      return joinpath(parent, child)
    end
    local sep = package.config:sub(1, 1)
    if parent:sub(-1) == sep then
      return parent .. child
    end
    return parent .. sep .. child
  end

  local function parent_dir_fn(path)
    if parent_dir then
      return parent_dir(path)
    end
    return vim.fn.fnamemodify(path, ":h")
  end

  local function repo_entry_for(repo)
    if repo_entry then
      return repo_entry(repo)
    end
    local cfg_tbl = workspace_config() or {}
    return cfg_tbl[repo]
  end

  local function fire_attention_refresh()
    if attention_refresh then
      attention_refresh()
    end
  end

  local function workspace_key_parts(repo, name)
    if not repo or repo == "" or not name or name == "" then
      return nil
    end
    return repo .. "::" .. name
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
    local key = workspace_key and workspace_key(ctx)
    if not key then
      return false
    end
    local active = get_active_workspace()
    if active and workspace_key and workspace_key(active) == key then
      workspace_attention[key] = nil
      fire_attention_refresh()
      return false
    end
    workspace_attention[key] = {
      pending = true,
      last_event = payload,
      last_command = payload and payload.command or nil,
      message = payload and payload.message or nil,
    }
    fire_attention_refresh()
    return true
  end

  local function clear_workspace_attention(ctx)
    local key = workspace_key and workspace_key(ctx)
    if not key then
      return false
    end
    local state = workspace_attention[key]
    if not state then
      return false
    end
    workspace_attention[key] = nil
    fire_attention_refresh()
    return true, state
  end

  local function systemlist(cmd, cwd)
    local ok, res = pcall(function()
      return vim.system({ "bash", "-lc", cmd }, { text = true, cwd = cwd }):wait()
    end)
    if not ok then
      return nil, res
    end
    if not res or res.code ~= 0 then
      local err = trim_text(res and res.stderr or "")
      if err ~= "" then
        notify_user(err, vim.log.levels.ERROR)
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
    for _, l in ipairs(lines or {}) do
      local name = trim_text(l)
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
    local repo_path = opts.repo_path
    local repo_cfg = repo_entry_for(repo)
    if repo_cfg then
      for name, info in pairs(repo_cfg) do
        if name ~= META_KEY and info and info.path then
          local path = canonical_path_fn(info.path) or trim_text(info.path)
          table.insert(items, {
            kind = "workspace",
            repo = repo,
            name = name,
            path = path,
            managed = true,
            repo_path = repo_path or info.repo_path,
          })
          by_name[name] = true
        end
      end
    end

    local cwd = opts.cwd
    if cwd then
      if not dir_exists_fn(cwd) then
        local key = canonical_path_fn(cwd) or cwd
        if key and not missing_repo_dirs_warned[key] then
          missing_repo_dirs_warned[key] = true
          notify_user(string.format("Skipping jj workspace discovery for %s (missing %s)", repo, cwd), vim.log.levels.WARN)
        end
      else
        local lines = select(1, systemlist(cfg.list_cmd or [[jj workspace list -T 'name ++ "\n"']], cwd))
        if lines then
          local base = parent_dir_fn(cwd)
          for _, name in ipairs(parse_workspace_names(lines)) do
            if not by_name[name] then
              local ws_path = joinpath_fn(base, name)
              table.insert(items, {
                kind = "workspace",
                repo = repo,
                name = name,
                path = canonical_path_fn(ws_path) or ws_path,
                managed = false,
                repo_path = repo_path,
              })
              by_name[name] = true
            end
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
    local ctx = current_workspace_fn and current_workspace_fn() or nil
    if ctx and ctx.repo and not seen[ctx.repo] then
      table.insert(repos, ctx.repo)
      seen[ctx.repo] = true
    end
    table.sort(repos)
    return repos, seen, ctx
  end

  local function normalize_workspace_ref(ws)
    if type(ws) ~= "table" then
      return nil
    end
    if not ws.name or ws.name == "" then
      return nil
    end
    local root = ws.root or ws.path
    if not root or root == "" then
      return nil
    end
    local canonical_root = canonical_path_fn(root) or root
    local repo_path = ws.repo_path or (repo_storage_path and repo_storage_path(canonical_root))
    return {
      repo = ws.repo,
      name = ws.name,
      root = canonical_root,
      repo_path = repo_path,
      detached = ws.detached or false,
    }
  end

  local function read_workspace_lock(path)
    if not path or path == "" then
      return nil
    end
    local f = io.open(path, "r")
    if not f then
      return nil
    end
    local ok, data = pcall(vim.json.decode, f:read("*a"))
    f:close()
    if not ok or type(data) ~= "table" then
      return nil
    end
    data.pid = tonumber(data.pid)
    return data
  end

  local function pid_alive(pid)
    if type(pid) ~= "number" or pid <= 0 then
      return false
    end
    if not (uv and uv.kill) then
      return true
    end
    local ok = pcall(uv.kill, pid, 0)
    return ok
  end

  local function proc_name(pid)
    if type(pid) ~= "number" or pid <= 0 then
      return nil
    end
    local comm_path = string.format("/proc/%d/comm", pid)
    local f = io.open(comm_path, "r")
    if not f then
      return nil
    end
    local name = trim_text(f:read("*l") or "")
    f:close()
    if name == "" then
      return nil
    end
    return name
  end

  local function safe_unlink(path)
    if not path or path == "" then
      return
    end
    local removed = false
    if uv and uv.fs_unlink then
      local ok = pcall(uv.fs_unlink, path)
      if ok then
        removed = true
      end
    end
    if not removed then
      pcall(os.remove, path)
    end
  end

  local function lock_is_stale(info)
    if type(info) ~= "table" then
      return true
    end
    local pid = tonumber(info.pid)
    if not pid or pid <= 0 then
      return true
    end
    if not pid_alive(pid) then
      return true
    end
    local name = proc_name(pid)
    if name and name ~= "" then
      local lowered = name:lower()
      if not lowered:find("nvim", 1, true) then
        return true
      end
    end
    return false
  end

  local function workspace_state_key(repo_path, workspace_name, workspace_root)
    if not workspace_name or workspace_name == "" then
      return nil
    end
    local base = canonical_path_fn(repo_path) or canonical_path_fn(workspace_root)
    if not base or base == "" then
      base = workspace_name
    end
    local key = base .. "::" .. workspace_name
    return vim.fn.sha256(key)
  end

  local function workspace_layout_path(repo_path, workspace_name, workspace_root)
    local state_key = workspace_state_key(repo_path, workspace_name, workspace_root)
    if not state_key then
      return nil
    end
    return vim.fn.stdpath("state") .. "/jjws_layout_" .. state_key .. ".json"
  end

  local function workspace_lock_path(repo_path, workspace_name, workspace_root)
    local state_key = workspace_state_key(repo_path, workspace_name, workspace_root)
    if not state_key then
      return nil
    end
    return vim.fn.stdpath("state") .. "/jjws_lock_" .. state_key .. ".lock"
  end

  local function workspace_lock_status(ref)
    if not ref then
      return { locked = false }
    end
    local path = workspace_lock_path(ref.repo_path, ref.name, ref.root)
    if not path then
      return { locked = false }
    end
    local info = read_workspace_lock(path)
    if not info then
      return { locked = false, path = path }
    end
    if info.pid == current_pid then
      return { locked = false, path = path, owned = true, info = info }
    end
    if lock_is_stale(info) then
      safe_unlink(path)
      return { locked = false, path = path, stale = true }
    end
    return { locked = true, path = path, info = info }
  end

  local function write_workspace_lock(path, payload)
    if not path or path == "" then
      return false
    end
    local dir = vim.fn.fnamemodify(path, ":h")
    vim.fn.mkdir(dir, "p")
    local f = io.open(path, "w")
    if not f then
      return false
    end
    local ok, encoded = pcall(vim.json.encode, payload)
    if not ok then
      f:close()
      return false
    end
    f:write(encoded)
    f:close()
    return true
  end

  local function acquire_workspace_lock(ctx)
    local ref = normalize_workspace_ref(ctx)
    if not ref or ref.detached then
      return true
    end
    local status = workspace_lock_status(ref)
    if status.locked then
      return false, status
    end
    local path = status.path
    if not path then
      return true
    end
    local payload = {
      pid = current_pid,
      repo = ref.repo,
      name = ref.name,
      root = ref.root,
      timestamp = os.time(),
    }
    local ok = write_workspace_lock(path, payload)
    if not ok then
      return false
    end
    owned_workspace_lock = { path = path }
    return true
  end

  local function release_workspace_lock()
    if not owned_workspace_lock or not owned_workspace_lock.path then
      return
    end
    safe_unlink(owned_workspace_lock.path)
    owned_workspace_lock = nil
  end

  local function maybe_handle_locked_workspace(ws, opts)
    opts = opts or {}
    if not ws or ws.detached then
      return true
    end
    local ref = normalize_workspace_ref(ws)
    if not ref then
      return true
    end
    ws.path = ref.root
    ws.repo_path = ref.repo_path
    local status = workspace_lock_status(ref)
    if not status.locked then
      return true
    end
    if opts.allow_prompt == false then
      ws.detached = true
      notify_user(
        string.format(
          "%s locked by pid %s; running in detached edit-only mode",
          label_for_workspace(ws),
          status.info and status.info.pid or "?"
        ),
        vim.log.levels.WARN
      )
      return true
    end
    local owner_pid = status.info and status.info.pid or "?"
    local message = string.format(
      "Workspace '%s' is locked by PID %s.\nChoose an action:",
      label_for_workspace(ws),
      owner_pid
    )
    local choice = vim.fn.confirm(message, "&Cancel\n&Open without agent", 1)
    if choice ~= 2 then
      if opts.on_cancel then
        opts.on_cancel()
      end
      return false
    end
    ws.detached = true
    notify_user(
      string.format("%s opened without agent/layout (detached).", label_for_workspace(ws)),
      vim.log.levels.WARN
    )
    return true
  end

  local function collect_normal_buffers()
    local files = {}
    local seen = {}
    local current_file = nil
    local curbuf = vim.api.nvim_get_current_buf()
    if vim.api.nvim_buf_is_loaded(curbuf) and vim.api.nvim_buf_get_option(curbuf, "buftype") == "" then
      local name = vim.api.nvim_buf_get_name(curbuf)
      if name ~= "" then
        local path = canonical_path_fn(name)
        if path and path ~= "" then
          current_file = path
        end
      end
    end
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(buf) and vim.api.nvim_buf_get_option(buf, "buftype") == "" then
        local name = vim.api.nvim_buf_get_name(buf)
        if name ~= "" then
          local path = canonical_path_fn(name)
          if path and path ~= "" and not seen[path] and (vim.loop.fs_stat(path) ~= nil) then
            table.insert(files, path)
            seen[path] = true
          end
        end
      end
    end
    return files, current_file
  end

  local function workspace_agent_state(ctx)
    if not workspace_key then
      return { open = false }
    end
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

  local function save_workspace_layout(ctx)
    if not ctx or ctx.detached or not ctx.name then
      return
    end
    local layout_path = workspace_layout_path(ctx.repo_path, ctx.name, ctx.root)
    if not layout_path then
      return
    end

    local files, current_file = collect_normal_buffers()
    local agent_state = workspace_agent_state(ctx)

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

    local key = workspace_key and workspace_key(ctx) or nil
    local agent_layout = nil
    if key then
      local size = agent_sizes[key]
      if agent_state.open and agent_state.buf then
        local wins = vim.fn.win_findbuf(agent_state.buf)
        if wins[1] and vim.api.nvim_win_is_valid(wins[1]) and agent_window_size then
          size = agent_window_size(wins[1]) or size
        end
      end
      if size and size > 0 then
        agent_sizes[key] = size
        agent_layout = {
          size = size,
          position = (cfg.agent_position or "right"),
        }
      end
    end
    if agent_layout then
      data.layout = { agent = agent_layout }
    end

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
    if not ctx or ctx.detached or not ctx.name then
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
      local canon = canonical_path_fn(path)
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
      primary = canonical_path_fn(primary)
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

    local agent_layout = data.layout and data.layout.agent or nil
    if agent_layout and agent_layout.size and ctx then
      local key = workspace_key and workspace_key(ctx)
      if key then
        agent_sizes[key] = agent_layout.size
      end
    end

    if type(data.agent) == "table" and data.agent.open then
      local revived = revive_agent_buffer and revive_agent_buffer(ctx)
      if not revived and open_agent then
        local opts = {}
        if data.agent.session then
          opts.session_id = data.agent.session
        end
        if agent_layout and agent_layout.size then
          opts.size_override = agent_layout.size
        end
        open_agent(opts)
      end
    end
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

  return {
    normalize_workspace_ref = normalize_workspace_ref,
    workspace_lock_status = workspace_lock_status,
    acquire_lock = acquire_workspace_lock,
    release_lock = release_workspace_lock,
    maybe_handle_locked_workspace = maybe_handle_locked_workspace,
    save_layout = save_workspace_layout,
    restore_layout = restore_workspace_layout,
    save_last = save_last,
    load_last = load_last,
    has_attention = workspace_has_attention,
    mark_attention = mark_workspace_attention,
    clear_attention = clear_workspace_attention,
    collect_repo_workspaces = collect_repo_workspaces,
    known_repos = known_repos,
  }
end

return Workspace
