local diff = require("vrv.diff")

local M = {}

function M.build(annotations, pull_request, parsed_diff)
    if #annotations == 0 then
        return nil, { "no annotations on the current branch" }
    end
    if type(pull_request.head_oid) ~= "string" or pull_request.head_oid == "" then
        return nil, { "pull request head commit is missing" }
    end

    local comments = {}
    local errors = {}
    for _, annotation in ipairs(annotations) do
        local mapped, err = diff.right_range(parsed_diff, annotation.file, annotation.start_line, annotation.end_line)
        if not mapped then
            errors[#errors + 1] = err
        else
            local comment = {
                path = mapped.path,
                line = annotation.end_line,
                side = "RIGHT",
                body = annotation.text,
            }
            if annotation.start_line ~= annotation.end_line then
                comment.start_line = annotation.start_line
                comment.start_side = "RIGHT"
            end
            comments[#comments + 1] = comment
        end
    end

    if #errors > 0 then
        return nil, errors
    end
    return {
        commit_id = pull_request.head_oid,
        comments = comments,
    }
end

function M.encode(annotations, pull_request, parsed_diff)
    local payload, errors = M.build(annotations, pull_request, parsed_diff)
    if not payload then
        return nil, errors
    end
    local ok, encoded = pcall(vim.json.encode, payload)
    if not ok then
        return nil, { tostring(encoded) }
    end
    return encoded
end

return M
