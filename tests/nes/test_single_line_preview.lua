local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set()
T["single_line_preview"] = MiniTest.new_set({
    hooks = {
        pre_case = function()
            child.restart({ "-u", "scripts/minimal_init.lua" })
            child.g.test_codediff_spec = { kind = "missing", message = "codediff unavailable" }
            child.lua_func(function()
                local spec = vim.g.test_codediff_spec
                package.loaded["codediff.diff"] = nil
                package.preload["codediff.diff"] = function()
                    if spec.kind == "missing" then
                        error(spec.message)
                    end

                    return {
                        compute_diff = function()
                            if spec.kind == "timeout" then
                                return {
                                    changes = spec.changes or {},
                                    hit_timeout = true,
                                }
                            end
                            return vim.deepcopy(spec.result)
                        end,
                    }
                end
            end)
        end,
        post_once = child.stop,
    },
})

local function set_codediff_spec(spec)
    child.g.test_codediff_spec = spec
    child.lua_func(function()
        local spec = vim.g.test_codediff_spec
        local function find_codediff_root()
            local data_dir = vim.fn.stdpath("data")
            local candidates = {
                data_dir .. "/lazy/codediff.nvim",
                data_dir .. "/lazy/vscode-diff.nvim",
            }

            for _, root in ipairs(candidates) do
                if vim.fn.filereadable(root .. "/VERSION") == 1 then
                    return root
                end
            end
        end

        package.loaded["codediff.diff"] = nil
        package.loaded["codediff.core.diff"] = nil
        package.loaded["codediff.core.installer"] = nil
        package.loaded["codediff.core.path"] = nil
        package.loaded["codediff.version"] = nil
        package.preload["codediff.diff"] = nil

        if spec.kind == "real" then
            local root = find_codediff_root()
            if not root then
                error("codediff backend not installed")
            end

            package.path = root .. "/lua/?.lua;" .. root .. "/lua/?/init.lua;" .. package.path
            package.preload["codediff.diff"] = function()
                return require("codediff.core.diff")
            end
            return
        end

        package.preload["codediff.diff"] = function()
            if spec.kind == "missing" then
                error(spec.message)
            end

            return {
                compute_diff = function()
                    if spec.kind == "timeout" then
                        return {
                            changes = spec.changes or {},
                            hit_timeout = true,
                        }
                    end
                    return vim.deepcopy(spec.result)
                end,
            }
        end
    end)
end

local function inner_change(original_start, original_end, modified_start, modified_end)
    return {
        original = {
            start_line = 1,
            start_col = original_start,
            end_line = 1,
            end_col = original_end,
        },
        modified = {
            start_line = 1,
            start_col = modified_start,
            end_line = 1,
            end_col = modified_end,
        },
    }
end

local function diff_result(inner_changes)
    return {
        changes = {
            {
                original = { start_line = 1, end_line = 2 },
                modified = { start_line = 1, end_line = 2 },
                inner_changes = inner_changes,
            },
        },
        hit_timeout = false,
    }
end

local function utf16_len(text)
    child.g.test_text = text
    return child.lua_func(function()
        return vim.str_utfindex(vim.g.test_text, "utf-16")
    end)
end

local function canonicalize_lines(old_line, new_line)
    child.g.test_old_line = old_line
    child.g.test_new_line = new_line
    return child.lua_func(function()
        return require("copilot-lsp.nes.single_line_preview").canonicalize_line_diff(vim.g.test_old_line, vim.g.test_new_line)
    end)
end

local function inspect_inline_preview(line, start_character, end_character, new_text)
    child.g.test_args = {
        line = line,
        start_character = start_character,
        end_character = end_character,
        new_text = new_text,
    }

    return child.lua_func(function()
        local preview = require("copilot-lsp.nes.single_line_preview")
        local args = vim.g.test_args
        local change = preview.extract_change(args.line, args.start_character, args.end_character, args.new_text)
        return {
            change = change,
            inline = change and preview.build_inline_preview(0, change) or nil,
            compact = change and preview.build_compact_preview(0, change) or nil,
        }
    end)
