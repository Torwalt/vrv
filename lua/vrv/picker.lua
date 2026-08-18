local M = {}

local function github_label(annotation)
    local origin = annotation.origin
    if not origin or origin.provider ~= "github" then
        return ""
    end
    local marker = "[GH]"
    if origin.resolved then
        marker = "[GH✓]"
    elseif origin.outdated or origin.anchor == "approximate" then
        marker = "[GH~]"
    end
    if origin.is_reply then
        marker = marker .. " reply"
    end
    local suffix = not origin.is_reply
            and origin.reply_count
            and origin.reply_count > 0
            and string.format(" (+%d replies)", origin.reply_count)
        or ""
    return string.format("%s @%s%s ", marker, origin.author, suffix)
end

local function display(annotation)
    local range = annotation.start_line == annotation.end_line and tostring(annotation.start_line)
        or string.format("%d–%d", annotation.start_line, annotation.end_line)
    local text = annotation.text:gsub("\n", " ")
    return string.format("%s%s:%s — %s", github_label(annotation), annotation.file, range, text)
end

local function ordinal(annotation)
    return table.concat(
        { github_label(annotation), annotation.file, annotation.text, table.concat(annotation.snippet, "\n") },
        " "
    )
end

local function without_id(annotations, id)
    return vim.tbl_filter(function(annotation)
        return annotation.id ~= id
    end, annotations)
end

function M.make_entry(root, annotation)
    return {
        value = annotation,
        display = display(annotation),
        ordinal = ordinal(annotation),
        filename = root .. "/" .. annotation.file,
        lnum = annotation.start_line,
        col = 1,
    }
end

function M.open(annotations, opts)
    opts = opts or {}
    if #annotations == 0 then
        vim.notify("vrv: no annotations on the current branch", vim.log.levels.INFO)
        return
    end

    local pickers = require("telescope.pickers")
    local finders = require("telescope.finders")
    local conf = require("telescope.config").values
    local actions = require("telescope.actions")
    local action_state = require("telescope.actions.state")
    local current = vim.list_slice(annotations)

    local function finder()
        return finders.new_table({
            results = current,
            entry_maker = function(annotation)
                return M.make_entry(opts.root, annotation)
            end,
        })
    end

    pickers
        .new({}, {
            prompt_title = opts.title or "vrv annotations",
            finder = finder(),
            sorter = conf.generic_sorter({}),
            previewer = conf.grep_previewer({}),
            attach_mappings = function(prompt_bufnr, map)
                actions.select_default:replace(function()
                    local entry = action_state.get_selected_entry()
                    actions.close(prompt_bufnr)
                    if entry and opts.on_select then
                        opts.on_select(entry.value)
                    end
                end)

                local function delete_selected()
                    local entry = action_state.get_selected_entry()
                    if not entry or not opts.on_delete or not opts.on_delete(entry.value) then
                        return
                    end
                    current = without_id(current, entry.value.id)
                    local picker = action_state.get_current_picker(prompt_bufnr)
                    picker:refresh(finder(), { reset_prompt = false })
                end

                local function edit_selected()
                    local entry = action_state.get_selected_entry()
                    if not entry or not opts.on_edit then
                        return
                    end
                    actions.close(prompt_bufnr)
                    opts.on_edit(entry.value)
                end

                map("i", "<C-d>", delete_selected)
                map("n", "<C-d>", delete_selected)
                map("i", "<C-e>", edit_selected)
                map("n", "<C-e>", edit_selected)
                return true
            end,
        })
        :find()
end

M._display = display
M._ordinal = ordinal
M._without_id = without_id
M._github_label = github_label

return M
