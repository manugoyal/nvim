-- Test basic plugin loading and setup
-- Run: nvim --headless -u ~/.config/nvim/init.lua -c "luafile tests/test_basic.lua"

local function test()
  print("=== Testing gh-pr plugin basics ===")

  -- Load plugin
  local ok, ghpr = pcall(require, 'gh-pr')
  if not ok then
    print("FAIL: Could not load plugin: " .. tostring(ghpr))
    return false
  end
  print("PASS: Plugin loaded")

  -- Setup
  ok, err = pcall(ghpr.setup)
  if not ok then
    print("FAIL: Setup failed: " .. tostring(err))
    return false
  end
  print("PASS: Setup completed")

  -- Check state initialization
  if ghpr.state then
    print("PASS: State initialized")
    print("  - comments_buf: " .. tostring(ghpr.state.comments_buf))
    print("  - files: " .. tostring(#ghpr.state.files))
    print("  - comment_line_map: " .. type(ghpr.state.comment_line_map))
  else
    print("FAIL: State not initialized")
    return false
  end

  -- Check key functions exist
  local required_functions = {
    "load_comments", "load_comments_async", "populate_comments_buffer",
    "add_comment", "edit_comment", "delete_comment", "reply_to_thread",
    "start_review", "close_review", "open_file_diff", "next_file", "prev_file",
    "next_comment", "prev_comment", "restore_layout", "reload_current_file",
  }

  local all_exist = true
  for _, fn_name in ipairs(required_functions) do
    if type(ghpr[fn_name]) ~= "function" then
      print("FAIL: Missing function: " .. fn_name)
      all_exist = false
    end
  end
  if all_exist then
    print("PASS: All required functions exist (" .. #required_functions .. " functions)")
  end

  -- Check commands exist
  local expected_commands = {
    "GHPRComments", "GHPRCommentsClose", "GHPRNextComment", "GHPRPrevComment",
    "GHPRReview", "GHPRReviewClose", "GHPRNextFile", "GHPRPrevFile",
    "GHPRReloadFile", "GHPRCommentAdd", "GHPRCommentEdit", "GHPRCommentDelete",
    "GHPRCommentReply", "GHPRReviewSubmit", "GHPRGoto", "GHPRReact", "GHPRUnreact",
  }
  local all_commands = vim.api.nvim_get_commands({})
  local found = 0
  for _, cmd in ipairs(expected_commands) do
    if all_commands[cmd] then
      found = found + 1
    else
      print("FAIL: Missing command: " .. cmd)
    end
  end
  print("PASS: Found " .. found .. "/" .. #expected_commands .. " expected commands")

  print("\n=== Basic tests completed ===")
  return true
end

local ok, err = pcall(test)
if not ok then print("Error: " .. tostring(err)) end
vim.cmd("qa!")
