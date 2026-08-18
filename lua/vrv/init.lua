local M = {}

local configured = false
local active_root = nil
local active_branch = nil
local github_busy = false

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

local function export_markdown()
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

local function github_error(errors)
    if type(errors) ~= "table" then
        return tostring(errors)
    end
    local displayed = {}
    for index = 1, math.min(#errors, 5) do
        displayed[#displayed + 1] = tostring(errors[index])
    end
    if #errors > #displayed then
        displayed[#displayed + 1] = string.format("and %d more", #errors - #displayed)
    end
    return table.concat(displayed, "\n")
end

local function start_github()
    if github_busy then
        notify_error("a GitHub operation is already running")
        return false
    end
    github_busy = true
    return true
end

local function finish_github()
    github_busy = false
end

local function resolve_pull_request(context, selector, callback)
    require("vrv.github").resolve(context.root, selector, function(pull_request, err)
        if not pull_request then
            finish_github()
            notify_error(err)
            return
        end
        local head, head_err = require("vrv.git").head(context.root)
        if not head then
            finish_github()
            notify_error(head_err)
            return
        end
        if head ~= pull_request.head_oid then
            finish_github()
            notify_error(
                string.format("local HEAD %s does not match pull request head %s", head, pull_request.head_oid)
            )
            return
        end
        callback(pull_request)
    end)
end

function M.export_github(selector)
    local context = action_context()
    if not context or not start_github() then
        return
    end
    local store = require("vrv.store")
    local ok, save_err = store.save()
    if not ok then
        finish_github()
        notify_error(save_err)
        return
    end
    local annotations = vim.deepcopy(store.for_branch(context.branch))

    vim.notify("vrv: resolving GitHub pull request", vim.log.levels.INFO)
    resolve_pull_request(context, selector, function(pull_request)
        require("vrv.github").fetch_diff(context.root, pull_request, function(raw_diff, diff_err)
            if not raw_diff then
                finish_github()
                notify_error(diff_err)
                return
            end
            local encoded, errors =
                require("vrv.github_export").encode(annotations, pull_request, require("vrv.diff").parse(raw_diff))
            if not encoded then
                finish_github()
                notify_error(github_error(errors))
                return
            end
            local copied, copy_err = pcall(vim.fn.setreg, "+", encoded .. "\n")
            finish_github()
            if not copied then
                notify_error(copy_err)
                return
            end
            vim.notify(
                string.format(
                    "vrv: GitHub review JSON copied; POST with gh api -X POST repos/%s/pulls/%d/reviews --input -",
                    pull_request.repository,
                    pull_request.number
                ),
                vim.log.levels.INFO
            )
        end)
    end)
end

function M.export(opts)
    local format = opts and opts.fargs and opts.fargs[2] or "markdown"
    if (not format or format == "" or format == "markdown") and not (opts and opts.fargs[3]) then
        export_markdown()
    elseif format == "github" and not opts.fargs[4] then
        M.export_github(opts.fargs[3])
    else
        notify_error("usage: :Vrv export [markdown|github [PR]]")
    end
end

function M.import_github(selector)
    local context = action_context()
    if not context or not start_github() then
        return
    end
    vim.notify("vrv: resolving GitHub pull request", vim.log.levels.INFO)
    resolve_pull_request(context, selector, function(pull_request)
        local pending = 2
        local raw_diff
        local comments
        local failed = false

        local function fail(err)
            if failed then
                return
            end
            failed = true
            finish_github()
            notify_error(err)
        end

        local function complete_one()
            pending = pending - 1
            if pending > 0 or failed then
                return
            end
            local parsed = require("vrv.diff").parse(raw_diff)
            local current_branch = require("vrv.git").branch(context.root)
            if current_branch ~= context.branch or require("vrv.store").root() ~= context.root then
                fail("project or branch changed while the GitHub import was running; run the import again")
                return
            end
            local report = require("vrv.github_import").transform(comments, {
                repository = pull_request.repository,
                pull_number = pull_request.number,
                branch = context.branch,
                diff = parsed,
                read_file = function(path)
                    return require("vrv.git").file_at(context.root, pull_request.head_oid, path)
                end,
            })
            local result, store_err = require("vrv.store").add_many(report.records)
            if not result then
                fail(store_err)
                return
            end
            finish_github()
            require("vrv.signs").render_all(context.root, context.branch)
            local added_exact = 0
            local added_approximate = 0
            for _, annotation in ipairs(result.added) do
                if annotation.origin.anchor == "exact" then
                    added_exact = added_exact + 1
                else
                    added_approximate = added_approximate + 1
                end
            end
            local summary = string.format(
                "vrv: imported %d GitHub comments: %d exact, %d approximated, %d skipped, %d already present",
                #result.added,
                added_exact,
                added_approximate,
                #report.skipped,
                #result.skipped
            )
            if #report.skipped > 0 then
                local details = {}
                for index = 1, math.min(#report.skipped, 3) do
                    local skipped = report.skipped[index]
                    details[#details + 1] = string.format(
                        "%s%s: %s",
                        skipped.path or "unknown file",
                        skipped.id and " (#" .. skipped.id .. ")" or "",
                        skipped.reason
                    )
                end
                summary = summary .. "\nSkipped: " .. table.concat(details, "; ")
            end
            vim.notify(summary, #report.skipped > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
        end

        require("vrv.github").fetch_diff(context.root, pull_request, function(output, err)
            if not output then
                fail(err)
                return
            end
            raw_diff = output
            complete_one()
        end)
        require("vrv.github").fetch_comments(context.root, pull_request, function(output, err)
            if not output then
                fail(err)
                return
            end
            comments = output
            complete_one()
        end)
    end)
end

function M.import_review(opts)
    if not opts or opts.fargs[2] ~= "github" or opts.fargs[4] then
        notify_error("usage: :Vrv import github [PR]")
        return
    end
    M.import_github(opts.fargs[3])
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
    import = M.import_review,
    next = M.next,
    prev = M.previous,
    reload = M.reload,
}

local function register_interface()
    vim.api.nvim_create_user_command("Vrv", function(opts)
        local action = subcommands[opts.fargs[1]]
        if not action then
            notify_error("usage: :Vrv <add|delete|edit|browse|clear|export|import|next|prev|reload>")
            return
        end
        action(opts)
    end, {
        nargs = "+",
        range = true,
        complete = function(lead, command_line)
            local choices = vim.tbl_keys(subcommands)
            if command_line:match("^%s*Vrv%s+export%s+") then
                choices = { "markdown", "github" }
            elseif command_line:match("^%s*Vrv%s+import%s+") then
                choices = { "github" }
            end
            return vim.tbl_filter(function(name)
                return name:find(lead, 1, true) == 1
            end, choices)
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
    github_busy = false
end

return M
