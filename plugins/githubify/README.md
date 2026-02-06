# githubify

Generate GitHub permalinks for the current buffer location in Neovim.

## Requirements

- Neovim 0.10+ (uses `vim.system`)
- `git` available in `$PATH`
- Current file should be inside a git repository (and tracked by git)

## Installation in this config

This repo already wires the plugin in `init.lua`:

```lua
{
  dir = vim.fn.stdpath("config") .. "/plugins/githubify",
  config = function()
    require("githubify").setup()
  end,
},
```

## Command

```vim
:Githubify [commit] [use_lineno] [base_url]
```

Arguments are optional and positional:

- `commit` (string): commit-ish (e.g. `HEAD`, `main`, tag, SHA). Default: `HEAD`
- `use_lineno` (number): `1` includes `#L<line>`, `0` excludes it. Default: `1`
- `base_url` (string): remote base URL override. Default: `origin` remote URL

The command:

- Prints the generated URL
- Copies it to `+` and `*` clipboard registers when available

## Examples

Use defaults (`HEAD`, include current line, origin remote):

```vim
:Githubify
```

Link to branch tip instead of current HEAD:

```vim
:Githubify main
```

Exclude line number:

```vim
:Githubify HEAD 0
```

Override base URL (useful for GitHub Enterprise):

```vim
:Githubify HEAD 1 https://github.example.com/org/repo
```

## Notes

- SSH remotes like `git@github.com:org/repo.git` are normalized to
  `https://github.com/org/repo`.
- File paths are URL-encoded to support spaces and special characters.

## Troubleshooting

- `Githubify failed: ... not a git repository`
  - Run the command from a file inside a git repo.
- `Githubify failed: Current file is not tracked by git`
  - `git add` the file first.
- `Githubify failed: ... unknown revision`
  - Verify the `commit` argument exists (`git rev-parse <commit>`).
