-- GitHub API calls via gh CLI
local M = {}

-- Await helper: blocks until async operation completes
-- Returns (result, error) from the callback
-- Exported so callers can explicitly block on async functions when needed
function M.await(async_fn, ...)
  local done = false
  local result, err

  -- Call the async function with a callback that captures the result
  local args = { ... }
  table.insert(args, function(r, e)
    result, err = r, e
    done = true
  end)
  async_fn(unpack(args))

  -- Wait for completion (timeout after 30 seconds)
  vim.wait(30000, function() return done end, 10)

  if not done then
    return nil, "Timeout waiting for API response"
  end

  return result, err
end

-- Execute a gh command asynchronously, returning raw output (no JSON parsing)
---@param args string[] Arguments to pass to gh
---@param callback function Called with (output, error) when complete
function M.gh_async_raw(args, callback)
  local cmd = { "gh" }
  for _, arg in ipairs(args) do
    table.insert(cmd, arg)
  end

  local stdout_chunks = {}
  local stderr_chunks = {}

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(stdout_chunks, line)
          end
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(stderr_chunks, line)
          end
        end
      end
    end,
    on_exit = function(_, exit_code)
      vim.schedule(function()
        if exit_code ~= 0 then
          callback(nil, table.concat(stderr_chunks, "\n"))
          return
        end
        callback(vim.trim(table.concat(stdout_chunks, "\n")), nil)
      end)
    end,
  })
end

-- Execute a gh command asynchronously (primary implementation)
---@param args string[] Arguments to pass to gh
---@param callback function Called with (result, error) when complete
function M.gh_async(args, callback)
  local cmd = { "gh" }
  for _, arg in ipairs(args) do
    table.insert(cmd, arg)
  end

  local stdout_chunks = {}
  local stderr_chunks = {}

  vim.fn.jobstart(cmd, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(stdout_chunks, line)
          end
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, line in ipairs(data) do
          if line ~= "" then
            table.insert(stderr_chunks, line)
          end
        end
      end
    end,
    on_exit = function(_, exit_code)
      vim.schedule(function()
        if exit_code ~= 0 then
          callback(nil, table.concat(stderr_chunks, "\n"))
          return
        end

        local output = table.concat(stdout_chunks, "\n")
        local ok, parsed = pcall(vim.json.decode, output)
        if not ok then
          callback(nil, "Failed to parse JSON: " .. output)
          return
        end

        callback(parsed, nil)
      end)
    end,
  })
end

-- Execute a gh GraphQL query asynchronously
---@param query string
---@param callback function Called with (result, error) when complete
function M.graphql_async(query, callback)
  M.gh_async({ "api", "graphql", "-f", "query=" .. query }, callback)
end

-- Get repo owner and name from current git repo
---@return string|nil owner
---@return string|nil name
function M.get_repo()
  local output = vim.fn.system({ "gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner" })
  if vim.v.shell_error ~= 0 then
    return nil, nil
  end
  output = vim.trim(output)
  local owner, name = output:match("([^/]+)/(.+)")
  return owner, name
end

-- GraphQL query for PR comments
local function get_pr_comments_query(owner, repo, pr_number)
  return string.format([[
query {
  repository(owner: "%s", name: "%s") {
    pullRequest(number: %d) {
      id
      comments(first: 100) {
        nodes {
          id
          databaseId
          body
          author { login }
          createdAt
          url
          reactionGroups {
            content
            viewerHasReacted
            reactors { totalCount }
          }
        }
      }
      reviewThreads(first: 100) {
        nodes {
          id
          path
          line
          startLine
          originalLine
          isResolved
          isOutdated
          comments(first: 50) {
            nodes {
              id
              databaseId
              body
              author { login }
              createdAt
              url
              replyTo { id }
              outdated
              diffHunk
              originalCommit { oid }
              pullRequestReview {
                id
                databaseId
                state
              }
              reactionGroups {
                content
                viewerHasReacted
                reactors { totalCount }
              }
            }
          }
        }
      }
      reviews(first: 20, states: [PENDING]) {
        nodes {
          id
          databaseId
          state
          author { login }
        }
      }
    }
  }
}
]], owner, repo, pr_number)
end

