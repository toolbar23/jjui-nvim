-- lua/jjws/init.lua
local util = require("jjws.util")
local config_module = require("jjws.config")
local diff_module = require("jjws.diff")
local picker_module = require("jjws.picker")
local workspace_module = require("jjws.workspace")
local agent_module = require("jjws.agent")

local M = {}

local open_agent
local diff_refresh
local diff_comment
local picker_api
local strip_ansi
local is_agent_buffer
local hide_agent_buffer
local attach_agent_autocmds
local agent_abbrev_target
local revive_agent_buffer
local agent_buffers
local agent_sizes
local agent_window_size

local function trim(s)
  return util.trim(s)
end

local function joinpath(parent, child)
  return util.joinpath(parent, child)
end

local function workspace_root_from_jj(cwd)
  return util.workspace_root_from_jj(cwd)
end

local function notify(msg, level)
  return util.notify(msg, level)
end

local function save_config()
  return config_module.save_config(notify)
end

local function workspace_config()
  return config_module.workspace_config()
end

local function canonical_path(path)
  return util.canonical_path(path)
end

local function repo_storage_path(root)
  return config_module.repo_storage_path(root)
end

local function repo_from_root(root)
  return config_module.repo_from_root(root)
end

local function repo_default_root(repo_path)
  return config_module.repo_default_root(repo_path)
end

local function find_workspace(repo, path)
  return config_module.find_workspace(repo, path)
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
  agent_term_cols = 80, -- terminal column count reported to the agent
  diff_command = { "bash", "-lc", "jj diff" },
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
local current_pid = (uv and uv.os_getpid and uv.os_getpid()) or vim.fn.getpid()

strip_ansi = util.strip_ansi

local function picker_attention_refresh()
  if picker_api and picker_api.attention_refresh then
    picker_api.attention_refresh()
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
  local registered = true
  if not name then
    registered = false
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
    unregistered = not registered,
  }
end

local function is_valid_buf(buf)
  return type(buf) == "number" and buf > 0 and vim.api.nvim_buf_is_valid(buf)
end

local function is_valid_win(win)
  return type(win) == "number" and win > 0 and vim.api.nvim_win_is_valid(win)
end

local function noop()
end

local function always_true()
  return true
end

local save_workspace_layout = noop
local restore_workspace_layout = noop
local maybe_handle_locked_workspace = always_true
local acquire_workspace_lock = always_true
local release_workspace_lock = noop
local save_last = noop
local function load_last_stub()
  return nil
end
local load_last = load_last_stub
local function default_lock_status()
  return { locked = false }
end
local workspace_lock_status = default_lock_status
local function passthrough_ref(ws)
  return ws
end
local normalize_workspace_ref = passthrough_ref
local function attention_false()
  return false
end
local function attention_noop()
  return false
end
local workspace_has_attention = attention_false
local mark_workspace_attention = attention_noop
local clear_workspace_attention = attention_noop
local function empty_collect_repo_workspaces()
  return {}
end
local collect_repo_workspaces = empty_collect_repo_workspaces
local function empty_known_repos()
  return {}, {}, nil
end
local known_repos = empty_known_repos
local ensure_initial_restore

