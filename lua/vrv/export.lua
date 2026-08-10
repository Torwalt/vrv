local M = {}

local languages = {
    lua = "lua",
    py = "python",
    rs = "rust",
    go = "go",
    js = "javascript",
    ts = "typescript",
    tsx = "tsx",
    jsx = "jsx",
    c = "c",
    cpp = "cpp",
    h = "c",
    hpp = "cpp",
    md = "markdown",
    sh = "bash",
    zsh = "bash",
    vim = "vim",
    json = "json",
    yaml = "yaml",
    yml = "yaml",
    toml = "toml",
    html = "html",
    css = "css",
    sql = "sql",
}

local function language(file)
    local extension = file:match("%.([^./]+)$")
    if not extension then
        return ""
    end
    extension = extension:lower()
    return languages[extension] or extension
end

local function location(annotation)
    if annotation.start_line == annotation.end_line then
        return "line " .. annotation.start_line
    end
    return string.format("lines %d–%d", annotation.start_line, annotation.end_line)
end

function M.format(annotations)
    annotations = vim.deepcopy(annotations)
    table.sort(annotations, function(left, right)
        if left.file ~= right.file then
            return left.file < right.file
        end
        if left.start_line ~= right.start_line then
            return left.start_line < right.start_line
        end
        return left.id < right.id
    end)

    local blocks = {}
    local current_file = nil

    for _, annotation in ipairs(annotations) do
        if annotation.file ~= current_file then
            current_file = annotation.file
            blocks[#blocks + 1] = "## @" .. current_file
        end

        local snippet = table.concat(annotation.snippet, "\n")
        blocks[#blocks + 1] = table.concat({
            string.format("### %s — %s", annotation.file, location(annotation)),
            string.format("```%s\n%s\n```", language(annotation.file), snippet),
            annotation.text,
        }, "\n\n")
    end

    if #blocks == 0 then
        return ""
    end
    return table.concat(blocks, "\n\n") .. "\n"
end

function M.to_clipboard(annotations)
    local output = M.format(annotations)
    if output == "" then
        return false, "no annotations on the current branch"
    end

    local ok, err = pcall(vim.fn.setreg, "+", output)
    if not ok then
        return false, tostring(err)
    end
    return true, output
end

return M
