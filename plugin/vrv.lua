if vim.g.loaded_vrv == 1 then
    return
end

if vim.fn.has("nvim-0.11.7") == 0 then
    vim.api.nvim_err_writeln("vrv requires Neovim 0.11.7 or newer")
    return
end

vim.g.loaded_vrv = 1
