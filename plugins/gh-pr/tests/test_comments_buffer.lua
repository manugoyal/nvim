-- Test comments buffer creation and navigation
-- Run: nvim --headless -u ~/.config/nvim/init.lua -c "luafile tests/test_comments_buffer.lua"

local function test()
  print("=== Testing comments buffer ===")

  local ghpr = require('gh-pr')
  ghpr.setup()

  -- Set up mock comments
  ghpr.state.pr_number = 123
  ghpr.state.comments = {
    { type = "issue", id = "1", body = "General comment 1", author = "user1", path = nil, line = 0, state = "PUBLISHED", thread_id = nil, reactions = "", viewer_reactions = {} },
    { type = "issue", id = "2", body = "General comment 2", author = "user2", path = nil, line = 0, state = "PUBLISHED", thread_id = nil, reactions = "", viewer_reactions = {} },
    { type = "review", id = "3", body = "Review comment on file1", author = "user1", path = "file1.lua", line = 10, state = "COMMENTED", thread_id = "t1", reactions = "", viewer_reactions = {} },
    { type = "review", id = "4", body = "Reply to review comment", author = "user2", path = "file1.lua", line = 10, state = "COMMENTED", thread_id = "t1", reactions = "", viewer_reactions = {} },
    { type = "review", id = "5", body = "Pending comment", author = "user1", path = "file2.lua", line = 20, state = "PENDING", thread_id = "t2", reactions = "", viewer_reactions = {} },
  }

  -- Test buffer creation
  print("\n1. Testing buffer creation...")
  ghpr.populate_comments_buffer({ focus = false })

  if not ghpr.state.comments_buf then
    print("FAIL: comments_buf is nil")
    return false
  end

  if not vim.api.nvim_buf_is_valid(ghpr.state.comments_buf) then
    print("FAIL: comments_buf is not valid")
    return false
  end
  print("PASS: Buffer created and valid")

  -- Check buffer options
  local bufhidden = vim.api.nvim_buf_get_option(ghpr.state.comments_buf, "bufhidden")
  if bufhidden == "hide" then
    print("PASS: bufhidden is 'hide' (buffer persists)")
  else
    print("FAIL: bufhidden is '" .. bufhidden .. "' (expected 'hide')")
  end

  -- Check buffer content
  local lines = vim.api.nvim_buf_get_lines(ghpr.state.comments_buf, 0, -1, false)
  print("PASS: Buffer has " .. #lines .. " lines")

  -- Check line map
  local map_count = 0
  for _ in pairs(ghpr.state.comment_line_map) do map_count = map_count + 1 end
  if map_count == #ghpr.state.comments then
    print("PASS: comment_line_map has " .. map_count .. " entries (matches comment count)")
  else
    print("FAIL: comment_line_map has " .. map_count .. " entries (expected " .. #ghpr.state.comments .. ")")
  end

  -- Test navigation
  print("\n2. Testing comment navigation...")
  ghpr.state.current_comment_idx = 1
  print("  Initial index: " .. ghpr.state.current_comment_idx)

  ghpr.next_comment()
  if ghpr.state.current_comment_idx == 2 then
    print("PASS: next_comment increments index")
  else
    print("FAIL: next_comment index is " .. ghpr.state.current_comment_idx .. " (expected 2)")
  end

  ghpr.prev_comment()
  if ghpr.state.current_comment_idx == 1 then
    print("PASS: prev_comment decrements index")
  else
    print("FAIL: prev_comment index is " .. ghpr.state.current_comment_idx .. " (expected 1)")
  end

  -- Test boundary conditions
  print("\n3. Testing boundary conditions...")
  ghpr.state.current_comment_idx = 1
  ghpr.prev_comment()  -- Should notify "Already at first comment"
  if ghpr.state.current_comment_idx == 1 then
    print("PASS: prev_comment at start stays at 1")
  else
    print("FAIL: prev_comment at start changed index to " .. ghpr.state.current_comment_idx)
  end

  ghpr.state.current_comment_idx = #ghpr.state.comments
  ghpr.next_comment()  -- Should notify "Already at last comment"
  if ghpr.state.current_comment_idx == #ghpr.state.comments then
    print("PASS: next_comment at end stays at last")
  else
    print("FAIL: next_comment at end changed index")
  end

  print("\n=== Comments buffer tests completed ===")
  return true
end

local ok, err = pcall(test)
if not ok then print("Error: " .. tostring(err)) end
vim.cmd("qa!")
