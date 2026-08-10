local M = {}

local configured = false

function M.setup()
    if configured then
        return M
    end

    configured = true
    return M
end

return M
