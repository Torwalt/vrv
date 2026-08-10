local script = debug.getinfo(1, "S").source:sub(2)
local tests_root = vim.fn.fnamemodify(script, ":p:h")
local T = dofile(tests_root .. "/testlib.lua")
local context = require("vrv.context")
local exporter = require("vrv.export")
local git = require("vrv.git")
local model = require("vrv.model")
local navigation = require("vrv.navigation")
local picker = require("vrv.picker")
local signs = require("vrv.signs")
local store = require("vrv.store")
local vrv = require("vrv")

vim.wait(20)

local initial_cwd = vim.fn.getcwd()

local function reset_runtime()
    pcall(vim.cmd, "stopinsert")
    pcall(vim.cmd, "silent! %bwipeout!")
    vim.cmd("enew!")
    signs.clear_all()
    store._reset()
    require("vrv.editor")._reset()
    vim.cmd("cd " .. vim.fn.fnameescape(initial_cwd))
end

T.test("model validates and round-trips durable data", function()
    local annotation = T.annotation({
        branch = "feature/unicode",
        text = "First line\nGrüße, 世界",
        _bufnr = 42,
        _extmark_id = 9,
    })
    local valid, validation_error = model.validate_annotation(annotation)
    T.truthy(valid, validation_error)

    local encoded = T.truthy(model.encode({ annotation }))
    local decoded = T.truthy(model.decode(encoded))
    T.eq(1, #decoded)
    T.eq("First line\nGrüße, 世界", decoded[1].text)
    T.eq(nil, decoded[1]._bufnr)
    T.eq(nil, decoded[1]._extmark_id)

    local new_fields = T.annotation()
    new_fields.id = nil
    local created = T.truthy(model.new(new_fields))
    T.match("^[0-9a-f]+$", created.id)
    T.eq(24, #created.id)
end)

T.test("model rejects malformed, unsupported, and duplicate records", function()
    local invalid = T.annotation({ start_line = 0 })
    local encoded, encode_error = model.encode({ invalid })
    T.eq(nil, encoded)
    T.match("positive integer", encode_error)

    local decoded, json_error = model.decode("not-json")
    T.eq(nil, decoded)
    T.match("valid JSON", json_error)

    local unsupported, version_error = model.decode('{"version":2,"annotations":[]}')
    T.eq(nil, unsupported)
    T.match("unsupported store version", version_error)

    local duplicate = vim.json.encode({
        version = 1,
        annotations = { T.annotation(), T.annotation() },
    })
    local result, duplicate_error = model.decode(duplicate)
    T.eq(nil, result)
    T.match("duplicate annotation id", duplicate_error)
end)

T.test("context capture uses live text, boundaries, and visual line ranges", function()
    reset_runtime()
    local bufnr = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        "one",
        "two",
        "three",
        "unsaved four",
        "five",
        "six",
        "seven",
        "eight",
    })

    local middle = context.capture(bufnr, 4, 5, 3)
    T.eq(1, middle.snippet_start)
    T.eq("4: unsaved four", middle.snippet[4])
    T.eq("8: eight", middle.snippet[8])

    local first = context.capture(bufnr, 1, 1, 3)
    T.eq({ "1: one", "2: two", "3: three", "4: unsaved four" }, first.snippet)

    local last = context.capture(bufnr, 8, 8, 3)
    T.eq(5, last.snippet_start)
    T.eq({ "5: five", "6: six", "7: seven", "8: eight" }, last.snippet)

    vim.api.nvim_win_set_cursor(0, { 6, 0 })
    vim.cmd("normal! V3G")
    local range_start, range_end = context.visual_range()
    T.eq(3, range_start)
    T.eq(6, range_end)
    vim.cmd("normal! \27")
end)

T.test("Git helpers support roots, unborn branches, slash names, and detached HEAD", function()
    local unborn = T.repo({ branch = "topic/unborn" })
    T.eq(unborn, git.root(unborn))
    T.eq("topic/unborn", git.branch(unborn))

    local root = T.repo({ commit = true })
    T.command({ "git", "switch", "-c", "feature/review" }, root)
    T.eq("feature/review", git.branch(root))

    local source = root .. "/lua/example.lua"
    T.write(source, "return true\n")
    reset_runtime()
    vim.cmd("edit " .. vim.fn.fnameescape(source))
    T.eq("lua/example.lua", git.relative_file(root, 0))

    T.command({ "git", "checkout", "--detach", "HEAD" }, root)
    local branch, branch_error = git.branch(root)
    T.eq(nil, branch)
    T.truthy(branch_error ~= nil)
end)