-- Get all comments for a PR (async)
---@param owner string
---@param repo string
---@param pr_number number
---@param callback function Called with (result, error) when complete
function M.get_pr_comments_async(owner, repo, pr_number, callback)
  M.graphql_async(get_pr_comments_query(owner, repo, pr_number), callback)
end

-- Get or create a pending review for the current user (async)
---@param owner string
---@param repo string
---@param pr_number number
---@param callback function Called with (review, error) when complete
function M.get_or_create_pending_review_async(owner, repo, pr_number, callback)
  -- First check if there's already a pending review
  M.get_pr_comments_async(owner, repo, pr_number, function(result, err)
    if err then
      callback(nil, err)
      return
    end

    local pr = result.data.repository.pullRequest
    local pending_reviews = pr.reviews.nodes or {}

    -- Find existing pending review (we filter by PENDING state in query, so just take first)
    for _, review in ipairs(pending_reviews) do
      if review.state == "PENDING" then
        callback({ id = review.id, databaseId = review.databaseId }, nil)
        return
      end
    end

    -- No pending review found, create one
    -- First get the commit SHA (returns plain text, not JSON)
    M.gh_async_raw({
      "pr", "view", tostring(pr_number), "--json", "commits", "-q", ".commits[-1].oid"
    }, function(commit_sha, commit_err)
      if commit_err then
        callback(nil, "Failed to get commit SHA: " .. commit_err)
        return
      end

      M.gh_async({
        "api", string.format("repos/%s/%s/pulls/%d/reviews", owner, repo, pr_number),
        "-X", "POST",
        "-f", "commit_id=" .. commit_sha,
        "-f", "body="
      }, function(create_result, create_err)
        if create_err then
          callback(nil, create_err)
          return
        end
        callback({ id = create_result.node_id, databaseId = create_result.id }, nil)
      end)
    end)
  end)
end

-- GraphQL mutation for adding review thread
local function add_review_thread_query(review_id, path, line, body, side)
  side = side or "RIGHT"
  return string.format([[
mutation {
  addPullRequestReviewThread(input: {
    pullRequestReviewId: "%s"
    path: "%s"
    line: %d
    side: %s
    body: %s
  }) {
    thread {
      id
      comments(first: 1) {
        nodes {
          id
          databaseId
          body
          url
        }
      }
    }
  }
}
]], review_id, path, line, side, vim.json.encode(body))
end

-- Add a new comment thread to a pending review (async)
---@param review_id string GraphQL node ID of the review
---@param path string File path
---@param line number Line number
---@param body string Comment body
---@param side string|nil "LEFT" or "RIGHT" (default "RIGHT")
---@param callback function Called with (result, error) when complete
function M.add_review_thread_async(review_id, path, line, body, side, callback)
  M.graphql_async(add_review_thread_query(review_id, path, line, body, side), callback)
end

-- GraphQL mutation for replying to thread
local function reply_to_thread_query(thread_id, body, review_id)
  local review_field = ""
  if review_id then
    review_field = string.format('pullRequestReviewId: "%s"', review_id)
  end
  return string.format([[
mutation {
  addPullRequestReviewThreadReply(input: {
    pullRequestReviewThreadId: "%s"
    body: %s
    %s
  }) {
    comment {
      id
      databaseId
      body
      url
      pullRequestReview {
        id
        state
      }
    }
  }
}
]], thread_id, vim.json.encode(body), review_field)
end

-- Reply to an existing thread (async)
---@param thread_id string GraphQL node ID of the thread
---@param body string Comment body
---@param review_id string|nil Optional pending review ID to associate reply with
---@param callback function Called with (result, error) when complete
function M.reply_to_thread_async(thread_id, body, review_id, callback)
  M.graphql_async(reply_to_thread_query(thread_id, body, review_id), callback)
end

