local context = require("vrv.context")
local diff = require("vrv.diff")

local M = {}

local function value(item)
    if item == nil or item == vim.NIL then
        return nil
    end
    return item
end

local function first(left, right)
    return value(left) or value(right)
end

local function positive_integer(number)
    return type(number) == "number" and number >= 1 and number % 1 == 0
end

local function valid_identifier(identifier)
    return positive_integer(identifier) or type(identifier) == "string" and identifier ~= ""
end

local function copy_coordinates(comment, parent)
    local effective = vim.deepcopy(comment)
    for _, field in ipairs({
        "path",
        "line",
        "side",
        "start_line",
        "start_side",
        "original_line",
        "original_side",
        "diff_hunk",
        "subject_type",
    }) do
        effective[field] = first(effective[field], parent[field])
    end
    return effective
end

local function unique_line(lines, text)
    local match
    for line_number, line in ipairs(lines) do
        if line == text then
            if match then
                return nil
            end
            match = line_number
        end
    end
    return match
end

local function hunk_right_record(hunk, line)
    for _, record in ipairs(hunk.lines) do
        if record.new_line == line then
            return record
        end
    end
end

function M.transform(comments, opts)
    local by_id = {}
    for _, comment in ipairs(comments) do
        by_id[comment.id] = comment
    end

    local file_cache = {}
    local function load_file(path)
        if file_cache[path] then
            return file_cache[path].lines, file_cache[path].err
        end
        local lines, err = opts.read_file(path)
        file_cache[path] = { lines = lines, err = err }
        return lines, err
    end

    local records = {}
    local report = { exact = 0, approximate = 0, skipped = {}, unreadable = 0 }
    for _, original in ipairs(comments) do
        local comment = original
        local parent_id = value(comment.in_reply_to_id)
        if parent_id and by_id[parent_id] then
            comment = copy_coordinates(comment, by_id[parent_id])
        end

        local comment_path = value(comment.path)
        -- Coordinates come from the thread itself, so the pull request diff is
        -- only consulted to follow a file GitHub renamed under the comment.
        local resolved_path = opts.diff and select(2, diff.file(opts.diff, comment_path or "")) or nil
        local path = resolved_path or comment_path
        local lines
        local read_err
        if path then
            lines, read_err = load_file(path)
        end

        local start_line
        local end_line
        local anchor = "exact"
        local mapping_error

        local side = first(comment.side, comment.original_side)
        local line = first(comment.line, comment.original_line)
        if not path or not lines or #lines == 0 then
            mapping_error = read_err or "file does not exist at the pull request head"
            report.unreadable = report.unreadable + 1
        elseif positive_integer(value(comment.line)) and side == "RIGHT" then
            end_line = comment.line
            start_line = value(comment.start_side) == "RIGHT" and value(comment.start_line) or end_line
            start_line = positive_integer(start_line) and start_line or end_line
            if value(comment.start_line) and value(comment.start_side) ~= "RIGHT" then
                anchor = "approximate"
            end
            if end_line > #lines or start_line > end_line then
                mapping_error = "right-side range is outside the pull request head file"
            end
        elseif side == "LEFT" then
            anchor = "approximate"
            local hunk, hunk_err = diff.parse_hunk(value(comment.diff_hunk))
            local old_line = line
            local candidate, candidate_err
            if hunk and positive_integer(old_line) then
                candidate, candidate_err = diff.nearest_right_for_left(hunk, old_line)
            end
            if not candidate then
                mapping_error = candidate_err or hunk_err or "deleted line has no usable diff hunk"
            else
                local candidate_line = candidate.new_line
                if candidate_line <= #lines and lines[candidate_line] == candidate.text then
                    start_line = candidate_line
                    end_line = candidate_line
                else
                    local unique = unique_line(lines, candidate.text)
                    if unique then
                        start_line = unique
                        end_line = unique
                    else
                        mapping_error = "nearest surviving line cannot be re-anchored unambiguously"
                    end
                end
            end
        elseif value(comment.subject_type) == "file" or line == nil then
            anchor = "approximate"
            start_line = 1
            end_line = 1
        else
            anchor = "approximate"
            local hunk, hunk_err = diff.parse_hunk(value(comment.diff_hunk))
            local original_line = line
            local candidate = hunk and positive_integer(original_line) and hunk_right_record(hunk, original_line) or nil
            if not candidate then
                mapping_error = hunk_err or "outdated comment cannot be located in its diff hunk"
            else
                local unique = unique_line(lines, candidate.text)
                if unique then
                    start_line = unique
                    end_line = unique
                else
                    mapping_error = "outdated comment cannot be re-anchored unambiguously"
                end
            end
        end

        local body = type(comment.body) == "string" and vim.trim(comment.body) or ""
        if body == "" then
            mapping_error = mapping_error or "comment body is empty"
        end
        if not valid_identifier(value(comment.id)) then
            mapping_error = mapping_error or "comment ID is missing or invalid"
        end

        if mapping_error then
            report.skipped[#report.skipped + 1] = {
                id = value(comment.id),
                path = comment_path,
                reason = mapping_error,
            }
        else
            local captured = context.capture_lines(lines, start_line, end_line, 3)
            local identity = string.format("github:%s:%s", opts.repository, tostring(comment.id))
            local user = type(comment.user) == "table" and comment.user or {}
            local thread = type(comment._thread) == "table" and comment._thread or {}
            records[#records + 1] = {
                id = vim.fn.sha256(identity):sub(1, 24),
                branch = opts.branch,
                file = path,
                start_line = start_line,
                end_line = end_line,
                snippet_start = captured.snippet_start,
                snippet = captured.snippet,
                text = body,
                origin = {
                    provider = "github",
                    repository = opts.repository,
                    hostname = opts.hostname,
                    pull_number = opts.pull_number,
                    comment_id = comment.id,
                    url = value(comment.html_url) or value(comment.url) or string.format(
                        "https://%s/%s/pull/%d",
                        opts.hostname or "github.com",
                        opts.repository,
                        opts.pull_number
                    ),
                    author = value(user.login) or "unknown",
                    anchor = anchor,
                    original_path = comment_path,
                    original_line = line,
                    original_side = side,
                    thread_id = thread.id,
                    resolved = thread.resolved,
                    outdated = thread.outdated,
                    is_reply = thread.is_reply,
                    reply_count = thread.reply_count,
                },
            }
            report[anchor] = report[anchor] + 1
        end
    end

    report.records = records
    return report