T.test("store persists branches atomically and updates gitignore once", function()
    reset_runtime()
    local root = T.repo()
    T.truthy(store.load(root))
    T.eq({}, store.all())

    local main = T.truthy(store.add(T.annotation({ id = nil })))
    local other = T.truthy(store.add(T.annotation({
        id = "other-branch",
        branch = "feature/other",
        file = "b.lua",
        start_line = 2,
        end_line = 3,
        snippet_start = 1,
        snippet = { "1: before", "2: start", "3: end" },
        text = "Other branch",
    })))
    local earlier = T.truthy(store.add(T.annotation({
        id = "main-earlier",
        file = "a.lua",
        start_line = 1,
        end_line = 1,
        snippet = { "1: target" },
        text = "Earlier",
    })))

    T.eq(
        { earlier.id, main.id },
        vim.tbl_map(function(annotation)
            return annotation.id
        end, store.for_branch("main"))
    )
    T.eq(
        { other.id },
        vim.tbl_map(function(annotation)
            return annotation.id
        end, store.for_branch("feature/other"))
    )

    T.truthy(store.update(main.id, "Updated\ntext"))
    T.eq("Updated\ntext", store.get(main.id).text)
    T.truthy(store.delete(other.id))
    T.eq(nil, store.get(other.id))
    T.truthy(store.save())

    local ignored = T.read(root .. "/.gitignore")
    local _, count = ignored:gsub("/.cache/vrv/annotations%.json", "")
    T.eq(1, count)

    local encoded = T.read(store.path(root))
    T.falsy(encoded:find("_bufnr", 1, true))
    store._reset()
    T.truthy(store.load(root))
    T.eq(2, #store.all())

    local previous = T.read(store.path(root))
    store.all()[1].text = function() end
    local saved = store.save()
    T.falsy(saved)
    T.eq(previous, T.read(store.path(root)))
end)

T.test("malformed stores become read-only and are never overwritten", function()
    reset_runtime()
    local root = T.repo()
    local path = store.path(root)
    T.write(path, "{broken")
    local loaded, load_error = store.load(root)
    T.falsy(loaded)
    T.match("valid JSON", load_error)
    T.falsy(store.is_writable())

    local added, add_error = store.add(T.annotation({ id = "will-not-save" }))
    T.eq(nil, added)
    T.match("read%-only", add_error)
    T.eq("{broken", T.read(path))

    T.write(path, '{"version":99,"annotations":[]}')
    loaded, load_error = store.load(root)
    T.falsy(loaded)
    T.match("unsupported store version", load_error)
    T.eq('{"version":99,"annotations":[]}', T.read(path))
end)

T.test("Markdown export is exact, deterministic, minimal, and clipboard-safe when empty", function()
    local second = T.annotation({
        id = "z",
        file = "z.unknown",
        start_line = 8,
        end_line = 10,
        snippet_start = 7,
        snippet = { "7: α", "8: β", "9: γ", "10: δ", "11: ε" },
        text = "Multiline\ncomment.",
    })
    local first = T.annotation({
        id = "a",
        file = "a.lua",
        start_line = 2,
        end_line = 2,
        snippet_start = 1,
        snippet = { "1: before", "2: target", "3: after" },
        text = "First comment.",
    })
    local expected = table.concat({
        "## @a.lua",
        "",
        "### a.lua — line 2",
        "",
        "```lua",
        "1: before",
        "2: target",
        "3: after",
        "```",
        "",
        "First comment.",
        "",
        "## @z.unknown",
        "",
        "### z.unknown — lines 8–10",
        "",
        "```unknown",
        "7: α",
        "8: β",
        "9: γ",
        "10: δ",
        "11: ε",
        "```",
        "",
        "Multiline",
        "comment.",
        "",
    }, "\n")
    T.eq(expected, exporter.format({ second, first }))
    T.eq("z.unknown", second.file, "format must not mutate its input")
    T.falsy(expected:find("summary", 1, true))
    T.falsy(expected:find("issue", 1, true))

    local original_setreg = vim.fn.setreg
    local clipboard_calls = {}
    vim.fn.setreg = function(register, value)
        clipboard_calls[#clipboard_calls + 1] = { register, value }
    end
    local exported, empty_error = exporter.to_clipboard({})
    local copied, copied_output = exporter.to_clipboard({ second, first })
    vim.fn.setreg = original_setreg
    T.falsy(exported)
    T.match("no annotations", empty_error)
    T.truthy(copied)
    T.eq(expected, copied_output)
    T.eq({ { "+", expected } }, clipboard_calls)
end)

T.test("Telescope entries expose display, search, and preview coordinates", function()
    local annotation = T.annotation({ text = "First line\nSecond line" })
    local entry = picker.make_entry("/project", annotation)
    T.eq(annotation, entry.value)
    T.eq("/project/lua/example.lua", entry.filename)
    T.eq(4, entry.lnum)
    T.eq("lua/example.lua:4 — First line Second line", entry.display)
    T.truthy(entry.ordinal:find("lua/example.lua", 1, true))
    T.truthy(entry.ordinal:find("First line", 1, true))
    T.truthy(entry.ordinal:find("4: target", 1, true))
end)

T.test("annotation editor supports write, repeated write, edit, drift, delete, and cancel", function()
    reset_runtime()
    local root = T.repo({ commit = true })
    local source = root .. "/lua/example.lua"
    T.write(source, table.concat({ "one", "two", "three", "four", "five", "six" }, "\n") .. "\n")
    vim.cmd("edit " .. vim.fn.fnameescape(source))
    local source_buf = vim.api.nvim_get_current_buf()
    local source_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    vrv.refresh()

    vrv.add()
    local editor_buf = vim.api.nvim_get_current_buf()
    T.match("^vrv://annotation/new%-", vim.api.nvim_buf_get_name(editor_buf))
    T.eq("acwrite", vim.bo[editor_buf].buftype)
    T.eq("markdown", vim.bo[editor_buf].filetype)
    vim.cmd("stopinsert")
    vim.api.nvim_buf_set_lines(editor_buf, 0, -1, false, { "Please fix this.", "It is subtle." })
    vim.cmd("write")
    T.eq(editor_buf, vim.api.nvim_get_current_buf())
    T.eq(1, #store.for_branch("main"))
    vim.cmd("write")
    T.eq(1, #store.for_branch("main"), "repeated writes must update, not duplicate")

    local annotation = store.for_branch("main")[1]
    T.eq(3, annotation.start_line)
    T.eq("Please fix this.\nIt is subtle.", annotation.text)
    T.eq("1: one", annotation.snippet[1])
    T.eq("6: six", annotation.snippet[6])
    T.truthy(annotation._extmark_id)
    vim.cmd("wq")
    vim.wait(20)
    T.eq(source_win, vim.api.nvim_get_current_win())
    T.eq(source_buf, vim.api.nvim_get_current_buf())

    vim.api.nvim_buf_set_lines(source_buf, 0, 0, false, { "inserted" })
    T.truthy(store.save())
    T.eq(4, annotation.start_line)
    T.eq(4, annotation.end_line)
    T.eq("1: one", annotation.snippet[1], "historical context must not drift")

    vim.api.nvim_win_set_cursor(source_win, { 4, 0 })
    vrv.edit()
    editor_buf = vim.api.nvim_get_current_buf()
    T.eq({ "Please fix this.", "It is subtle." }, vim.api.nvim_buf_get_lines(editor_buf, 0, -1, false))
    vim.cmd("stopinsert")
    vim.api.nvim_buf_set_lines(editor_buf, 0, -1, false, { "Reworded." })
    vim.cmd("wq")
    vim.wait(20)
    T.eq("Reworded.", annotation.text)
    T.eq(4, annotation.start_line)
    T.eq("1: one", annotation.snippet[1])

    vrv.delete()
    T.eq(0, #store.for_branch("main"))
    T.eq({}, vim.api.nvim_buf_get_extmarks(source_buf, signs.namespace, 0, -1, {}))

    vrv.add(2, 4)
    editor_buf = vim.api.nvim_get_current_buf()
    vim.cmd("stopinsert")
    vim.api.nvim_buf_set_lines(editor_buf, 0, -1, false, { "discard me" })
    vim.cmd("q!")
    vim.wait(20)
    T.eq(0, #store.for_branch("main"))

    vrv.add(2, 4)
    vim.cmd("stopinsert")
    local ok, write_error = pcall(vim.cmd, "write")
    T.falsy(ok)
    T.match("non%-empty", write_error)
    T.eq(0, #store.for_branch("main"))
    vim.cmd("q!")
end)

T.test("navigation sorts through current positions, wraps, and reports bad targets", function()
    reset_runtime()
    local root = T.repo()
    T.write(root .. "/a.lua", "one\ntwo\nthree\n")
    T.write(root .. "/b.lua", "only\n")
    vim.cmd("edit " .. vim.fn.fnameescape(root .. "/a.lua"))
    local annotations = {
        T.annotation({ id = "a", file = "a.lua", start_line = 2, end_line = 2 }),
        T.annotation({ id = "b", file = "b.lua", start_line = 1, end_line = 1 }),
    }
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    T.eq("a", navigation.next(root, annotations).id)
    T.eq("b", navigation.previous(root, annotations).id)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    T.eq("b", navigation.next(root, annotations).id)
    T.eq("a", navigation.previous(root, annotations).id)

    T.truthy(navigation.jump(root, annotations[2]))
    T.eq("b.lua", vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t"))
    T.eq(1, vim.api.nvim_win_get_cursor(0)[1])
    local jumped, jump_error = navigation.jump(root, T.annotation({ file = "missing.lua" }))
    T.falsy(jumped)
    T.match("does not exist", jump_error)
    jumped, jump_error = navigation.jump(root, T.annotation({ file = "b.lua", start_line = 99, end_line = 99 }))
    T.falsy(jumped)
    T.match("line 99", jump_error)
end)

T.test("branch switches, reload, and detached HEAD preserve branch isolation", function()
    reset_runtime()
    local root = T.repo({ commit = true })
    local source = root .. "/review.lua"
    T.write(source, "one\ntwo\nthree\nfour\n")
    T.command({ "git", "add", "review.lua" }, root)
    T.command({ "git", "commit", "-m", "source" }, root)
    T.command({ "git", "branch", "other" }, root)
    vim.cmd("edit " .. vim.fn.fnameescape(source))

    T.truthy(store.load(root))
    T.truthy(store.add(T.annotation({
        id = "main",
        file = "review.lua",
        start_line = 1,
        end_line = 1,
        text = "Main branch annotation",
    })))
    T.truthy(store.add(T.annotation({
        id = "other",
        branch = "other",
        file = "review.lua",
        start_line = 3,
        end_line = 3,
        text = "Other branch annotation",
    })))
    vrv.refresh()
    local marks = vim.api.nvim_buf_get_extmarks(0, signs.namespace, 0, -1, {})
    T.eq(1, #marks)
    T.eq(0, marks[1][2])
    T.eq(
        { "main" },
        vim.tbl_map(function(annotation)
            return annotation.id
        end, store.for_branch(git.branch(root)))
    )

    T.command({ "git", "switch", "other" }, root)
    vrv.refresh()
    marks = vim.api.nvim_buf_get_extmarks(0, signs.namespace, 0, -1, {})
    T.eq(1, #marks)
    T.eq(2, marks[1][2])
    T.eq(
        { "other" },
        vim.tbl_map(function(annotation)
            return annotation.id
        end, store.for_branch(git.branch(root)))
    )
    T.match("Other branch annotation", exporter.format(store.for_branch("other")))

    local replacement = T.annotation({
        id = "external",
        branch = "other",
        file = "review.lua",
        start_line = 2,
        end_line = 2,
        text = "Loaded externally",
    })
    T.write(store.path(root), T.truthy(model.encode({ replacement })))
    vrv.reload()
    T.eq("external", store.all()[1].id)
    marks = vim.api.nvim_buf_get_extmarks(0, signs.namespace, 0, -1, {})
    T.eq(1, #marks)
    T.eq(1, marks[1][2])

    local before = T.read(store.path(root))
    T.command({ "git", "checkout", "--detach", "HEAD" }, root)
    local original_setreg = vim.fn.setreg
    local clipboard_calls = 0
    vim.fn.setreg = function()
        clipboard_calls = clipboard_calls + 1
    end
    vrv.export()
    vim.fn.setreg = original_setreg
    T.eq(before, T.read(store.path(root)))
    T.eq(0, clipboard_calls)
end)

T.test("commands, mappings, setup, and Telescope UI wiring are idempotent", function()
    reset_runtime()
    T.eq(2, vim.fn.exists(":Vrv"))
    for _, mapping in ipairs({ " ra", " rd", " re", " rf", " rE", "]r", "[r" }) do
        T.truthy(vim.fn.maparg(mapping, "n") ~= "", "missing mapping " .. mapping)
    end
    T.truthy(vim.fn.maparg(" ra", "x") ~= "")

    local before = #vim.api.nvim_get_autocmds({ group = "VrvLifecycle" })
    T.eq(vrv, vrv.setup())
    T.eq(before, #vim.api.nvim_get_autocmds({ group = "VrvLifecycle" }))

    local root = T.repo()
    T.write(root .. "/lua/example.lua", "return true\n")
    picker.open({ T.annotation({ id = "selected" }), T.annotation({ id = "adjacent", start_line = 5 }) }, {
        root = root,
        on_delete = function()
            return true
        end,
    })
    T.truthy(
        vim.wait(500, function()
            return vim.bo.filetype == "TelescopePrompt"
        end),
        "Telescope prompt did not open"
    )
    local prompt_bufnr = vim.api.nvim_get_current_buf()
    T.eq("TelescopePrompt", vim.bo[prompt_bufnr].filetype)
    local delete_mapping = vim.fn.maparg("<C-d>", "n", false, true)
    T.truthy(delete_mapping.callback, "Telescope delete mapping is missing")
    T.truthy(vim.fn.maparg("<C-e>", "n", false, true).callback, "Telescope edit mapping is missing")
    local remaining = picker._without_id({
        T.annotation({ id = "selected" }),
        T.annotation({ id = "adjacent" }),
    }, "selected")
    T.eq(
        { "adjacent" },
        vim.tbl_map(function(annotation)
            return annotation.id
        end, remaining),
        "picker refresh must remove only the selected stable ID"
    )
    require("telescope.actions").close(prompt_bufnr)
end)

T.finish()
