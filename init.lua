-- Load from ~/.vim
vim.cmd([[
set runtimepath^=~/.vim runtimepath+=~/.vim/after
let &packpath = &runtimepath
source ~/.vim/vimrc
]])

-- lazy.vim
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

-- Load packages.
require("lazy").setup({
  {"pmizio/typescript-tools.nvim",
   dependencies = { "nvim-lua/plenary.nvim", "neovim/nvim-lspconfig" },
   opts = {},
  },
  "tpope/vim-vinegar",
  "junegunn/fzf",
  "junegunn/fzf.vim",
})
