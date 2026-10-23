local M = {
  path = vim.fn.stdpath('state') .. '/project-profiles.json',
}

-- The registry can select these tags, but cannot supply settings or code.
local presets = {
  ['rust-all-features'] = {
    ['rust-analyzer'] = { cargo = { features = 'all' } },
  },
  ['rust-all-targets'] = {
    ['rust-analyzer'] = { cargo = { allTargets = true } },
  },
}

function M.apply(config)
  if not config.root_dir then
    return
  end

  local file = io.open(M.path, 'r')
  if not file then
    return
  end
  local contents = file:read('*a')
  file:close()

  local ok, registry = pcall(vim.json.decode, contents)
  if not ok or type(registry) ~= 'table' or vim.islist(registry) then
    vim.notify('Expected a JSON object in ' .. M.path, vim.log.levels.WARN)
    return
  end

  local tags = registry[config.root_dir]
  if tags == nil then
    return
  end
  if type(tags) ~= 'table' or not vim.islist(tags) then
    vim.notify('Expected a list of project tags in ' .. M.path, vim.log.levels.WARN)
    return
  end

  -- Apply tags in order; later tags take precedence for overlapping settings.
  for _, name in ipairs(tags) do
    if type(name) ~= 'string' or not presets[name] then
      vim.notify('Unknown project tag in ' .. M.path, vim.log.levels.WARN)
    else
      for server, settings in pairs(presets[name]) do
        config.settings[server] = vim.tbl_deep_extend('force', config.settings[server] or {}, settings)
      end
    end
  end
end

return M
