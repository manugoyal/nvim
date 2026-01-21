-- GitHub API calls via gh CLI
local M = {}

-- Execute a gh command and return the parsed JSON result
---@param args string[]
---@return table|nil result
---@return string|nil error
function M.gh(args)
  local cmd = { "gh" }
  for _, arg in ipairs(args) do
    table.insert(cmd, arg)
  end

  local result = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return nil, result
  end

  local ok, parsed = pcall(vim.json.decode, result)
  if not ok then
    return nil, "Failed to parse JSON: " .. result
  end

  return parsed, nil
end

-- Execute a gh GraphQL query
---@param query string
---@return table|nil result
---@return string|nil error
function M.graphql(query)
  return M.gh({ "api", "graphql", "-f", "query=" .. query })
end

-- Get repo owner and name from current git repo
---@return string|nil owner
---@return string|nil name
function M.get_repo()
  local result, err = M.gh({ "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner" })
  if err then
    -- Try parsing as plain text (gh repo view -q returns plain text, not JSON)
    local output = vim.fn.system({ "gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner" })
    if vim.v.shell_error ~= 0 then
      return nil, nil
    end
    output = vim.trim(output)
    local owner, name = output:match("([^/]+)/(.+)")
    return owner, name
  end
  return nil, nil
end

-- Get all comments for a PR (including pending review comments)
---@param owner string
---@param repo string
---@param pr_number number
---@return table|nil comments
---@return string|nil error
function M.get_pr_comments(owner, repo, pr_number)
  local query = string.format([[
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

  return M.graphql(query)
end

-- Get or create a pending review for the current user
---@param owner string
---@param repo string
---@param pr_number number
---@return table|nil review {id, databaseId}
---@return string|nil error
function M.get_or_create_pending_review(owner, repo, pr_number)
  -- First check if there's already a pending review
  local result, err = M.get_pr_comments(owner, repo, pr_number)
  if err then
    return nil, err
  end

  local pr = result.data.repository.pullRequest
  local pending_reviews = pr.reviews.nodes or {}

  -- Find existing pending review by current user
  local current_user = vim.fn.system({ "gh", "api", "user", "-q", ".login" })
  current_user = vim.trim(current_user)

  for _, review in ipairs(pending_reviews) do
    if review.state == "PENDING" and review.author and review.author.login == current_user then
      return { id = review.id, databaseId = review.databaseId }, nil
    end
  end

  -- Create a new pending review
  local commit_result = M.gh({
    "pr", "view", tostring(pr_number), "--json", "commits", "-q", ".commits[-1].oid"
  })
  -- commit_result is plain text, not JSON
  local commit_sha = vim.fn.system({
    "gh", "pr", "view", tostring(pr_number), "--json", "commits", "-q", ".commits[-1].oid"
  })
  commit_sha = vim.trim(commit_sha)

  local create_result, create_err = M.gh({
    "api", string.format("repos/%s/%s/pulls/%d/reviews", owner, repo, pr_number),
    "-X", "POST",
    "-f", "commit_id=" .. commit_sha,
    "-f", "body="
  })

  if create_err then
    return nil, create_err
  end

  return { id = create_result.node_id, databaseId = create_result.id }, nil
end

-- Add a new comment thread to a pending review
---@param review_id string GraphQL node ID of the review
---@param path string File path
---@param line number Line number
---@param body string Comment body
---@param side string|nil "LEFT" or "RIGHT" (default "RIGHT")
---@return table|nil comment
---@return string|nil error
function M.add_review_thread(review_id, path, line, body, side)
  side = side or "RIGHT"
  local query = string.format([[
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

  return M.graphql(query)
end

-- Reply to an existing thread
---@param thread_id string GraphQL node ID of the thread
---@param body string Comment body
---@return table|nil comment
---@return string|nil error
function M.reply_to_thread(thread_id, body)
  local query = string.format([[
mutation {
  addPullRequestReviewThreadReply(input: {
    pullRequestReviewThreadId: "%s"
    body: %s
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
]], thread_id, vim.json.encode(body))

  return M.graphql(query)
end

-- Add a general PR comment (issue comment, not review comment)
---@param owner string
---@param repo string
---@param pr_number number
---@param body string
---@return table|nil comment
---@return string|nil error
function M.add_issue_comment(owner, repo, pr_number, body)
  return M.gh({
    "api", string.format("repos/%s/%s/issues/%d/comments", owner, repo, pr_number),
    "-f", "body=" .. body
  })
end

-- Update a comment
---@param comment_id string GraphQL node ID (IC_* for issue comments, PRRC_* for review comments)
---@param body string New comment body
---@return table|nil result
---@return string|nil error
function M.update_comment(comment_id, body)
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
  local result, err = M.graphql(query)
  if not err and result.data and result.data.updatePullRequestReviewComment then
    return result, nil
  end

  -- Try as issue comment
  query = string.format([[
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

  return M.graphql(query)
end

-- Delete a comment
---@param comment_id string GraphQL node ID
---@return boolean success
---@return string|nil error
function M.delete_comment(comment_id)
  -- Try as review comment first
  local query = string.format([[
mutation {
  deletePullRequestReviewComment(input: {
    id: "%s"
  }) {
    clientMutationId
  }
}
]], comment_id)

  local result, err = M.graphql(query)
  if not err and result.data and result.data.deletePullRequestReviewComment then
    return true, nil
  end

  -- Try as issue comment
  query = string.format([[
mutation {
  deleteIssueComment(input: {
    id: "%s"
  }) {
    clientMutationId
  }
}
]], comment_id)

  result, err = M.graphql(query)
  if err then
    return false, err
  end

  return true, nil
end

-- Submit a pending review
---@param review_id string GraphQL node ID of the review
---@param event string "APPROVE", "REQUEST_CHANGES", or "COMMENT"
---@param body string|nil Optional review body
---@return table|nil result
---@return string|nil error
function M.submit_review(review_id, event, body)
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

  return M.graphql(query)
end

return M
