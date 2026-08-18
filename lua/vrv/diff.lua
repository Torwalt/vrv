local M = {}

local function unquote_path(path)
    if path:sub(1, 1) == '"' and path:sub(-1) == '"' then
        path = path:sub(2, -2)
        path = path:gsub("\\([0-7][0-7][0-7])", function(octal)
            return string.char(tonumber(octal, 8))
        end)
        local escapes = { a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", v = "\v" }
        path = path:gsub("\\(.)", function(escaped)
            return escapes[escaped] or escaped
        end)
    end
    return path
end

local function normalize_path(path, prefix)
    path = unquote_path(path)
    if path == "/dev/null" then
        return nil
    end
    if path:sub(1, #prefix) == prefix then
        return path:sub(#prefix + 1)
    end
    return path
end

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

function M.parse_hunk(content)
    local hunk
    local counters
    for _, line in ipairs(vim.split(content or "", "\n", { plain = true })) do
        if line:match("^@@ ") then
            hunk = new_hunk(line)
            if not hunk then
                return nil, "invalid diff hunk header"
            end
            counters = { old_line = hunk.old_start, new_line = hunk.new_start }
        elseif hunk then
            add_hunk_line(hunk, line, counters)
        end
    end
    if not hunk then
        return nil, "diff hunk is missing a header"
    end
    return hunk
end

function M.parse(content)
    local result = { files = {}, old_paths = {} }
    local current
    local hunk
    local counters

    local function register_file()
        if not current or not current.path then
            return
        end
        result.files[current.path] = current
        if current.old_path then
            result.old_paths[current.old_path] = current.path
        end
    end

    for _, line in ipairs(vim.split(content or "", "\n", { plain = true })) do
        if line:match("^diff %-%-git ") then
            register_file()
            current = { hunks = {} }
            hunk = nil
            counters = nil
        elseif current and line:match("^rename from ") then
            current.old_path = unquote_path(line:sub(13))
        elseif current and line:match("^rename to ") then
            current.path = unquote_path(line:sub(11))
        elseif current and line:match("^%-%-%- ") then
            current.old_path = normalize_path(line:sub(5), "a/")
        elseif current and line:match("^%+%+%+ ") then
            current.path = normalize_path(line:sub(5), "b/")
        elseif current and line:match("^@@ ") then
            hunk = new_hunk(line)
            if hunk then
                current.hunks[#current.hunks + 1] = hunk
                counters = { old_line = hunk.old_start, new_line = hunk.new_start }
            end
        elseif hunk and counters then
            add_hunk_line(hunk, line, counters)
        end
    end
    register_file()
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
