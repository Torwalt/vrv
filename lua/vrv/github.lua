local M = {}

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

function M.fetch_comments(root, pull_request, callback)
    local args = {
        "api",
        string.format("repos/%s/pulls/%d/comments?per_page=100", pull_request.repository, pull_request.number),
        "--paginate",
        "--slurp",
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
        local comments = {}
        for _, page in ipairs(pages) do
            if type(page) == "table" then
                vim.list_extend(comments, page)
            end
        end
        callback(comments)
    end)
end

return M
