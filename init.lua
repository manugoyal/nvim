-- Package-agnostic configuration.

-- No vi compatibility
vim.opt.compatible = false

-- Enables hidden buffers
vim.opt.hidden = true

-- No syntax highlighting
vim.cmd("syntax off")

-- No filetype detection
vim.cmd("filetype off")

-- No filetype-specific indentation.
vim.cmd("filetype indent off")

-- Copy indent from the previous line
vim.opt.autoindent = true

-- Use spaces instead of tabs.
vim.opt.expandtab = true

-- 4 spaces per tab
vim.opt.tabstop = 4
vim.opt.shiftwidth = 4

-- No highlighting when searching
vim.opt.hlsearch = false

-- 80 characters per line (also controls wrapping by 'gq').
vim.opt.textwidth = 80
-- But don't auto-wrap text, only comments and 'gq'.
vim.opt.formatoptions = "cq"

-- If ripgrep is available, use it as our default grep program.
if vim.fn.executable("rg") then
  vim.opt.grepprg = "rg --vimgrep --smart-case --hidden"
  vim.opt.grepformat= "%f:%l:%c:%m"
end

-- Vim has a hard time guessing the background color in all terminals (e.g.
-- tmux), so set it explicitly.
vim.opt.background = "light"

-- Set the hardcoded python program, so neovim doesn't get confused when
-- launched within a virtualenv.
if os.getenv("NEOVIM_PYTHON3_HOST_PROG") ~= nil then
    vim.g.python3_host_prog = os.getenv("NEOVIM_PYTHON3_HOST_PROG")
end

-- Download lazy.vim package manager.
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable", -- latest stable release
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

-- Hide all semantic highlights
for _, group in ipairs(vim.fn.getcompletion("@lsp", "highlight")) do
  vim.api.nvim_set_hl(0, group, {})
end

-- Load packages
require("lazy").setup({
  "neovim/nvim-lspconfig",
  {"pmizio/typescript-tools.nvim",
   dependencies = { "nvim-lua/plenary.nvim", "neovim/nvim-lspconfig" },
   opts = {},
  },
  "tpope/vim-vinegar",
  "junegunn/fzf",
  "junegunn/fzf.vim",
  "manugoyal/githubify",
})

-- Fzf
vim.keymap.set('n', '<leader>fg',
               function () vim.cmd("GitFiles --recurse-submodules") end)
vim.keymap.set('n', '<leader>ff', function () vim.cmd("Files") end)
vim.keymap.set('n', '<leader>fb', function () vim.cmd("Buffers") end)

-- Set netrw sorting order to strictly lexicographic. Do this after loading
-- vim-vinegar, which has its own setting.
vim.api.nvim_create_autocmd('VimEnter', {
    callback = function(ev)
        if vim.g.loaded_vinegar then
            vim.g.netrw_sort_sequence = "*"
        end
    end,
})

-- lspconfig setup. Adapted from
-- https://github.com/neovim/nvim-lspconfig#Suggested-configuration.
local lspconfig = require("lspconfig")

-- Global mappings.
-- See `:help vim.diagnostic.*` for documentation on any of the below functions
vim.keymap.set('n', '<leader>le', vim.diagnostic.open_float)
vim.keymap.set('n', '<leader>lp', vim.diagnostic.goto_prev)
vim.keymap.set('n', '<leader>ln', vim.diagnostic.goto_next)
vim.keymap.set('n', '<leader>lq', function() 
    vim.diagnostic.setqflist({ severity = { min = vim.diagnostic.severity.WARN } })
end)

-- Use LspAttach autocommand to only map the following keys
-- after the language server attaches to the current buffer
vim.api.nvim_create_autocmd('LspAttach', {
  group = vim.api.nvim_create_augroup('UserLspConfig', {}),
  callback = function(ev)
    -- Use internal formatting for bindings like gq.
    vim.bo[ev.buf].formatexpr = nil

    -- Enable completion triggered by <c-x><c-o>
    vim.bo[ev.buf].omnifunc = 'v:lua.vim.lsp.omnifunc'

    -- Buffer local mappings.
    -- See `:help vim.lsp.*` for documentation on any of the below functions
    local opts = { buffer = ev.buf }
    vim.keymap.set('n', '<leader>lD', vim.lsp.buf.declaration, opts)
    vim.keymap.set('n', '<leader>ld', vim.lsp.buf.definition, opts)
    vim.keymap.set('n', '<leader>lr', vim.lsp.buf.references, opts)
    vim.keymap.set('n', '<leader>lt', vim.lsp.buf.type_definition, opts)
    vim.keymap.set('n', '<leader>lk', vim.lsp.buf.hover, opts)
    vim.keymap.set('n', '<leader>li', vim.lsp.buf.implementation, opts)
    vim.keymap.set('n', '<leader>lK', vim.lsp.buf.signature_help, opts)

    vim.keymap.set('n', '<leader>lwa', vim.lsp.buf.add_workspace_folder, opts)
    vim.keymap.set('n', '<leader>lwr', vim.lsp.buf.remove_workspace_folder, opts)
    vim.keymap.set('n', '<leader>lwl', function()
      print(vim.inspect(vim.lsp.buf.list_workspace_folders()))
    end, opts)

    vim.keymap.set('n', '<leader>lrn', vim.lsp.buf.rename, opts)
    vim.keymap.set({ 'n', 'v' }, '<leader>la', vim.lsp.buf.code_action, opts)
    vim.keymap.set('n', '<leader>lf', function()
      vim.lsp.buf.format { async = true }
    end, opts)
  end,
})

-- Typescript-specific setup.

-- typescript-tools
require("typescript-tools").setup {}

-- eslint
lspconfig.eslint.setup {}
