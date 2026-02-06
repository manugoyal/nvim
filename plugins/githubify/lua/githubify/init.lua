local M = {}

local function run_git(cwd, args)
  local result = vim.system(vim.list_extend({ "git" }, args), { cwd = cwd, text = true }):wait()
  if result.code ~= 0 then
    local err = (result.stderr or ""):gsub("%s+$", "")
    error(err ~= "" and err or ("git command failed: " .. table.concat(args, " ")))
  end
  return (result.stdout or ""):gsub("%s+$", "")
end

local function sanitize_origin_url(url)
  if url:sub(-4) == ".git" then
    url = url:sub(1, -5)
  end
  if not (url:match("^git@") and url:find(":", 1, true)) then
    return url
  end
  local host_and_path = url:match("^git@(.*)$")
  if not host_and_path then
    return url
  end
  local host, path = host_and_path:match("^([^:]+):(.+)$")
  if not host or not path then
    return url
  end
  return "https://" .. host .. "/" .. path
end

local function url_encode_path(path)
  return path:gsub("([^%w%-%._~/])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
end

function M.githubify(abs_filename, commit, lineno, base_url)
  local cwd = vim.fs.dirname(abs_filename)
  if not cwd or cwd == "" then
    error("Unable to determine file directory for current buffer")
  end

  local commit_ref = (commit and commit ~= "") and commit or "HEAD"
  local commit_sha = run_git(cwd, { "rev-parse", commit_ref })

  local base = base_url
  if not base or base == "" then
    local remote = run_git(cwd, { "remote", "get-url", "origin" })
    base = sanitize_origin_url(remote)
  end

  local rel_filename = run_git(cwd, { "ls-files", "--full-name", abs_filename })
  if rel_filename == "" then
    error("Current file is not tracked by git")
  end

  local suffix = lineno and ("#L" .. tostring(lineno)) or ""
  return string.format("%s/blob/%s/%s%s", base, commit_sha, url_encode_path(rel_filename), suffix)
end

function M.command(opts)
  local fargs = opts.fargs or {}
  local commit = fargs[1]
  local use_lineno = fargs[2] == nil and true or tonumber(fargs[2]) ~= 0
  local base_url = fargs[3]
  local abs_filename = vim.api.nvim_buf_get_name(0)

  if abs_filename == "" then
    vim.notify("No file in current buffer", vim.log.levels.ERROR)
    return
  end

  local lineno = use_lineno and vim.api.nvim_win_get_cursor(0)[1] or nil
  local ok, url = pcall(M.githubify, abs_filename, commit, lineno, base_url)
  if not ok then
    vim.notify("Githubify failed: " .. url, vim.log.levels.ERROR)
    return
  end

  pcall(vim.fn.setreg, "+", url)
  pcall(vim.fn.setreg, "*", url)
  print(url)
end

function M.setup()
  vim.api.nvim_create_user_command("Githubify", M.command, { nargs = "*" })
end

return M
