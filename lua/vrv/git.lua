local M = {}

local function run(args, cwd, raw)
    if vim.fn.executable("git") == 0 then
        return nil, "git executable not found"
    end
    local command = { "git" }
    if cwd and cwd ~= "" then
        vim.list_extend(command, { "-C", cwd })
    end
    vim.list_extend(command, args)

    local result = vim.system(command, { text = true }):wait()
    if result.code ~= 0 then
        return nil, vim.trim(result.stderr or "git command failed")
    end
    local output = result.stdout or ""
    return raw and output or vim.trim(output)
end

function M.root(path)
    local directory = path
    if not directory or directory == "" then
        local buffer_name = vim.api.nvim_buf_get_name(0)
        directory = buffer_name ~= "" and vim.fn.fnamemodify(buffer_name, ":p:h") or vim.fn.getcwd()
    elseif vim.fn.isdirectory(directory) == 0 then
        directory = vim.fn.fnamemodify(directory, ":p:h")
    end

    local root = run({ "rev-parse", "--show-toplevel" }, directory)
    return root and vim.fs.normalize(root) or vim.fs.normalize(vim.fn.getcwd())
end

-- Detached HEAD: the local branch named by the last checkout, as `git status` reports it.
local function detached_branch(root)
    local message = run({
        "log",
        "--walk-reflogs",
        "--max-count=1",
        "--grep-reflog=^checkout: moving from ",
        "--format=%gs",
        "HEAD",
    }, root)
    local name = message and message:match(" to (%S+)$")
    if not name or not run({ "show-ref", "--verify", "--quiet", "refs/heads/" .. name }, root) then
        return nil
    end
    return name
end

function M.branch(root)
    local branch, err = run({ "symbolic-ref", "--quiet", "--short", "HEAD" }, root)
    if branch and branch ~= "" then
        return branch
    end
    if err and err ~= "" then
        return nil, err
    end
    branch = detached_branch(root)
    if not branch then
        return nil, "detached HEAD was not checked out from a local branch"
    end
    return branch
end

function M.head(root)
    return run({ "rev-parse", "HEAD" }, root)
end

function M.file_at(root, revision, path)
    local content, err = run({ "show", revision .. ":" .. path }, root, true)
    if not content then
        return nil, err
    end
    local lines = vim.split(content, "\n", { plain = true })
    if lines[#lines] == "" then
        table.remove(lines)
    end
    return lines
end

function M.relative_file(root, bufnr)
    bufnr = bufnr or 0
    local absolute = vim.api.nvim_buf_get_name(bufnr)
    if absolute == "" then
        return nil, "current buffer has no file"
    end

    absolute = vim.fs.normalize(absolute)
    root = vim.fs.normalize(root)
    local relative = vim.fs.relpath(root, absolute)
    if not relative or relative == "" or relative:match("^%.%./") or relative == ".." then
        return nil, "current file is outside the project root"
    end
    return relative
end

return M
