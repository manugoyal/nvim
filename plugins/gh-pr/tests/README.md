# gh-pr.nvim Test Suite

This directory contains test scripts for verifying the gh-pr plugin functionality.

## Running Tests

### Headless Tests (Unit Tests)

These tests run in headless Neovim and verify plugin functionality with mock data:

```bash
cd ~/.config/nvim/plugins/gh-pr

# Run all headless tests
nvim --headless -u ~/.config/nvim/init.lua -c "luafile tests/test_basic.lua"
nvim --headless -u ~/.config/nvim/init.lua -c "luafile tests/test_comments_buffer.lua"
nvim --headless -u ~/.config/nvim/init.lua -c "luafile tests/test_buffer_reuse.lua"
nvim --headless -u ~/.config/nvim/init.lua -c "luafile tests/test_guards.lua"
nvim --headless -u ~/.config/nvim/init.lua -c "luafile tests/test_layout.lua"
```

Or run them all in sequence:

```bash
for test in tests/test_*.lua; do
  echo "Running $test..."
  nvim --headless -u ~/.config/nvim/init.lua -c "luafile $test"
  echo ""
done
```

### Expected Output

Each test should print PASS/FAIL for each check. Note that tests may be slow to exit in headless mode (this is normal - the assertions complete quickly but cleanup may take a moment).

Example:

```
=== Testing gh-pr plugin basics ===
PASS: Plugin loaded
PASS: Setup completed
PASS: State initialized
PASS: All required functions exist (16 functions)
PASS: Found 17/17 expected commands
```

## Test Descriptions

### test_basic.lua
Tests basic plugin loading and setup:
- Plugin can be required
- Setup completes without error
- State is properly initialized
- All required functions exist
- All expected commands are registered

### test_comments_buffer.lua
Tests the custom comments buffer:
- Buffer creation and validation
- Buffer persistence (`bufhidden = "hide"`)
- Comment line map population
- Navigation (next/prev comment)
- Boundary conditions (first/last comment)

### test_buffer_reuse.lua
Tests buffer reuse and persistence:
- Initial buffer creation
- Buffer reuse on repopulate (same buffer ID)
- Buffer survives window close
- Buffer reuse after window close

### test_guards.lua
Tests guard conditions and error handling:
- `open_file_diff` without `merge_base` returns false
- `select_file_by_path` with non-existent file returns false
- `next_comment`/`prev_comment` with no comments doesn't error
- `get_current_comment` with invalid index returns nil
- `close_comments` with no buffer doesn't error
- `restore_layout` without PR data doesn't error
- `reload_current_file` without PR data doesn't error

### test_layout.lua
Tests layout restoration functionality:
- `restore_layout` requires PR data
- `restore_layout` handles missing PR number
- `reload_current_file` delegates to `restore_layout`
- `populate_comments_buffer` creates valid buffer
- Comments buffer is reused on repopulate

## Manual Testing with Real PRs

For full integration testing with real GitHub PRs:

### Prerequisites
1. Checkout a branch that has an open PR
2. Ensure `gh` CLI is authenticated (`gh auth status`)
3. Be in a git repository

### Test Workflow

```bash
# 1. Checkout a branch with an open PR
git checkout my-feature-branch

# 2. Verify PR exists
gh pr view

# 3. Open Neovim and run tests
nvim
```

In Neovim:

```vim
" Load the review UI
:GHPRReview

" Test file navigation
]f                     " Next file
[f                     " Previous file

" Test comment navigation
j                      " Next comment (in comments buffer)
k                      " Previous comment
<CR>                   " Go to comment location

" Test adding comments
:GHPRCommentAdd        " Add comment on current line
" Write comment, :wq to submit

" Test reply to comment
r                      " Reply to thread (in comments buffer)
" Write reply, :wq to submit

" Test layout restoration
:q                     " Close a panel
:GHPRReloadFile        " Restore layout

" Test review submission
:GHPRReviewSubmit      " Submit review (COMMENT/APPROVE/REQUEST_CHANGES)
```

### Things to Verify Manually

1. **Unified Layout**: `:GHPRReview` opens file list, diffs, and comments together
2. **Comment Navigation**: `j`/`k` move between comments, cursor indicator updates
3. **Jump to Location**: `<CR>` on a comment jumps to the file and line
4. **Add Comment**: `<leader>gha` opens edit buffer, submitting returns to original buffer
5. **Reply to Comment**: `r` opens reply buffer, submitting returns to comments buffer
6. **Layout Restore**: `<leader>gh.` restores missing panels
7. **Reactions**: `+` to add, `-` to remove emoji reactions
8. **Preview**: `p` shows full comment in floating window
9. **View Original**: `o` on outdated comments shows file at original commit

## Adding New Tests

When adding new functionality:

1. Create a new test file `test_<feature>.lua`
2. Follow the existing pattern:
   - `local function test() ... end`
   - `pcall(test)` wrapper for error handling
   - `vim.cmd("qa!")` at the end for headless exit
3. Print PASS/FAIL for each assertion
4. Add the test to this README
