local M = {}

function M.capture_lines(lines, start_line, end_line, padding)
    padding = padding or 3
    local first = math.max(1, start_line - padding)
    local last = math.min(#lines, end_line + padding)
    local snippet = {}

    for line_number = first, last do
        snippet[#snippet + 1] = string.format("%d: %s", line_number, lines[line_number])
    end

    return {
        snippet_start = first,
        snippet = snippet,
    }
end

function M.capture(bufnr, start_line, end_line, padding)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    return M.capture_lines(lines, start_line, end_line, padding)
end

function M.visual_range()
    local anchor = vim.fn.line("v")
    local cursor = vim.api.nvim_win_get_cursor(0)[1]
    return math.min(anchor, cursor), math.max(anchor, cursor)
end

return M
