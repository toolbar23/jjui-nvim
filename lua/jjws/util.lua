local M = {}

function M.trim(s)
  if not s then
    return ""
  end
  if vim.trim then
    return vim.trim(s)
  end
  return vim.fn.trim(s)
end

function M.joinpath(parent, child)
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

function M.workspace_root_from_jj(cwd)
  local ok, res = pcall(function()
    return vim.system({ "bash", "-lc", "jj workspace root" }, { text = true, cwd = cwd or vim.fn.getcwd() }):wait()
  end)
  if not ok or not res or res.code ~= 0 then
    return nil
  end
  local root = M.trim(res.stdout)
  return root ~= "" and root or nil
end

function M.notify(msg, level)
  vim.notify("[jjws] " .. msg, level or vim.log.levels.INFO)
end

function M.set_default_highlight(name, opts)
  local ok, current = pcall(vim.api.nvim_get_hl, 0, { name = name, link = false })
  if ok and current and not vim.tbl_isempty(current) then
    return
  end
  vim.api.nvim_set_hl(0, name, opts)
end

function M.canonical_path(path)
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

function M.dir_exists(path)
  if not path or path == "" then
    return false
  end
  local uv = vim.uv or vim.loop
  local st = uv.fs_stat(path)
  return st and st.type == "directory"
end

function M.clone_cmd(cmd)
  if type(cmd) ~= "table" then
    return cmd
  end
  local copy = {}
  for i, v in ipairs(cmd) do
    copy[i] = v
  end
  return copy
end

function M.normalize_system_cmd(cmd)
  if not cmd then
    return nil
  end
  if type(cmd) == "string" then
    return { "bash", "-lc", cmd }
  elseif type(cmd) == "table" then
    return M.clone_cmd(cmd)
  end
  return nil
end

function M.parent_dir(path)
  return vim.fn.fnamemodify(path, ":h")
end

function M.read_file(path)
  local f = io.open(path, "r")
  if not f then
    return nil
  end
  local data = f:read("*a")
  f:close()
  return data
end

function M.strip_ansi(text)
  if not text or text == "" then
    return text
  end
  return text:gsub("\27%[[%d;]*m", "")
end

return M
