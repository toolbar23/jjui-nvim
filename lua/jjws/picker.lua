local Picker = {}

function Picker.setup(env)
  local cfg = env.cfg
  local notify = env.notify
  local trim = env.trim
  local set_default_highlight = env.set_default_highlight
  local workspace_config = env.workspace_config
  local repo_entry = env.repo_entry
  local update_workspace = env.update_workspace
  local delete_workspace = env.delete_workspace
  local repo_any_path = env.repo_any_path
  local repo_default_root = env.repo_default_root
  local find_workspace = env.find_workspace
  local repo_storage_path = env.repo_storage_path
  local dir_exists = env.dir_exists
  local joinpath = env.joinpath
  local parent_dir = env.parent_dir
  local canonical_path = env.canonical_path
  local workspace_has_attention = env.workspace_has_attention
  local normalize_workspace_ref = env.normalize_workspace_ref
  local workspace_lock_status = env.workspace_lock_status
  local current_workspace = env.current_workspace
  local use_workspace = env.use_workspace
  local META_KEY = env.META_KEY
  local collect_repo_workspaces = env.collect_repo_workspaces or function()
    return {}
  end
  local known_repos = env.known_repos or function()
    return {}, {}, current_workspace()
  end

  local picker_ns = vim.api.nvim_create_namespace("jjws-picker")
  local picker_state = {}
  local ensured_highlights = false

  local function ensure_picker_highlights()
    if ensured_highlights then
      return
    end
    set_default_highlight("JJWSPickerRepo", { bold = true })
    set_default_highlight("JJWSPickerPath", { link = "Comment" })
    set_default_highlight("JJWSPickerStar", { bold = true })
    set_default_highlight("JJWSPickerAttention", { link = "WarningMsg" })
    set_default_highlight("JJWSPickerLocked", { link = "WarningMsg" })
    set_default_highlight("JJWSPickerCursorLine", { link = "CursorLine" })
    ensured_highlights = true
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

      local workspaces = collect_repo_workspaces(repo, { cwd = cwd, repo_path = repo_path })
      if (not managed) and ctx and ctx.repo == repo and #workspaces == 0 and ctx.root then
        workspaces = {
          {
            kind = "workspace",
            repo = repo,
            name = "default",
            path = ctx.root,
            managed = false,
            is_current = true,
            needs_attention = workspace_has_attention(repo, "default"),
            repo_path = repo_path or ctx.repo_path,
          },
        }
      end
      for _, ws in ipairs(workspaces) do
        ws.repo_path = ws.repo_path or repo_path
        if ctx and ctx.repo == repo then
          local canonical = canonical_path(ws.path)
          local is_current = canonical and canonical == ctx.root
          ws.is_current = is_current
        end
        ws.needs_attention = workspace_has_attention(ws.repo, ws.name)
        if not ws.is_current then
          local ref = normalize_workspace_ref({
            repo = ws.repo,
            name = ws.name,
            path = ws.path,
            repo_path = ws.repo_path,
          })
          local status = workspace_lock_status(ref)
          ws.locked = status and status.locked or false
        else
          ws.locked = false
        end
        table.insert(entries, ws)
      end
    end
    return entries
  end

  local function format_picker_lines(entries)
    entries = entries or {}
    local indent = "  "
    local prefix_pad = " "
    local repo_icon = " "
    local branch_mid = "├─ "
    local branch_last = "└─ "
    local workspace_label_width = 0
    local workspace_cache = {}
    for idx, entry in ipairs(entries) do
      if entry.kind == "workspace" then
        local next_entry = entries[idx + 1]
        local is_last = not next_entry or next_entry.kind == "repo" or next_entry.repo ~= entry.repo
        local connector = indent .. (is_last and branch_last or branch_mid)
        local name = entry.name or ""
        local node_icon = entry.is_current and " " or " "
        local label = connector .. node_icon .. name
        local star_start = nil
        if entry.is_current then
          label = label .. " *"
          star_start = #label - 1
        end
        local attention_start = nil
        local attention_len = 0
        if entry.needs_attention then
          local attention = " ●"
          attention_start = #label
          attention_len = #attention
          label = label .. attention
        end
        workspace_label_width = math.max(workspace_label_width, vim.api.nvim_strwidth(label))
        workspace_cache[idx] = {
          label = label,
          star_start = star_start,
          attention_start = attention_start,
          attention_len = attention_len,
        }
      end
    end
    local path_col = workspace_label_width > 0 and (workspace_label_width + 2) or 0
    local lines = {}
    local highlights = {}
    local line_defs = {}
    local max_width = 0
    local max_pre_status_width = 0
    local pad_len = #prefix_pad
    local function queue_line(text, segments, entry)
      table.insert(line_defs, { text = text, segments = segments or {}, entry = entry })
      local width = vim.api.nvim_strwidth(prefix_pad .. text)
      if width > max_pre_status_width then
        max_pre_status_width = width
      end
    end
    for idx, entry in ipairs(entries) do
      if entry.kind == "repo" then
        local suffix = entry.managed and "" or " [unregistered]"
        local text = repo_icon .. entry.repo .. "/" .. suffix
        local icon_len = #repo_icon
        queue_line(text, {
          { hl = "JJWSPickerRepo", start_col = icon_len, end_col = #text },
        }, entry)
      elseif entry.kind == "workspace" then
        local cached = workspace_cache[idx]
        local label = cached and cached.label or ""
        if label == "" then
          local next_entry = entries[idx + 1]
          local is_last = not next_entry or next_entry.kind == "repo" or next_entry.repo ~= entry.repo
          local connector = indent .. (is_last and branch_last or branch_mid)
          local node_icon = entry.is_current and " " or " "
          local name = entry.name or ""
          label = connector .. node_icon .. name
          local star_start = nil
          if entry.is_current then
            label = label .. " *"
            star_start = #label - 1
          end
          local attention_start = nil
          local attention_len = 0
          if entry.needs_attention then
            local attention = " ●"
            attention_start = #label
            attention_len = #attention
            label = label .. attention
          end
          cached = {
            label = label,
            star_start = star_start,
            attention_start = attention_start,
            attention_len = attention_len,
          }
        end
        local path = entry.path or ""
        local line_text = label
        local path_start_col
        if path ~= "" then
          if path_col > 0 then
            local pad = path_col - vim.api.nvim_strwidth(label)
            if pad < 1 then
              pad = 1
            end
            local spacer = string.rep(" ", pad)
            line_text = label .. spacer .. path
            path_start_col = #label + #spacer
          else
            line_text = label .. " " .. path
            path_start_col = #label + 1
          end
        end
        local segments = {}
        if cached and cached.star_start then
          local star_start = cached.star_start
          table.insert(segments, { hl = "JJWSPickerStar", start_col = star_start, end_col = star_start + 1 })
        end
        if cached and cached.attention_start and cached.attention_len and cached.attention_len > 0 then
          local start_col = cached.attention_start
          table.insert(segments, {
            hl = "JJWSPickerAttention",
            start_col = start_col,
            end_col = start_col + cached.attention_len,
          })
        end
        if path_start_col then
          table.insert(segments, { hl = "JJWSPickerPath", start_col = path_start_col, end_col = #line_text })
        end
        queue_line(line_text, segments, entry)
      end
    end
    if #line_defs == 0 then
      local text = "(no workspaces configured)"
      local final = prefix_pad .. text
      table.insert(lines, final)
      return lines, vim.api.nvim_strwidth(final), highlights
    end
    local status_col = max_pre_status_width > 0 and (max_pre_status_width + 2) or 0
    for _, def in ipairs(line_defs) do
      local text = def.text
      local segments = def.segments or {}
      local entry = def.entry
      if entry and entry.kind == "workspace" and entry.locked and not entry.is_current then
        local marker = "(!locked)"
        local current_width = vim.api.nvim_strwidth(prefix_pad .. text)
        local pad = status_col - current_width
        if pad < 1 then
          pad = 1
        end
        local spacer = string.rep(" ", pad)
        local start_col = #text + #spacer
        text = text .. spacer .. marker
        table.insert(segments, {
          hl = "JJWSPickerLocked",
          start_col = start_col,
          end_col = start_col + #marker,
        })
      end
      if segments then
        for _, seg in ipairs(segments) do
          if seg.start_col then
            seg.start_col = seg.start_col + pad_len
          end
          if seg.end_col then
            seg.end_col = seg.end_col + pad_len
          end
        end
      end
      local final = prefix_pad .. text
      table.insert(lines, final)
      highlights[#lines] = segments
      max_width = math.max(max_width, vim.api.nvim_strwidth(final))
    end
    return lines, max_width, highlights
  end

  local function close_picker()
    if picker_state.win and vim.api.nvim_win_is_valid(picker_state.win) then
      vim.api.nvim_win_close(picker_state.win, true)
    end
    if picker_state.buf and vim.api.nvim_buf_is_valid(picker_state.buf) then
      vim.api.nvim_buf_delete(picker_state.buf, { force = true })
    end
    picker_state.win = nil
    picker_state.buf = nil
    picker_state.entries = nil
    picker_state.current = nil
  end

  local function render_picker()
    if not picker_state.buf or not vim.api.nvim_buf_is_valid(picker_state.buf) then
      return
    end
    ensure_picker_highlights()
    local lines, _, highlights = format_picker_lines(picker_state.entries)
    vim.api.nvim_buf_set_option(picker_state.buf, "modifiable", true)
    vim.api.nvim_buf_set_lines(picker_state.buf, 0, -1, false, lines)
    vim.api.nvim_buf_set_option(picker_state.buf, "modifiable", false)
    vim.api.nvim_buf_clear_namespace(picker_state.buf, picker_ns, 0, -1)
    for idx, segments in ipairs(highlights or {}) do
      if segments then
        for _, seg in ipairs(segments) do
          if seg and seg.start_col and seg.end_col and seg.start_col < seg.end_col then
            pcall(vim.api.nvim_buf_add_highlight, picker_state.buf, picker_ns, seg.hl, idx - 1, seg.start_col, seg.end_col)
          end
        end
      end
    end
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
    if not idx and picker_state.current then
      idx = find_entry_index(picker_state.current)
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

  local switch_from_picker

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

    local _, max_line_width = format_picker_lines(picker_state.entries)
    local width = math.min(math.max(max_line_width + 2, 30), math.floor(vim.o.columns * 0.8))
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
    vim.api.nvim_win_set_option(picker_state.win, "cursorline", true)
    vim.api.nvim_win_set_option(picker_state.win, "winhighlight", "CursorLine:JJWSPickerCursorLine")

    render_picker()
    local idx = active_idx or 1
    vim.api.nvim_win_set_cursor(picker_state.win, { idx, 0 })

    vim.keymap.set("n", "<CR>", function()
      local entry = current_picker_entry()
      if entry then
        local ok = switch_from_picker(entry)
        if ok then
          close_picker()
        elseif picker_state.win and vim.api.nvim_win_is_valid(picker_state.win) then
          refresh_picker(entry)
        end
      end
    end, { buffer = buf, nowait = true })

    vim.keymap.set("n", "q", close_picker, { buffer = buf, nowait = true })

    vim.keymap.set("n", "r", function()
      ensure_picker_open()
      register_repo()
    end, { buffer = buf, nowait = true })

    vim.keymap.set("n", "w", function()
      ensure_picker_open()
      create_workspace()
    end, { buffer = buf, nowait = true })

    vim.keymap.set("n", "x", function()
      ensure_picker_open()
      remove_workspace()
    end, { buffer = buf, nowait = true })

    vim.keymap.set("n", "<Esc>", close_picker, { buffer = buf, nowait = true })

    vim.api.nvim_buf_set_option(buf, "modifiable", false)
  end

  local function ensure_picker_open()
    if not picker_state.win or not vim.api.nvim_win_is_valid(picker_state.win) then
      open_picker_window()
    end
  end

  local function toggle_picker()
    if picker_state.win and vim.api.nvim_win_is_valid(picker_state.win) then
      close_picker()
    else
      open_picker_window()
    end
  end

  switch_from_picker = function(entry)
    if not entry then
      return false
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
        return false
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
      return use_workspace({ name = name, path = canonical, repo = repo })
    end

    if entry.kind == "workspace" then
      return use_workspace({
        name = entry.name,
        path = entry.path,
        repo = entry.repo,
        repo_path = entry.repo_path,
      })
    end
    return false
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

  local function list_workspaces(repo)
    local ctx = current_workspace()
    local target_repo = repo or (ctx and ctx.repo)
    if not target_repo then
      notify("not inside a jj workspace and no repo specified", vim.log.levels.WARN)
      return {}
    end

    local cwd
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

  local function attention_refresh()
    if picker_state and picker_state.win and vim.api.nvim_win_is_valid(picker_state.win) then
      refresh_picker()
    end
  end

  local api = {
    open = open_picker_window,
    close = close_picker,
    toggle = toggle_picker,
    refresh = refresh_picker,
    current_entry = current_picker_entry,
    switch = switch_from_picker,
    register_repo = register_repo,
    create_workspace = create_workspace,
    remove_workspace = remove_workspace,
    list_workspaces = list_workspaces,
    attention_refresh = attention_refresh,
    ensure_open = ensure_picker_open,
  }

  return api
end

return Picker
