-- Neovim Configuration

-- Basic Options
vim.opt.compatible = false      -- No vi compatibility (default in Neovim)
vim.opt.hidden = true           -- Allow hidden buffers
vim.opt.autoindent = true       -- Copy indent from previous line
vim.opt.expandtab = true        -- Use spaces instead of tabs
vim.opt.tabstop = 4             -- 4 spaces per tab
vim.opt.shiftwidth = 4          -- 4 spaces for indentation
vim.opt.hlsearch = false        -- No search highlighting
vim.opt.textwidth = 80          -- 80 characters per line
vim.opt.formatoptions = "cq"    -- Only auto-wrap comments and use 'gq'
if vim.fn.executable("rg") == 1 then
  vim.opt.grepprg = "rg --vimgrep --smart-case"
end

-- Disable syntax and filetype features
vim.cmd("syntax off")
vim.cmd("filetype off")
vim.cmd("filetype indent off")

-- Note: fzf-lua automatically uses ripgrep for live_grep if available

-- Python host configuration
-- Use dedicated virtual environment for Neovim
local venv_python = vim.fn.stdpath("config") .. "/venv/bin/python"
if vim.fn.executable(venv_python) == 1 then
    vim.g.python3_host_prog = venv_python
end

-- Package Manager Setup (lazy.nvim)
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable",
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

-- Plugin Configuration
require("lazy").setup({
  {
    "ibhagwan/fzf-lua",
    config = function()
      require("fzf-lua").setup({
        defaults = {
          keymap = {
            fzf = {
              -- Ctrl+Q to select all items and accept (works in all pickers)
              ["ctrl-q"] = "select-all+accept"
            }
          }
        },
        files = {
          -- Use fd to find files, including in submodules
          cmd = "fd --type f --hidden --follow --exclude .git",
        },
        git = {
          files = {
            -- Include submodules in git files search
            cmd = "git ls-files --recurse-submodules",
          },
        },
        grep = {
          -- Use rg with submodule support
          rg_opts = "--column --line-number --no-heading --color=always --smart-case --max-columns=4096 --hidden --follow",
          actions = {
            -- Ctrl+Q in live_grep sends all results to quickfix window
            ["ctrl-q"] = { 
              fn = require"fzf-lua".actions.file_sel_to_qf, 
              prefix = "select-all" 
            }
          }
        }
      })
    end
  },
  "manugoyal/githubify",
  "neovim/nvim-lspconfig",
  "nvim-lua/plenary.nvim",
  {
    "pmizio/typescript-tools.nvim",
    dependencies = {
      "nvim-lua/plenary.nvim",
      "neovim/nvim-lspconfig"
    },
    opts = {
        on_attach = function(client, bufnr)
          vim.keymap.set('n', 'gs', '<cmd>TSToolsGoToSourceDefinition<CR>', {
              buffer = bufnr,
              desc = "Go to Source Definition",
          })
        end,
    }
  },
  {
    "Exafunction/codeium.vim",
    event = "BufEnter",
    config = function()
      -- Disable default bindings
      vim.g.codeium_disable_bindings = 1
      -- Set up Tab for accepting suggestions
      vim.keymap.set('i', '<Tab>', function()
        return vim.fn['codeium#Accept']()
      end, { expr = true, silent = true })
    end
  },
  {
    "sindrets/diffview.nvim",
    cmd = { "DiffviewOpen", "DiffviewClose" },
    opts = {
      -- This is the "magic" setting that enables LSP on the RHS
      default_args = {
        DiffviewOpen = { "--imply-local" },
      },
      enhanced_diff_hl = true, -- Better syntax highlighting
      use_icons = true,
      icons = {
        folder_closed = "",
        folder_open = "",
      },
      view = {
        -- Use horizontal layout for side-by-side diff (left/right panes)
        default = { layout = "diff2_horizontal" },
      },
    },
  },
  {
    dir = vim.fn.stdpath("config") .. "/plugins/gh-pr",
    config = function()
      require("gh-pr").setup()
    end,
  },
})

-- Commands

