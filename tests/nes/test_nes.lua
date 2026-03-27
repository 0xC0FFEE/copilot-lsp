local eq = MiniTest.expect.equality

local child = MiniTest.new_child_neovim()

local T = MiniTest.new_set()
T["nes"] = MiniTest.new_set({
    hooks = {
        pre_case = function()
            child.restart({ "-u", "scripts/minimal_init.lua" })
            child.lua_func(function()
                package.loaded["codediff.diff"] = nil
                package.preload["codediff.diff"] = function()
                    error("codediff unavailable")
                end
                vim.g.copilot_nes_debounce = 450
                vim.lsp.config("copilot_ls", {
                    cmd = require("tests.mock_lsp").server,
                })
                vim.lsp.enable("copilot_ls")
            end)
        end,
        post_once = child.stop,
    },
})

local function request_nes()
    child.lua_func(function()
        local copilot = vim.lsp.get_clients()[1]
        require("copilot-lsp.nes").request_nes(copilot)
    end)
    vim.uv.sleep(500)
end

local function preview_hls(hl)
    return { "CopilotLspNesPreview", hl }
end

local function get_content()
    return table.concat(child.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
end

local function clear_nes()
    return child.lua_func(function()
        return require("copilot-lsp.nes").clear()
    end)
end

local function restore_last_nes()
    return child.lua_func(function()
        return require("copilot-lsp.nes").restore_last_nes()
    end)
end

local function change_current_buffer_line(new_line)
    child.lua_func(function(line)
        vim.api.nvim_buf_set_lines(0, 0, 1, false, { line })
    end, new_line)
end

local function wait_for_active_nes(bufnr, should_exist)
    return child.lua_func(function(target_bufnr, expected)
        vim.wait(1000, function()
            local has_state = vim.b[target_bufnr].nes_state ~= nil
            return has_state == expected
        end)

        return vim.b[target_bufnr].nes_state ~= nil
    end, bufnr or child.api.nvim_get_current_buf(), should_exist)
end

local function extmarks()
    return child.lua_func(function()
        local ns_id = vim.b[0].copilotlsp_nes_namespace_id
        return vim.api.nvim_buf_get_extmarks(0, ns_id, 0, -1, { details = true })
    end)
end

local function find_mark(marks, key, value)
    for _, mark in ipairs(marks) do
        if mark[4][key] ~= nil and (value == nil or mark[4][key] == value) then
            return mark
        end
    end
end

local function buffer_lines()
    return child.api.nvim_buf_get_lines(0, 0, -1, false)
end

T["nes"]["lsp starts"] = function()
    child.cmd("edit tests/fixtures/sameline_edit.txt")
    local lsp_count = child.lua_func(function()
        local count = 0
        for _, _ in pairs(vim.lsp.get_clients()) do
            count = count + 1
        end
        return count
    end)
    eq(lsp_count, 1)
end

T["nes"]["restore_last_nes returns false without saved suggestion"] = function()
    child.cmd("edit tests/fixtures/sameline_edit.txt")

    local result = child.lua_func(function()
        local bufnr = vim.api.nvim_get_current_buf()
        return {
            restored = require("copilot-lsp.nes").restore_last_nes(),
            active = vim.b[bufnr].nes_state ~= nil,
            saved = vim.b[bufnr].copilotlsp_nes_last_state ~= nil,
        }
    end)
    eq(result.restored, false)
    eq(result.active, false)
    eq(result.saved, false)
end

T["nes"]["clear saves last dismissed suggestion"] = function()
    child.cmd("edit tests/fixtures/sameline_edit.txt")
    request_nes()

    local result = child.lua_func(function()
        local bufnr = vim.api.nvim_get_current_buf()
        local state = vim.deepcopy(vim.b[bufnr].nes_state)
        return {
            cleared = require("copilot-lsp.nes").clear(),
            active = vim.b[bufnr].nes_state ~= nil,
            saved = vim.b[bufnr].copilotlsp_nes_last_state ~= nil,
            matches = vim.deep_equal(vim.b[bufnr].copilotlsp_nes_last_state, state),
        }
    end)
    eq(result.cleared, true)
    eq(result.active, false)
    eq(result.saved, true)
    eq(result.matches, true)
end

T["nes"]["restore_last_nes restores dismissed suggestion"] = function()
    child.cmd("edit tests/fixtures/sameline_edit.txt")
    request_nes()
    clear_nes()

    local result = child.lua_func(function()
        local bufnr = vim.api.nvim_get_current_buf()
        local saved = vim.deepcopy(vim.b[bufnr].copilotlsp_nes_last_state)
        return {
            restored = require("copilot-lsp.nes").restore_last_nes(),
            active = vim.b[bufnr].nes_state ~= nil,
            matches = vim.deep_equal(vim.b[bufnr].nes_state, saved),
            second = require("copilot-lsp.nes").restore_last_nes(),
        }
    end)
    eq(result.restored, true)
    eq(result.active, true)
    eq(result.matches, true)
    eq(result.second, false)
end

T["nes"]["apply_pending_nes applies matching version"] = function()
    child.cmd("edit tests/fixtures/sameline_edit.txt")
    request_nes()

    local versions = child.lua_func(function()
        local bufnr = vim.api.nvim_get_current_buf()
        return {
            current = vim.lsp.util.buf_versions[bufnr],
            request = vim.b[bufnr].copilotlsp_nes_state_version,
        }
    end)
    eq(versions.request, versions.current)

    local applied = child.lua_func(function()
        return require("copilot-lsp.nes").apply_pending_nes()
    end)
    eq(applied, true)

    vim.uv.sleep(100)

    eq(get_content(), "xyz\nbbb\nccc")
end

T["nes"]["active NES clears on text change"] = function()
    child.cmd("edit tests/fixtures/sameline_edit.txt")
    request_nes()

    local bufnr = child.api.nvim_get_current_buf()
    change_current_buffer_line("Line one")
    eq(wait_for_active_nes(bufnr, false), false)

    local result = child.lua_func(function()
        local bufnr = vim.api.nvim_get_current_buf()
        return {
            active = vim.b[bufnr].nes_state ~= nil,
            saved = vim.b[bufnr].copilotlsp_nes_last_state ~= nil,
            version = vim.b[bufnr].copilotlsp_nes_state_version,
        }
    end)
    eq(result.active, false)
    eq(result.saved, false)
    eq(result.version, nil)
    eq(get_content(), "Line one\nbbb\nccc")
end

T["nes"]["stale-cleared NES is not restorable"] = function()
    child.cmd("edit tests/fixtures/sameline_edit.txt")
    request_nes()

    local bufnr = child.api.nvim_get_current_buf()
    change_current_buffer_line("Line one")
    eq(wait_for_active_nes(bufnr, false), false)

    local result = child.lua_func(function()
        local bufnr = vim.api.nvim_get_current_buf()
        return {
            restored = require("copilot-lsp.nes").restore_last_nes(),
            active = vim.b[bufnr].nes_state ~= nil,
            saved = vim.b[bufnr].copilotlsp_nes_last_state ~= nil,
        }
    end)
    eq(result.restored, false)
    eq(result.active, false)
    eq(result.saved, false)
    eq(get_content(), "Line one\nbbb\nccc")
end

T["nes"]["restore_last_nes restored suggestion applies"] = function()
    child.cmd("edit tests/fixtures/sameline_edit.txt")
    request_nes()
    clear_nes()

    local restored = restore_last_nes()
    eq(restored, true)

    local applied = child.lua_func(function()
        return require("copilot-lsp.nes").apply_pending_nes()
    end)
    eq(applied, true)

    vim.uv.sleep(100)

    eq(get_content(), "xyz\nbbb\nccc")
end

T["nes"]["restore_last_nes rejects stale saved suggestion"] = function()
    child.cmd("edit tests/fixtures/sameline_edit.txt")
    request_nes()
    clear_nes()

    child.lua_func(function()
        vim.api.nvim_buf_set_lines(0, 0, 1, false, { "Line one" })
    end)

    local result = child.lua_func(function()
        local bufnr = vim.api.nvim_get_current_buf()
        return {
            restored = require("copilot-lsp.nes").restore_last_nes(),
            applied = require("copilot-lsp.nes").apply_pending_nes(),
            active = vim.b[bufnr].nes_state ~= nil,
            saved = vim.b[bufnr].copilotlsp_nes_last_state ~= nil,
        }
    end)
    eq(result.restored, false)
    eq(result.applied, false)
    eq(result.active, false)
    eq(result.saved, false)
    eq(get_content(), "Line one\nbbb\nccc")
end

T["nes"]["text-change stale clear is scoped per buffer"] = function()
    child.cmd("edit tests/fixtures/sameline_edit.txt")
    request_nes()
    child.lua_func(function()
        vim.g.copilotlsp_first_nes_bufnr = vim.api.nvim_get_current_buf()
    end)

    child.cmd("edit tests/fixtures/multiline_edit.txt")
    request_nes()

    local result = child.lua_func(function()
        local first_bufnr = vim.g.copilotlsp_first_nes_bufnr
        local second_bufnr = vim.api.nvim_get_current_buf()

        vim.api.nvim_buf_set_lines(second_bufnr, 0, 1, false, { "changed line" })
        vim.wait(1000, function()
            return vim.b[second_bufnr].nes_state == nil
        end)

        return {
            first_active = vim.b[first_bufnr].nes_state ~= nil,
            second_active = vim.b[second_bufnr].nes_state ~= nil,
        }
    end)

    eq(result.first_active, true)
    eq(result.second_active, false)
end

T["nes"]["restore_last_nes is scoped per buffer"] = function()
    child.cmd("edit tests/fixtures/sameline_edit.txt")
    request_nes()
    clear_nes()

    child.cmd("edit tests/fixtures/multiline_edit.txt")

    local other_result = child.lua_func(function()
        local bufnr = vim.api.nvim_get_current_buf()
        return {
            restored = require("copilot-lsp.nes").restore_last_nes(),
            saved = vim.b[bufnr].copilotlsp_nes_last_state ~= nil,
        }
    end)
    eq(other_result.restored, false)
    eq(other_result.saved, false)

    child.cmd("edit tests/fixtures/sameline_edit.txt")

    local restored = restore_last_nes()
    eq(restored, true)
end

T["nes"]["same line request renders virtual preview and applies edit"] = function()
    child.cmd("edit tests/fixtures/sameline_edit.txt")
    request_nes()

    local marks = extmarks()
    local delete_mark = find_mark(marks, "hl_group", "CopilotLspNesDelete")
    local preview_mark = find_mark(marks, "virt_lines")

    eq(find_mark(marks, "virt_text"), nil)
    eq({ delete_mark[2], delete_mark[3], delete_mark[4].end_col }, { 0, 0, 3 })
    eq(preview_mark[4].virt_lines, {
        {
            { "xyz", preview_hls("CopilotLspNesAdd") },
        },
    })

    child.lua_func(function()
        require("copilot-lsp.nes").apply_pending_nes()
    end)
    vim.uv.sleep(100)

    eq(buffer_lines(), { "xyz", "bbb", "ccc" })
end

T["nes"]["multiline request still applies through transport edit"] = function()
    child.cmd("edit tests/fixtures/multiline_edit.txt")
    request_nes()

    child.lua_func(function()
        require("copilot-lsp.nes").apply_pending_nes()
    end)
    vim.uv.sleep(100)

    eq(buffer_lines(), { "new line one", "new line two", "line three" })
end

T["nes"]["removal request still applies through transport edit"] = function()
    child.cmd("edit tests/fixtures/removal_edit.txt")
    request_nes()

    child.lua_func(function()
        require("copilot-lsp.nes").apply_pending_nes()
    end)
    vim.uv.sleep(100)

    eq(buffer_lines(), { "line one", "line three" })
end

T["nes"]["add-only request still applies through transport edit"] = function()
    child.cmd("edit tests/fixtures/addonly_edit.txt")
    request_nes()

    child.lua_func(function()
        require("copilot-lsp.nes").apply_pending_nes()
    end)
    vim.uv.sleep(100)

    eq(buffer_lines(), { "1 line", "2 line", "line 3", "4 line" })
end

T["nes"]["highlight replacement request uses inline diff preview"] = function()
    child.cmd("edit tests/fixtures/highlight_test.c")
    request_nes()

    local marks = extmarks()
    local delete_mark = find_mark(marks, "hl_group", "CopilotLspNesDelete")
    local preview_mark = find_mark(marks, "virt_lines")

    eq(find_mark(marks, "virt_text"), nil)
    eq(delete_mark ~= nil, true)
    eq(preview_mark[4].virt_lines, {
        {
            { [[  printf("]], preview_hls("CopilotLspNesContext") },
            { [[Goodb]], preview_hls("CopilotLspNesAdd") },
            { [[, %s!\n", name);]], preview_hls("CopilotLspNesContext") },
        },
    })
end

T["nes"]["apply ignores preview artifacts and uses original edit"] = function()
    child.lua_func(function()
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "abcdef" })
        local ns_id = vim.api.nvim_create_namespace("nes_test_apply")
        local ui = require("copilot-lsp.nes.ui")
        local original_calculate_preview = ui._calculate_preview
        ui._calculate_preview = function()
            return {
                inline_diff = {
                    line = 0,
                    old_line = "abcdef",
                    new_line = "WRONG PREVIEW",
                    old_ranges = {
                        { start_col = 0, end_col = 6 },
                    },
                    new_ranges = {
                        { start_col = 0, end_col = 13 },
                    },
                },
            }
        end

        local edit = {
            command = { title = "mock", command = "mock" },
            range = {
                start = { line = 0, character = 2 },
                ["end"] = { line = 0, character = 4 },
            },
            textDocument = { uri = vim.uri_from_fname("/") },
            newText = "ZZ",
            text = "ZZ",
        }

        ui._display_next_suggestion(0, ns_id, { edit })
        require("copilot-lsp.nes").apply_pending_nes(0)
        ui._calculate_preview = original_calculate_preview
    end)

    vim.uv.sleep(100)
    eq(buffer_lines(), { "abZZef" })
end

T["nes"]["walk_cursor_start_edit converts utf-16 columns on unnamed buffers"] = function()
    child.lua_func(function()
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "line one", "a🙂b" })
        vim.b[0].nes_state = {
            command = { title = "mock", command = "mock" },
            range = {
                start = { line = 1, character = 3 },
                ["end"] = { line = 1, character = 4 },
            },
            textDocument = { uri = vim.uri_from_fname("/") },
            newText = "X",
            text = "X",
        }
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        require("copilot-lsp.nes").walk_cursor_start_edit(0)
    end)

    vim.uv.sleep(100)
    eq(child.api.nvim_win_get_cursor(0), { 2, 5 })
end

T["nes"]["walk_cursor_end_edit converts utf-16 columns on unnamed buffers"] = function()
    child.lua_func(function()
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { "line one", "a🙂b" })
        vim.b[0].nes_state = {
            command = { title = "mock", command = "mock" },
            range = {
                start = { line = 1, character = 1 },
                ["end"] = { line = 1, character = 3 },
            },
            textDocument = { uri = vim.uri_from_fname("/") },
            newText = "X",
            text = "X",
        }
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        require("copilot-lsp.nes").walk_cursor_end_edit(0)
    end)

    vim.uv.sleep(100)
    eq(child.api.nvim_win_get_cursor(0), { 2, 5 })
end

T["nes"]["apply_pending_nes on empty buffer"] = function()
    request_nes()
    child.lua_func(function()
        require("copilot-lsp.nes").apply_pending_nes()
    end)
    vim.uv.sleep(100)

    eq(buffer_lines(), { "new line one", "new line two" })
end

return T
