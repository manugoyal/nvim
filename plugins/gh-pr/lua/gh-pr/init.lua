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
}

-- Parse comments from API response into a flat list
---@param data table API response
---@return table[] comments
local function parse_comments(data)
  local comments = {}
  local pr = data.data.repository.pullRequest

  -- Issue comments (general PR comments)
  for _, comment in ipairs(safe_get(pr, "comments", "nodes") or {}) do
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

    -- Populate quickfix
    M.populate_quickfix({ focus = focus })
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

-- Populate quickfix with comments, grouped by thread
---@param opts table|nil {focus: boolean} whether to focus quickfix (default true)
function M.populate_quickfix(opts)
  opts = opts or {}
  local focus = opts.focus ~= false  -- default to true

  local items = {}

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

  -- Add issue comments first
  for _, comment in ipairs(issue_comments) do
    local body = comment.body:gsub("\n", " "):sub(1, 80)
    local state_indicator = comment.state == "PENDING" and "[PENDING] " or ""
    local text = string.format("@%s: %s%s", comment.author, state_indicator, body)

    table.insert(items, {
      filename = "PR_COMMENT",
      lnum = 0,
      col = 0,
      text = text,
      user_data = comment,
    })
  end

  -- Add a separator if we have both issue comments and review threads
  if #issue_comments > 0 and #thread_order > 0 then
    table.insert(items, {
      filename = "---",
      lnum = 0,
      col = 0,
      text = "--- Review Comments ---",
      user_data = nil,
    })
  end

  -- Add review threads with threading indicators
  for _, tid in ipairs(thread_order) do
    local thread_comments = threads[tid]
    for i, comment in ipairs(thread_comments) do
      local filename = comment.path or "REVIEW"
      local lnum = comment.line or 0

      -- Threading indicator
      local prefix = ""
      if i == 1 then
        prefix = #thread_comments > 1 and "┬ " or "─ "
      elseif i == #thread_comments then
        prefix = "└ "
      else
        prefix = "├ "
      end

      local state_indicator = ""
      if comment.state == "PENDING" then
        state_indicator = "[PENDING] "
      end
      if comment.outdated then
        state_indicator = state_indicator .. "[OUTDATED] "
      end

      -- Truncate body for display
      local body = comment.body:gsub("\n", " "):sub(1, 120)
      local text = string.format("%s@%s: %s%s", prefix, comment.author, state_indicator, body)

      table.insert(items, {
        filename = filename,
        lnum = lnum,
        col = 0,
        text = text,
        user_data = comment,
      })
    end
  end

  vim.fn.setqflist({}, "r", {
    title = string.format("PR #%d Comments (%d)", M.state.pr_number or 0, #M.state.comments),
    items = items,
  })

  if focus then
    vim.cmd("copen")
  end
end

-- Get the comment under cursor in quickfix
---@return table|nil comment
function M.get_current_comment()
  -- Use cursor line position (1-based) instead of selected quickfix item
  local cursor_line = vim.fn.line(".")

  -- Get all items and return the one at cursor line
  local items = vim.fn.getqflist({ items = 1 }).items
  if items and items[cursor_line] then
    return items[cursor_line].user_data
  end
  return nil
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

  -- Create a scratch buffer for editing the comment
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, "buftype", "acwrite")
  vim.api.nvim_buf_set_option(buf, "filetype", "markdown")
  vim.api.nvim_buf_set_name(buf, title)

  -- Open in a split
  vim.cmd("split")
  vim.api.nvim_win_set_buf(0, buf)

  -- Track if comment has been submitted
  local submitted = false

  -- Helper to handle successful submission
  local function on_submit_success()
    M.load_comments_async(M.state.pr_number)
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
        -- Reply to existing thread (async)
        api.reply_to_thread_async(opts.reply_to_thread, body, function(result, err)
          if err then
            on_submit_error("Failed to add reply: " .. err)
            return
          end
          on_submit_success()
        end)
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

-- Submit pending review
---@param event string|nil "APPROVE", "REQUEST_CHANGES", or "COMMENT" (will prompt if nil)
function M.submit_review(event)
  if not M.state.pending_review then
    vim.notify("No pending review", vim.log.levels.WARN)
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

  -- Optionally add a review body
  vim.ui.input({ prompt = "Review summary (optional): " }, function(body)
    api.submit_review_async(M.state.pending_review.id, event, body or "", function(result, err)
      if err then
        vim.notify("Failed to submit review: " .. err, vim.log.levels.ERROR)
        return
      end

      M.state.pending_review = nil
      M.load_comments_async(M.state.pr_number)
    end)
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

-- Setup function
function M.setup(opts)
  opts = opts or {}

  -- Create commands
  vim.api.nvim_create_user_command("GHPRComments", function(args)
    local pr_number = args.args ~= "" and tonumber(args.args) or nil
    M.load_comments(pr_number)
  end, { nargs = "?", desc = "Load PR comments into quickfix" })

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

  -- Set up quickfix keymaps
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "qf",
    callback = function()
      local bufnr = vim.api.nvim_get_current_buf()

      -- Only set up for our PR comments quickfix
      local qf_title = vim.fn.getqflist({ title = 1 }).title or ""
      if not qf_title:match("^PR #%d+ Comments") then
        return
      end

      local map_opts = { buffer = bufnr, silent = true }
      vim.keymap.set("n", "e", M.edit_comment, map_opts)
      vim.keymap.set("n", "d", M.delete_comment, map_opts)
      vim.keymap.set("n", "r", M.reply_to_thread, map_opts)
      vim.keymap.set("n", "p", M.preview_comment, map_opts)
      vim.keymap.set("n", "o", M.view_original, map_opts)
      vim.keymap.set("n", "R", function() M.load_comments(M.state.pr_number) end, map_opts)
      vim.keymap.set("n", "S", M.submit_review, map_opts)
    end,
  })
end

return M