-- Add a general PR comment (async)
---@param owner string
---@param repo string
---@param pr_number number
---@param body string
---@param callback function Called with (result, error) when complete
function M.add_issue_comment_async(owner, repo, pr_number, body, callback)
  M.gh_async({
    "api", string.format("repos/%s/%s/issues/%d/comments", owner, repo, pr_number),
    "-f", "body=" .. body
  }, callback)
end

-- Update a comment (async)
---@param comment_id string GraphQL node ID
---@param body string New comment body
---@param callback function Called with (result, error) when complete
function M.update_comment_async(comment_id, body, callback)
  local query = string.format([[
mutation {
  updatePullRequestReviewComment(input: {
    pullRequestReviewCommentId: "%s"
    body: %s
  }) {
    pullRequestReviewComment {
      id
      body
    }
  }
}
]], comment_id, vim.json.encode(body))

  -- Try as review comment first
  M.graphql_async(query, function(result, err)
    if not err and result and result.data and result.data.updatePullRequestReviewComment then
      callback(result, nil)
      return
    end

    -- Try as issue comment
    local issue_query = string.format([[
mutation {
  updateIssueComment(input: {
    id: "%s"
    body: %s
  }) {
    issueComment {
      id
      body
    }
  }
}
]], comment_id, vim.json.encode(body))

    M.graphql_async(issue_query, callback)
  end)
end

-- Delete a comment (async)
---@param comment_id string GraphQL node ID
---@param callback function Called with (success, error) when complete
function M.delete_comment_async(comment_id, callback)
  local query = string.format([[
mutation {
  deletePullRequestReviewComment(input: {
    id: "%s"
  }) {
    clientMutationId
  }
}
]], comment_id)

  M.graphql_async(query, function(result, err)
    if not err and result and result.data and result.data.deletePullRequestReviewComment then
      callback(true, nil)
      return
    end

    -- Try as issue comment
    local issue_query = string.format([[
mutation {
  deleteIssueComment(input: {
    id: "%s"
  }) {
    clientMutationId
  }
}
]], comment_id)

    M.graphql_async(issue_query, function(r, e)
      if e then
        callback(false, e)
      else
        callback(true, nil)
      end
    end)
  end)
end

-- Submit a pending review (async)
---@param review_id string GraphQL node ID of the review
---@param event string "APPROVE", "REQUEST_CHANGES", or "COMMENT"
---@param body string|nil Optional review body
---@param callback function Called with (result, error) when complete
function M.submit_review_async(review_id, event, body, callback)
  body = body or ""
  local query = string.format([[
mutation {
  submitPullRequestReview(input: {
    pullRequestReviewId: "%s"
    event: %s
    body: %s
  }) {
    pullRequestReview {
      id
      state
      url
    }
  }
}
]], review_id, event, vim.json.encode(body))

  M.graphql_async(query, callback)
end

-- Add a reaction to a comment (async)
---@param subject_id string GraphQL node ID of the comment
---@param content string Reaction type: THUMBS_UP, THUMBS_DOWN, LAUGH, HOORAY, CONFUSED, HEART, ROCKET, EYES
---@param callback function Called with (result, error) when complete
function M.add_reaction_async(subject_id, content, callback)
  local query = string.format([[
mutation {
  addReaction(input: {
    subjectId: "%s"
    content: %s
  }) {
    reaction {
      content
    }
    subject {
      id
    }
  }
}
]], subject_id, content)

  M.graphql_async(query, callback)
end

-- Remove a reaction from a comment (async)
---@param subject_id string GraphQL node ID of the comment
---@param content string Reaction type: THUMBS_UP, THUMBS_DOWN, LAUGH, HOORAY, CONFUSED, HEART, ROCKET, EYES
---@param callback function Called with (result, error) when complete
function M.remove_reaction_async(subject_id, content, callback)
  local query = string.format([[
mutation {
  removeReaction(input: {
    subjectId: "%s"
    content: %s
  }) {
    reaction {
      content
    }
    subject {
      id
    }
  }
}
]], subject_id, content)

  M.graphql_async(query, callback)
end

return M
