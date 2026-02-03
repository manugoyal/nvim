-- gh-pr.nvim: GitHub PR comment management for Neovim
local api = require("gh-pr.api")

local M = {}

-- Helper to safely get nested values (handles vim.NIL from JSON null)
local function safe_get(tbl, ...)
  local val = tbl
  for _, key in ipairs({...}) do
    if val == nil or val == vim.NIL or type(val) ~= "table" then
      return nil
    end
    val = val[key]
  end
  if val == vim.NIL then
    return nil
  end
  return val
end

-- State
M.state = {
  owner = nil,
  repo = nil,
  pr_number = nil,
  comments = {},      -- Parsed comments
  pending_review = nil, -- Current pending review {id, databaseId}
  -- Diff review state
  files = {},         -- List of changed files {path, status, additions, deletions}
  merge_base = nil,   -- Merge base commit
  current_file_idx = 0, -- Currently selected file (1-indexed, 0 = none)
  file_list_buf = nil,  -- Buffer for file list
  file_list_win = nil,  -- Window for file list
  diff_win_left = nil,  -- Left diff window (base version)
  diff_win_right = nil, -- Right diff window (current version)
  -- Comments buffer state
  comments_buf = nil,   -- Buffer for comments list
  comments_win = nil,   -- Window for comments list
  current_comment_idx = 0, -- Currently selected comment (1-indexed)
  comment_line_map = {}, -- Maps line numbers to comment indices
}

-- Map GitHub reaction content types to emoji
local REACTION_EMOJI = {
  THUMBS_UP = "👍",
  THUMBS_DOWN = "👎",
  LAUGH = "😄",
  HOORAY = "🎉",
  CONFUSED = "😕",
  HEART = "❤️",
  ROCKET = "🚀",
  EYES = "👀",
}

-- Parse reaction groups into a display string and list of viewer's reactions
---@return string display_string
---@return table viewer_reactions List of reaction content types the viewer has added
local function parse_reactions(reaction_groups)
  if not reaction_groups then
    return "", {}
  end

  local parts = {}
  local viewer_reactions = {}

  for _, group in ipairs(reaction_groups) do
    local count = safe_get(group, "reactors", "totalCount") or 0
    if count > 0 then
      local emoji = REACTION_EMOJI[group.content] or group.content
      if count > 1 then
        table.insert(parts, emoji .. count)
      else
        table.insert(parts, emoji)
      end
    end
    -- Track which reactions the viewer has added
    if group.viewerHasReacted then
      table.insert(viewer_reactions, group.content)
    end
  end

  return table.concat(parts, " "), viewer_reactions
end

-- Parse comments from API response into a flat list
---@param data table API response
---@return table[] comments
local function parse_comments(data)
  local comments = {}
  local pr = data.data.repository.pullRequest

  -- Issue comments (general PR comments)
  for _, comment in ipairs(safe_get(pr, "comments", "nodes") or {}) do
    local reactions, viewer_reactions = parse_reactions(comment.reactionGroups)
    table.insert(comments, {
      type = "issue",
      id = comment.id,
      database_id = comment.databaseId,
      body = comment.body or "",
      author = safe_get(comment, "author", "login") or "unknown",
      created_at = comment.createdAt,
      url = comment.url,
      path = nil,
      line = 0,
      state = "PUBLISHED",
      thread_id = nil,
      reactions = reactions,
      viewer_reactions = viewer_reactions,
    })
  end

  -- Review thread comments
  for _, thread in ipairs(safe_get(pr, "reviewThreads", "nodes") or {}) do
    local line = safe_get(thread, "line") or safe_get(thread, "startLine") or 0
    local original_line = safe_get(thread, "originalLine") or line
    local is_thread_outdated = safe_get(thread, "isOutdated") or false
    for i, comment in ipairs(safe_get(thread, "comments", "nodes") or {}) do
      local state = safe_get(comment, "pullRequestReview", "state") or "COMMENTED"
      local is_outdated = is_thread_outdated or safe_get(comment, "outdated") or false
      local reactions, viewer_reactions = parse_reactions(comment.reactionGroups)
      table.insert(comments, {
        type = "review",
        id = comment.id,
        database_id = comment.databaseId,
        body = comment.body or "",
        author = safe_get(comment, "author", "login") or "unknown",
        created_at = comment.createdAt,
        url = comment.url,
        path = thread.path,
        line = line,
        original_line = original_line,
        state = state,
        thread_id = thread.id,
        is_reply = i > 1,
        reply_to = safe_get(comment, "replyTo", "id"),
        review_id = safe_get(comment, "pullRequestReview", "id"),
        outdated = is_outdated,
        original_commit = safe_get(comment, "originalCommit", "oid"),
        diff_hunk = safe_get(comment, "diffHunk"),
        reactions = reactions,
        viewer_reactions = viewer_reactions,
      })
    end
  end

  -- Sort by path, then line, then thread_id (to keep threads together), then created_at
  table.sort(comments, function(a, b)
    local path_a = a.path or ""
    local path_b = b.path or ""
    if path_a ~= path_b then
      return path_a < path_b
    end
    if a.line ~= b.line then
      return a.line < b.line
    end
    -- Keep same thread together, sorted by creation time
    local thread_a = a.thread_id or ""
    local thread_b = b.thread_id or ""
    if thread_a ~= thread_b then
      return thread_a < thread_b
    end
    -- Within same thread, sort by creation time
    local time_a = a.created_at or ""
    local time_b = b.created_at or ""
    return time_a < time_b
  end)

  return comments
end

-- Load comments for a PR (async, non-blocking)
-- Use this for background refreshes
---@param pr_number number PR number
---@param opts table|nil {focus: boolean} options
function M.load_comments_async(pr_number, opts)
  opts = opts or {}
  local focus = opts.focus or false
  local on_complete = opts.on_complete

  if not pr_number or not M.state.owner or not M.state.repo then
    return
  end

  api.get_pr_comments_async(M.state.owner, M.state.repo, pr_number, function(result, err)
    if err then
      vim.notify("Failed to load comments: " .. err, vim.log.levels.ERROR)
      return
    end

    M.state.comments = parse_comments(result)

    -- Check for existing pending review
    local pr = result.data.repository.pullRequest
    -- Get current user async would be better, but for now just update pending review from data
    for _, review in ipairs(safe_get(pr, "reviews", "nodes") or {}) do
      if review.state == "PENDING" then
        M.state.pending_review = { id = review.id, databaseId = review.databaseId }
        break
      end
    end

    -- Populate comments buffer
    M.populate_quickfix({ focus = focus })

    -- Call completion callback if provided
    if on_complete then
      on_complete()
    end
  end)
end

