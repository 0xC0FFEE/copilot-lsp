local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set()
T["ui_preview"] = MiniTest.new_set({
    hooks = {
        pre_case = function()
            child.restart({ "-u", "scripts/minimal_init.lua" })
            child.bo.filetype = "txt"
            child.lua_func(function()
                package.loaded["codediff.diff"] = nil
                package.preload["codediff.diff"] = function()
                    error("codediff unavailable")
                end
            end)
        end,
        post_once = child.stop,
    },
})

local function set_content(content)
    child.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(content, "\n", { plain = true }))
end

local function get_content()
    return table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
end

local function utf16_len(text)
    child.g.test_text = text
    return child.lua_func(function()
        return vim.str_utfindex(vim.g.test_text, "utf-16")
    end)
end

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
            error(spec.message)
        end
    end)
end

local function calculate_preview(edit)
    child.g.inline_edit = edit
    return child.lua_func(function()
        return require("copilot-lsp.nes.ui")._calculate_preview(0, vim.g.inline_edit)
    end)
end

local function apply_edit(edit)
    child.g.inline_edit = edit
    child.lua_func(function()
        local bufnr = vim.api.nvim_get_current_buf()
        vim.lsp.util.apply_text_edits({ vim.g.inline_edit }, bufnr, "utf-16")
    end)
end

local function render_preview(preview)
    child.g.inline_preview = preview
    return child.lua_func(function()
        local ns_id = vim.api.nvim_create_namespace("nes-ui-preview-test")
        require("copilot-lsp.nes.ui")._display_preview(0, ns_id, vim.g.inline_preview)
        return vim.api.nvim_buf_get_extmarks(0, ns_id, 0, -1, { details = true })
    end)
end

local function preview_hls(hl)
    return { "CopilotLspNesPreview", hl }
end