end

local function compute_backend_diff(old_line, new_line)
    set_codediff_spec({ kind = "real" })
    child.g.test_backend_diff = {
        original = { old_line },
        modified = { new_line },
    }

    return child.lua_func(function()
        local diff = require("codediff.diff")
        return diff.compute_diff(vim.g.test_backend_diff.original, vim.g.test_backend_diff.modified, {
            ignore_trim_whitespace = false,
            max_computation_time_ms = 5000,
            compute_moves = false,
            extend_to_subwords = false,
        })
    end)
end

T["single_line_preview"]["canonicalizes minimal replacement from full lines"] = function()
    eq(canonicalize_lines("abcXYZdef", "abc123def"), {
        old_line = "abcXYZdef",
        new_line = "abc123def",
        outer_prefix = "abc",
        old_middle = "XYZ",
        new_middle = "123",
        outer_suffix = "def",
        old_start_col = 3,
        old_end_col = 6,
        new_start_col = 3,
        new_end_col = 6,
    })
end

T["single_line_preview"]["canonicalizes minimal insertion from full lines"] = function()
    eq(canonicalize_lines("foo()", "foo(bar)"), {
        old_line = "foo()",
        new_line = "foo(bar)",
        outer_prefix = "foo(",
        old_middle = "",
        new_middle = "bar",
        outer_suffix = ")",
        old_start_col = 4,
        old_end_col = 4,
        new_start_col = 4,
        new_end_col = 7,
    })
end

T["single_line_preview"]["canonicalizes minimal deletion from full lines"] = function()
    eq(canonicalize_lines("foobar", "foo"), {
        old_line = "foobar",
        new_line = "foo",
        outer_prefix = "foo",
        old_middle = "bar",
        new_middle = "",
        outer_suffix = "",
        old_start_col = 3,
        old_end_col = 6,
        new_start_col = 3,
        new_end_col = 3,
    })
end

T["single_line_preview"]["extract_change canonicalizes multibyte replacements with byte columns"] = function()
    local inspected = inspect_inline_preview("a🙂b", 1, 3, "X")

    eq(inspected.change, {
        old_line = "a🙂b",
        new_line = "aXb",
        outer_prefix = "a",
        old_middle = "🙂",
        new_middle = "X",
        outer_suffix = "b",
        old_start_col = 1,
        old_end_col = 5,
        new_start_col = 1,
        new_end_col = 2,
    })
end

T["single_line_preview"]["extract_change keeps tab-prefixed replacements in byte space"] = function()
    local inspected = inspect_inline_preview("\tfoobar", 1, 7, "x")

    eq(inspected.change, {
        old_line = "\tfoobar",
        new_line = "\tx",
        outer_prefix = "\t",
        old_middle = "foobar",
        new_middle = "x",
        outer_suffix = "",
        old_start_col = 1,
        old_end_col = 7,
        new_start_col = 1,
        new_end_col = 2,
    })
end

T["single_line_preview"]["real codediff reports 1-based exclusive columns for ASCII replacements"] = function()
    local result = compute_backend_diff("hello world", "hello universe")

    eq(result.changes[1].inner_changes[1], {
        original = {
            start_line = 1,
            start_col = 7,
            end_line = 1,
            end_col = 12,
        },
        modified = {
            start_line = 1,
            start_col = 7,
            end_line = 1,
            end_col = 15,
        },
    })
end

T["single_line_preview"]["real codediff reports empty original ranges for insertions"] = function()
    local result = compute_backend_diff("abc", "abXYZc")

    eq(result.changes[1].inner_changes[1], {
        original = {
            start_line = 1,
            start_col = 3,
            end_line = 1,
            end_col = 3,
        },
        modified = {
            start_line = 1,
            start_col = 3,
            end_line = 1,
            end_col = 6,
        },
    })
end

T["single_line_preview"]["real codediff reports empty modified ranges for deletions"] = function()
    local result = compute_backend_diff("abXYZc", "abc")

    eq(result.changes[1].inner_changes[1], {
        original = {
            start_line = 1,
            start_col = 3,
            end_line = 1,
            end_col = 6,
        },
        modified = {
            start_line = 1,
            start_col = 3,
            end_line = 1,
            end_col = 3,
        },
    })
