-- Test buffer reuse and persistence
-- Run: nvim --headless -u ~/.config/nvim/init.lua -c "luafile tests/test_buffer_reuse.lua"

local function test()
  print("=== Testing buffer reuse and persistence ===")

  local ghpr = require('gh-pr')
  ghpr.setup()

  -- Set up mock data
  ghpr.state.pr_number = 123
  ghpr.state.comments = {
    { type = "issue", id = "1", body = "Test comment", author = "user1", path = nil, line = 0, state = "PUBLISHED", thread_id = nil, reactions = "", viewer_reactions = {} },
  }

  -- Test 1: Create initial buffer
  print("\n1. Testing initial buffer creation...")
  ghpr.populate_comments_buffer({ focus = false })
  local first_buf = ghpr.state.comments_buf

  if not first_buf or not vim.api.nvim_buf_is_valid(first_buf) then
    print("FAIL: Initial buffer not created")
    return false
  end
  print("PASS: Initial buffer created (buf " .. first_buf .. ")")

  -- Test 2: Repopulate should reuse buffer
  print("\n2. Testing buffer reuse on repopulate...")
  ghpr.populate_comments_buffer({ focus = false })
  local second_buf = ghpr.state.comments_buf

  if second_buf ~= first_buf then
    print("FAIL: Buffer was recreated (expected " .. first_buf .. ", got " .. second_buf .. ")")
    return false
  end
  print("PASS: Buffer reused (still buf " .. second_buf .. ")")

  -- Test 3: Check bufhidden is "hide" (persistence)
  print("\n3. Testing buffer persistence setting...")
  local bufhidden = vim.api.nvim_buf_get_option(ghpr.state.comments_buf, "bufhidden")
  if bufhidden ~= "hide" then
    print("FAIL: bufhidden is '" .. bufhidden .. "' (expected 'hide')")
    return false
  end
  print("PASS: bufhidden is 'hide' (buffer persists when window closes)")

  -- Test 4: Close window, buffer should still exist
  print("\n4. Testing buffer survives window close...")
  -- Open window first
  ghpr.populate_comments_buffer({ focus = true })
  local win = ghpr.state.comments_win

  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_close(win, true)
    ghpr.state.comments_win = nil
  end

  if not vim.api.nvim_buf_is_valid(ghpr.state.comments_buf) then
    print("FAIL: Buffer was deleted when window closed")
    return false
  end
  print("PASS: Buffer still valid after window close")

  -- Test 5: Repopulate after window close should reuse buffer
  print("\n5. Testing buffer reuse after window close...")
  ghpr.populate_comments_buffer({ focus = false })
  local third_buf = ghpr.state.comments_buf

  if third_buf ~= first_buf then
    print("FAIL: Buffer was recreated after window close (expected " .. first_buf .. ", got " .. third_buf .. ")")
    return false
  end
  print("PASS: Buffer reused after window close (still buf " .. third_buf .. ")")

  print("\n=== Buffer reuse tests completed ===")
  return true
end

local ok, err = pcall(test)
if not ok then print("Error: " .. tostring(err)) end
vim.cmd("qa!")
