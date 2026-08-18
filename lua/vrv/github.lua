local M = {}

local review_threads_query = [[
query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $endCursor) {
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          originalLine
          startLine
          originalStartLine
          diffSide
          startDiffSide
          subjectType
          comments(first: 100) {
            totalCount
            nodes {
              id
              fullDatabaseId
              body
              url
              diffHunk
              author { login }
            }
            pageInfo { hasNextPage endCursor }
          }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}]]

local review_thread_comments_query = [[
query($threadId: ID!, $endCursor: String) {
  node(id: $threadId) {
    ... on PullRequestReviewThread {
      comments(first: 100, after: $endCursor) {
        nodes {
          id
          fullDatabaseId
          body
          url
          diffHunk
          author { login }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}]]

local resolve_thread_mutation = [[
mutation($threadId: ID!) {
  resolveReviewThread(input: { threadId: $threadId }) {
    thread { id isResolved }
  }
}]]

local function fail_later(callback, message)
    vim.schedule(function()
        callback(nil, message)
    end)
end

local function run(root, args, callback)
    if vim.fn.executable("gh") == 0 then
        fail_later(callback, "gh executable not found")
        return
    end
    local command = { "gh" }
    vim.list_extend(command, args)
    vim.system(command, { cwd = root, text = true }, function(result)
        vim.schedule(function()
            if result.code ~= 0 then
                callback(nil, vim.trim(result.stderr or "gh command failed"))
                return
            end
            callback(result.stdout or "")
        end)
    end)
end

local function decode_json(content)
    local ok, decoded = pcall(vim.json.decode, content)
    if not ok then
        return nil, "gh returned invalid JSON: " .. tostring(decoded)
    end
    return decoded
end

function M.resolve(root, selector, callback)
    local args = { "pr", "view" }
    if selector and selector ~= "" then
        args[#args + 1] = selector
    end
    vim.list_extend(args, { "--json", "number,url,headRefOid" })
    run(root, args, function(output, err)
        if not output then
            callback(nil, err)
            return
        end
        local data, decode_err = decode_json(output)
        if not data then
            callback(nil, decode_err)
            return
        end
        local hostname
        local repository
        if data.url then
            hostname, repository = data.url:match("^https?://([^/]+)/([^/]+/[^/]+)/pull/%d+")
        end
        if not repository or type(data.number) ~= "number" or type(data.headRefOid) ~= "string" then
            callback(nil, "could not resolve repository, pull request number, and head commit")
            return
        end
        callback({
            repository = repository,
            hostname = hostname,
            number = data.number,
            url = data.url,
            head_oid = data.headRefOid,
        })
    end)
end

function M.fetch_diff(root, pull_request, callback)
    local args = {
        "api",
        string.format("repos/%s/pulls/%d", pull_request.repository, pull_request.number),
        "-H",
        "Accept: application/vnd.github.v3.diff",
    }
    if pull_request.hostname and pull_request.hostname ~= "github.com" then
        vim.list_extend(args, { "--hostname", pull_request.hostname })
    end
    run(root, args, callback)
end

function M.fetch_threads(root, pull_request, callback)
    local owner, name = pull_request.repository:match("^([^/]+)/(.+)$")
    if not owner or not name then
        fail_later(callback, "invalid GitHub repository name: " .. tostring(pull_request.repository))
        return
    end
    local args = {
        "api",
        "graphql",
        "--paginate",
        "--slurp",
        "-f",
        "query=" .. review_threads_query,
        "-f",
        "owner=" .. owner,
        "-f",
        "name=" .. name,
        "-F",
        "number=" .. pull_request.number,
    }
    if pull_request.hostname and pull_request.hostname ~= "github.com" then
        vim.list_extend(args, { "--hostname", pull_request.hostname })
    end
    run(root, args, function(output, err)
        if not output then
            callback(nil, err)
            return
        end
        local pages, decode_err = decode_json(output)
        if not pages then
            callback(nil, decode_err)
            return
        end
        if pages.data then
            pages = { pages }
        end
        local threads = {}
        for _, page in ipairs(pages) do
            if page.errors and page.errors[1] then
                callback(nil, page.errors[1].message or "GitHub GraphQL query failed")
                return
            end
            local connection = page.data
                and page.data.repository
                and page.data.repository.pullRequest
                and page.data.repository.pullRequest.reviewThreads
            if not connection then
                callback(nil, "GitHub GraphQL response did not contain review threads")
                return
            end
            vim.list_extend(threads, connection.nodes or {})
        end
        local pending = 0
        local failed = false
        local function fail(message)
            if not failed then
                failed = true
                callback(nil, message)
            end
        end
        local function complete_one()
            pending = pending - 1
            if pending == 0 and not failed then
                callback(threads)
            end
        end

        for _, thread in ipairs(threads) do
            local connection = type(thread.comments) == "table" and thread.comments or nil
            local page_info = connection and connection.pageInfo
            if page_info and page_info.hasNextPage then
                connection.nodes = type(connection.nodes) == "table" and connection.nodes or {}
                if type(page_info.endCursor) ~= "string" or page_info.endCursor == "" then
                    fail("GitHub review thread comments were paginated without an end cursor")
                    return
                end
                pending = pending + 1
                local comment_args = {
                    "api",
                    "graphql",
                    "--paginate",
                    "--slurp",
                    "-f",
                    "query=" .. review_thread_comments_query,
                    "-f",
                    "threadId=" .. thread.id,
                    "-f",
                    "endCursor=" .. page_info.endCursor,
                }
                if pull_request.hostname and pull_request.hostname ~= "github.com" then
                    vim.list_extend(comment_args, { "--hostname", pull_request.hostname })
                end
                run(root, comment_args, function(comment_output, comment_err)
                    if not comment_output then
                        fail(comment_err)
                        return
                    end
                    local comment_pages, comment_decode_err = decode_json(comment_output)
                    if not comment_pages then
                        fail(comment_decode_err)
                        return
                    end
                    if comment_pages.data then
                        comment_pages = { comment_pages }
                    end
                    for _, comment_page in ipairs(comment_pages) do
                        if comment_page.errors and comment_page.errors[1] then
                            fail(comment_page.errors[1].message or "GitHub GraphQL query failed")
                            return
                        end
                        local comments = comment_page.data
                            and comment_page.data.node
                            and comment_page.data.node.comments
                        if not comments then
                            fail("GitHub GraphQL response did not contain review thread comments")
                            return
                        end
                        vim.list_extend(connection.nodes, comments.nodes or {})
                    end
                    connection.pageInfo = { hasNextPage = false }
                    complete_one()
                end)
            end
        end
        if pending == 0 and not failed then
            callback(threads)
        end
    end)
end

function M.resolve_thread(root, origin, callback)
    local args = {
        "api",
        "graphql",
        "-f",
        "query=" .. resolve_thread_mutation,
        "-f",
        "threadId=" .. origin.thread_id,
    }
    if origin.hostname and origin.hostname ~= "github.com" then
        vim.list_extend(args, { "--hostname", origin.hostname })
    end
    run(root, args, function(output, err)
        if not output then
            callback(nil, err)
            return
        end
        local response, decode_err = decode_json(output)
        if not response then
            callback(nil, decode_err)
            return
        end
        if response.errors and response.errors[1] then
            callback(nil, response.errors[1].message or "GitHub GraphQL mutation failed")
            return
        end
        local thread = response.data and response.data.resolveReviewThread and response.data.resolveReviewThread.thread
        if not thread or thread.isResolved ~= true then
            callback(nil, "GitHub did not mark the review thread as resolved")
            return
        end
        callback(thread)
    end)
end

return M