-- Load comments for a PR (sync, blocks until complete)
-- Use this for user-initiated loads
---@param pr_number number|nil PR number (will prompt if nil)
---@param opts table|nil {focus: boolean} options
function M.load_comments(pr_number, opts)
  opts = opts or {}
  local focus = opts.focus ~= false  -- default to true

  -- Get repo info
  local owner, repo = api.get_repo()
  if not owner or not repo then
    vim.notify("Failed to detect repository. Are you in a git repo?", vim.log.levels.ERROR)
    return
  end

  -- Get PR number
  if not pr_number then
    -- Try to get from current branch
    local pr_info = vim.fn.system({ "gh", "pr", "view", "--json", "number", "-q", ".number" })
    if vim.v.shell_error == 0 then
      pr_number = tonumber(vim.trim(pr_info))
    end
  end

  if not pr_number then
    vim.ui.input({ prompt = "PR number: " }, function(input)
      if input then
        M.load_comments(tonumber(input), opts)
      end
    end)
    return
  end

  M.state.owner = owner
  M.state.repo = repo
  M.state.pr_number = pr_number

  -- Fetch comments
  vim.notify(string.format("Loading comments for PR #%d...", pr_number), vim.log.levels.INFO)

  local result, err = api.await(api.get_pr_comments_async, owner, repo, pr_number)
  if err then
    vim.notify("Failed to load comments: " .. err, vim.log.levels.ERROR)
    return
  end

  M.state.comments = parse_comments(result)

  -- Check for existing pending review
  local pr = result.data.repository.pullRequest
  local current_user = vim.trim(vim.fn.system({ "gh", "api", "user", "-q", ".login" }))
  for _, review in ipairs(safe_get(pr, "reviews", "nodes") or {}) do
    local author_login = safe_get(review, "author", "login")
    if review.state == "PENDING" and author_login == current_user then
      M.state.pending_review = { id = review.id, databaseId = review.databaseId }
      break
    end
  end

  -- Populate quickfix
  M.populate_quickfix({ focus = focus })

  vim.notify(string.format("Loaded %d comments for PR #%d", #M.state.comments, pr_number), vim.log.levels.INFO)
end

-- Render the comments buffer
local function render_comments_buffer()
  if not M.state.comments_buf or not vim.api.nvim_buf_is_valid(M.state.comments_buf) then
    return
  end

  local lines = {}
  M.state.comment_line_map = {}
  local comment_idx = 0

  -- Group comments by thread_id
  local threads = {}
  local thread_order = {}
  local issue_comments = {}

  for _, comment in ipairs(M.state.comments) do
    if comment.type == "issue" then
      table.insert(issue_comments, comment)
    else
      local tid = comment.thread_id or comment.id
      if not threads[tid] then
        threads[tid] = {}
        table.insert(thread_order, tid)
      end
      table.insert(threads[tid], comment)
    end
  end

  -- Add header
  table.insert(lines, string.format("PR #%d Comments (%d)", M.state.pr_number or 0, #M.state.comments))
  table.insert(lines, string.rep("─", 60))
  table.insert(lines, "")

  -- Add issue comments first
  if #issue_comments > 0 then
    table.insert(lines, "General Comments:")
    table.insert(lines, "")
    for _, comment in ipairs(issue_comments) do
      comment_idx = comment_idx + 1
      local marker = comment_idx == M.state.current_comment_idx and "▶" or " "
      local body = comment.body:gsub("\n", " "):sub(1, 70)
      local state_indicator = comment.state == "PENDING" and "[PENDING] " or ""
      local reactions_str = comment.reactions ~= "" and (" " .. comment.reactions) or ""

      local line = string.format("%s @%s: %s%s%s", marker, comment.author, state_indicator, body, reactions_str)
      table.insert(lines, line)
      M.state.comment_line_map[#lines] = comment_idx
    end
    table.insert(lines, "")
  end

  -- Add review threads
  if #thread_order > 0 then
    table.insert(lines, "Review Comments:")
    table.insert(lines, "")
    for _, tid in ipairs(thread_order) do
      local thread_comments = threads[tid]
      local first_comment = thread_comments[1]

      -- Show file:line header for thread
      local location = first_comment.path or "REVIEW"
      if first_comment.line and first_comment.line > 0 then
        location = location .. ":" .. first_comment.line
      end
      table.insert(lines, string.format("  %s", location))

      for i, comment in ipairs(thread_comments) do
        comment_idx = comment_idx + 1
        local marker = comment_idx == M.state.current_comment_idx and "▶" or " "

        -- Threading indicator
        local prefix = ""
        if i == 1 then
          prefix = #thread_comments > 1 and "┬" or "─"
        elseif i == #thread_comments then
          prefix = "└"
        else
          prefix = "├"
        end

        local state_indicator = ""
        if comment.state == "PENDING" then
          state_indicator = "[P] "
        end
        if comment.outdated then
          state_indicator = state_indicator .. "[O] "
        end

        local body = comment.body:gsub("\n", " "):sub(1, 60)
        local reactions_str = comment.reactions ~= "" and (" " .. comment.reactions) or ""

        local line = string.format("%s   %s @%s: %s%s%s", marker, prefix, comment.author, state_indicator, body, reactions_str)
        table.insert(lines, line)
        M.state.comment_line_map[#lines] = comment_idx
      end
      table.insert(lines, "")
    end
  end

  -- Add help text at the bottom
  table.insert(lines, string.rep("─", 60))
  table.insert(lines, "j/k:move  Enter:goto  e:edit  d:delete  r:reply  p:preview")
  table.insert(lines, "+:react  -:unreact  R:refresh  S:submit  o:view original")

  vim.api.nvim_buf_set_option(M.state.comments_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(M.state.comments_buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(M.state.comments_buf, "modifiable", false)

  -- Move cursor to current comment
  if M.state.current_comment_idx > 0 then
    for line_num, idx in pairs(M.state.comment_line_map) do
      if idx == M.state.current_comment_idx then
        if M.state.comments_win and vim.api.nvim_win_is_valid(M.state.comments_win) then
          vim.api.nvim_win_set_cursor(M.state.comments_win, { line_num, 0 })
        end
        break
      end
    end
  end
end

-- Get comment at current cursor position in comments buffer
function M.get_current_comment()
  if not M.state.comments_buf or not vim.api.nvim_buf_is_valid(M.state.comments_buf) then
    return nil
  end

  local cursor_line = vim.fn.line(".")
  local comment_idx = M.state.comment_line_map[cursor_line]

  if comment_idx and M.state.comments[comment_idx] then
    M.state.current_comment_idx = comment_idx
    return M.state.comments[comment_idx]
  end
  return nil
end

-- Navigate to next comment
function M.next_comment()
  if M.state.current_comment_idx < #M.state.comments then
    M.state.current_comment_idx = M.state.current_comment_idx + 1
    render_comments_buffer()
    M.goto_current_comment()
  else
    vim.notify("Already at last comment", vim.log.levels.INFO)
  end
end

-- Navigate to previous comment
function M.prev_comment()
  if M.state.current_comment_idx > 1 then
    M.state.current_comment_idx = M.state.current_comment_idx - 1
    render_comments_buffer()
    M.goto_current_comment()
  else
    vim.notify("Already at first comment", vim.log.levels.INFO)
  end
end

-- Go to the currently selected comment's location
function M.goto_current_comment()
  if M.state.current_comment_idx < 1 or M.state.current_comment_idx > #M.state.comments then
    return
  end

  local comment = M.state.comments[M.state.current_comment_idx]
  if not comment or not comment.path then
    return
  end

  -- If review panel is open, select the file there
  if M.state.file_list_win and vim.api.nvim_win_is_valid(M.state.file_list_win) then
    M.select_file_by_path(comment.path)
    -- After opening diff, jump to the specific line in the right pane
    if comment.line and comment.line > 0 and M.state.diff_win_right and vim.api.nvim_win_is_valid(M.state.diff_win_right) then
      vim.api.nvim_set_current_win(M.state.diff_win_right)
      pcall(vim.api.nvim_win_set_cursor, M.state.diff_win_right, { comment.line, 0 })
      vim.cmd("normal! zz")
    end
  end
end

-- Close the comments buffer
function M.close_comments()
  if M.state.comments_win and vim.api.nvim_win_is_valid(M.state.comments_win) then
    vim.api.nvim_win_close(M.state.comments_win, true)
  end
  M.state.comments_win = nil
  M.state.comments_buf = nil
end

-- Set up keymaps for the comments buffer
local function setup_comments_keymaps()
  if not M.state.comments_buf or not vim.api.nvim_buf_is_valid(M.state.comments_buf) then
    return
  end

  local map_opts = { buffer = M.state.comments_buf, silent = true }

  vim.keymap.set("n", "<CR>", function()
    local comment = M.get_current_comment()
    if comment then
      M.goto_current_comment()
    end
  end, map_opts)

  vim.keymap.set("n", "j", function()
    -- Move to next comment line
    local cursor = vim.fn.line(".")
    -- Get sorted line numbers
    local sorted_lines = {}
    for line_num, _ in pairs(M.state.comment_line_map) do
      table.insert(sorted_lines, line_num)
    end
    table.sort(sorted_lines)
    -- Find next line after cursor
    for _, line_num in ipairs(sorted_lines) do
      if line_num > cursor then
        vim.api.nvim_win_set_cursor(0, { line_num, 0 })
        M.get_current_comment()  -- Update selection
        render_comments_buffer()
        return
      end
    end
  end, map_opts)

  vim.keymap.set("n", "k", function()
    -- Move to prev comment line
    local cursor = vim.fn.line(".")
    -- Get sorted line numbers in reverse
    local sorted_lines = {}
    for line_num, _ in pairs(M.state.comment_line_map) do
      table.insert(sorted_lines, line_num)
    end
    table.sort(sorted_lines, function(a, b) return a > b end)
    -- Find prev line before cursor
    for _, line_num in ipairs(sorted_lines) do
      if line_num < cursor then
        vim.api.nvim_win_set_cursor(0, { line_num, 0 })
        M.get_current_comment()  -- Update selection
        render_comments_buffer()
        return
      end
    end
  end, map_opts)

  vim.keymap.set("n", "e", M.edit_comment, map_opts)
  vim.keymap.set("n", "d", M.delete_comment, map_opts)
  vim.keymap.set("n", "r", M.reply_to_thread, map_opts)
  vim.keymap.set("n", "p", M.preview_comment, map_opts)
  vim.keymap.set("n", "o", M.view_original, map_opts)
  vim.keymap.set("n", "+", M.react_to_comment, map_opts)
  vim.keymap.set("n", "-", M.unreact_to_comment, map_opts)
  vim.keymap.set("n", "R", function() M.load_comments(M.state.pr_number) end, map_opts)
  vim.keymap.set("n", "S", M.submit_review, map_opts)
  vim.keymap.set("n", "q", M.close_comments, map_opts)
end

-- Populate comments buffer (replaces quickfix)
---@param opts table|nil {focus: boolean} whether to focus comments buffer (default true)
function M.populate_comments_buffer(opts)
  opts = opts or {}
  local focus = opts.focus ~= false  -- default to true

  -- Reuse existing buffer if valid, otherwise create new one
  local need_new_buffer = not M.state.comments_buf or not vim.api.nvim_buf_is_valid(M.state.comments_buf)

  if need_new_buffer then
    -- Delete any stale buffers with this name
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(buf)
      if name:match("%[PR Comments%]$") then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end

    -- Create buffer (use "hide" so buffer persists when window closes)
    M.state.comments_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(M.state.comments_buf, "buftype", "nofile")
    vim.api.nvim_buf_set_option(M.state.comments_buf, "bufhidden", "hide")
    vim.api.nvim_buf_set_option(M.state.comments_buf, "swapfile", false)
    vim.api.nvim_buf_set_name(M.state.comments_buf, "[PR Comments]")

    -- Set up keymaps for new buffer
    setup_comments_keymaps()
  end

  -- Initialize comment selection
  if #M.state.comments > 0 and M.state.current_comment_idx == 0 then
    M.state.current_comment_idx = 1
  end

  -- Render/update content
  render_comments_buffer()

  -- Open in a window if focus requested
  if focus then
    -- If review panel is open, open comments as a horizontal split below
    if M.state.file_list_win and vim.api.nvim_win_is_valid(M.state.file_list_win) then
      vim.cmd("botright split")
      vim.cmd("resize 12")
    else
      vim.cmd("botright split")
      vim.cmd("resize 20")
    end
    M.state.comments_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(M.state.comments_win, M.state.comments_buf)

    -- Window options
    vim.api.nvim_win_set_option(M.state.comments_win, "number", false)
    vim.api.nvim_win_set_option(M.state.comments_win, "relativenumber", false)
    vim.api.nvim_win_set_option(M.state.comments_win, "signcolumn", "no")
    vim.api.nvim_win_set_option(M.state.comments_win, "winfixheight", true)
    vim.api.nvim_win_set_option(M.state.comments_win, "cursorline", true)
  end
end

-- Legacy alias for backward compatibility
function M.populate_quickfix(opts)
  M.populate_comments_buffer(opts)
end

-- Add a new comment
---@param opts table|nil {path: string, line: number, pending: boolean, reply_to_thread: string}
function M.add_comment(opts)
  opts = opts or {}

  if not M.state.pr_number then
    vim.notify("No PR loaded. Use :GHPRComments first.", vim.log.levels.ERROR)
    return
  end

  -- Determine path and line from current buffer if not provided
  local path = opts.path
  local line = opts.line

  if not path and vim.bo.buftype == "" then
    path = vim.fn.expand("%:.")
    line = line or vim.fn.line(".")
  end

  -- Determine buffer title
  local title = "New Comment"
  if opts.reply_to_thread then
    title = "Reply to Thread"
  elseif path then
    title = string.format("New Comment on %s:%d", path, line or 0)
  end

  -- Check if a buffer with this name already exists and delete it
  local existing_buf = vim.fn.bufnr(title)
  if existing_buf ~= -1 then
    vim.api.nvim_buf_delete(existing_buf, { force = true })
  end

  -- Remember the window to return to after closing the comment buffer
  -- For replies, return to comments window; for new comments, return to original window
  local return_win = opts.reply_to_thread and M.state.comments_win or vim.api.nvim_get_current_win()

  -- Create a scratch buffer for editing the comment
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, "buftype", "acwrite")
  vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
  vim.api.nvim_buf_set_name(buf, title)

  -- Open in a split
  vim.cmd("split")
  vim.api.nvim_win_set_buf(0, buf)

  -- When this buffer's window closes, return to the appropriate window
  vim.api.nvim_create_autocmd("BufWinLeave", {
    buffer = buf,
    once = true,
    callback = function()
      vim.schedule(function()
        if return_win and vim.api.nvim_win_is_valid(return_win) then
          vim.api.nvim_set_current_win(return_win)
        end
      end)
    end
  })

  -- Track if comment has been submitted
  local submitted = false

  -- Helper to handle successful submission
  local function on_submit_success()
    M.load_comments_async(M.state.pr_number, { focus = false })
  end

  -- Helper to handle failed submission
  local function on_submit_error(msg)
    submitted = false  -- Allow retry
    vim.notify(msg, vim.log.levels.ERROR)
  end

  -- Set up save handler
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      if submitted then
        -- Already submitted, just mark as saved
        vim.bo[buf].modified = false
        return
      end

      local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local body = table.concat(lines, "\n")

      if body:match("^%s*$") then
        vim.notify("Comment body is empty", vim.log.levels.WARN)
        return
      end

      -- Mark as submitted immediately so user can close buffer
      submitted = true
      vim.bo[buf].modified = false

      if opts.reply_to_thread then
        -- Reply to existing thread (as pending review comment)
        local function do_reply(retry_on_stale)
          api.reply_to_thread_async(opts.reply_to_thread, body, M.state.pending_review.id, function(result, err)
            if err then
              -- If the review ID is stale, clear cache and retry once
              if retry_on_stale and err:match("Could not resolve to a node") then
                M.state.pending_review = nil
                api.get_or_create_pending_review_async(
                  M.state.owner, M.state.repo, M.state.pr_number,
                  function(review, create_err)
                    if create_err then
                      on_submit_error("Failed to create pending review: " .. create_err)
                      return
                    end
                    M.state.pending_review = review
                    do_reply(false)  -- retry without further retries
                  end
                )
                return
              end
              on_submit_error("Failed to add reply: " .. err)
              return
            end
            on_submit_success()
          end)
        end

        -- Ensure we have a pending review
        if not M.state.pending_review then
          api.get_or_create_pending_review_async(
            M.state.owner, M.state.repo, M.state.pr_number,
            function(review, err)
              if err then
                on_submit_error("Failed to create pending review: " .. err)
                return
              end
              M.state.pending_review = review
              do_reply(true)  -- allow one retry on stale ID
            end
          )
        else
          do_reply(true)  -- allow one retry on stale ID
        end
      elseif path then
        -- Add review comment (to pending review)
        local pending = opts.pending ~= false -- default to pending

        if pending then
          -- Helper to add the review thread
          local function do_add_thread(retry_on_stale)
            api.add_review_thread_async(
              M.state.pending_review.id, path, line, body, "RIGHT",
              function(result, err)
                if err then
                  -- If the review ID is stale, clear cache and retry once
                  if retry_on_stale and err:match("Could not resolve to a node") then
                    M.state.pending_review = nil
                    api.get_or_create_pending_review_async(
                      M.state.owner, M.state.repo, M.state.pr_number,
                      function(review, create_err)
                        if create_err then
                          on_submit_error("Failed to create pending review: " .. create_err)
                          return
                        end
                        M.state.pending_review = review
                        do_add_thread(false)  -- retry without further retries
                      end
                    )
                    return
                  end
                  on_submit_error("Failed to add comment: " .. err)
                  return
                end
                on_submit_success()
              end
            )
          end

          -- Ensure we have a pending review
          if not M.state.pending_review then
            api.get_or_create_pending_review_async(
              M.state.owner, M.state.repo, M.state.pr_number,
              function(review, err)
                if err then
                  on_submit_error("Failed to create pending review: " .. err)
                  return
                end
                M.state.pending_review = review
                do_add_thread(true)  -- allow one retry on stale ID
              end
            )
          else
            do_add_thread(true)  -- allow one retry on stale ID
          end
        else
          vim.notify("Direct (non-pending) review comments not yet implemented", vim.log.levels.WARN)
          submitted = false
          return
        end
      else
        -- Add issue comment (general PR comment, async)
        api.add_issue_comment_async(
          M.state.owner, M.state.repo, M.state.pr_number, body,
          function(result, err)
            if err then
              on_submit_error("Failed to add comment: " .. err)
              return
            end
            on_submit_success()
          end
        )
      end
    end,
  })

  vim.notify(":w to submit, :wq to submit and close, :q! to cancel", vim.log.levels.INFO)
end

-- Edit a comment
---@param comment table|nil Comment to edit (uses current qf item if nil)
function M.edit_comment(comment)
  comment = comment or M.get_current_comment()

  if not comment then
    vim.notify("No comment selected", vim.log.levels.WARN)
    return
  end

  -- Check if a buffer for this comment already exists and delete it
  local buf_name = "Edit Comment: " .. comment.id
  local existing_buf = vim.fn.bufnr(buf_name)
  if existing_buf ~= -1 then
    vim.api.nvim_buf_delete(existing_buf, { force = true })
  end

  -- Create a scratch buffer for editing
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, "buftype", "acwrite")
  vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
  vim.api.nvim_buf_set_name(buf, buf_name)

  -- Set initial content
  local lines = vim.split(comment.body, "\n")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)

  -- Open in a split
  vim.cmd("split")
  vim.api.nvim_win_set_buf(0, buf)

  -- Track last saved content and submission state
  local last_saved = comment.body
  local submitting = false

  -- Set up save handler
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function()
      local new_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local body = table.concat(new_lines, "\n")

      -- Skip if content hasn't changed since last save
      if body == last_saved then
        vim.bo[buf].modified = false
        return
      end

      -- Skip if already submitting
      if submitting then
        return
      end

      -- Mark as submitting and allow user to close buffer
      submitting = true
      local pending_body = body
      vim.bo[buf].modified = false

      api.update_comment_async(comment.id, body, function(result, err)
        if err then
          submitting = false
          vim.notify("Failed to update comment: " .. err, vim.log.levels.ERROR)
          return
        end

        last_saved = pending_body
        submitting = false
        M.load_comments_async(M.state.pr_number)
      end)
    end,
  })

  vim.notify(":w to save, :wq to save and close, :q! to cancel", vim.log.levels.INFO)
end

-- Delete a comment
---@param comment table|nil Comment to delete (uses current qf item if nil)
function M.delete_comment(comment)
  comment = comment or M.get_current_comment()

  if not comment then
    vim.notify("No comment selected", vim.log.levels.WARN)
    return
  end

  vim.ui.select({ "Yes", "No" }, {
    prompt = string.format("Delete comment by %s?", comment.author),
  }, function(choice)
    if choice == "Yes" then
      local was_pending = comment.state == "PENDING"

      api.delete_comment_async(comment.id, function(success, err)
        if not success then
          vim.notify("Failed to delete comment: " .. (err or "unknown error"), vim.log.levels.ERROR)
          return
        end

        -- Clear pending review cache if we deleted a pending comment
        -- (GitHub may have deleted the review if it was the last comment)
        if was_pending then
          M.state.pending_review = nil
        end

        M.load_comments_async(M.state.pr_number)
      end)
    end
  end)
end

-- Reply to a thread
function M.reply_to_thread()
  local comment = M.get_current_comment()

  if not comment then
    vim.notify("No comment selected", vim.log.levels.WARN)
    return
  end

  if not comment.thread_id then
    vim.notify("This is not a review comment (no thread to reply to)", vim.log.levels.WARN)
    return
  end

  M.add_comment({ reply_to_thread = comment.thread_id })
end

-- Available GitHub reactions with display labels
local REACTIONS = {
  { content = "THUMBS_UP", label = "👍 +1" },
  { content = "THUMBS_DOWN", label = "👎 -1" },
  { content = "LAUGH", label = "😄 Laugh" },
  { content = "HOORAY", label = "🎉 Hooray" },
  { content = "CONFUSED", label = "😕 Confused" },
  { content = "HEART", label = "❤️ Heart" },
  { content = "ROCKET", label = "🚀 Rocket" },
  { content = "EYES", label = "👀 Eyes" },
}

-- Add a reaction to a comment
function M.react_to_comment()
  local comment = M.get_current_comment()

  if not comment then
    vim.notify("No comment selected", vim.log.levels.WARN)
    return
  end

  -- Build selection list
  local labels = {}
  for _, reaction in ipairs(REACTIONS) do
    table.insert(labels, reaction.label)
  end

  vim.ui.select(labels, {
    prompt = "Add reaction:",
  }, function(choice, idx)
    if not choice or not idx then
      return
    end

    local reaction = REACTIONS[idx]
    api.add_reaction_async(comment.id, reaction.content, function(result, err)
      if err then
        vim.notify("Failed to add reaction: " .. err, vim.log.levels.ERROR)
        return
      end
      M.load_comments_async(M.state.pr_number)
    end)
  end)
end

-- Remove a reaction from a comment
function M.unreact_to_comment()
  local comment = M.get_current_comment()

  if not comment then
    vim.notify("No comment selected", vim.log.levels.WARN)
    return
  end

  -- Check if viewer has any reactions on this comment
  if not comment.viewer_reactions or #comment.viewer_reactions == 0 then
    vim.notify("You have no reactions on this comment", vim.log.levels.INFO)
    return
  end

  -- Build selection list from viewer's reactions
  local labels = {}
  for _, content in ipairs(comment.viewer_reactions) do
    local emoji = REACTION_EMOJI[content] or content
    table.insert(labels, emoji .. " " .. content:gsub("_", " "):lower())
  end

  vim.ui.select(labels, {
    prompt = "Remove reaction:",
  }, function(choice, idx)
    if not choice or not idx then
      return
    end

    local content = comment.viewer_reactions[idx]
    api.remove_reaction_async(comment.id, content, function(result, err)
      if err then
        vim.notify("Failed to remove reaction: " .. err, vim.log.levels.ERROR)
        return
      end
      M.load_comments_async(M.state.pr_number)
    end)
  end)
end

-- Submit pending review
---@param event string|nil "APPROVE", "REQUEST_CHANGES", or "COMMENT" (will prompt if nil)
function M.submit_review(event)
  if not M.state.pr_number then
    vim.notify("No PR loaded. Use :GHPRComments first.", vim.log.levels.ERROR)
    return
  end

  if not event then
    vim.ui.select({ "COMMENT", "APPROVE", "REQUEST_CHANGES" }, {
      prompt = "Submit review as:",
    }, function(choice)
      if choice then
        M.submit_review(choice)
      end
    end)
    return
  end

  -- Helper to do the actual submit
  local function do_submit(review_id, body)
    api.submit_review_async(review_id, event, body or "", function(result, err)
      if err then
        vim.notify("Failed to submit review: " .. err, vim.log.levels.ERROR)
        return
      end

      M.state.pending_review = nil
      M.load_comments_async(M.state.pr_number)
    end)
  end

  -- Optionally add a review body
  vim.ui.input({ prompt = "Review summary (optional): " }, function(body)
    if M.state.pending_review then
      do_submit(M.state.pending_review.id, body)
    else
      -- No pending review, create one first then submit
      api.get_or_create_pending_review_async(
        M.state.owner, M.state.repo, M.state.pr_number,
        function(review, err)
          if err then
            vim.notify("Failed to create review: " .. err, vim.log.levels.ERROR)
            return
          end
          do_submit(review.id, body)
        end
      )
    end
  end)
end

-- Jump to comment location
function M.goto_comment()
  local comment = M.get_current_comment()

  if not comment then
    vim.notify("No comment selected", vim.log.levels.WARN)
    return
  end

  if not comment.path then
    vim.notify("This comment is not attached to a file", vim.log.levels.INFO)
    return
  end

  -- Find or open the file
  local bufnr = vim.fn.bufnr(comment.path)
  if bufnr == -1 then
    vim.cmd("edit " .. comment.path)
  else
    vim.cmd("buffer " .. bufnr)
  end

  -- Jump to line
  if comment.line > 0 then
    vim.api.nvim_win_set_cursor(0, { comment.line, 0 })
    vim.cmd("normal! zz")
  end
end

-- Preview full comment in a floating window
function M.preview_comment()
  local comment = M.get_current_comment()

  if not comment then
    vim.notify("No comment selected", vim.log.levels.WARN)
    return
  end

  -- Save current window to return to it later
  local prev_win = vim.api.nvim_get_current_win()

  -- Build content
  local lines = {}
  table.insert(lines, string.format("Author: @%s", comment.author))
  table.insert(lines, string.format("State: %s%s", comment.state, comment.outdated and " [OUTDATED]" or ""))
  if comment.path then
    table.insert(lines, string.format("File: %s:%d", comment.path, comment.line or 0))
    if comment.outdated and comment.original_line and comment.original_line ~= comment.line then
      table.insert(lines, string.format("Original line: %d", comment.original_line))
    end
  end
  if comment.original_commit then
    table.insert(lines, string.format("Commit: %s", comment.original_commit:sub(1, 8)))
  end
  table.insert(lines, string.format("Created: %s", comment.created_at or "unknown"))
  table.insert(lines, "")
  table.insert(lines, string.rep("─", 60))
  table.insert(lines, "")

  -- Add comment body
  for _, line in ipairs(vim.split(comment.body, "\n")) do
    table.insert(lines, line)
  end

  -- Show original code context if we have commit info
  if comment.original_commit and comment.path then
    local commit = comment.original_commit
    local path = comment.path
    local target_line = comment.original_line or comment.line or 1
    local context_lines = 15

    -- Fetch file content at original commit
    local file_content = vim.fn.systemlist({ "git", "show", commit .. ":" .. path })
    if vim.v.shell_error == 0 and #file_content > 0 then
      table.insert(lines, "")
      table.insert(lines, string.rep("─", 60))
      table.insert(lines, string.format("Code at commit %s:", commit:sub(1, 8)))
      table.insert(lines, "")

      -- Calculate range
      local start_line = math.max(1, target_line - context_lines)
      local end_line = math.min(#file_content, target_line + context_lines)

      -- Add line numbers and content
      for i = start_line, end_line do
        local prefix = "   "
        local marker = "  "
        if i == target_line then
          prefix = ">>>"
          marker = "→ "
        end
        local line_content = file_content[i] or ""
        table.insert(lines, string.format("%s %4d %s%s", prefix, i, marker, line_content))
      end
    elseif comment.diff_hunk then
      -- Fallback to diff hunk if git show fails
      table.insert(lines, "")
      table.insert(lines, string.rep("─", 60))
      table.insert(lines, "Original diff context:")
      table.insert(lines, "")
      for _, line in ipairs(vim.split(comment.diff_hunk, "\n")) do
        table.insert(lines, line)
      end
    end
  elseif comment.diff_hunk then
    -- No commit info, just show diff hunk
    table.insert(lines, "")
    table.insert(lines, string.rep("─", 60))
    table.insert(lines, "Original diff context:")
    table.insert(lines, "")
    for _, line in ipairs(vim.split(comment.diff_hunk, "\n")) do
      table.insert(lines, line)
    end
  end

  -- Calculate window size
  local width = math.min(80, vim.o.columns - 4)
  local height = math.min(#lines + 2, vim.o.lines - 4)

  -- Create buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
  vim.api.nvim_buf_set_option(buf, "modifiable", false)

  -- Create floating window
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    col = math.floor((vim.o.columns - width) / 2),
    row = math.floor((vim.o.lines - height) / 2),
    style = "minimal",
    border = "rounded",
    title = " Comment Preview ",
    title_pos = "center",
  })

  -- Close on q or Esc and return to previous window
  local function close_preview()
    vim.api.nvim_win_close(win, true)
    if vim.api.nvim_win_is_valid(prev_win) then
      vim.api.nvim_set_current_win(prev_win)
    end
  end

  vim.keymap.set("n", "q", close_preview, { buffer = buf })
  vim.keymap.set("n", "<Esc>", close_preview, { buffer = buf })
end

-- View file at original commit (for outdated comments)
function M.view_original()
  local comment = M.get_current_comment()

  if not comment then
    vim.notify("No comment selected", vim.log.levels.WARN)
    return
  end

  if comment.state == "PENDING" then
    vim.notify("Pending comments are on current code - use :GHPRGoto or <CR> instead", vim.log.levels.INFO)
    return
  end

  if not comment.path then
    vim.notify("This comment is not attached to a file", vim.log.levels.WARN)
    return
  end

  if not comment.original_commit then
    vim.notify("No original commit info available", vim.log.levels.WARN)
    return
  end

  local commit = comment.original_commit
  local path = comment.path
  local line = comment.original_line or comment.line or 1

  -- Use git show to get file content at that commit
  local content = vim.fn.systemlist({ "git", "show", commit .. ":" .. path })
  if vim.v.shell_error ~= 0 then
    vim.notify("Failed to get file at commit: " .. table.concat(content, "\n"), vim.log.levels.ERROR)
    return
  end

  -- Check if a buffer with this name already exists and delete it
  local buf_name = string.format("%s @ %s", path, commit:sub(1, 8))
  local existing_buf = vim.fn.bufnr(buf_name)
  if existing_buf ~= -1 then
    vim.api.nvim_buf_delete(existing_buf, { force = true })
  end

  -- Create a buffer with the content
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, content)
  vim.api.nvim_buf_set_name(buf, buf_name)
  vim.api.nvim_buf_set_option(buf, "modifiable", false)
  vim.api.nvim_buf_set_option(buf, "buftype", "nofile")

  -- Set filetype based on extension
  local ext = path:match("%.([^%.]+)$")
  if ext then
    local ft = vim.filetype.match({ filename = path })
    if ft then
      vim.api.nvim_buf_set_option(buf, "filetype", ft)
    end
  end

  -- Open in a split
  vim.cmd("split")
  vim.api.nvim_win_set_buf(0, buf)

  -- Jump to the original line
  if line > 0 and line <= #content then
    vim.api.nvim_win_set_cursor(0, { line, 0 })
    vim.cmd("normal! zz")
  end

  vim.notify(string.format("Showing %s at commit %s (line %d)", path, commit:sub(1, 8), line), vim.log.levels.INFO)
