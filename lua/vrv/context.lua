local M = {}

function M.capture(bufnr, start_line, end_line, padding)
    padding = padding or 3
    local total = vim.api.nvim_buf_line_count(bufnr)
    local first = math.max(1, start_line - padding)
    local last = math.min(total, end_line + padding)
    local source = vim.api.nvim_buf_get_lines(bufnr, first - 1, last, false)
    local snippet = {}

    for offset, line in ipairs(source) do
        snippet[offset] = string.format("%d: %s", first + offset - 1, line)
    end

    return {
        snippet_start = first,
        snippet = snippet,
    }
end

function M.visual_range()
    local anchor = vim.fn.line("v")
    local cursor = vim.api.nvim_win_get_cursor(0)[1]
    return math.min(anchor, cursor), math.max(anchor, cursor)
end

return M
