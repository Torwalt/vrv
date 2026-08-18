local model = require("vrv.model")
local util = require("vrv.util")

local M = {}

local state = {
    root = nil,
    annotations = {},
    writable = true,
}

local function store_path(root)
    return util.path_join(root, ".cache", "vrv", "annotations.json")
end

function M.path(root)
    return store_path(root or state.root)
end

function M.root()
    return state.root
end

function M.is_writable()
    return state.writable
end

function M.load(root)
    root = vim.fs.normalize(root)
    local path = store_path(root)
    local content = util.read_file(path)
    if not content then
        state = { root = root, annotations = {}, writable = true }
        return true
    end

    local annotations, err = model.decode(content)
    if not annotations then
        state = { root = root, annotations = {}, writable = false }
        return false, err
    end

    state = { root = root, annotations = annotations, writable = true }
    return true
end

function M.ensure(root)
    root = vim.fs.normalize(root)
    if state.root == root then
        return state.writable
    end
    return M.load(root)
end

function M.save()
    if not state.root then
        return false, "store has no project root"
    end
    if not state.writable then
        return false, "store is read-only because loading failed"
    end

    local signs_ok, signs = pcall(require, "vrv.signs")
    if signs_ok then
        signs.sync_positions()
    end

    local encoded, encode_err = model.encode(state.annotations)
    if not encoded then
        return false, encode_err
    end

    local ok, write_err = util.write_file_atomic(store_path(state.root), encoded)
    if not ok then
        return false, write_err
    end

    return true
end

function M.all()
    return state.annotations
end

function M.for_branch(branch)
    local annotations = {}
    for _, annotation in ipairs(state.annotations) do
        if annotation.branch == branch then
            annotations[#annotations + 1] = annotation
        end
    end
    table.sort(annotations, function(left, right)
        if left.file ~= right.file then
            return left.file < right.file
        end
        if left.start_line ~= right.start_line then
            return left.start_line < right.start_line
        end
        return left.id < right.id
    end)
    return annotations
end

function M.get(id)
    for _, annotation in ipairs(state.annotations) do
        if annotation.id == id then
            return annotation
        end
    end
    return nil
end

function M.at(branch, file, line)
    local matches = {}
    for _, annotation in ipairs(M.for_branch(branch)) do
        if annotation.file == file and line >= annotation.start_line and line <= annotation.end_line then
            matches[#matches + 1] = annotation
        end
    end
    return matches
end

function M.add(fields)
    local annotation, model_err = model.new(fields)
    if not annotation then
        return nil, model_err
    end
    if M.get(annotation.id) then
        return nil, "duplicate annotation id: " .. annotation.id
    end

    state.annotations[#state.annotations + 1] = annotation
    local ok, err = M.save()
    if not ok then
        table.remove(state.annotations)
        return nil, err
    end
    return annotation
end

function M.add_many(records)
    local known = {}
    for _, annotation in ipairs(state.annotations) do
        known[annotation.id] = true
    end

    local added = {}
    local skipped = {}
    for _, fields in ipairs(records) do
        local annotation, model_err = model.new(fields)
        if not annotation then
            return nil, model_err
        end
        if known[annotation.id] then
            skipped[#skipped + 1] = annotation
        else
            known[annotation.id] = true
            added[#added + 1] = annotation
        end
    end

    if #added == 0 then
        return { added = added, skipped = skipped }
    end

    local previous_count = #state.annotations
    vim.list_extend(state.annotations, added)
    local ok, err = M.save()
    if not ok then
        for index = #state.annotations, previous_count + 1, -1 do
            table.remove(state.annotations, index)
        end
        return nil, err
    end
    return { added = added, skipped = skipped }
end

function M.update(id, text)
    local annotation = M.get(id)
    if not annotation then
        return false, "annotation not found: " .. tostring(id)
    end

    text = vim.trim(text or "")
    if text == "" then
        return false, "annotation text must be non-empty"
    end

    local previous = annotation.text
    annotation.text = text
    local ok, err = M.save()
    if not ok then
        annotation.text = previous
        return false, err
    end
    return true, annotation
end

function M.delete(id)
    for index, annotation in ipairs(state.annotations) do
        if annotation.id == id then
            table.remove(state.annotations, index)
            local ok, err = M.save()
            if not ok then
                table.insert(state.annotations, index, annotation)
                return false, err
            end
            return true, annotation
        end
    end
    return false, "annotation not found: " .. tostring(id)
end

function M.delete_branch(branch)
    local previous = state.annotations
    local kept = {}
    local deleted = {}

    for _, annotation in ipairs(previous) do
        if annotation.branch == branch then
            deleted[#deleted + 1] = annotation
        else
            kept[#kept + 1] = annotation
        end
    end

    if #deleted == 0 then
        return true, deleted
    end

    state.annotations = kept
    local ok, err = M.save()
    if not ok then
        state.annotations = previous
        return false, err
    end
    return true, deleted
end

function M.mark_github_thread_resolved(thread_id)
    local changed = {}
    for _, annotation in ipairs(state.annotations) do
        if
            annotation.origin
            and annotation.origin.provider == "github"
            and annotation.origin.thread_id == thread_id
            and annotation.origin.resolved ~= true
        then
            changed[#changed + 1] = { annotation = annotation, previous = annotation.origin.resolved }
            annotation.origin.resolved = true
        end
    end
    if #changed == 0 then
        return false, "no unresolved imported annotations for this GitHub thread"
    end

    local ok, err = M.save()
    if not ok then
        for _, item in ipairs(changed) do
            item.annotation.origin.resolved = item.previous
        end
        return false, err
    end
    return true, vim.tbl_map(function(item)
        return item.annotation
    end, changed)
end

function M._reset()
    state = { root = nil, annotations = {}, writable = true }
end

return M
