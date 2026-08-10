local M = {}

function M.read_file(path)
    local file, err = io.open(path, "rb")
    if not file then
        return nil, err
    end

    local content = file:read("*a")
    file:close()
    return content
end

function M.ensure_parent(path)
    local parent = vim.fn.fnamemodify(path, ":h")
    if vim.fn.isdirectory(parent) == 1 then
        return true
    end

    if vim.fn.mkdir(parent, "p") == 1 or vim.fn.isdirectory(parent) == 1 then
        return true
    end

    return false, "could not create directory: " .. parent
end

function M.write_file_atomic(path, content)
    local ok, err = M.ensure_parent(path)
    if not ok then
        return false, err
    end

    local suffix = tostring(vim.fn.getpid()) .. "." .. tostring(vim.uv.hrtime())
    local temporary = path .. ".tmp." .. suffix
    local file, open_err = io.open(temporary, "wb")
    if not file then
        return false, open_err
    end

    local wrote, write_err = file:write(content)
    local closed, close_err = file:close()
    if not wrote or not closed then
        os.remove(temporary)
        return false, write_err or close_err or "could not write temporary file"
    end

    local renamed, rename_err = vim.uv.fs_rename(temporary, path)
    if not renamed then
        os.remove(temporary)
        return false, rename_err or "could not replace store"
    end

    return true
end

function M.path_join(...)
    return vim.fs.normalize(table.concat({ ... }, "/"))
end

function M.trim_text(lines)
    return vim.trim(table.concat(lines, "\n"))
end

return M
