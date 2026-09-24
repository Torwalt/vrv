local M = {}

local function new_hunk(header)
    local old_start, old_count, new_start, new_count = header:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
    if not old_start then
        return nil
    end
    return {
        header = header,
        old_start = tonumber(old_start),
        old_count = tonumber(old_count ~= "" and old_count or 1),
        new_start = tonumber(new_start),
        new_count = tonumber(new_count ~= "" and new_count or 1),
        lines = {},
    }
end

local function add_hunk_line(hunk, line, counters)
    local prefix = line:sub(1, 1)
    if prefix == "\\" then
        return
    end
    local record = { text = line:sub(2) }
    if prefix == " " then
        record.kind = "context"
        record.old_line = counters.old_line
        record.new_line = counters.new_line
        counters.old_line = counters.old_line + 1
        counters.new_line = counters.new_line + 1
    elseif prefix == "-" then
        record.kind = "delete"
        record.old_line = counters.old_line
        counters.old_line = counters.old_line + 1
    elseif prefix == "+" then
        record.kind = "add"
        record.new_line = counters.new_line
        counters.new_line = counters.new_line + 1
    else
        return
    end
    hunk.lines[#hunk.lines + 1] = record
end

local function parse_hunks(content)
    local hunks = {}
    local headers = 0
    local hunk
    local counters
    for _, line in ipairs(vim.split(content or "", "\n", { plain = true })) do
        if line:match("^@@ ") then
            headers = headers + 1
            hunk = new_hunk(line)
            counters = hunk and { old_line = hunk.old_start, new_line = hunk.new_start } or nil
            if hunk then
                hunks[#hunks + 1] = hunk
            end
        elseif hunk and counters then
            add_hunk_line(hunk, line, counters)
        end
    end
    return hunks, headers
end

function M.parse_hunk(content)
    local hunks, headers = parse_hunks(content)
    if #hunks == 0 then
        return nil, headers > 0 and "invalid diff hunk header" or "diff hunk is missing a header"
    end
    return hunks[#hunks]
end

-- Builds the same lookup shape as a parsed unified diff from the entries of
-- `repos/{repo}/pulls/{number}/files`. The whole-pull-request diff endpoint
-- refuses anything over 20000 lines, the per-file listing never does.
function M.from_files(files)
    local result = { files = {}, old_paths = {} }
    for _, file in ipairs(files or {}) do
        local path = type(file.filename) == "string" and file.filename ~= "" and file.filename or nil
        if path and file.status ~= "removed" then
            local patch = type(file.patch) == "string" and file.patch or nil
            local entry = {
                path = path,
                hunks = patch and parse_hunks(patch) or {},
                -- GitHub drops `patch` for binary files and for diffs it
                -- considers too large; an unchanged rename simply has none.
                patch_omitted = patch == nil and (tonumber(file.changes) or 0) > 0,
            }
            local old_path = type(file.previous_filename) == "string" and file.previous_filename or nil
            if old_path and old_path ~= "" and old_path ~= path then
                entry.old_path = old_path
                result.old_paths[old_path] = path
            end
            result.files[path] = entry
        end
    end
    return result
end

function M.file(parsed, path)
    local direct = parsed.files[path]
    if direct then
        return direct, path
    end
    local renamed = parsed.old_paths[path]
    if renamed then
        return parsed.files[renamed], renamed
    end
    return nil
end

local function right_record(hunk, line)
    for _, record in ipairs(hunk.lines) do
        if record.new_line == line then
            return record
        end
    end
end

function M.right_range(parsed, path, start_line, end_line)
    local file, resolved_path = M.file(parsed, path)
    if not file then
        return nil, "file is not present in the pull request diff: " .. path
    end
    for _, hunk in ipairs(file.hunks) do
        if right_record(hunk, start_line) and right_record(hunk, end_line) then
            return { file = file, path = resolved_path, hunk = hunk }
        end
    end
    if file.patch_omitted then
        return nil, string.format("GitHub withheld the diff for %s; it is binary or too large to review", resolved_path)
    end
    return nil, string.format("%s:%d-%d is not a commentable range in one diff hunk", path, start_line, end_line)
end

function M.nearest_right_for_left(hunk, old_line)
    local target_index
    for index, record in ipairs(hunk.lines) do
        if record.old_line == old_line and record.kind == "delete" then
            target_index = index
            break
        end
    end
    if not target_index then
        return nil, "deleted line is not present in the comment diff hunk"
    end

    for distance = 1, #hunk.lines do
        local following = hunk.lines[target_index + distance]
        if following and following.new_line then
            return following
        end
        local preceding = hunk.lines[target_index - distance]
        if preceding and preceding.new_line then
            return preceding
        end
    end
    return nil, "deleted line has no surviving anchor in its diff hunk"
end

return M
