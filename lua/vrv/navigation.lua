local util = require("vrv.util")

local M = {}

function M.jump(root, annotation)
    local path = util.path_join(root, annotation.file)
    if vim.fn.filereadable(path) == 0 then
        return false, "file does not exist: " .. annotation.file
    end

    local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(path))
    if not ok then
        return false, tostring(err)
    end
    if annotation.start_line > vim.api.nvim_buf_line_count(0) then
        return false, string.format("line %d does not exist in %s", annotation.start_line, annotation.file)
    end
    vim.api.nvim_win_set_cursor(0, { annotation.start_line, 0 })
    return true
end

local function current_key(root)
    local absolute = vim.api.nvim_buf_get_name(0)
    local relative = vim.fs.relpath(root, absolute) or ""
    local line = vim.api.nvim_win_get_cursor(0)[1]
    return relative, line
end

function M.next(root, annotations)
    if #annotations == 0 then
        return nil
    end
    local file, line = current_key(root)
    for _, annotation in ipairs(annotations) do
        if annotation.file > file or (annotation.file == file and annotation.start_line > line) then
            return annotation
        end
    end
    return annotations[1]
end

function M.previous(root, annotations)
    if #annotations == 0 then
        return nil
    end
    local file, line = current_key(root)
    for index = #annotations, 1, -1 do
        local annotation = annotations[index]
        if annotation.file < file or (annotation.file == file and annotation.start_line < line) then
            return annotation
        end
    end
    return annotations[#annotations]
end

return M
