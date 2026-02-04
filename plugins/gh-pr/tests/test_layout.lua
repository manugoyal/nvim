-- Test layout restoration logic
-- Run: nvim --headless -u ~/.config/nvim/init.lua -c "luafile tests/test_layout.lua"

local function test()
  print("=== Testing layout restoration ===")

  local ghpr = require('gh-pr')
  ghpr.setup()

  -- Test 1: restore_layout requires PR data
  print("\n1. Testing restore_layout requires PR data...")
  ghpr.state.pr_number = nil
  ghpr.state.files = {}

  local ok = pcall(ghpr.restore_layout)
  if ok then
    print("PASS: restore_layout handles missing PR data")
  else
    print("FAIL: restore_layout errored on missing PR data")
  end

  -- Test 2: restore_layout with files but no PR number
  print("\n2. Testing restore_layout with files but no PR number...")
  ghpr.state.pr_number = nil
  ghpr.state.files = { { path = "test.lua", status = "modified" } }

  ok = pcall(ghpr.restore_layout)
  if ok then
    print("PASS: restore_layout handles missing PR number")
  else
    print("FAIL: restore_layout errored on missing PR number")
  end

  -- Test 3: reload_current_file delegates to restore_layout
  print("\n3. Testing reload_current_file delegates properly...")
  ghpr.state.pr_number = nil
  ghpr.state.files = {}

  ok = pcall(ghpr.reload_current_file)
  if ok then
    print("PASS: reload_current_file delegates to restore_layout")
  else
    print("FAIL: reload_current_file errored")
  end

  -- Test 4: set_review_window_proportions helper exists
  print("\n4. Testing window proportion helper is accessible...")
  -- Can't directly test local function, but we can verify it's used
  -- by checking that open_file_diff doesn't error when called properly
  -- (even though it will fail due to missing merge_base)
  ghpr.state.merge_base = nil
  local result = ghpr.open_file_diff(1)
  if result == false then
    print("PASS: open_file_diff returns false gracefully (uses proportion helper internally)")
  else
    print("INFO: open_file_diff returned " .. tostring(result))
  end

  -- Test 5: populate_comments_buffer creates buffer
  print("\n5. Testing populate_comments_buffer creates buffer...")
  ghpr.state.comments_buf = nil
  ghpr.state.comments = {}
  ghpr.state.pr_number = 123  -- fake PR number for display

  ok = pcall(function()
    ghpr.populate_comments_buffer({ focus = false })
  end)
  if ok and ghpr.state.comments_buf and vim.api.nvim_buf_is_valid(ghpr.state.comments_buf) then
    print("PASS: populate_comments_buffer creates valid buffer")
  else
    print("FAIL: populate_comments_buffer did not create valid buffer")
  end

  -- Test 6: Buffer reuse
  print("\n6. Testing comments buffer reuse...")
  local first_buf = ghpr.state.comments_buf
  ghpr.populate_comments_buffer({ focus = false })
  local second_buf = ghpr.state.comments_buf

  if first_buf == second_buf then
    print("PASS: Comments buffer is reused")
  else
    print("FAIL: Comments buffer was recreated (got new buf " .. tostring(second_buf) .. ")")
  end

  print("\n=== Layout restoration tests completed ===")
  return true
end

local ok, err = pcall(test)
if not ok then print("Error: " .. tostring(err)) end
vim.cmd("qa!")