local function find_marks(extmarks, key, value)
    local matches = {}
    for _, mark in ipairs(extmarks) do
        local detail = mark[4]
        if detail[key] ~= nil and (value == nil or detail[key] == value) then
            matches[#matches + 1] = mark
        end
    end
    table.sort(matches, function(left, right)
        if left[2] == right[2] then
            return left[3] < right[3]
        end
        return left[2] < right[2]
    end)
    return matches
end

local function find_mark(extmarks, key, value)
    return find_marks(extmarks, key, value)[1]
end

local cases = {
    ["inline insertion"] = {
        content = "123456\nabcdefg\nhijklmn",
        edit = {
            range = {
                start = { line = 1, character = 2 },
                ["end"] = { line = 1, character = 2 },
            },
            newText = "XYZ",
        },
        preview = {
            inline_diff = {
                line = 1,
                old_line = "abcdefg",
                new_line = "abXYZcdefg",
                old_ranges = {},
                new_ranges = {
                    { start_col = 2, end_col = 5 },
                },
            },
        },
        final = "123456\nabXYZcdefg\nhijklmn",
    },
    ["inline deletion"] = {
        content = "123456\nabcdefg\nhijklmn",
        edit = {
            range = {
                start = { line = 1, character = 2 },
                ["end"] = { line = 1, character = 5 },
            },
            newText = "",
        },
        preview = {
            inline_diff = {
                line = 1,
                old_line = "abcdefg",
                new_line = "abfg",
                old_ranges = {
                    { start_col = 2, end_col = 5 },
                },
                new_ranges = {},
            },
        },
        final = "123456\nabfg\nhijklmn",
    },
    ["single line replacement"] = {
        content = "123456\nabcdefg\nhijklmn",
        edit = {
            range = {
                start = { line = 1, character = 0 },
                ["end"] = { line = 1, character = 8 },
            },
            newText = "XXXX",
        },
        preview = {
            inline_diff = {
                line = 1,
                old_line = "abcdefg",
                new_line = "XXXX",
                old_ranges = {
                    { start_col = 0, end_col = 7 },
                },
                new_ranges = {
                    { start_col = 0, end_col = 4 },
                },
            },
        },
        final = "123456\nXXXX\nhijklmn",
    },
    ["multiline replacement fallback"] = {
        content = "123456\nabcdefg\nhijklmn",
        edit = {
            range = {
                start = { line = 0, character = 3 },
                ["end"] = { line = 1, character = 4 },
            },
            newText = "XXXX\nYYY",
        },
        preview = {
            deletion = {
                range = {
                    start_row = 0,
                    start_col = 0,
                    end_row = 1,
                    end_col = 7,
                },
            },
            lines_insertion = {
                line = 1,
                text = "123XXXX\nYYYefg",
            },
        },
        final = "123XXXX\nYYYefg\nhijklmn",
    },
    ["insert lines below"] = {
        content = "123456\nabcdefg\nhijklmn",
        edit = {
            range = {
                start = { line = 1, character = 7 },
                ["end"] = { line = 1, character = 7 },
            },
            newText = "\nXXXX\nYYY",
        },
        preview = {
            lines_insertion = {
                text = "XXXX\nYYY",
                line = 1,
            },
        },
        final = "123456\nabcdefg\nXXXX\nYYY\nhijklmn",
    },
    ["insert lines above"] = {
        content = "123456\nabcdefg\nhijklmn",
        edit = {
            range = {
                start = { line = 1, character = 0 },
                ["end"] = { line = 1, character = 0 },
            },
            newText = "XXXX\nYYY\n",
        },
        preview = {
            lines_insertion = {
                text = "XXXX\nYYY",
                line = 1,
                above = true,
            },
        },
        final = "123456\nXXXX\nYYY\nabcdefg\nhijklmn",
    },
    ["delete lines"] = {
        content = "123456\nabcdefg\nhijklmn",
        edit = {
            range = {
                start = { line = 0, character = 0 },
                ["end"] = { line = 2, character = 0 },
            },
            newText = "",
        },
        preview = {
            deletion = {
                range = {
                    start_row = 0,
                    start_col = 0,
                    end_row = 2,
                    end_col = 0,
                },
            },
        },
        final = "hijklmn",
    },
}

for name, case in pairs(cases) do
    T["ui_preview"][name] = function()
        set_content(case.content)
        local preview = calculate_preview(case.edit)
        eq(preview, case.preview)
        apply_edit(case.edit)
        eq(get_content(), case.final)
    end
end

T["ui_preview"]["full-line transport replacement stays localized"] = function()
    local old_line = [[config.backend = "codex"]]
    local new_line = [[config.backend = "copilot"]]
    set_content(old_line)

    eq(calculate_preview({
        range = {
            start = { line = 0, character = 0 },
            ["end"] = { line = 0, character = utf16_len(old_line) },
        },
        newText = new_line,
    }), {
        inline_diff = {
            line = 0,
            old_line = old_line,
            new_line = new_line,
            old_ranges = {
                { start_col = 20, end_col = 23 },
            },
            new_ranges = {
                { start_col = 20, end_col = 25 },
            },
        },
    })
end

T["ui_preview"]["utf-16 multibyte replacement uses byte ranges"] = function()
    set_content("a🙂b")

    eq(calculate_preview({
        range = {
            start = { line = 0, character = 1 },
            ["end"] = { line = 0, character = 3 },
        },
        newText = "X",
    }), {
        inline_diff = {
            line = 0,
            old_line = "a🙂b",
            new_line = "aXb",
            old_ranges = {
                { start_col = 1, end_col = 5 },
            },
            new_ranges = {
                { start_col = 1, end_col = 2 },
            },
        },
    })
end

T["ui_preview"]["same-line preview highlights buffer text and renders a virtual replacement line"] = function()
    set_content("aXbYc")
    local extmarks = render_preview({
        inline_diff = {
            line = 0,
            old_line = "aXbYc",
            new_line = "a1b2c",
            old_ranges = {
                { start_col = 1, end_col = 2 },
                { start_col = 3, end_col = 4 },
            },
            new_ranges = {
                { start_col = 1, end_col = 2 },
                { start_col = 3, end_col = 4 },
            },
        },
    })

    eq(find_mark(extmarks, "virt_text"), nil)
    local delete_marks = find_marks(extmarks, "hl_group", "CopilotLspNesDelete")
    eq({
        { delete_marks[1][2], delete_marks[1][3], delete_marks[1][4].end_col },
        { delete_marks[2][2], delete_marks[2][3], delete_marks[2][4].end_col },
    }, {
        { 0, 1, 2 },
        { 0, 3, 4 },
    })

    local preview_mark = find_mark(extmarks, "virt_lines")
    eq(preview_mark[4].virt_lines_above, false)
    eq(preview_mark[4].virt_lines, {
        {
            { "a", preview_hls("CopilotLspNesContext") },
            { "1", preview_hls("CopilotLspNesAdd") },
            { "b", preview_hls("CopilotLspNesContext") },
            { "2", preview_hls("CopilotLspNesAdd") },
            { "c", preview_hls("CopilotLspNesContext") },
        },
    })
end

T["ui_preview"]["multibyte inline preview renders shorter replacements without overlay padding"] = function()
    set_content("a🙂b")
    local preview = calculate_preview({
        range = {
            start = { line = 0, character = 1 },
            ["end"] = { line = 0, character = 3 },
        },
        newText = "X",
    })

    local extmarks = render_preview(preview)
    eq(find_mark(extmarks, "virt_text"), nil)

    local delete_mark = find_mark(extmarks, "hl_group", "CopilotLspNesDelete")
    eq({ delete_mark[2], delete_mark[3], delete_mark[4].end_col }, { 0, 1, 5 })

    local preview_mark = find_mark(extmarks, "virt_lines")
    eq(preview_mark[4].virt_lines_above, false)
    eq(preview_mark[4].virt_lines, {
        {
            { "a", preview_hls("CopilotLspNesContext") },
            { "X", preview_hls("CopilotLspNesAdd") },
            { "b", preview_hls("CopilotLspNesContext") },
        },
    })
end

T["ui_preview"]["tabbed inline preview renders shorter replacements without overlay padding"] = function()
    set_content("\tfoobar")
    local preview = calculate_preview({
        range = {
            start = { line = 0, character = 1 },
            ["end"] = { line = 0, character = 7 },
        },
        newText = "x",
    })

    local extmarks = render_preview(preview)
    eq(find_mark(extmarks, "virt_text"), nil)

    local delete_mark = find_mark(extmarks, "hl_group", "CopilotLspNesDelete")
    eq({ delete_mark[2], delete_mark[3], delete_mark[4].end_col }, { 0, 1, 7 })

    local preview_mark = find_mark(extmarks, "virt_lines")
    eq(preview_mark[4].virt_lines_above, false)
    eq(preview_mark[4].virt_lines, {
        {
            { "\t", preview_hls("CopilotLspNesContext") },
            { "x", preview_hls("CopilotLspNesAdd") },
        },
    })
end

T["ui_preview"]["first-line inline previews still create highlight and preview marks"] = function()
    set_content("aaa\nbbb\nccc")
    local preview = calculate_preview({
        range = {
            start = { line = 0, character = 0 },
            ["end"] = { line = 0, character = 3 },
        },
        newText = "xyz",
    })

    local extmarks = render_preview(preview)
    eq(find_mark(extmarks, "virt_lines") ~= nil, true)
    eq(find_mark(extmarks, "hl_group", "CopilotLspNesDelete") ~= nil, true)
    eq(find_mark(extmarks, "virt_text"), nil)
end

T["ui_preview"]["same-line preview skips stale buffer-line overlays"] = function()
    set_content("current")

    local extmarks = render_preview({
        inline_diff = {
            line = 0,
            old_line = "stale",
            new_line = "next",
            old_ranges = {
                { start_col = 0, end_col = 5 },
            },
            new_ranges = {
                { start_col = 0, end_col = 4 },
            },
        },
    })

    eq(extmarks, {})
end

T["ui_preview"]["calculate_preview uses multiline diff payload when codediff is available"] = function()
    set_codediff_spec({ kind = "real" })
    set_content("alpha one\nbeta two")

    eq(calculate_preview({
        range = {
            start = { line = 0, character = 0 },
            ["end"] = { line = 1, character = utf16_len("beta two") },
        },
        newText = "alpha ONE\nbeta TWO",
    }), {
        multi_line_diff = {
            start_line = 0,
            old_lines = { "alpha one", "beta two" },
            buffer_lines = {
                {
                    line = 0,
                    text = "alpha one",
                    changed_ranges = {
                        { start_col = 6, end_col = 9 },
                    },
                },
                {
                    line = 1,
                    text = "beta two",
                    changed_ranges = {
                        { start_col = 5, end_col = 8 },
                    },
                },
            },
            virtual_blocks = {
                {
                    anchor_line = 0,
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
                    anchor_line = 1,
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
        },
    })
end

T["ui_preview"]["multiline diff preview renders grouped virtual blocks and delete highlights"] = function()
    set_content("keep\ndrop a\ndrop b\ntail")

    local extmarks = render_preview({
        multi_line_diff = {
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
        },
    })

    local line_marks = {}
    local range_marks = {}
    for _, mark in ipairs(find_marks(extmarks, "hl_group", "CopilotLspNesDelete")) do
        if mark[4].hl_eol then
            line_marks[#line_marks + 1] = { mark[2], mark[3], mark[4].end_row }
        else
            range_marks[#range_marks + 1] = { mark[2], mark[3], mark[4].end_col }
        end
    end

    eq(line_marks, {
        { 1, 0, 2 },
        { 2, 0, 3 },
    })
    eq(range_marks, {
        { 1, 0, 6 },
        { 2, 0, 6 },
    })

    local preview_mark = find_mark(extmarks, "virt_lines")
    eq(preview_mark[2], 0)
    eq(preview_mark[4].virt_lines_above, false)
    eq(preview_mark[4].virt_lines, {
        {
            { "insert a", preview_hls("CopilotLspNesAdd") },
        },
        {
            { "insert b", preview_hls("CopilotLspNesAdd") },
        },
    })
end

T["ui_preview"]["multiline diff preview skips stale buffer slices"] = function()
    set_content("current one\ncurrent two")

    local extmarks = render_preview({
        multi_line_diff = {
            start_line = 0,
            old_lines = { "stale one", "stale two" },
            buffer_lines = {
                {
                    line = 0,
                    text = "stale one",
                    changed_ranges = {
                        { start_col = 0, end_col = 8 },
                    },
                },
            },
            virtual_blocks = {
                {
                    anchor_line = 0,
                    above = false,
                    lines = {
                        {
                            text = "next one",
                            changed_ranges = {
                                { start_col = 0, end_col = 8 },
                            },
                        },
                    },
                },
            },
        },
    })

    eq(extmarks, {})
end

T["ui_preview"]["cursor_aware_suggestion_clearing"] = function()
    set_content("line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8")

    local edit = {
        range = {
            start = { line = 2, character = 0 },
            ["end"] = { line = 2, character = 0 },
        },
        newText = "suggested text ",
    }

    child.g.test_edit = edit
    child.lua_func(function()
        local ns_id = vim.api.nvim_create_namespace("nes_test")
        require("copilot-lsp.nes.ui")._display_next_suggestion(0, ns_id, { vim.g.test_edit })
    end)

    child.cmd("normal! gg")
    child.cmd("normal! j")
    child.lua_func(function()
        vim.uv.sleep(500)
    end)

    eq(child.lua_func(function()
        return vim.b[0].nes_state ~= nil
    end), true)

    child.cmd("normal! j")
    child.cmd("normal! j")
    child.cmd("normal! j")
    child.cmd("normal! j")
    child.cmd("normal! j")
    child.lua_func(function()
        vim.uv.sleep(500)
    end)

    eq(child.lua_func(function()
        return vim.b[0].nes_state == nil
    end), true)
end

T["ui_preview"]["suggestion_preserves_on_movement_towards"] = function()
    set_content("line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8")
    child.cmd("normal! gg7j")

    local edit = {
        range = {
            start = { line = 2, character = 0 },
            ["end"] = { line = 2, character = 0 },
        },
        newText = "suggested text ",
    }

    child.g.test_edit = edit
    child.lua_func(function()
        local ns_id = vim.api.nvim_create_namespace("nes_test")
        require("copilot-lsp.nes.ui")._display_next_suggestion(0, ns_id, { vim.g.test_edit })
    end)

    child.cmd("normal! 4k")
    child.lua_func(function()
        vim.uv.sleep(500)
    end)

    eq(child.lua_func(function()
        return vim.b[0].nes_state ~= nil
    end), true)
end

T["ui_preview"]["deletions before response"] = function()
    set_content("loooooooooooooooong")
    child.cmd("normal! gg$")

    local edit = {
        range = {
            start = { line = 0, character = 0 },
            ["end"] = { line = 0, character = 19 },
        },
        newText = "long",
    }

    child.cmd("normal! xxxxxxxxxxxxx")
    child.g.inline_edit = edit
    child.lua_func(function()
        local ns_id = vim.api.nvim_create_namespace("nes_test")
        require("copilot-lsp.nes.ui")._display_next_suggestion(0, ns_id, { vim.g.inline_edit })
    end)

    apply_edit(edit)
    eq(get_content(), edit.newText)
end

T["ui_preview"]["new suggestion clears old even when nes_jump is set"] = function()
    set_content("aaa\nbbb\nccc")

    local first_edit = {
        range = {
            start = { line = 0, character = 0 },
            ["end"] = { line = 0, character = 3 },
        },
        newText = "xxx",
    }
    local second_edit = {
        range = {
            start = { line = 1, character = 0 },
            ["end"] = { line = 1, character = 3 },
        },
        newText = "yyy",
    }

    child.g.test_first = first_edit
    child.g.test_second = second_edit
    local result = child.lua_func(function()
        local ns_id = vim.api.nvim_create_namespace("nes_test_jump")
        local ui = require("copilot-lsp.nes.ui")
        ui._display_next_suggestion(0, ns_id, { vim.g.test_first })
        -- Simulate a pending walk_cursor by setting nes_jump
        vim.b[0].nes_jump = true
        ui._display_next_suggestion(0, ns_id, { vim.g.test_second })
        return {
            state_line = vim.b[0].nes_state and vim.b[0].nes_state.range.start.line,
            jump = vim.b[0].nes_jump,
        }
    end)
    eq(result.state_line, 1)
    eq(result.jump, false)
end

T["ui_preview"]["config changes via setup are reflected in cursor clearing"] = function()
    set_content("line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8")

    local edit = {
        range = {
            start = { line = 2, character = 0 },
            ["end"] = { line = 2, character = 0 },
        },
        newText = "suggested text ",
    }

    -- Set a very high threshold so cursor moves don't clear
    child.lua_func(function()
        require("copilot-lsp.config").setup({ nes = { move_count_threshold = 100 } })
    end)

    child.g.test_edit = edit
    child.lua_func(function()
        local ns_id = vim.api.nvim_create_namespace("nes_test_config")
        require("copilot-lsp.nes.ui")._display_next_suggestion(0, ns_id, { vim.g.test_edit })
    end)

    -- Move cursor many times - should NOT clear because threshold is 100
    child.cmd("normal! gg")
    child.cmd("normal! j")
    child.cmd("normal! j")
    child.cmd("normal! j")
    child.cmd("normal! j")
    child.cmd("normal! j")
    child.lua_func(function()
        vim.uv.sleep(500)
    end)

    eq(child.lua_func(function()
        return vim.b[0].nes_state ~= nil
    end), true)
end

T["ui_preview"]["indentation-changing edit highlights entire new line as Add"] = function()
    set_content("    foo")

    local preview = calculate_preview({
        range = {
            start = { line = 0, character = 0 },
            ["end"] = { line = 0, character = utf16_len("    foo") },
        },
        newText = "bar",
    })

    eq(preview.inline_diff.old_ranges, {
        { start_col = 0, end_col = 7 },
    })
    eq(preview.inline_diff.new_ranges, {
        { start_col = 0, end_col = 3 },
    })

    local extmarks = render_preview(preview)
    local preview_mark = find_mark(extmarks, "virt_lines")
    eq(preview_mark[4].virt_lines, {
        {
            { "bar", preview_hls("CopilotLspNesAdd") },
        },
    })
end

T["ui_preview"]["indentation-increasing edit preserves leading whitespace as context"] = function()
    set_content("foo")

    local preview = calculate_preview({
        range = {
            start = { line = 0, character = 0 },
            ["end"] = { line = 0, character = utf16_len("foo") },
        },
        newText = "    bar",
    })

    eq(preview.inline_diff.new_line, "    bar")

    local extmarks = render_preview(preview)
    local preview_mark = find_mark(extmarks, "virt_lines")
    eq(preview_mark[4].virt_lines, {
        {
            { "    bar", preview_hls("CopilotLspNesAdd") },
        },
    })
end

T["ui_preview"]["tab-to-spaces indentation change renders correctly"] = function()
    set_content("\tfoo")

    local preview = calculate_preview({
        range = {
            start = { line = 0, character = 0 },
            ["end"] = { line = 0, character = utf16_len("\tfoo") },
        },
        newText = "  foo",
    })

    eq(preview.inline_diff.old_line, "\tfoo")
    eq(preview.inline_diff.new_line, "  foo")

    local extmarks = render_preview(preview)
    local preview_mark = find_mark(extmarks, "virt_lines")
    eq(preview_mark[4].virt_lines, {
        {
            { "  ", preview_hls("CopilotLspNesAdd") },
            { "foo", preview_hls("CopilotLspNesContext") },
        },
    })
end

T["ui_preview"]["empty old line with insertion renders entire new line as Add"] = function()
    set_content("")

    local preview = calculate_preview({
        range = {
            start = { line = 0, character = 0 },
            ["end"] = { line = 0, character = 0 },
        },
        newText = "hello",
    })

    eq(preview.inline_diff.old_line, "")
    eq(preview.inline_diff.new_line, "hello")
    eq(preview.inline_diff.new_ranges, {
        { start_col = 0, end_col = 5 },
    })

    local extmarks = render_preview(preview)
    local preview_mark = find_mark(extmarks, "virt_lines")
    eq(preview_mark[4].virt_lines, {
        {
            { "hello", preview_hls("CopilotLspNesAdd") },
        },
    })
end

return T