ensure_initial_restore = function()
  if ui_state.initial_restored then
    return
  end
  ui_state.initial_restored = true
  local ok, ctx = pcall(current_workspace)
  if ok and ctx and not ctx.unregistered then
    ctx.path = ctx.root
    active_workspace = ctx
    maybe_handle_locked_workspace(ctx, { allow_prompt = false })
    if not ctx.detached then
      local lock_ok = acquire_workspace_lock(ctx)
      if not lock_ok then
        ctx.detached = true
        notify(
          string.format("%s locked elsewhere; running detached.", workspace_label(ctx)),
          vim.log.levels.WARN
        )
      end
    end
    if not ctx.detached then
      restore_workspace_layout(ctx)
    end
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

  local agent_api = agent_module.setup({
    cfg = cfg,
    notify = notify,
    trim = trim,
    strip_ansi = strip_ansi,
    clone_cmd = util.clone_cmd,
    normalize_system_cmd = util.normalize_system_cmd,
    workspace_label = workspace_label,
    workspace_snapshot = workspace_snapshot,
    workspace_key = workspace_key,
    mark_workspace_attention = function(...)
      return mark_workspace_attention(...)
    end,
    get_active_workspace = function()
      return active_workspace
    end,
    current_workspace = current_workspace,
    save_workspace_layout = function(...)
      return save_workspace_layout(...)
    end,
  })

  open_agent = agent_api.open
  hide_agent_buffer = agent_api.hide
  is_agent_buffer = agent_api.is_agent_buffer
  attach_agent_autocmds = agent_api.attach_autocmds
  revive_agent_buffer = agent_api.revive
  agent_buffers = agent_api.buffers
  agent_sizes = agent_api.sizes
  agent_window_size = agent_api.window_size
  agent_abbrev_target = agent_api.abbrev_target

  local workspace_api = workspace_module.setup({
    cfg = cfg,
    notify = notify,
    trim = trim,
    workspace_label = workspace_label,
    workspace_key = workspace_key,
    canonical_path = canonical_path,
    repo_storage_path = repo_storage_path,
    repo_default_root = repo_default_root,
    workspace_config = workspace_config,
    repo_entry = config_module.repo_entry,
    dir_exists = util.dir_exists,
    joinpath = joinpath,
    parent_dir = util.parent_dir,
    META_KEY = config_module.META_KEY,
    agent_buffers = agent_buffers,
    agent_sizes = agent_sizes,
    agent_window_size = agent_window_size,
    open_agent = open_agent,
    revive_agent_buffer = revive_agent_buffer,
    current_pid = current_pid,
    uv = uv,
    attention_refresh = picker_attention_refresh,
    get_active_workspace = function()
      return active_workspace
    end,
    current_workspace = current_workspace,
  })

  normalize_workspace_ref = workspace_api.normalize_workspace_ref
  workspace_lock_status = workspace_api.workspace_lock_status
  acquire_workspace_lock = workspace_api.acquire_lock
  release_workspace_lock = workspace_api.release_lock
  maybe_handle_locked_workspace = workspace_api.maybe_handle_locked_workspace
  save_workspace_layout = workspace_api.save_layout
  restore_workspace_layout = workspace_api.restore_layout
  save_last = workspace_api.save_last
  load_last = workspace_api.load_last
  workspace_has_attention = workspace_api.has_attention
  mark_workspace_attention = workspace_api.mark_attention
  clear_workspace_attention = workspace_api.clear_attention
  collect_repo_workspaces = workspace_api.collect_repo_workspaces
  known_repos = workspace_api.known_repos

  picker_api = picker_module.setup({
    cfg = cfg,
    notify = notify,
    trim = trim,
    set_default_highlight = set_default_highlight,
    workspace_config = workspace_config,
    repo_entry = config_module.repo_entry,
    update_workspace = function(repo, name, path, repo_path)
      return config_module.update_workspace(repo, name, path, repo_path, notify)
    end,
    delete_workspace = function(repo, name)
      return config_module.delete_workspace(repo, name, notify)
    end,
    repo_any_path = config_module.repo_any_path,
    repo_default_root = repo_default_root,
    find_workspace = find_workspace,
    repo_storage_path = repo_storage_path,
    dir_exists = util.dir_exists,
    joinpath = joinpath,
    parent_dir = util.parent_dir,
    canonical_path = canonical_path,
    workspace_has_attention = workspace_has_attention,
    normalize_workspace_ref = normalize_workspace_ref,
    workspace_lock_status = workspace_lock_status,
    current_workspace = current_workspace,
    use_workspace = function(ws, picker_opts)
      return M.use_workspace(ws, picker_opts)
    end,
    META_KEY = config_module.META_KEY,
    collect_repo_workspaces = collect_repo_workspaces,
    known_repos = known_repos,
  })

  local diff_api = diff_module.setup({
    cfg = cfg,
    notify = notify,
    trim = trim,
    strip_ansi = strip_ansi,
    is_valid_buf = is_valid_buf,
    is_valid_win = is_valid_win,
    workspace_key = workspace_key,
    current_workspace = current_workspace,
    get_active_workspace = function()
      return active_workspace
    end,
    open_agent = open_agent,
    agent_buffers = agent_buffers,
    attach_agent_autocmds = attach_agent_autocmds,
  })
  diff_refresh = diff_api.refresh
  diff_comment = diff_api.comment
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