end

T["single_line_preview"]["real codediff uses UTF-16 columns for multibyte replacements"] = function()
    local result = compute_backend_diff("a🙂b", "a🙂X")

    eq(result.changes[1].inner_changes[1], {
        original = {
            start_line = 1,
            start_col = 4,
            end_line = 1,
            end_col = 5,
        },
        modified = {
            start_line = 1,
            start_col = 4,
            end_line = 1,
            end_col = 5,
        },
    })
end

T["single_line_preview"]["build_inline_preview uses codediff to split separated ascii replacements"] = function()
    set_codediff_spec({
        kind = "result",
        result = diff_result({
            inner_change(2, 3, 2, 3),
            inner_change(4, 5, 4, 5),
        }),
    })

    local old_line = "aXbYc"
    local new_line = "a1b2c"
    local inspected = inspect_inline_preview(old_line, 0, utf16_len(old_line), new_line)

    eq(inspected.inline, {
        line = 0,
        old_line = old_line,
        new_line = new_line,
        old_ranges = {
            { start_col = 1, end_col = 2 },
            { start_col = 3, end_col = 4 },
        },
        new_ranges = {
            { start_col = 1, end_col = 2 },
            { start_col = 3, end_col = 4 },
        },
    })
end

T["single_line_preview"]["build_inline_preview localizes insertion with codediff ranges"] = function()
    set_codediff_spec({
        kind = "result",
        result = diff_result({
            inner_change(3, 3, 3, 6),
        }),
    })

    local inspected = inspect_inline_preview("abcdefg", 2, 2, "XYZ")

    eq(inspected.inline, {
        line = 0,
        old_line = "abcdefg",
        new_line = "abXYZcdefg",
        old_ranges = {},
        new_ranges = {
            { start_col = 2, end_col = 5 },
        },
    })
end

T["single_line_preview"]["build_inline_preview normalizes zero-based inner ranges instead of rejecting them"] = function()
    set_codediff_spec({
        kind = "result",
        result = diff_result({
            inner_change(0, 0, 0, 4),
        }),
    })

    local inline = inspect_inline_preview("abc", 0, 0, "XYZ").inline

    eq(inline, {
        line = 0,
        old_line = "abc",
        new_line = "XYZabc",
        old_ranges = {},
        new_ranges = {
            { start_col = 0, end_col = 3 },
        },
    })
end

T["single_line_preview"]["build_inline_preview localizes replacement where new line is longer"] = function()
    set_codediff_spec({
        kind = "result",
        result = diff_result({
            inner_change(21, 24, 21, 26),
        }),
    })

    local old_line = [[config.backend = "codex"]]
    local new_line = [[config.backend = "copilot"]]
    local inspected = inspect_inline_preview(old_line, 0, utf16_len(old_line), new_line)

    eq(inspected.inline, {
        line = 0,
        old_line = old_line,
        new_line = new_line,
        old_ranges = {
            { start_col = 20, end_col = 23 },
        },
        new_ranges = {
            { start_col = 20, end_col = 25 },
        },
    })
end

T["single_line_preview"]["build_inline_preview keeps replacement where new line is shorter in byte ranges"] = function()
    local inspected = inspect_inline_preview("\tfoobar", 1, 7, "x")

    eq(inspected.inline, {
        line = 0,
        old_line = "\tfoobar",
        new_line = "\tx",
        old_ranges = {
            { start_col = 1, end_col = 7 },
        },
        new_ranges = {
            { start_col = 1, end_col = 2 },
        },
    })
end

T["single_line_preview"]["build_inline_preview converts real multibyte backend columns into byte ranges"] = function()
    set_codediff_spec({ kind = "real" })

    local inspected = inspect_inline_preview("a🙂b", 0, utf16_len("a🙂b"), "a🙂X")

    eq(inspected.inline, {
        line = 0,
        old_line = "a🙂b",
        new_line = "a🙂X",
        old_ranges = {
            { start_col = 5, end_col = 6 },
        },
        new_ranges = {
            { start_col = 5, end_col = 6 },
        },
    })