end

-- ============================================================================
-- DIFF REVIEW FUNCTIONS
-- ============================================================================

-- Status icons for file list
local STATUS_ICONS = {
  added = "+",
  removed = "-",
  modified = "~",
  renamed = "→",
  copied = "C",
}

-- Render the file list buffer
local function render_file_list()
  if not M.state.file_list_buf or not vim.api.nvim_buf_is_valid(M.state.file_list_buf) then
    return
  end

  local lines = {}
  local current_idx = M.state.current_file_idx

  for i, file in ipairs(M.state.files) do
    local icon = STATUS_ICONS[file.status] or "?"
    local marker = i == current_idx and "▶" or " "
    local stats = ""
    if file.additions > 0 or file.deletions > 0 then
      stats = string.format(" +%d/-%d", file.additions, file.deletions)
    end
    table.insert(lines, string.format("%s %s %s%s", marker, icon, file.path, stats))
  end

  vim.api.nvim_buf_set_option(M.state.file_list_buf, "modifiable", true)
  vim.api.nvim_buf_set_lines(M.state.file_list_buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(M.state.file_list_buf, "modifiable", false)

  -- Move cursor to current file
  if current_idx > 0 and M.state.file_list_win and vim.api.nvim_win_is_valid(M.state.file_list_win) then
    vim.api.nvim_win_set_cursor(M.state.file_list_win, { current_idx, 0 })
  end
end

-- Forward declaration for create_file_list (defined later)
local create_file_list

-- Open diff for a specific file
---@param idx number File index (1-based)
---@return boolean success
function M.open_file_diff(idx)
  if idx < 1 or idx > #M.state.files then
    return false
  end

  if not M.state.merge_base then
    vim.notify("No merge base set. Run :GHPRReview first.", vim.log.levels.WARN)
    return false
  end

  -- Check if review panel is open
  if not M.state.file_list_win or not vim.api.nvim_win_is_valid(M.state.file_list_win) then
    vim.notify("Review panel not open. Run :GHPRReview first.", vim.log.levels.WARN)
    return false
  end

  local file = M.state.files[idx]
  M.state.current_file_idx = idx

  -- Update file list highlighting
  render_file_list()

  -- Get the base version content
  local base_content = {}
  if file.status ~= "added" then
    local git_ref = M.state.merge_base .. ":" .. file.path
    base_content = vim.fn.systemlist({
      "git", "show", git_ref
    })
    if vim.v.shell_error ~= 0 then
      -- Debug: show what command failed
      vim.notify(string.format("git show failed for: %s (error: %s)", git_ref, table.concat(base_content, " ")), vim.log.levels.WARN)
      base_content = { "(file did not exist at base)" }
    end
  else
    base_content = { "(new file)" }
  end

  -- Turn off diff mode in existing diff windows before closing
  if M.state.diff_win_left and vim.api.nvim_win_is_valid(M.state.diff_win_left) then
    vim.api.nvim_win_call(M.state.diff_win_left, function() vim.cmd("diffoff") end)
    vim.api.nvim_win_close(M.state.diff_win_left, true)
  end
  if M.state.diff_win_right and vim.api.nvim_win_is_valid(M.state.diff_win_right) then
    vim.api.nvim_win_call(M.state.diff_win_right, function() vim.cmd("diffoff") end)
    vim.api.nvim_win_close(M.state.diff_win_right, true)
  end
  M.state.diff_win_left = nil
  M.state.diff_win_right = nil

  -- Delete existing base buffer if it exists
  local base_buf_name = string.format("[BASE] %s", file.path)
  local existing_base_buf = vim.fn.bufnr(base_buf_name)
  if existing_base_buf ~= -1 then
    vim.api.nvim_buf_delete(existing_base_buf, { force = true })
  end

  -- Create left buffer (base version)
  local left_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, base_content)
  vim.api.nvim_buf_set_name(left_buf, base_buf_name)
  vim.api.nvim_buf_set_option(left_buf, "modifiable", false)
  vim.api.nvim_buf_set_option(left_buf, "buftype", "nofile")
  local ft = vim.filetype.match({ filename = file.path })
  if ft then
    vim.api.nvim_buf_set_option(left_buf, "filetype", ft)
  end

  -- Determine right buffer (current version)
  local right_buf
  local using_real_file = false
  if file.status ~= "removed" then
    -- Use the actual file for LSP support
    -- Use absolute path to avoid matching the [BASE] buffer
    local abs_path = vim.fn.fnamemodify(file.path, ":p")
    local existing_buf = vim.fn.bufnr("^" .. abs_path .. "$")
    if existing_buf ~= -1 then
      right_buf = existing_buf
    else
      -- Load the file into a new buffer (without opening in a window yet)
      right_buf = vim.fn.bufadd(abs_path)
      vim.fn.bufload(right_buf)
    end
    using_real_file = true
  else
    -- File was deleted, create a scratch buffer
    local current_buf_name = string.format("[CURRENT] %s", file.path)
    local existing_current_buf = vim.fn.bufnr(current_buf_name)
    if existing_current_buf ~= -1 then
      vim.api.nvim_buf_delete(existing_current_buf, { force = true })
    end
    right_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, { "(file deleted)" })
    vim.api.nvim_buf_set_name(right_buf, current_buf_name)
    vim.api.nvim_buf_set_option(right_buf, "modifiable", false)
    vim.api.nvim_buf_set_option(right_buf, "buftype", "nofile")
  end

  -- Set up windows: we want file_list | base | current (with comments below)
  -- Close only the diff windows, preserving file list and comments
  if M.state.diff_win_left and vim.api.nvim_win_is_valid(M.state.diff_win_left) then
    vim.api.nvim_win_close(M.state.diff_win_left, true)
  end
  if M.state.diff_win_right and vim.api.nvim_win_is_valid(M.state.diff_win_right) then
    vim.api.nvim_win_close(M.state.diff_win_right, true)
  end
  M.state.diff_win_left = nil
  M.state.diff_win_right = nil

  -- Go to file list and create the diff windows to the right
  if M.state.file_list_win and vim.api.nvim_win_is_valid(M.state.file_list_win) then
    vim.api.nvim_set_current_win(M.state.file_list_win)
  end

  -- Create left diff window with base buffer directly
  vim.cmd("rightbelow vsplit")
  M.state.diff_win_left = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.state.diff_win_left, left_buf)

  -- Create right diff window with current buffer directly
  vim.cmd("rightbelow vsplit")
  M.state.diff_win_right = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.state.diff_win_right, right_buf)

  -- Enable diff mode
  vim.api.nvim_win_call(M.state.diff_win_left, function() vim.cmd("diffthis") end)
  vim.api.nvim_win_call(M.state.diff_win_right, function() vim.cmd("diffthis") end)

  -- Set window proportions: file list ~10%, diffs split remaining 50/50
  local total_width = vim.o.columns
  local file_list_width = math.max(math.floor(total_width * 0.10), 25)
  local remaining_width = total_width - file_list_width - 2  -- account for separators
  local diff_width = math.floor(remaining_width / 2)

  vim.api.nvim_win_set_width(M.state.file_list_win, file_list_width)
  vim.api.nvim_win_set_width(M.state.diff_win_left, diff_width)
  vim.api.nvim_win_set_width(M.state.diff_win_right, diff_width)

  -- Set up navigation keymaps in the diff buffers
  local function setup_nav_keymaps(buf)
    local opts = { buffer = buf, silent = true }
    vim.keymap.set("n", "]f", function() M.next_file() end, opts)
    vim.keymap.set("n", "[f", function() M.prev_file() end, opts)
    vim.keymap.set("n", "q", function() M.close_review() end, opts)
  end

  setup_nav_keymaps(left_buf)
  if not using_real_file then
    setup_nav_keymaps(right_buf)
  end

  -- Focus on the right (current) window
  vim.api.nvim_set_current_win(M.state.diff_win_right)
  return true
