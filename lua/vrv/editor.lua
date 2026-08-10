local store = require("vrv.store")
local util = require("vrv.util")

local M = {}

local sessions = {}
local editing = {}
local next_buffer = 0

local function focus_source(session)
    if session.source_win and vim.api.nvim_win_is_valid(session.source_win) then
        vim.api.nvim_set_current_win(session.source_win)
    end
end

local function fail(message)
    vim.notify("vrv: " .. message, vim.log.levels.ERROR)
    error(message)
end

local function write_session(bufnr)
    local session = sessions[bufnr]
    if not session then
        fail("annotation editor state is missing")
    end

    local text = util.trim_text(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    if text == "" then
        fail("annotation text must be non-empty")
    end
    if not store.ensure(session.root) then
        fail("annotation store is unavailable")
    end

    if session.id then
        local ok, err = store.update(session.id, text)
        if not ok then
            fail(tostring(err))
        end
        vim.notify("vrv: annotation updated", vim.log.levels.INFO)
    else
        local fields = vim.deepcopy(session.fields)
        fields.text = text
        local annotation, err = store.add(fields)
        if not annotation then
            fail(tostring(err))
        end
        session.id = annotation.id
        editing[annotation.id] = bufnr
        pcall(vim.api.nvim_buf_set_name, bufnr, "vrv://annotation/" .. annotation.id)
        if session.source_buf and vim.api.nvim_buf_is_valid(session.source_buf) then
            require("vrv.signs").place(annotation, session.source_buf)
        end
        vim.notify("vrv: annotation added", vim.log.levels.INFO)
    end

    vim.bo[bufnr].modified = false
end

local function open(session, initial_text)
    if session.id and editing[session.id] then
        local existing = editing[session.id]
        if vim.api.nvim_buf_is_valid(existing) then
            local winid = vim.fn.bufwinid(existing)
            if winid ~= -1 then
                vim.api.nvim_set_current_win(winid)
            else
                vim.cmd("botright sbuffer " .. existing)
            end
            vim.notify("vrv: this annotation is already being edited", vim.log.levels.WARN)
            return existing
        end
        editing[session.id] = nil
    end

    next_buffer = next_buffer + 1
    vim.cmd("botright new")
    local bufnr = vim.api.nvim_get_current_buf()
    local name = session.id or ("new-" .. next_buffer)
    vim.api.nvim_buf_set_name(bufnr, "vrv://annotation/" .. name)
    vim.bo[bufnr].buftype = "acwrite"
    vim.bo[bufnr].bufhidden = "wipe"
    vim.bo[bufnr].swapfile = false
    vim.bo[bufnr].filetype = "markdown"
    vim.bo[bufnr].modifiable = true

    local lines = initial_text and vim.split(initial_text, "\n", { plain = true }) or { "" }
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].modified = false

    sessions[bufnr] = session
    if session.id then
        editing[session.id] = bufnr
    end

    vim.api.nvim_create_autocmd("BufWriteCmd", {
        buffer = bufnr,
        callback = function()
            write_session(bufnr)
        end,
    })
    vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = bufnr,
        once = true,
        callback = function()
            local current = sessions[bufnr]
            if current and current.id then
                editing[current.id] = nil
            end
            sessions[bufnr] = nil
            vim.schedule(function()
                focus_source(session)
            end)
        end,
    })

    vim.cmd("startinsert")
    return bufnr
end

function M.open_new(fields, source_buf, source_win)
    local durable_fields = vim.deepcopy(fields)
    durable_fields.root = nil
    return open({
        fields = durable_fields,
        root = fields.root,
        source_buf = source_buf,
        source_win = source_win,
    })
end

function M.open_edit(annotation, root, source_win)
    return open({
        id = annotation.id,
        root = root,
        source_win = source_win,
    }, annotation.text)
end

function M._write(bufnr)
    return write_session(bufnr)
end

function M._reset()
    sessions = {}
    editing = {}
    next_buffer = 0
end

return M
