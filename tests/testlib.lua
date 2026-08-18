local M = {
    failures = {},
    temporary_paths = {},
}

local function inspect(value)
    return vim.inspect(value)
end

function M.eq(expected, actual, message)
    if not vim.deep_equal(expected, actual) then
        error(
            (message and (message .. ": ") or "") .. "expected " .. inspect(expected) .. ", got " .. inspect(actual),
            2
        )
    end
end

function M.truthy(value, message)
    if not value then
        error(message or ("expected a truthy value, got " .. inspect(value)), 2)
    end
    return value
end

function M.falsy(value, message)
    if value then
        error(message or ("expected a falsy value, got " .. inspect(value)), 2)
    end
end

function M.match(pattern, value, message)
    if type(value) ~= "string" or not value:match(pattern) then
        error(message or string.format("expected %s to match %s", inspect(value), inspect(pattern)), 2)
    end
end

function M.test(name, callback)
    local ok, err = xpcall(callback, debug.traceback)
    if ok then
        print("ok - " .. name)
    else
        M.failures[#M.failures + 1] = { name = name, error = err }
        print("not ok - " .. name .. "\n" .. err)
    end
end

function M.tempdir()
    local path = vim.fn.tempname()
    assert(vim.fn.mkdir(path, "p") == 1)
    M.temporary_paths[#M.temporary_paths + 1] = path
    return vim.fs.normalize(path)
end

function M.write(path, content)
    local parent = vim.fn.fnamemodify(path, ":h")
    assert(vim.fn.mkdir(parent, "p") == 1 or vim.fn.isdirectory(parent) == 1)
    local file = assert(io.open(path, "wb"))
    assert(file:write(content))
    assert(file:close())
end

function M.read(path)
    local file = assert(io.open(path, "rb"))
    local content = assert(file:read("*a"))
    assert(file:close())
    return content
end

function M.command(command, cwd)
    local result = vim.system(command, { cwd = cwd, text = true }):wait()
    if result.code ~= 0 then
        error(string.format("command failed (%d): %s", result.code, vim.trim(result.stderr or "")), 2)
    end
    return vim.trim(result.stdout or "")
end

function M.repo(opts)
    opts = opts or {}
    local root = M.tempdir()
    M.command({ "git", "init", "-b", opts.branch or "main", root })
    if opts.commit then
        M.command({ "git", "config", "user.name", "vrv tests" }, root)
        M.command({ "git", "config", "user.email", "vrv@example.invalid" }, root)
        M.write(root .. "/README.md", "fixture\n")
        M.command({ "git", "add", "README.md" }, root)
        M.command({ "git", "commit", "-m", "fixture" }, root)
    end
    return root
end

function M.annotation(overrides)
    local annotation = {
        id = "annotation-1",
        branch = "main",
        file = "lua/example.lua",
        start_line = 4,
        end_line = 4,
        snippet_start = 1,
        snippet = {
            "1: one",
            "2: two",
            "3: three",
            "4: target",
            "5: five",
            "6: six",
            "7: seven",
        },
        text = "Review this.",
    }
    for key, value in pairs(overrides or {}) do
        annotation[key] = value
    end
    return annotation
end

function M.github_origin(overrides)
    local origin = {
        provider = "github",
        repository = "owner/repo",
        hostname = "github.com",
        pull_number = 7,
        comment_id = "123456789012345678",
        url = "https://github.com/owner/repo/pull/7#discussion_r123",
        author = "reviewer",
        anchor = "exact",
        original_path = "lua/example.lua",
        original_line = 4,
        original_side = "RIGHT",
        thread_id = "PRRT_thread",
        resolved = false,
        outdated = false,
        is_reply = false,
        reply_count = 2,
    }
    for key, value in pairs(overrides or {}) do
        origin[key] = value
    end
    return origin
end

function M.finish()
    pcall(vim.cmd, "silent! %bwipeout!")
    for _, path in ipairs(M.temporary_paths) do
        vim.fn.delete(path, "rf")
    end

    if #M.failures > 0 then
        local lines = { string.format("%d test(s) failed:", #M.failures) }
        for _, failure in ipairs(M.failures) do
            lines[#lines + 1] = "- " .. failure.name
        end
        error(table.concat(lines, "\n"))
    end
    print("all vrv tests passed")
end

return M
