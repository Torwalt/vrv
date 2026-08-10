local M = {}

local configured = false
local active_root = nil
local active_branch = nil

local function notify_error(message)
    vim.notify("vrv: " .. tostring(message), vim.log.levels.ERROR)
end

local function is_editor_buffer(bufnr)
    return vim.api.nvim_buf_get_name(bufnr):match("^vrv://annotation/") ~= nil
end

local function action_context(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local git = require("vrv.git")
    local signs = require("vrv.signs")
    local store = require("vrv.store")
    local root = git.root(vim.api.nvim_buf_get_name(bufnr))
    local branch, branch_err = git.branch(root)
    if not branch then
        notify_error(branch_err or "detached HEAD is not supported")
        return nil
    end

    local context_changed = active_root ~= root or active_branch ~= branch
    if store.root() ~= root then
        signs.clear_all()
        local loaded, load_err = store.load(root)
        if not loaded then
            notify_error("could not load annotation store: " .. tostring(load_err))
            return nil
        end
    elseif not store.is_writable() then
        notify_error("annotation store is unavailable; fix it and run :Vrv reload")
        return nil
    end

    if context_changed then
        signs.render_all(root, branch)
    end
    active_root = root
    active_branch = branch
    return { root = root, branch = branch, bufnr = bufnr }
end

local function current_file(context)
    local file, err = require("vrv.git").relative_file(context.root, context.bufnr)
    if not file then
        notify_error(err)
    end
    return file
end

local function open_picker(annotations, title, on_select, context)
    require("vrv.picker").open(annotations, {
        root = context.root,
        title = title,
        on_select = on_select,
        on_delete = function(annotation)
            return M.delete_by_id(annotation.id)
        end,
        on_edit = function(annotation)
            require("vrv.editor").open_edit(annotation, context.root, vim.api.nvim_get_current_win())
        end,
    })
end

function M.add(start_line, end_line)
    local context = action_context()
    if not context then
        return
    end
    local file = current_file(context)
    if not file then
        return
    end

    start_line = start_line or vim.api.nvim_win_get_cursor(0)[1]
    end_line = end_line or start_line
    if end_line < start_line then
        start_line, end_line = end_line, start_line
    end
    local captured = require("vrv.context").capture(context.bufnr, start_line, end_line, 3)
    require("vrv.editor").open_new({
        root = context.root,
        branch = context.branch,
        file = file,
        start_line = start_line,
        end_line = end_line,
        snippet_start = captured.snippet_start,
        snippet = captured.snippet,
    }, context.bufnr, vim.api.nvim_get_current_win())
end

local function annotations_at_cursor(context)
    require("vrv.signs").sync_positions()
    local file = current_file(context)
    if not file then
        return {}
    end
    return require("vrv.store").at(context.branch, file, vim.api.nvim_win_get_cursor(0)[1])
end

function M.edit()
    local context = action_context()
    if not context then
        return
    end
    local annotations = annotations_at_cursor(context)
    if #annotations == 0 then
        notify_error("no annotation at cursor")
    elseif #annotations == 1 then
        require("vrv.editor").open_edit(annotations[1], context.root, vim.api.nvim_get_current_win())
    else
        open_picker(annotations, "Edit annotation", function(annotation)
            require("vrv.editor").open_edit(annotation, context.root, vim.api.nvim_get_current_win())
        end, context)
    end
end

function M.delete_by_id(id)
    local annotation = require("vrv.store").get(id)
    if not annotation then
        notify_error("annotation not found")
        return false
    end
    local ok, deleted = require("vrv.store").delete(id)
    if not ok then
        notify_error(deleted)
        return false
    end
    require("vrv.signs").remove(deleted)
    vim.notify("vrv: annotation deleted", vim.log.levels.INFO)
    return true
end

function M.delete()
    local context = action_context()
    if not context then
        return
    end
    local annotations = annotations_at_cursor(context)
    if #annotations == 0 then
        notify_error("no annotation at cursor")
    elseif #annotations == 1 then
        M.delete_by_id(annotations[1].id)
    else
        open_picker(annotations, "Delete annotation", function(annotation)
            M.delete_by_id(annotation.id)
        end, context)
    end
end

function M.clear()
    local context = action_context()
    if not context then
        return
    end

    local ok, deleted = require("vrv.store").delete_branch(context.branch)
    if not ok then
        notify_error(deleted)
        return
    end
    if #deleted == 0 then
        vim.notify("vrv: no annotations on the current branch", vim.log.levels.INFO)
        return
    end

    for _, annotation in ipairs(deleted) do
        require("vrv.signs").remove(annotation)
    end
    vim.notify("vrv: cleared all annotations on " .. context.branch, vim.log.levels.INFO)
end

function M.export()
    local context = action_context()
    if not context then
        return
    end
    local store = require("vrv.store")
    local ok, save_err = store.save()
    if not ok then
        notify_error(save_err)
        return
    end
    local exported, result = require("vrv.export").to_clipboard(store.for_branch(context.branch))
    if not exported then
        vim.notify("vrv: " .. result, vim.log.levels.INFO)
        return
    end
    vim.notify("vrv: annotations copied to clipboard", vim.log.levels.INFO)
end

function M.browse()
    local context = action_context()
    if not context then
        return
    end
    local store = require("vrv.store")
    open_picker(store.for_branch(context.branch), "vrv — " .. context.branch, function(annotation)
        local ok, err = require("vrv.navigation").jump(context.root, annotation)
        if not ok then
            notify_error(err)
        end
    end, context)
end

local function navigate(direction)
    local context = action_context()
    if not context then
        return
    end
    require("vrv.signs").sync_positions()
    local annotations = require("vrv.store").for_branch(context.branch)
    local navigation = require("vrv.navigation")
    local annotation = direction == "next" and navigation.next(context.root, annotations)
        or navigation.previous(context.root, annotations)
    if not annotation then
        vim.notify("vrv: no annotations on the current branch", vim.log.levels.INFO)
        return
    end
    local ok, err = navigation.jump(context.root, annotation)
    if not ok then
        notify_error(err)
    end
end

function M.next()
    navigate("next")
end

function M.previous()
    navigate("previous")
end

function M.reload()
    local git = require("vrv.git")
    local root = git.root(vim.api.nvim_buf_get_name(0))
    local branch, branch_err = git.branch(root)
    if not branch then
        notify_error(branch_err or "detached HEAD is not supported")
        return
    end
    local loaded, err = require("vrv.store").load(root)
    if not loaded then
        notify_error("could not load annotation store: " .. tostring(err))
        return
    end
    active_root = root
    active_branch = branch
    require("vrv.signs").render_all(root, branch)
    vim.notify("vrv: annotations reloaded", vim.log.levels.INFO)
end

function M.refresh()
    local bufnr = vim.api.nvim_get_current_buf()
    if is_editor_buffer(bufnr) then
        return
    end
    local git = require("vrv.git")
    local root = git.root(vim.api.nvim_buf_get_name(bufnr))
    local branch = git.branch(root)
    if not branch then
        require("vrv.signs").clear_all()
        active_root = root
        active_branch = nil
        return
    end

    local store = require("vrv.store")
    if active_root ~= root or store.root() ~= root then
        require("vrv.signs").clear_all()
        local loaded, err = store.load(root)
        if not loaded then
            notify_error("could not load annotation store: " .. tostring(err))
            return
        end
    end

    if active_root ~= root or active_branch ~= branch then
        require("vrv.signs").render_all(root, branch)
    else
        require("vrv.signs").render_buffer(bufnr, root, branch)
    end
    active_root = root
    active_branch = branch
end

local subcommands = {
    add = function(opts)
        local start_line = opts.range > 0 and opts.line1 or nil
        local end_line = opts.range > 0 and opts.line2 or nil
        M.add(start_line, end_line)
    end,
    delete = M.delete,
    edit = M.edit,
    browse = M.browse,
    clear = M.clear,
    export = M.export,
    next = M.next,
    prev = M.previous,
    reload = M.reload,
}

local function register_interface()
    vim.api.nvim_create_user_command("Vrv", function(opts)
        local action = subcommands[opts.fargs[1]]
        if not action then
            notify_error("usage: :Vrv <add|delete|edit|browse|clear|export|next|prev|reload>")
            return
        end
        action(opts)
    end, {
        nargs = 1,
        range = true,
        complete = function(lead)
            return vim.tbl_filter(function(name)
                return name:find(lead, 1, true) == 1
            end, vim.tbl_keys(subcommands))
        end,
        force = true,
    })

    vim.keymap.set("n", "<leader>ra", M.add, { desc = "Add review annotation" })
    vim.keymap.set("x", "<leader>ra", function()
        local start_line, end_line = require("vrv.context").visual_range()
        M.add(start_line, end_line)
    end, { desc = "Add review annotation" })
    vim.keymap.set("n", "<leader>rd", M.delete, { desc = "Delete review annotation" })
    vim.keymap.set("n", "<leader>re", M.edit, { desc = "Edit review annotation" })
    vim.keymap.set("n", "<leader>rf", M.browse, { desc = "Find review annotations" })
    vim.keymap.set("n", "<leader>rC", M.clear, { desc = "Clear current-branch review annotations" })
    vim.keymap.set("n", "<leader>rE", M.export, { desc = "Export review annotations" })
    vim.keymap.set("n", "]r", M.next, { desc = "Next review annotation" })
    vim.keymap.set("n", "[r", M.previous, { desc = "Previous review annotation" })
end

function M.setup()
    if configured then
        return M
    end
    configured = true
    require("vrv.signs").setup()
    register_interface()

    local group = vim.api.nvim_create_augroup("VrvLifecycle", { clear = true })
    vim.api.nvim_create_autocmd({ "BufEnter", "FocusGained", "DirChanged" }, {
        group = group,
        callback = function()
            vim.schedule(M.refresh)
        end,
    })
    vim.schedule(M.refresh)
    return M
end

function M._reset()
    configured = false
    active_root = nil
    active_branch = nil
end

return M
