local script = debug.getinfo(1, "S").source:sub(2)
local tests_root = vim.fn.fnamemodify(script, ":p:h")
local T = dofile(tests_root .. "/testlib.lua")
local context = require("vrv.context")
local exporter = require("vrv.export")
local diff = require("vrv.diff")
local git = require("vrv.git")
local github = require("vrv.github")
local github_export = require("vrv.github_export")
local github_import = require("vrv.github_import")
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

    local unsupported, version_error = model.decode('{"version":3,"annotations":[]}')
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

T.test("model migrates v1 stores and round-trips GitHub provenance", function()
    local legacy = T.truthy(model.decode(vim.json.encode({
        version = 1,
        annotations = { T.annotation() },
    })))
    T.eq(nil, legacy[1].origin)

    local annotation = T.annotation({
        origin = T.github_origin({
            pull_number = 12,
            comment_id = "9223372036854775807",
            url = "https://github.com/owner/repo/pull/12#discussion_r9223372036854775807",
            anchor = "approximate",
            original_side = "LEFT",
            outdated = true,
        }),
    })
    local encoded = T.truthy(model.encode({ annotation }))
    T.eq(2, vim.json.decode(encoded).version)
    local decoded = T.truthy(model.decode(encoded))
    T.eq(annotation.origin, decoded[1].origin)
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

T.test("store persists branches atomically and leaves gitignore untouched", function()
    reset_runtime()
    local root = T.repo()
    T.truthy(store.load(root))
    T.eq({}, store.all())

    local main = T.truthy(store.add(T.annotation({ id = nil })))
    T.eq(nil, vim.uv.fs_stat(root .. "/.gitignore"))

    local gitignore = "# Managed by the user\n/custom-cache/\n"
    T.write(root .. "/.gitignore", gitignore)
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

    T.eq(gitignore, T.read(root .. "/.gitignore"))

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

T.test("bulk store additions are idempotent and validate before saving", function()
    local root = T.repo()
    T.truthy(store.load(root))
    local first = T.annotation({ id = "bulk-one" })
    local duplicate = T.annotation({ id = "bulk-one", text = "duplicate" })
    local result = T.truthy(store.add_many({ first, duplicate }))
    T.eq(1, #result.added)
    T.eq(1, #result.skipped)
    T.eq("Review this.", store.get("bulk-one").text)

    local invalid = T.annotation({ id = "invalid", start_line = 0 })
    local failed, err = store.add_many({ T.annotation({ id = "never-added" }), invalid })
    T.eq(nil, failed)
    T.match("positive integer", err)
    T.eq(nil, store.get("never-added"))

    local imported = T.truthy(store.add(T.annotation({ id = "github-thread", origin = T.github_origin() })))
    local resolved, changed = store.mark_github_thread_resolved("PRRT_thread")
    T.truthy(resolved)
    T.eq(1, #changed)
    T.eq(true, imported.origin.resolved)
end)

T.test("GitHub diff mapping exports strict right-side review payloads", function()
    local parsed = diff.from_files({
        {
            filename = "foo.lua",
            status = "modified",
            changes = 2,
            patch = table.concat({
                "@@ -1,4 +1,4 @@",
                " one",
                "-old",
                "+new",
                " three",
                " four",
            }, "\n"),
        },
    })
    local payload = T.truthy(github_export.build({
        T.annotation({ id = "one", file = "foo.lua", start_line = 2, end_line = 2, text = "single" }),
        T.annotation({ id = "two", file = "foo.lua", start_line = 2, end_line = 3, text = "range" }),
    }, { head_oid = "abc123" }, parsed))
    T.eq("abc123", payload.commit_id)
    T.eq({ path = "foo.lua", line = 2, side = "RIGHT", body = "single" }, payload.comments[1])
    T.eq({
        path = "foo.lua",
        start_line = 2,
        start_side = "RIGHT",
        line = 3,
        side = "RIGHT",
        body = "range",
    }, payload.comments[2])

    local rejected, errors = github_export.build({
        T.annotation({ file = "foo.lua", start_line = 20, end_line = 20 }),
    }, { head_oid = "abc123" }, parsed)
    T.eq(nil, rejected)
    T.match("not a commentable range", errors[1])
end)

T.test("pull request file listings map renames and withheld patches", function()
    local parsed = diff.from_files({
        {
            filename = "renamed.lua",
            previous_filename = "old.lua",
            status = "renamed",
            changes = 1,
            patch = "@@ -1 +1 @@\n-one\n+two",
        },
        { filename = "gone.lua", status = "removed", changes = 3, patch = "@@ -1 +0,0 @@\n-one" },
        { filename = "huge.lua", status = "modified", changes = 40000 },
        { filename = "moved.lua", previous_filename = "was.lua", status = "renamed", changes = 0 },
    })

    local file, resolved = diff.file(parsed, "old.lua")
    T.truthy(file)
    T.eq("renamed.lua", resolved, "an old path must resolve to its new path")
    T.truthy(diff.right_range(parsed, "old.lua", 1, 1))
    T.eq(nil, diff.file(parsed, "gone.lua"), "deleted files have no head-side path")

    local mapped, err = diff.right_range(parsed, "huge.lua", 1, 1)
    T.eq(nil, mapped)
    T.match("too large", err)

    local _, rename_err = diff.right_range(parsed, "moved.lua", 1, 1)
    T.match("not a commentable range", rename_err, "an unchanged rename is not a withheld patch")
end)

T.test("GitHub import maps exact, reply, file, and deleted-line comments", function()
    local hunk = table.concat({
        "@@ -1,4 +1,4 @@",
        " one",
        "-old",
        "+new",
        " three",
        " four",
    }, "\n")
    local function comment(overrides)
        local value = {
            id = 1,
            path = "foo.lua",
            line = 3,
            side = "RIGHT",
            body = "Comment",
            html_url = "https://github.com/owner/repo/pull/7#discussion_r1",
            user = { login = "reviewer" },
            diff_hunk = hunk,
        }
        for key, item in pairs(overrides or {}) do
            value[key] = item
        end
        return value
    end
    local reply = comment({ id = 2, in_reply_to_id = 1, body = "Reply" })
    reply.line = vim.NIL
    reply.side = vim.NIL
    local file_comment = comment({ id = 4, subject_type = "file", body = "Whole file" })
    file_comment.line = vim.NIL
    file_comment.side = vim.NIL
    file_comment.original_line = vim.NIL
    local comments = {
        comment(),
        reply,
        comment({ id = 3, line = 2, side = "LEFT", body = "Deleted" }),
        file_comment,
        comment({ id = 5, path = "gone.lua", line = 1, side = "LEFT", body = "Gone" }),
    }
    -- No diff: thread coordinates and the head-commit file are enough.
    local report = github_import.transform(comments, {
        repository = "owner/repo",
        pull_number = 7,
        branch = "review",
        read_file = function(path)
            if path == "foo.lua" then
                return { "one", "new", "three", "four" }
            end
            return nil, "missing"
        end,
    })
    T.eq(4, #report.records)
    T.eq(1, report.unreadable, "only the vanished path needs the changed-file listing")
    T.eq(2, report.exact)
    T.eq(2, report.approximate)
    T.eq(1, #report.skipped)
    T.eq(3, report.records[1].start_line)
    T.eq(3, report.records[2].start_line, "reply must inherit its parent location")
    T.eq(2, report.records[3].start_line, "deleted line must prefer the following surviving line")
    T.eq("approximate", report.records[3].origin.anchor)
    T.eq(1, report.records[4].start_line)
    T.eq("Deleted", report.records[3].text)
end)

T.test("GitHub import follows renames only when the changed-file listing is supplied", function()
    local comments = {
        {
            id = 11,
            path = "old.lua",
            line = 1,
            side = "RIGHT",
            body = "Renamed under the comment",
            user = { login = "reviewer" },
        },
    }
    local options = {
        repository = "owner/repo",
        pull_number = 7,
        branch = "review",
        read_file = function(path)
            if path == "new.lua" then
                return { "one" }
            end
            return nil, "missing"
        end,
    }

    local without = github_import.transform(comments, options)
    T.eq(0, #without.records)
    T.eq(1, without.unreadable)

    options.diff = diff.from_files({
        {
            filename = "new.lua",
            previous_filename = "old.lua",
            status = "renamed",
            changes = 1,
            patch = "@@ -1 +1 @@\n-zero\n+one",
        },
    })
    local with = github_import.transform(comments, options)
    T.eq(1, #with.records)
    T.eq(0, with.unreadable)
    T.eq("new.lua", with.records[1].file)
    T.eq("old.lua", with.records[1].origin.original_path)
end)

T.test("GitHub thread import defaults to unresolved roots and supports all replies", function()
    local hunk = table.concat({
        "@@ -1,4 +1,4 @@",
        " one",
        "-old",
        "+new",
        " three",
        " four",
    }, "\n")
    local parsed = diff.from_files({
        { filename = "foo.lua", status = "modified", changes = 2, patch = hunk },
    })
    local function node(id, body, author)
        return {
            id = "PRRC_" .. id,
            fullDatabaseId = id,
            body = body,
            url = "https://github.com/owner/repo/pull/7#discussion_r" .. id,
            diffHunk = hunk,
            author = { login = author },
        }
    end
    local threads = {
        {
            id = "PRRT_open",
            isResolved = false,
            isOutdated = false,
            path = "foo.lua",
            line = 3,
            diffSide = "RIGHT",
            subjectType = "LINE",
            comments = { nodes = { node("101", "Root", "alice"), node("102", "Reply", "bob") } },
        },
        {
            id = "PRRT_resolved",
            isResolved = true,
            isOutdated = false,
            path = "foo.lua",
            line = 4,
            diffSide = "RIGHT",
            subjectType = "LINE",
            comments = { nodes = { node("103", "Resolved", "carol") } },
        },
        {
            id = "PRRT_outdated",
            isResolved = false,
            isOutdated = true,
            path = "foo.lua",
            line = vim.NIL,
            originalLine = 3,
            diffSide = "RIGHT",
            subjectType = "LINE",
            comments = { nodes = { node("104", "Outdated", "dave") } },
        },
    }
    local options = {
        repository = "owner/repo",
        hostname = "github.com",
        pull_number = 7,
        branch = "review",
        diff = parsed,
        read_file = function()
            return { "one", "new", "three", "four" }
        end,
    }
    local defaults = github_import.transform_threads(threads, options)
    T.eq(2, #defaults.records)
    T.eq(1, defaults.filtered)
    T.eq(2, defaults.threads)
    T.eq("Root", defaults.records[1].text)
    T.eq(1, defaults.records[1].origin.reply_count)
    T.eq(false, defaults.records[1].origin.is_reply)
    T.eq(true, defaults.records[2].origin.outdated)

    options.include_resolved = true
    options.include_replies = true
    local everything = github_import.transform_threads(threads, options)
    T.eq(4, #everything.records)
    T.eq(0, everything.filtered)
    T.eq(true, everything.records[2].origin.is_reply)
    T.eq(true, everything.records[3].origin.resolved)
end)

T.test("GitHub CLI adapter resolves PRs, fetches threads, and resolves a thread asynchronously", function()
    local original_system = vim.system
    local original_executable = vim.fn.executable
    local commands = {}
    local responses = {
        vim.json.encode({
            number = 7,
            url = "https://github.example/owner/repo/pull/7",
            headRefOid = "abc123",
        }),
        vim.json.encode({
            {
                data = {
                    repository = {
                        pullRequest = {
                            reviewThreads = {
                                nodes = {
                                    {
                                        id = "PRRT_1",
                                        comments = {
                                            totalCount = 2,
                                            nodes = { { id = "PRRC_1" } },
                                            pageInfo = { hasNextPage = true, endCursor = "comments-next" },
                                        },
                                    },
                                },
                                pageInfo = { hasNextPage = true, endCursor = "next" },
                            },
                        },
                    },
                },
            },
            {
                data = {
                    repository = {
                        pullRequest = {
                            reviewThreads = {
                                nodes = { { id = "PRRT_2" } },
                                pageInfo = { hasNextPage = false, endCursor = vim.NIL },
                            },
                        },
                    },
                },
            },
        }),
        vim.json.encode({
            {
                data = {
                    node = {
                        comments = {
                            nodes = { { id = "PRRC_2" } },
                            pageInfo = { hasNextPage = false, endCursor = vim.NIL },
                        },
                    },
                },
            },
        }),
        vim.json.encode({
            data = { resolveReviewThread = { thread = { id = "PRRT_1", isResolved = true } } },
        }),
        vim.json.encode({
            { { filename = "first.lua", status = "modified", changes = 1, patch = "@@ -1 +1 @@\n-a\n+b" } },
            { { filename = "second.lua", status = "added", changes = 1, patch = "@@ -0,0 +1 @@\n+c" } },
        }),
    }
    vim.fn.executable = function(command)
        return command == "gh" and 1 or original_executable(command)
    end
    vim.system = function(command, options, callback)
        if command[1] ~= "gh" or not callback then
            return original_system(command, options, callback)
        end
        commands[#commands + 1] = command
        local response = table.remove(responses, 1)
        callback({ code = 0, stdout = response, stderr = "" })
        return {}
    end

    local resolved
    github.resolve("/repo", "7", function(pull_request)
        resolved = pull_request
    end)
    T.truthy(vim.wait(200, function()
        return resolved ~= nil
    end))
    T.eq("owner/repo", resolved.repository)
    T.eq("github.example", resolved.hostname)
    T.eq("abc123", resolved.head_oid)
    T.eq({ "gh", "pr", "view", "7", "--json", "number,url,headRefOid" }, commands[1])

    local threads
    github.fetch_threads("/repo", resolved, function(result)
        threads = result
    end)
    T.truthy(vim.wait(200, function()
        return threads ~= nil
    end))
    T.eq(
        { "PRRT_1", "PRRT_2" },
        vim.tbl_map(function(thread)
            return thread.id
        end, threads)
    )
    T.eq("--hostname", commands[2][#commands[2] - 1])
    T.eq("github.example", commands[2][#commands[2]])
    T.eq({ "PRRC_1", "PRRC_2" }, {
        threads[1].comments.nodes[1].id,
        threads[1].comments.nodes[2].id,
    })
    T.eq("--hostname", commands[3][#commands[3] - 1])
    T.eq("github.example", commands[3][#commands[3]])

    local thread
    github.resolve_thread("/repo", {
        thread_id = "PRRT_1",
        hostname = "github.example",
    }, function(result)
        thread = result
    end)
    T.truthy(vim.wait(200, function()
        return thread ~= nil
    end))

    local files
    github.fetch_files("/repo", resolved, function(result)
        files = result
    end)
    T.truthy(vim.wait(200, function()
        return files ~= nil
    end))
    vim.system = original_system
    vim.fn.executable = original_executable
    T.eq("PRRT_1", thread.id)
    T.eq("--hostname", commands[4][#commands[4] - 1])
    T.eq("github.example", commands[4][#commands[4]])
    T.eq({
        "gh",
        "api",
        "--paginate",
        "--slurp",
        "repos/owner/repo/pulls/7/files?per_page=100",
        "--hostname",
        "github.example",
    }, commands[5], "the whole-diff endpoint refuses diffs over 20000 lines")
    T.eq(
        { "first.lua", "second.lua" },
        vim.tbl_map(function(file)
            return file.filename
        end, files),
        "paginated file listings must be flattened"
    )
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

T.test("clear removes only the current branch and clears its signs", function()
    reset_runtime()
    local root = T.repo()
    local source = root .. "/review.lua"
    T.write(source, "one\ntwo\nthree\n")
    vim.cmd("edit " .. vim.fn.fnameescape(source))

    T.truthy(store.load(root))
    T.truthy(store.add(T.annotation({
        id = "main-one",
        file = "review.lua",
        start_line = 1,
        end_line = 1,
    })))
    T.truthy(store.add(T.annotation({
        id = "main-two",
        file = "review.lua",
        start_line = 2,
        end_line = 2,
    })))
    T.truthy(store.add(T.annotation({
        id = "other",
        branch = "other",
        file = "review.lua",
        start_line = 3,
        end_line = 3,
    })))
    vrv.refresh()
    T.eq(2, #vim.api.nvim_buf_get_extmarks(0, signs.namespace, 0, -1, {}))

    vim.cmd("Vrv clear")
    T.eq(0, #store.for_branch("main"))
    T.eq(
        { "other" },
        vim.tbl_map(function(annotation)
            return annotation.id
        end, store.for_branch("other"))
    )
    T.eq({}, vim.api.nvim_buf_get_extmarks(0, signs.namespace, 0, -1, {}))

    store._reset()
    T.truthy(store.load(root))
    T.eq(
        { "other" },
        vim.tbl_map(function(annotation)
            return annotation.id
        end, store.all())
    )

    vim.cmd("Vrv clear")
    T.eq(
        { "other" },
        vim.tbl_map(function(annotation)
            return annotation.id
        end, store.all()),
        "clearing an empty branch must not affect another branch"
    )
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

    local imported = T.annotation({
        text = "Imported thread",
        origin = T.github_origin({ outdated = true }),
    })
    local imported_entry = picker.make_entry("/project", imported)
    T.eq("[GH~] @reviewer (+2 replies) lua/example.lua:4 — Imported thread", imported_entry.display)
    T.eq(
        "[GH] reply @reviewer ",
        picker._github_label(T.annotation({
            origin = T.github_origin({ is_reply = true }),
        }))
    )
    T.eq(
        "[GH✓] @reviewer (+2 replies) ",
        picker._github_label(T.annotation({
            origin = T.github_origin({ resolved = true }),
        }))
    )

    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "one", "two", "three", "four" })
    T.truthy(signs.place(imported, bufnr))
    local mark = vim.api.nvim_buf_get_extmark_by_id(bufnr, signs.namespace, imported._extmark_id, { details = true })
    T.eq("G", vim.trim(mark[3].sign_text))
    T.eq("VrvGitHubApproximate", mark[3].sign_hl_group)
    vim.api.nvim_buf_delete(bufnr, { force = true })
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
    for _, mapping in ipairs({ " ra", " rd", " re", " rf", " rC", " rE", "]r", "[r" }) do
        T.truthy(vim.fn.maparg(mapping, "n") ~= "", "missing mapping " .. mapping)
    end
    T.truthy(vim.fn.maparg(" ra", "x") ~= "")
    T.truthy(vim.tbl_contains(vim.fn.getcompletion("Vrv export g", "cmdline"), "github"))
    T.truthy(vim.tbl_contains(vim.fn.getcompletion("Vrv import g", "cmdline"), "github"))
    T.truthy(vim.tbl_contains(vim.fn.getcompletion("Vrv import github --", "cmdline"), "--all"))
    T.truthy(vim.tbl_contains(vim.fn.getcompletion("Vrv import github --", "cmdline"), "--replies"))
    T.truthy(vim.tbl_contains(vim.fn.getcompletion("Vrv resolve g", "cmdline"), "github"))

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