end

-- Navigate to next file
function M.next_file()
  if M.state.current_file_idx < #M.state.files then
    M.open_file_diff(M.state.current_file_idx + 1)
  else
    vim.notify("Already at last file", vim.log.levels.INFO)
  end
end

-- Navigate to previous file
function M.prev_file()
  if M.state.current_file_idx > 1 then
    M.open_file_diff(M.state.current_file_idx - 1)
  else
    vim.notify("Already at first file", vim.log.levels.INFO)
  end
end

-- Reload diff for current file and restore the canonical layout if needed
function M.reload_current_file()
  -- Ensure we have PR data loaded
  if not M.state.pr_number or #M.state.files == 0 then
    vim.notify("No PR loaded. Run :GHPRReview first.", vim.log.levels.WARN)
    return
  end

  -- Restore canonical layout: file list | diff windows | comments at bottom
  M.restore_layout()

  -- Open the current file (or first file if none selected)
  local idx = M.state.current_file_idx
  if idx < 1 or idx > #M.state.files then
    idx = 1
  end
  M.open_file_diff(idx)
end

-- Restore the canonical review layout
-- Layout: file list (left) | base diff | current diff
--         comments buffer (bottom, full width)
function M.restore_layout()
  -- Close all review-related windows first for a clean slate
  local windows_to_keep = {}

  -- Check what we need to recreate
  local need_file_list = not M.state.file_list_win or not vim.api.nvim_win_is_valid(M.state.file_list_win)
  local need_comments = not M.state.comments_win or not vim.api.nvim_win_is_valid(M.state.comments_win)

  -- If file list is missing, we need to recreate the whole layout
  if need_file_list then
    -- Close existing windows
    if M.state.diff_win_left and vim.api.nvim_win_is_valid(M.state.diff_win_left) then
      vim.api.nvim_win_close(M.state.diff_win_left, true)
    end
    if M.state.diff_win_right and vim.api.nvim_win_is_valid(M.state.diff_win_right) then
      vim.api.nvim_win_close(M.state.diff_win_right, true)
    end
    if M.state.comments_win and vim.api.nvim_win_is_valid(M.state.comments_win) then
      vim.api.nvim_win_close(M.state.comments_win, true)
    end
    M.state.diff_win_left = nil
    M.state.diff_win_right = nil
    M.state.comments_win = nil

    -- Recreate the file list (this sets up the left panel)
    create_file_list()
    need_comments = true  -- Force recreate comments too
  end

  -- Ensure comments buffer exists and has content
  if M.state.comments_buf == nil or not vim.api.nvim_buf_is_valid(M.state.comments_buf) then
    -- Create the buffer but don't open window yet
    for _, buf in ipairs(vim.api.nvim_list_bufs()) do
      local name = vim.api.nvim_buf_get_name(buf)
      if name:match("%[PR Comments%]$") then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end

    M.state.comments_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(M.state.comments_buf, "buftype", "nofile")
    vim.api.nvim_buf_set_option(M.state.comments_buf, "bufhidden", "hide")
    vim.api.nvim_buf_set_option(M.state.comments_buf, "swapfile", false)
    vim.api.nvim_buf_set_name(M.state.comments_buf, "[PR Comments]")

    -- Render content
    render_comments_buffer()
    setup_comments_keymaps()
  end

  -- Create comments window at the bottom if needed
  if need_comments then
    -- Save current window to return to
    local cur_win = vim.api.nvim_get_current_win()

    -- Create comments window at the very bottom
    vim.cmd("botright split")
    vim.cmd("resize 12")
    M.state.comments_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(M.state.comments_win, M.state.comments_buf)

    -- Window options
    vim.api.nvim_win_set_option(M.state.comments_win, "number", false)
    vim.api.nvim_win_set_option(M.state.comments_win, "relativenumber", false)
    vim.api.nvim_win_set_option(M.state.comments_win, "signcolumn", "no")
    vim.api.nvim_win_set_option(M.state.comments_win, "winfixheight", true)
    vim.api.nvim_win_set_option(M.state.comments_win, "cursorline", true)

    -- Return to previous window
    if vim.api.nvim_win_is_valid(cur_win) then
      vim.api.nvim_set_current_win(cur_win)
    end
  end