end

T["single_line_preview"]["build_inline_preview keeps pure deletions on the old line only"] = function()
    local inspected = inspect_inline_preview("abcdefg", 2, 5, "")

    eq(inspected.inline, {
        line = 0,
        old_line = "abcdefg",
        new_line = "abfg",
        old_ranges = {
            { start_col = 2, end_col = 5 },
        },
        new_ranges = {},
    })
end

T["single_line_preview"]["build_inline_preview falls back cleanly when codediff is unavailable"] = function()
    local inline = inspect_inline_preview("abcdefg", 2, 5, "XYZ").inline

    eq(inline, {
        line = 0,
        old_line = "abcdefg",
        new_line = "abXYZfg",
        old_ranges = {
            { start_col = 2, end_col = 5 },
        },
        new_ranges = {
            { start_col = 2, end_col = 5 },
        },
    })
end

T["single_line_preview"]["build_inline_preview falls back cleanly on backend timeout"] = function()
    set_codediff_spec({ kind = "timeout" })

    local inline = inspect_inline_preview("abcdefg", 2, 5, "XYZ").inline

    eq(inline, {
        line = 0,
        old_line = "abcdefg",
        new_line = "abXYZfg",
        old_ranges = {
            { start_col = 2, end_col = 5 },
        },
        new_ranges = {
            { start_col = 2, end_col = 5 },
        },
    })
end

T["single_line_preview"]["build_inline_preview falls back on malformed diff ranges"] = function()
    set_codediff_spec({
        kind = "result",
        result = diff_result({
            {
                original = { start_line = 2, start_col = 2, end_line = 2, end_col = 3 },
                modified = { start_line = 1, start_col = 2, end_line = 1, end_col = 3 },
            },
        }),
    })

    local old_line = "aXbYc"
    local new_line = "a1b2c"
    local inline = inspect_inline_preview(old_line, 0, utf16_len(old_line), new_line).inline

    eq(inline, {
        line = 0,
        old_line = old_line,
        new_line = new_line,
        old_ranges = {
            { start_col = 1, end_col = 4 },
        },
        new_ranges = {
            { start_col = 1, end_col = 4 },
        },
    })
end

T["single_line_preview"]["build_inline_preview falls back on contradictory insertion ranges"] = function()
    set_codediff_spec({
        kind = "result",
        result = diff_result({
            inner_change(3, 4, 3, 6),
        }),
    })

    local inline = inspect_inline_preview("abc", 2, 2, "XYZ").inline

    eq(inline, {
        line = 0,
        old_line = "abc",
        new_line = "abXYZc",
        old_ranges = {},
        new_ranges = {
            { start_col = 2, end_col = 5 },
        },
    })
end

T["single_line_preview"]["build_inline_preview returns nil for no-op changes"] = function()
    local inspected = inspect_inline_preview("foo = bar", 6, 9, "bar")

    eq(inspected.change.old_line, inspected.change.new_line)
    eq(inspected.inline, nil)
end

T["single_line_preview"]["large same-line replacements still prefer inline preview"] = function()
    local old_line = string.rep("alpha beta gamma delta ", 6)
    local new_line = string.rep("omega sigma lambda kappa ", 6)
    local inspected = inspect_inline_preview(old_line, 0, utf16_len(old_line), new_line)

    eq(inspected.inline ~= nil, true)
    eq(inspected.inline.old_line, old_line)
    eq(inspected.inline.new_line, new_line)
end

T["single_line_preview"]["compact fallback still uses buffer byte ranges"] = function()
    local inspected = inspect_inline_preview("abcdef", 2, 4, "ZZ")

    eq(inspected.compact, {
        deletion = {
            range = {
                start_row = 0,
                start_col = 0,
                end_row = 0,
                end_col = 6,
            },
        },
        lines_insertion = {
            text = "abZZef",
            line = 0,
        },
    })
end

return T
