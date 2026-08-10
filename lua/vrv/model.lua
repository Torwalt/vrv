local M = { VERSION = 1 }

local next_id = 0

local function is_positive_integer(value)
    return type(value) == "number" and value >= 1 and value % 1 == 0
end

local function validate_annotation(annotation)
    if type(annotation) ~= "table" then
        return false, "annotation must be an object"
    end
    if type(annotation.id) ~= "string" or annotation.id == "" then
        return false, "annotation.id must be a non-empty string"
    end
    if type(annotation.branch) ~= "string" or annotation.branch == "" then
        return false, "annotation.branch must be a non-empty string"
    end
    if type(annotation.file) ~= "string" or annotation.file == "" then
        return false, "annotation.file must be a non-empty string"
    end
    if not is_positive_integer(annotation.start_line) then
        return false, "annotation.start_line must be a positive integer"
    end
    if not is_positive_integer(annotation.end_line) or annotation.end_line < annotation.start_line then
        return false, "annotation.end_line must be an integer at or after start_line"
    end
    if not is_positive_integer(annotation.snippet_start) then
        return false, "annotation.snippet_start must be a positive integer"
    end
    if type(annotation.snippet) ~= "table" or not vim.islist(annotation.snippet) then
        return false, "annotation.snippet must be a list"
    end
    for _, line in ipairs(annotation.snippet) do
        if type(line) ~= "string" then
            return false, "annotation.snippet entries must be strings"
        end
    end
    if type(annotation.text) ~= "string" or vim.trim(annotation.text) == "" then
        return false, "annotation.text must be non-empty"
    end
    return true
end

function M.validate_annotation(annotation)
    return validate_annotation(annotation)
end

function M.new(fields)
    next_id = next_id + 1
    local annotation = vim.deepcopy(fields)
    local id_material = table.concat({
        tostring(vim.uv.hrtime()),
        tostring(vim.fn.getpid()),
        tostring(next_id),
        tostring({}),
    }, ":")
    annotation.id = annotation.id or vim.fn.sha256(id_material):sub(1, 24)
    annotation.text = vim.trim(annotation.text or "")

    local ok, err = validate_annotation(annotation)
    if not ok then
        return nil, err
    end
    return annotation
end

function M.serializable(annotation)
    return {
        id = annotation.id,
        branch = annotation.branch,
        file = annotation.file,
        start_line = annotation.start_line,
        end_line = annotation.end_line,
        snippet_start = annotation.snippet_start,
        snippet = vim.deepcopy(annotation.snippet),
        text = annotation.text,
    }
end

function M.encode(annotations)
    local durable = {}
    for index, annotation in ipairs(annotations) do
        local ok, err = validate_annotation(annotation)
        if not ok then
            return nil, string.format("annotation %d: %s", index, err)
        end
        durable[index] = M.serializable(annotation)
    end

    local ok, encoded = pcall(vim.json.encode, {
        version = M.VERSION,
        annotations = durable,
    })
    if not ok then
        return nil, tostring(encoded)
    end
    return encoded
end

function M.decode(content)
    local ok, document = pcall(vim.json.decode, content)
    if not ok or type(document) ~= "table" then
        return nil, "store is not valid JSON"
    end
    if document.version ~= M.VERSION then
        return nil, "unsupported store version: " .. tostring(document.version)
    end
    if type(document.annotations) ~= "table" or not vim.islist(document.annotations) then
        return nil, "store.annotations must be a list"
    end

    local annotations = {}
    local seen = {}
    for index, annotation in ipairs(document.annotations) do
        local valid, err = validate_annotation(annotation)
        if not valid then
            return nil, string.format("annotation %d: %s", index, err)
        end
        if seen[annotation.id] then
            return nil, "duplicate annotation id: " .. annotation.id
        end
        seen[annotation.id] = true
        annotations[index] = M.serializable(annotation)
    end
    return annotations
end

return M