end

function M.transform_threads(threads, opts)
    local comments = {}
    local filtered = 0
    local truncated = 0
    local selected_threads = 0

    for _, thread in ipairs(threads) do
        if thread.isResolved and not opts.include_resolved then
            filtered = filtered + 1
        else
            selected_threads = selected_threads + 1
            local connection = type(thread.comments) == "table" and thread.comments or {}
            local nodes = type(connection.nodes) == "table" and connection.nodes or {}
            if connection.pageInfo and connection.pageInfo.hasNextPage then
                truncated = truncated + 1
            end
            local limit = opts.include_replies and #nodes or math.min(#nodes, 1)
            local comment_count = type(connection.totalCount) == "number" and connection.totalCount or #nodes
            for index = 1, limit do
                local node = nodes[index]
                comments[#comments + 1] = {
                    id = value(node.fullDatabaseId) or value(node.id),
                    path = thread.path,
                    line = thread.line,
                    side = thread.diffSide,
                    start_line = thread.startLine,
                    start_side = thread.startDiffSide,
                    original_line = thread.originalLine,
                    original_start_line = thread.originalStartLine,
                    body = node.body,
                    html_url = node.url,
                    user = node.author,
                    diff_hunk = node.diffHunk,
                    subject_type = thread.subjectType == "FILE" and "file" or "line",
                    _thread = {
                        id = thread.id,
                        resolved = thread.isResolved == true,
                        outdated = thread.isOutdated == true,
                        is_reply = index > 1,
                        reply_count = math.max(0, comment_count - 1),
                    },
                }
            end
        end
    end

    local report = M.transform(comments, opts)
    report.filtered = filtered
    report.truncated = truncated
    report.threads = selected_threads
    return report
end

return M