end

-- Select a file in the review panel by path
-- Returns true if file was found and opened successfully
function M.select_file_by_path(path)
  if not path or #M.state.files == 0 then
    return false
  end

  for i, file in ipairs(M.state.files) do
    if file.path == path then
      return M.open_file_diff(i) or false
    end
  end
  return false
end

-- Create the file list panel
create_file_list = function()
  -- Close existing review first if one is open
  if M.state.file_list_win and vim.api.nvim_win_is_valid(M.state.file_list_win) then
    M.close_review()
  end

  -- Delete existing buffer if it exists (use exact match)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(buf)
    if name:match("%[PR Files%]$") then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end

  -- Create buffer
  M.state.file_list_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(M.state.file_list_buf, "buftype", "nofile")
  vim.api.nvim_buf_set_option(M.state.file_list_buf, "bufhidden", "wipe")
  vim.api.nvim_buf_set_option(M.state.file_list_buf, "swapfile", false)
  vim.api.nvim_buf_set_name(M.state.file_list_buf, "[PR Files]")

  -- Create window on the left (about 10% width)
  vim.cmd("topleft vsplit")
  local file_list_width = math.floor(vim.o.columns * 0.10)
  vim.cmd("vertical resize " .. math.max(file_list_width, 25))  -- minimum 25 cols
  M.state.file_list_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M.state.file_list_win, M.state.file_list_buf)

  -- Window options
  vim.api.nvim_win_set_option(M.state.file_list_win, "number", false)
  vim.api.nvim_win_set_option(M.state.file_list_win, "relativenumber", false)
  vim.api.nvim_win_set_option(M.state.file_list_win, "signcolumn", "no")
  vim.api.nvim_win_set_option(M.state.file_list_win, "winfixwidth", true)

  -- Render the file list
  render_file_list()

  -- Set up keymaps
  local opts = { buffer = M.state.file_list_buf, silent = true }
  vim.keymap.set("n", "<CR>", function()
    local line = vim.fn.line(".")
    M.open_file_diff(line)
  end, opts)
  vim.keymap.set("n", "j", "j", opts)
  vim.keymap.set("n", "k", "k", opts)
  vim.keymap.set("n", "]f", function() M.next_file() end, opts)
  vim.keymap.set("n", "[f", function() M.prev_file() end, opts)
  vim.keymap.set("n", "q", function() M.close_review() end, opts)

  -- Return to a different window
  vim.cmd("wincmd l")
