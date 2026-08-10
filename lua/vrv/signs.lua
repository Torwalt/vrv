local git = require("vrv.git")
local store = require("vrv.store")

local M = {}

M.namespace = vim.api.nvim_create_namespace("vrv_annotations")

function M.setup()
    vim.api.nvim_set_hl(0, "VrvAnnotation", { link = "DiagnosticInfo", default = true })
end

function M.remove(annotation)
    if annotation._bufnr and annotation._extmark_id and vim.api.nvim_buf_is_valid(annotation._bufnr) then
        pcall(vim.api.nvim_buf_del_extmark, annotation._bufnr, M.namespace, annotation._extmark_id)
    end
    annotation._bufnr = nil
    annotation._extmark_id = nil
end

function M.place(annotation, bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return false
    end

    M.remove(annotation)
    local line_count = vim.api.nvim_buf_line_count(bufnr)
    if annotation.start_line > line_count then
        return false
    end

    local ok, extmark = pcall(vim.api.nvim_buf_set_extmark, bufnr, M.namespace, annotation.start_line - 1, -1, {
        sign_text = "●",
        sign_hl_group = "VrvAnnotation",
        priority = 10,
    })
    if not ok then
        return false
    end

    annotation._bufnr = bufnr
    annotation._extmark_id = extmark
    return true
end

function M.clear_all()
    for _, annotation in ipairs(store.all()) do
        annotation._bufnr = nil
        annotation._extmark_id = nil
    end
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(bufnr) then
            pcall(vim.api.nvim_buf_clear_namespace, bufnr, M.namespace, 0, -1)
        end
    end
end

function M.render_buffer(bufnr, root, branch)
    if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
        return
    end

    local file = git.relative_file(root, bufnr)
    if not file then
        return
    end

    pcall(vim.api.nvim_buf_clear_namespace, bufnr, M.namespace, 0, -1)
    for _, annotation in ipairs(store.all()) do
        if annotation._bufnr == bufnr then
            annotation._bufnr = nil
            annotation._extmark_id = nil
        end
    end
    for _, annotation in ipairs(store.for_branch(branch)) do
        if annotation.file == file then
            M.place(annotation, bufnr)
        end
    end
end

function M.render_all(root, branch)
    M.clear_all()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        M.render_buffer(bufnr, root, branch)
    end
end

function M.sync_positions()
    local changed = false
    for _, annotation in ipairs(store.all()) do
        if annotation._bufnr and annotation._extmark_id and vim.api.nvim_buf_is_valid(annotation._bufnr) then
            local position =
                vim.api.nvim_buf_get_extmark_by_id(annotation._bufnr, M.namespace, annotation._extmark_id, {})
            if position and position[1] ~= nil then
                local new_start = position[1] + 1
                if new_start ~= annotation.start_line then
                    local drift = new_start - annotation.start_line
                    annotation.start_line = new_start
                    annotation.end_line = annotation.end_line + drift
                    changed = true
                end
            end
        end
    end
    return changed
end

return M