-- Open Diffview for the current PR (from merge-base to HEAD)
vim.api.nvim_create_user_command("DiffviewPR", function()
  local base_branch = vim.fn.system("gh pr view --json baseRefName -q .baseRefName")
  if vim.v.shell_error ~= 0 then
    vim.notify("Failed to get PR base branch: " .. base_branch, vim.log.levels.ERROR)
    return
  end
  base_branch = vim.trim(base_branch)

  local merge_base = vim.fn.system("git merge-base origin/" .. base_branch .. " HEAD")
  if vim.v.shell_error ~= 0 then
    vim.notify("Failed to get merge-base: " .. merge_base, vim.log.levels.ERROR)
    return
  end
  merge_base = vim.trim(merge_base)

  vim.cmd("DiffviewOpen " .. merge_base)
end, { desc = "Open Diffview for current PR changes" })

-- Key Mappings

-- GitHub PR mappings
vim.keymap.set('n', '<leader>ghc', "<cmd>GHPRComments<cr>", { desc = "Load GitHub PR comments" })

-- fzf-lua mappings
vim.keymap.set('n', '<leader>ff', "<cmd>FzfLua files<cr>", { desc = "Find files" })
vim.keymap.set('n', '<leader>fg', "<cmd>FzfLua git_files<cr>", { desc = "Find git files" })
vim.keymap.set('n', '<leader>fb', "<cmd>FzfLua buffers<cr>", { desc = "Find buffers" })
vim.keymap.set('n', '<leader>fl', "<cmd>FzfLua live_grep<cr>", { desc = "Live grep" })
vim.keymap.set('n', '<leader>fw', "<cmd>FzfLua grep_cword<cr>", { desc = "Grep word under cursor" })

-- File explorer
vim.keymap.set('n', '-', "<cmd>Explore<cr>", { desc = "Open netrw" })

-- Copy filepath to register (use with "x<leader>cp to copy to register x)
vim.keymap.set('n', '<leader>cp', function()
  local filepath = vim.fn.expand('%')
  local reg = vim.v.register
  vim.fn.setreg(reg, filepath)
  print('Copied to register ' .. reg .. ': ' .. filepath)
end, { desc = "Copy filepath to register" })

-- Copy filepath:line to register (use with "x<leader>cl to copy to register x)
vim.keymap.set('n', '<leader>cl', function()
  local filepath = vim.fn.expand('%')
  local line = vim.fn.line('.')
  local location = filepath .. ':' .. line
  local reg = vim.v.register
  vim.fn.setreg(reg, location)
  print('Copied to register ' .. reg .. ': ' .. location)
end, { desc = "Copy filepath:line to register" })

-- Netrw Configuration
vim.g.netrw_sort_sequence = "*"  -- Lexicographic sorting

-- Disable LSP semantic highlights
for _, group in ipairs(vim.fn.getcompletion("@lsp", "highlight")) do
  vim.api.nvim_set_hl(0, group, {})
end

-- LSP Configuration

-- LSP attach configuration
vim.api.nvim_create_autocmd('LspAttach', {
  group = vim.api.nvim_create_augroup('UserLspConfig', {}),
  callback = function(ev)
    -- Enable completion triggered by <c-x><c-o>
    vim.bo[ev.buf].omnifunc = 'v:lua.vim.lsp.omnifunc'
    
    -- Disable LSP formatting for gq
    vim.bo[ev.buf].formatexpr = nil
    
    -- Buffer local mappings
    local opts = { buffer = ev.buf }
    vim.keymap.set('n', 'gd', vim.lsp.buf.definition, opts)
    vim.keymap.set('n', 'gt', vim.lsp.buf.type_definition, opts)
    vim.keymap.set('n', 'gi', vim.lsp.buf.implementation, opts)
    vim.keymap.set('n', 'gD', vim.lsp.buf.declaration, opts)
    vim.keymap.set({ 'n', 'v' }, '<leader>ca', vim.lsp.buf.code_action, opts)
    vim.keymap.set('n', 'gr', vim.lsp.buf.references, opts)
  end,
})

-- Language server configurations

-- Python
vim.lsp.enable('pyright')
vim.lsp.config.pyright = {}

-- Rust
vim.lsp.enable('rust_analyzer')
vim.lsp.config.rust_analyzer = {
  settings = {
    ["rust-analyzer"] = {
      checkOnSave = {
        command = "clippy"
      }
    }
  }
}

-- TypeScript/JavaScript (using typescript-tools.nvim)
-- Configuration handled by lazy.nvim opts