end

-- Close the review UI
function M.close_review()
  -- Turn off diff mode in any windows that have it
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(win) then
      local ok = pcall(function()
        vim.api.nvim_win_call(win, function()
          vim.cmd("diffoff")
        end)
      end)
    end
  end

  -- Close file list window
  if M.state.file_list_win and vim.api.nvim_win_is_valid(M.state.file_list_win) then
    vim.api.nvim_win_close(M.state.file_list_win, true)
  end

  -- Close diff windows
  if M.state.diff_win_left and vim.api.nvim_win_is_valid(M.state.diff_win_left) then
    vim.api.nvim_win_close(M.state.diff_win_left, true)
  end
  if M.state.diff_win_right and vim.api.nvim_win_is_valid(M.state.diff_win_right) then
    -- Don't close if it's a real file buffer
    local buf = vim.api.nvim_win_get_buf(M.state.diff_win_right)
    local buftype = vim.api.nvim_buf_get_option(buf, "buftype")
    if buftype == "nofile" then
      vim.api.nvim_win_close(M.state.diff_win_right, true)
    end
  end

  -- Reset state
  M.state.file_list_buf = nil
  M.state.file_list_win = nil
  M.state.diff_win_left = nil
  M.state.diff_win_right = nil
  M.state.current_file_idx = 0

  vim.notify("Review closed", vim.log.levels.INFO)
