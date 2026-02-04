-- Test guard conditions and error handling
-- Run: nvim --headless -u ~/.config/nvim/init.lua -c "luafile tests/test_guards.lua"

local function test()
  print("=== Testing guard conditions ===")

  local ghpr = require('gh-pr')
  ghpr.setup()

  -- Test 1: open_file_diff without merge_base should return false
  print("\n1. Testing open_file_diff without merge_base...")
  ghpr.state.merge_base = nil
  ghpr.state.files = { { filename = "test.lua", status = "modified" } }
  ghpr.state.current_file_idx = 1

  local result = ghpr.open_file_diff(1)
  if result == false then
    print("PASS: open_file_diff returns false without merge_base")
  else
    print("FAIL: open_file_diff did not return false (got " .. tostring(result) .. ")")
  end

  -- Test 2: select_file_by_path with non-existent file
  print("\n2. Testing select_file_by_path with non-existent file...")
  ghpr.state.files = {
    { filename = "file1.lua", status = "modified" },
    { filename = "file2.lua", status = "added" },
  }

  result = ghpr.select_file_by_path("non_existent.lua")
  if result == false then
    print("PASS: select_file_by_path returns false for non-existent file")
  else
    print("FAIL: select_file_by_path did not return false (got " .. tostring(result) .. ")")
  end

  -- Test 3: next_comment with no comments
  print("\n3. Testing next_comment with no comments...")
  ghpr.state.comments = {}
  ghpr.state.current_comment_idx = 0

  -- Should not error, just notify
  local ok = pcall(ghpr.next_comment)
  if ok then
    print("PASS: next_comment handles empty comments gracefully")
  else
    print("FAIL: next_comment errored with empty comments")
  end

  -- Test 4: prev_comment with no comments
  print("\n4. Testing prev_comment with no comments...")
  ok = pcall(ghpr.prev_comment)
  if ok then
    print("PASS: prev_comment handles empty comments gracefully")
  else
    print("FAIL: prev_comment errored with empty comments")
  end

  -- Test 5: get_current_comment with invalid index
  print("\n5. Testing get_current_comment with invalid index...")
  ghpr.state.comments = {
    { type = "issue", id = "1", body = "Test", author = "user1" },
  }
  ghpr.state.current_comment_idx = 99  -- Invalid index

  local comment = ghpr.get_current_comment()
  if comment == nil then
    print("PASS: get_current_comment returns nil for invalid index")
  else
    print("FAIL: get_current_comment returned non-nil for invalid index")
  end

  -- Test 6: close_comments with no buffer
  print("\n6. Testing close_comments with no buffer...")
  ghpr.state.comments_buf = nil
  ghpr.state.comments_win = nil

  ok = pcall(ghpr.close_comments)
  if ok then
    print("PASS: close_comments handles nil buffer gracefully")
  else
    print("FAIL: close_comments errored with nil buffer")
  end

  -- Test 7: restore_layout without PR data
  print("\n7. Testing restore_layout without PR data...")
  ghpr.state.pr_number = nil
  ghpr.state.files = {}

  ok = pcall(ghpr.restore_layout)
  if ok then
    print("PASS: restore_layout handles no PR data gracefully")
  else
    print("FAIL: restore_layout errored without PR data")
  end

  -- Test 8: reload_current_file without PR data (calls restore_layout)
  print("\n8. Testing reload_current_file without PR data...")
  ghpr.state.pr_number = nil
  ghpr.state.files = {}

  ok = pcall(ghpr.reload_current_file)
  if ok then
    print("PASS: reload_current_file handles no PR data gracefully")
  else
    print("FAIL: reload_current_file errored without PR data")
  end

  print("\n=== Guard condition tests completed ===")
  return true
end

local ok, err = pcall(test)
if not ok then print("Error: " .. tostring(err)) end
vim.cmd("qa!")
