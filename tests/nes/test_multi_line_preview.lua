local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set()
T["multi_line_preview"] = MiniTest.new_set({
    hooks = {
        pre_case = function()
            child.restart({ "-u", "scripts/minimal_init.lua" })
            child.lua_func(function()
                vim.g.test_codediff_spec = { kind = "missing", message = "codediff unavailable" }
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

        package.loaded["copilot-lsp.nes.codediff"] = nil
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
                    return vim.deepcopy(spec.result)
                end,
            }
        end
    end)
end

local function mapping(orig_start, orig_end, mod_start, mod_end, inner_changes)
    return {
        original = {
            start_line = orig_start,
            end_line = orig_end,
        },
        modified = {
            start_line = mod_start,
            end_line = mod_end,
        },
        inner_changes = inner_changes or {},
    }
end

local function inner_change(orig_start_line, orig_start_col, orig_end_line, orig_end_col, mod_start_line, mod_start_col, mod_end_line, mod_end_col)
    return {
        original = {
            start_line = orig_start_line,
            start_col = orig_start_col,
            end_line = orig_end_line,
            end_col = orig_end_col,
        },
        modified = {
            start_line = mod_start_line,
            start_col = mod_start_col,
            end_line = mod_end_line,
            end_col = mod_end_col,
        },
    }
end

local function diff_result(changes)
    return {
        changes = changes,
        hit_timeout = false,
        moves = {},
    }
end

local function build_preview(start_line, old_lines, new_lines)
    child.g.test_preview_input = {
        start_line = start_line,
        old_lines = old_lines,
        new_lines = new_lines,
    }

    return child.lua_func(function()
        local preview = require("copilot-lsp.nes.multi_line_preview")
        local input = vim.g.test_preview_input
        return preview.build_preview(input.start_line, input.old_lines, input.new_lines)
    end)
end

T["multi_line_preview"]["aligns equal-count multiline replacements with per-line ranges"] = function()
    set_codediff_spec({
        kind = "result",
        result = diff_result({
            mapping(1, 3, 1, 3, {
                inner_change(1, 7, 1, 10, 1, 7, 1, 10),
                inner_change(2, 6, 2, 9, 2, 6, 2, 9),
            }),
        }),
    })

    eq(build_preview(4, { "alpha one", "beta two" }, { "alpha ONE", "beta TWO" }), {
        start_line = 4,
        old_lines = { "alpha one", "beta two" },
        buffer_lines = {
            {
                line = 4,
                text = "alpha one",
                changed_ranges = {
                    { start_col = 6, end_col = 9 },
                },
            },
            {
                line = 5,
                text = "beta two",
                changed_ranges = {
                    { start_col = 5, end_col = 8 },
                },
            },
        },
        virtual_blocks = {
            {
                anchor_line = 4,
                above = false,
                lines = {
                    {
                        text = "alpha ONE",
                        changed_ranges = {
                            { start_col = 6, end_col = 9 },
                        },
                    },
                },
            },
            {
                anchor_line = 5,
                above = false,
                lines = {
                    {
                        text = "beta TWO",
                        changed_ranges = {
                            { start_col = 5, end_col = 8 },
                        },
                    },
                },
            },
        },
    })
end

T["multi_line_preview"]["aligns multiline replacements with different line counts"] = function()
    set_codediff_spec({
        kind = "result",
        result = diff_result({
            mapping(1, 4, 1, 5, {
                inner_change(1, 7, 2, 12, 1, 7, 2, 16),
                inner_change(3, 7, 3, 11, 3, 7, 4, 9),
            }),
        }),
    })

    eq(build_preview(0, { "first line", "second line", "third line" }, {
        "first LINE",
        "inserted middle",
        "third LINE",
        "tail add",
    }), {
        start_line = 0,
        old_lines = { "first line", "second line", "third line" },
        buffer_lines = {
            {
                line = 0,
                text = "first line",
                changed_ranges = {
                    { start_col = 6, end_col = 10 },
                },
            },
            {
                line = 1,
                text = "second line",
                changed_ranges = {
                    { start_col = 0, end_col = 11 },
                },
            },
            {
                line = 2,
                text = "third line",
                changed_ranges = {
                    { start_col = 6, end_col = 10 },
                },
            },
        },
        virtual_blocks = {
            {
                anchor_line = 0,
                above = false,
                lines = {
                    {
                        text = "first LINE",
                        changed_ranges = {
                            { start_col = 6, end_col = 10 },
                        },
                    },
                },
            },
            {
                anchor_line = 1,
                above = false,
                lines = {
                    {
                        text = "inserted middle",
                        changed_ranges = {
                            { start_col = 0, end_col = 15 },
                        },
                    },
                },
            },
            {
                anchor_line = 2,
                above = false,
                lines = {
                    {
                        text = "third LINE",
                        changed_ranges = {
                            { start_col = 6, end_col = 10 },
                        },
                    },
                    {
                        text = "tail add",
                        changed_ranges = {
                            { start_col = 0, end_col = 8 },
                        },
                    },
                },
            },
        },
    })
end

T["multi_line_preview"]["builds pure multiline insertions as grouped virtual blocks"] = function()
    set_codediff_spec({
        kind = "result",
        result = diff_result({
            mapping(2, 2, 2, 4, {
                inner_change(2, 1, 2, 1, 2, 1, 4, 1),
            }),
        }),
    })

    eq(build_preview(0, { "keep", "tail" }, { "keep", "insert a", "insert b", "tail" }), {
        start_line = 0,
        old_lines = { "keep", "tail" },
        buffer_lines = {},
        virtual_blocks = {
            {
                anchor_line = 0,
                above = false,
                lines = {
                    {
                        text = "insert a",
                        changed_ranges = {
                            { start_col = 0, end_col = 8 },
                        },
                    },
                    {
                        text = "insert b",
                        changed_ranges = {
                            { start_col = 0, end_col = 8 },
                        },
                    },
                },
            },
        },
    })
end

T["multi_line_preview"]["builds pure multiline deletions as whole-line old-side highlights"] = function()
    set_codediff_spec({
        kind = "result",
        result = diff_result({
            mapping(2, 4, 2, 2, {
                inner_change(2, 1, 4, 1, 2, 1, 2, 1),
            }),
        }),
    })

    eq(build_preview(0, { "keep", "drop a", "drop b", "tail" }, { "keep", "tail" }), {
        start_line = 0,
        old_lines = { "keep", "drop a", "drop b", "tail" },
        buffer_lines = {
            {
                line = 1,
                text = "drop a",
                changed_ranges = {
                    { start_col = 0, end_col = 6 },
                },
                whole_line = true,
            },
            {
                line = 2,
                text = "drop b",
                changed_ranges = {
                    { start_col = 0, end_col = 6 },
                },
                whole_line = true,
            },
        },
        virtual_blocks = {},
    })
end

T["multi_line_preview"]["real codediff keeps multibyte inner changes in byte space"] = function()
    set_codediff_spec({ kind = "real" })

    eq(build_preview(0, { "a🙂b", "café" }, { "a🙂X", "cafè" }), {
        start_line = 0,
        old_lines = { "a🙂b", "café" },
        buffer_lines = {
            {
                line = 0,
                text = "a🙂b",
                changed_ranges = {
                    { start_col = 5, end_col = 6 },
                },
            },
            {
                line = 1,
                text = "café",
                changed_ranges = {
                    { start_col = 3, end_col = 5 },
                },
            },
        },
        virtual_blocks = {
            {
                anchor_line = 0,
                above = false,
                lines = {
                    {
                        text = "a🙂X",
                        changed_ranges = {
                            { start_col = 5, end_col = 6 },
                        },
                    },
                },
            },
            {
                anchor_line = 1,
                above = false,
                lines = {
                    {
                        text = "cafè",
                        changed_ranges = {
                            { start_col = 3, end_col = 5 },
                        },
                    },
                },
            },
        },
    })
end

return T
