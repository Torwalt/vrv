assert(vim.g.loaded_vrv == 1, "plugin/vrv.lua was not loaded")

local vrv = require("vrv")
assert(type(vrv.setup) == "function", "vrv.setup is missing")
assert(vrv.setup() == vrv, "vrv.setup must return the module")
assert(vrv.setup() == vrv, "vrv.setup must be idempotent")

assert(pcall(require, "plenary"), "plenary.nvim is missing from the runtime path")
assert(pcall(require, "telescope"), "telescope.nvim is missing from the runtime path")

print("vrv smoke test passed")