end

-- Start the diff review (load files and open UI)
---@param pr_number number|nil PR number (uses current branch's PR if nil)
function M.start_review(pr_number)
  -- Get repo info
  local owner, repo = api.get_repo()
  if not owner or not repo then
    vim.notify("Failed to detect repository. Are you in a git repo?", vim.log.levels.ERROR)
    return
  end

  -- Get PR number if not provided
  if not pr_number then
    local pr_info = vim.fn.system({ "gh", "pr", "view", "--json", "number", "-q", ".number" })
    if vim.v.shell_error == 0 then
      pr_number = tonumber(vim.trim(pr_info))
    end
  end

  if not pr_number then
    vim.ui.input({ prompt = "PR number: " }, function(input)
      if input then
        M.start_review(tonumber(input))
      end
    end)
    return
  end

  M.state.owner = owner
  M.state.repo = repo
  M.state.pr_number = pr_number

  vim.notify(string.format("Loading PR #%d...", pr_number), vim.log.levels.INFO)

  -- Load files
  api.get_pr_files_async(pr_number, function(result, err)
    if err then
      vim.notify("Failed to load PR files: " .. err, vim.log.levels.ERROR)
      return
    end

    M.state.files = result.files
    M.state.merge_base = result.merge_base

    if #M.state.files == 0 then
      vim.notify("No changed files in PR", vim.log.levels.INFO)
      return
    end

    vim.notify(string.format("Loaded %d files (base: %s)", #M.state.files, result.merge_base:sub(1, 8)), vim.log.levels.INFO)

    -- Create the UI: file list, then diff windows
    create_file_list()
    M.open_file_diff(1)

    -- Load comments and show in unified layout when done
    api.get_pr_comments_async(owner, repo, pr_number, function(comments_result, comments_err)
      if comments_err then
        vim.notify("Failed to load comments: " .. comments_err, vim.log.levels.WARN)
        return
      end

      M.state.comments = parse_comments(comments_result)

      -- Check for pending review
      local pr = comments_result.data.repository.pullRequest
      for _, review in ipairs(safe_get(pr, "reviews", "nodes") or {}) do
        if review.state == "PENDING" then
          M.state.pending_review = { id = review.id, databaseId = review.databaseId }
          break
        end
      end

      -- Create comments buffer and show it at the bottom
      if #M.state.comments > 0 then
        M.populate_comments_buffer({ focus = false })
        -- Now show it in the layout
        M.restore_layout()
        vim.notify(string.format("Loaded %d comments", #M.state.comments), vim.log.levels.INFO)
      end
    end)
  end)
end

-- Setup function
function M.setup(opts)
  opts = opts or {}

  -- Create commands
  vim.api.nvim_create_user_command("GHPRComments", function(args)
    local pr_number = args.args ~= "" and tonumber(args.args) or nil
    M.load_comments(pr_number)
  end, { nargs = "?", desc = "Load PR comments" })

  vim.api.nvim_create_user_command("GHPRCommentsClose", function()
    M.close_comments()
  end, { desc = "Close PR comments buffer" })

  vim.api.nvim_create_user_command("GHPRNextComment", function()
    M.next_comment()
  end, { desc = "Go to next comment" })

  vim.api.nvim_create_user_command("GHPRPrevComment", function()
    M.prev_comment()
  end, { desc = "Go to previous comment" })

  vim.api.nvim_create_user_command("GHPRReview", function(args)
    local pr_number = args.args ~= "" and tonumber(args.args) or nil
    M.start_review(pr_number)
  end, { nargs = "?", desc = "Start PR diff review" })

  vim.api.nvim_create_user_command("GHPRReviewClose", function()
    M.close_review()
  end, { desc = "Close PR diff review" })

  vim.api.nvim_create_user_command("GHPRNextFile", function()
    M.next_file()
  end, { desc = "Go to next file in review" })

  vim.api.nvim_create_user_command("GHPRPrevFile", function()
    M.prev_file()
  end, { desc = "Go to previous file in review" })

  vim.api.nvim_create_user_command("GHPRReloadFile", function()
    M.reload_current_file()
  end, { desc = "Reload diff for current file" })

  vim.api.nvim_create_user_command("GHPRCommentAdd", function()
    M.add_comment({
      path = vim.fn.expand("%:."),
      line = vim.fn.line("."),
    })
  end, { desc = "Add a comment on current line" })

  vim.api.nvim_create_user_command("GHPRCommentAddGeneral", function()
    M.add_comment()
  end, { desc = "Add a general PR comment" })

  vim.api.nvim_create_user_command("GHPRCommentEdit", function()
    M.edit_comment()
  end, { desc = "Edit selected comment" })

  vim.api.nvim_create_user_command("GHPRCommentDelete", function()
    M.delete_comment()
  end, { desc = "Delete selected comment" })

  vim.api.nvim_create_user_command("GHPRCommentReply", function()
    M.reply_to_thread()
  end, { desc = "Reply to selected thread" })

  vim.api.nvim_create_user_command("GHPRReviewSubmit", function(args)
    local event = args.args ~= "" and args.args or nil
    M.submit_review(event)
  end, { nargs = "?", desc = "Submit pending review" })

  vim.api.nvim_create_user_command("GHPRGoto", function()
    M.goto_comment()
  end, { desc = "Go to comment location" })

  vim.api.nvim_create_user_command("GHPRReact", function()
    M.react_to_comment()
  end, { desc = "Add reaction to selected comment" })

  vim.api.nvim_create_user_command("GHPRUnreact", function()
    M.unreact_to_comment()
  end, { desc = "Remove reaction from selected comment" })
end

return M
