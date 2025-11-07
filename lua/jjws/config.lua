local util = require("jjws.util")

local M = {}
local META_KEY = "__meta"
M.META_KEY = META_KEY

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

function M.workspace_config()
  ensure_config_loaded()
  return config_cache
end

function M.save_config(notify)
  ensure_config_loaded()
  local path = config_path()
  local dir = vim.fn.fnamemodify(path, ":h")
  vim.fn.mkdir(dir, "p")
  local f, err = io.open(path, "w")
  if not f then
    if notify then
      notify("failed to open config: " .. (err or "unknown error"), vim.log.levels.ERROR)
    end
    return false
  end
  local ok, encoded = pcall(vim.json.encode, config_cache)
  if not ok then
    if notify then
      notify("failed to encode config: " .. encoded, vim.log.levels.ERROR)
    end
    f:close()
    return false
  end
  f:write(encoded)
  f:close()
  return true
end

function M.repo_entry(repo, create)
  if not repo or repo == "" then
    return nil
  end
  local cfg = M.workspace_config()
  if create and not cfg[repo] then
    cfg[repo] = {}
  end
  return cfg[repo]
end

function M.update_workspace(repo, name, path, repo_path, notify)
  if not repo or repo == "" or not name or name == "" or not path or path == "" then
    if notify then
      notify("invalid workspace update request", vim.log.levels.ERROR)
    end
    return
  end
  local entry = M.repo_entry(repo, true)
  M.ensure_repo_meta(repo, repo_path)
  entry[name] = { path = util.canonical_path(path) or path }
  M.save_config(notify)
end

function M.delete_workspace(repo, name, notify)
  local entry = M.repo_entry(repo)
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
    M.workspace_config()[repo] = nil
  end
  M.save_config(notify)
end

function M.find_repo_by_path(repo_path)
  if not repo_path then
    return nil
  end
  local target = util.canonical_path(repo_path)
  if not target then
    return nil
  end
  for name, cfg in pairs(M.workspace_config()) do
    if type(cfg) == "table" then
      local meta = cfg[META_KEY]
      if meta and meta.repo_path and util.canonical_path(meta.repo_path) == target then
        return name
      end
    end
  end
  return nil
end

function M.find_repo_by_workspace_path(path)
  local target = util.canonical_path(path)
  if not target then
    return nil
  end
  for name, cfg in pairs(M.workspace_config()) do
    if type(cfg) == "table" then
      for key, info in pairs(cfg) do
        if key ~= META_KEY and info and info.path then
          local stored = util.canonical_path(info.path) or util.trim(info.path)
          if stored == target then
            return name
          end
        end
      end
    end
  end
  return nil
end

function M.ensure_repo_meta(repo, repo_path)
  if not repo or repo == "" then
    return nil
  end
  local entry = M.repo_entry(repo, true)
  entry[META_KEY] = entry[META_KEY] or {}
  if repo_path and repo_path ~= "" then
    entry[META_KEY].repo_path = util.canonical_path(repo_path)
  end
  return entry[META_KEY]
end

function M.repo_storage_path(root)
  if not root or root == "" then
    return nil
  end
  local spec = util.joinpath(root, ".jj/repo")
  local uv = vim.uv or vim.loop
  local st = uv.fs_stat(spec)
  if not st then
    return nil
  end
  if st.type == "file" then
    local target = util.trim(util.read_file(spec) or "")
    if target ~= "" then
      return util.canonical_path(target)
    end
    return nil
  end
  return util.canonical_path(spec)
end

function M.repo_default_root(repo_path)
  if not repo_path then
    return nil
  end
  local root = vim.fn.fnamemodify(repo_path, ":h:h")
  if root and root ~= "" then
    return util.canonical_path(root)
  end
  return nil
end

function M.repo_from_root(root)
  if not root or root == "" then
    return nil
  end
  local repo_path = M.repo_storage_path(root)
  if repo_path then
    local existing = M.find_repo_by_path(repo_path)
    if existing then
      return existing
    end
    local workspace_match = M.find_repo_by_workspace_path(root)
    if workspace_match then
      M.ensure_repo_meta(workspace_match, repo_path)
      return workspace_match
    end
    local default_name = vim.fn.fnamemodify(repo_path, ":h:h:t")
    if default_name and default_name ~= "" then
      return default_name
    end
  end
  return vim.fn.fnamemodify(root, ":t")
end

function M.find_workspace(repo, path)
  local cfg = M.workspace_config()[repo]
  if not cfg then
    return nil
  end
  local target = util.canonical_path(path) or util.trim(path)
  for name, info in pairs(cfg) do
    if name ~= META_KEY and info then
      local stored = util.canonical_path(info.path or "") or util.trim(info.path)
      if stored == target then
        return name, info
      end
    end
  end
  return nil
end

function M.repo_any_path(repo)
  local entry = M.repo_entry(repo)
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
    return M.repo_default_root(meta.repo_path)
  end
  return nil
end

return M
