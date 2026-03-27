local M = {}
local config_module = require("copilot-lsp.config")
local multi_line_preview = require("copilot-lsp.nes.multi_line_preview")
local single_line_preview = require("copilot-lsp.nes.single_line_preview")
local util = require("copilot-lsp.util")

local PREVIEW_LINE_HL = "CopilotLspNesPreview"

---@param hl_group string
---@return string[]
local function _preview_hl(hl_group)
    return { PREVIEW_LINE_HL, hl_group }
end

---@param text string
---@param changed_ranges copilotlsp.nes.BufferByteRange[]
---@param changed_hl string
---@return [string, string|string[]][]
local function _ranges_to_virt_text(text, changed_ranges, changed_hl)
    local virt_text = {}
    local cursor = 0

    for _, range in ipairs(changed_ranges or {}) do
        local start_col = math.max(0, math.min(range.start_col, #text))
        local end_col = math.max(start_col, math.min(range.end_col, #text))

        if start_col > cursor then
            virt_text[#virt_text + 1] = { text:sub(cursor + 1, start_col), _preview_hl("CopilotLspNesContext") }
        end

        if end_col > start_col then
            virt_text[#virt_text + 1] = { text:sub(start_col + 1, end_col), _preview_hl(changed_hl) }
        end

        cursor = end_col
    end

    if cursor < #text then
        virt_text[#virt_text + 1] = { text:sub(cursor + 1), _preview_hl("CopilotLspNesContext") }
    end

    if #virt_text == 0 then
        virt_text[1] = { "", _preview_hl("CopilotLspNesContext") }
    end

    return virt_text
end

---@param bufnr integer
---@param ns_id integer
---@param line integer
---@param text string
---@param changed_ranges copilotlsp.nes.BufferByteRange[]
---@param hl_group string
local function _highlight_ranges(bufnr, ns_id, line, text, changed_ranges, hl_group)
    for _, range in ipairs(changed_ranges or {}) do
        local start_col = math.max(0, math.min(range.start_col, #text))
        local end_col = math.max(start_col, math.min(range.end_col, #text))
        if end_col > start_col then
            vim.api.nvim_buf_set_extmark(bufnr, ns_id, line, start_col, {
                hl_group = hl_group,
                end_row = line,
                end_col = end_col,
                strict = false,
                priority = 200,
            })
        end
    end
end

---@param bufnr integer
---@param ns_id integer
---@param deletion copilotlsp.nes.TextDeletion
local function _display_deletion(bufnr, ns_id, deletion)
    local range = deletion.range
    local existing_line = vim.api.nvim_buf_get_lines(bufnr, range.end_row, range.end_row + 1, false)[1] or ""
    vim.api.nvim_buf_set_extmark(bufnr, ns_id, range.start_row, range.start_col, {
        hl_group = "CopilotLspNesDelete",
        end_row = range.end_row,
        end_col = math.min(range.end_col, #existing_line),
        strict = false,
        priority = 200,
    })
end

---@param bufnr integer
---@param ns_id integer
---@param line integer
local function _highlight_deleted_line(bufnr, ns_id, line)
    vim.api.nvim_buf_set_extmark(bufnr, ns_id, line, 0, {
        hl_group = "CopilotLspNesDelete",
        end_row = line + 1,
        end_col = 0,
        hl_eol = true,
        strict = false,
        priority = 150,
    })
end

---@param bufnr integer
---@param ns_id integer
---@param preview copilotlsp.nes.InlineDiffPreview
local function _display_inline_diff(bufnr, ns_id, preview)
    local total_lines = vim.api.nvim_buf_line_count(bufnr)
    local line = preview.line
    if line >= total_lines then
        line = math.max(total_lines - 1, 0)
    end

    local buffer_line = vim.api.nvim_buf_get_lines(bufnr, line, line + 1, false)[1] or ""
    if buffer_line ~= preview.old_line then
        -- Same-line byte ranges are computed against the original buffer text.
        -- If the line changed before we rendered, skip the stale overlay instead
        -- of highlighting the wrong spans.
        return
    end

    _highlight_ranges(bufnr, ns_id, line, buffer_line, preview.old_ranges, "CopilotLspNesDelete")

    local virt_text = _ranges_to_virt_text(preview.new_line, preview.new_ranges, "CopilotLspNesAdd")

    vim.api.nvim_buf_set_extmark(bufnr, ns_id, line, 0, {
        virt_lines = { virt_text },
        virt_lines_above = false,
        strict = false,
        priority = 200,
    })
end

---@param bufnr integer
---@param ns_id integer
---@param preview copilotlsp.nes.MultiLineDiffPreview
local function _display_multi_line_diff(bufnr, ns_id, preview)
    local total_lines = vim.api.nvim_buf_line_count(bufnr)
    local end_line = preview.start_line + #preview.old_lines
    if preview.start_line >= total_lines or end_line > total_lines then
        return
    end

    local current_lines = vim.api.nvim_buf_get_lines(bufnr, preview.start_line, end_line, false)
    if not vim.deep_equal(current_lines, preview.old_lines) then
        return
    end

    for _, buffer_line in ipairs(preview.buffer_lines) do
        if buffer_line.line >= 0 and buffer_line.line < total_lines then
            if buffer_line.whole_line then
                _highlight_deleted_line(bufnr, ns_id, buffer_line.line)
            end
            _highlight_ranges(bufnr, ns_id, buffer_line.line, buffer_line.text, buffer_line.changed_ranges, "CopilotLspNesDelete")
        end
    end

    for _, block in ipairs(preview.virtual_blocks) do
        local anchor_line = block.anchor_line
        if anchor_line >= total_lines then
            anchor_line = math.max(total_lines - 1, 0)
        end

        local virt_lines = {}
        for _, line in ipairs(block.lines) do
            virt_lines[#virt_lines + 1] = _ranges_to_virt_text(line.text, line.changed_ranges, "CopilotLspNesAdd")
        end

        if #virt_lines > 0 then
            vim.api.nvim_buf_set_extmark(bufnr, ns_id, anchor_line, 0, {
                virt_lines = virt_lines,
                virt_lines_above = block.above,
                strict = false,
                priority = 200,
            })
        end
    end
end

---@type fun(bufnr: integer): boolean|nil
local stale_checker = nil

---@param cb fun(bufnr: integer): boolean|nil
function M.set_stale_checker(cb)
    stale_checker = cb
end

---@param bufnr integer
---@param ns_id integer
local function _dismiss_suggestion(bufnr, ns_id)
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, ns_id, 0, -1)
end

---@param bufnr integer
local function _ensure_text_change_listener(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) or vim.b[bufnr].copilotlsp_nes_on_lines_attached then
        return
    end

    local attached = vim.api.nvim_buf_attach(bufnr, false, {
        on_lines = function(_, changed_bufnr)
            if stale_checker then
                stale_checker(changed_bufnr)
            end
        end,
        on_detach = function(_, detached_bufnr)
            if vim.api.nvim_buf_is_valid(detached_bufnr) then
                vim.b[detached_bufnr].copilotlsp_nes_on_lines_attached = nil
            end
        end,
    })

    if attached then
        vim.b[bufnr].copilotlsp_nes_on_lines_attached = true
    end
end

---@param bufnr? integer
---@param ns_id integer
---@param save_last? boolean
function M.clear_suggestion(bufnr, ns_id, save_last)
    bufnr = bufnr and bufnr > 0 and bufnr or vim.api.nvim_get_current_buf()
    -- Validate buffer exists before accessing buffer-scoped variables
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return
    end
    if save_last == nil then
        save_last = true
    end
    if vim.b[bufnr].nes_jump then
        vim.b[bufnr].nes_jump = false
        return
    end
    _dismiss_suggestion(bufnr, ns_id)
    ---@type copilotlsp.InlineEdit
    local state = vim.b[bufnr].nes_state
    if not state then
        return
    end

    if save_last then
        vim.b[bufnr].copilotlsp_nes_last_state = vim.deepcopy(state)
        vim.b[bufnr].copilotlsp_nes_last_version = vim.b[bufnr].copilotlsp_nes_state_version
    end

    -- Clear buffer variables
    vim.b[bufnr].nes_state = nil
    vim.b[bufnr].copilotlsp_nes_state_version = nil
    vim.b[bufnr].copilotlsp_nes_cursor_moves = nil
    vim.b[bufnr].copilotlsp_nes_last_line = nil
    vim.b[bufnr].copilotlsp_nes_last_col = nil
end

---@private
---@param bufnr integer
---@param edit lsp.TextEdit
---@return copilotlsp.nes.InlineEditPreview
function M._calculate_preview(bufnr, edit)
    local text = edit.newText or edit.text or ""
    local range = edit.range
    local start_line = range.start.line
    local start_char = range.start.character
    local end_line = range["end"].line
    local end_char = range["end"].character

    -- Split text by newline. Use plain=true to handle trailing newline correctly.
    local new_lines = vim.split(text, "\n", { plain = true })
    local num_new_lines = #new_lines

    local old_lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line + 1, false)
    local num_old_lines = #old_lines
    local start_line_text = old_lines[1] or ""
    local end_line_text = old_lines[num_old_lines] or start_line_text
    local start_col = util.character_to_byte_col(start_line_text, start_char)
    local end_col = util.character_to_byte_col(end_line_text, end_char)

    local is_same_line = start_line == end_line
    local is_deletion = text == ""
    local lines_edit = is_same_line or (start_char == 0 and end_char == 0)
    local is_insertion = is_same_line and start_char == end_char

    if is_deletion and is_insertion then
        -- no-op
        return {}
    end

    if is_same_line and num_new_lines == 1 then
        local change = single_line_preview.extract_change(start_line_text, start_char, end_char, text)
        if change then
            if change.old_line == change.new_line then
                return {}
            end

            local inline_diff = single_line_preview.build_inline_preview(start_line, change)
            if inline_diff then
                return {
                    inline_diff = inline_diff,
                }
            end

            return single_line_preview.build_compact_preview(start_line, change)
        end
    end

    local multi_line_change = multi_line_preview.extract_change(bufnr, edit)
    if multi_line_change then
        local diff_preview = multi_line_preview.build_preview(
            multi_line_change.start_line,
            multi_line_change.old_lines,
            multi_line_change.new_lines
        )
        if diff_preview then
            return {
                multi_line_diff = diff_preview,
            }
        end
    end

    if is_deletion and lines_edit then
        return {
            deletion = {
                range = {
                    start_row = start_line,
                    start_col = start_col,
                    end_row = end_line,
                    end_col = end_col,
                },
            },
        }
    end

    if is_insertion and num_new_lines > 1 then
        if num_old_lines == 0 then
            return {
                lines_insertion = {
                    text = text,
                    line = start_line,
                },
            }
        end

        if start_col == #start_line_text and new_lines[1] == "" then
            -- insert lines after the start line
            return {
                lines_insertion = {
                    text = table.concat(vim.list_slice(new_lines, 2), "\n"),
                    line = start_line,
                },
            }
        end

        if end_col == 0 and new_lines[num_new_lines] == "" then
            -- insert lines before the end line
            return {
                lines_insertion = {
                    text = table.concat(vim.list_slice(new_lines, 1, num_new_lines - 1), "\n"),
                    line = start_line,
                    above = true,
                },
            }
        end
    end

    -- insert lines in the middle
    local prefix = start_line_text:sub(1, start_col)
    local suffix = end_line_text:sub(end_col + 1)
    local new_lines_extend = vim.deepcopy(new_lines)
    new_lines_extend[1] = prefix .. new_lines_extend[1]
    new_lines_extend[num_new_lines] = new_lines_extend[num_new_lines] .. suffix
    local insertion = table.concat(new_lines_extend, "\n")

    return {
        deletion = {
            range = {
                start_row = start_line,
                start_col = 0,
                end_row = end_line,
                end_col = #end_line_text,
            },
        },
        lines_insertion = {
            text = insertion,
            line = end_line,
        },
    }
end

---@private
---@param bufnr integer
---@param ns_id integer
---@param preview copilotlsp.nes.InlineEditPreview
function M._display_preview(bufnr, ns_id, preview)
    local multi_line_diff = preview.multi_line_diff
    if multi_line_diff then
        _display_multi_line_diff(bufnr, ns_id, multi_line_diff)
        return
    end

    local inline_diff = preview.inline_diff
    if inline_diff then
        _display_inline_diff(bufnr, ns_id, inline_diff)
        return
    end

    if preview.deletion then
        _display_deletion(bufnr, ns_id, preview.deletion)
    end

    local lines_insertion = preview.lines_insertion
    if lines_insertion then
        local virt_lines = util.hl_text_to_virt_lines(lines_insertion.text, vim.bo[bufnr].filetype)
        local total_lines = vim.api.nvim_buf_line_count(bufnr)
        local line = lines_insertion.line
        if line >= total_lines then
            line = math.max(total_lines - 1, 0)
        end
        vim.api.nvim_buf_set_extmark(bufnr, ns_id, line, 0, {
            virt_lines = virt_lines,
            virt_lines_above = lines_insertion.above,
            strict = false,
            priority = 200,
        })
    end
end

---@private
---@param bufnr integer
---@param ns_id integer
---@param edits copilotlsp.InlineEdit[]
---@return boolean
function M._display_next_suggestion(bufnr, ns_id, edits)
    bufnr = bufnr and bufnr > 0 and bufnr or vim.api.nvim_get_current_buf()

    -- A pending walk_cursor sets nes_jump to suppress clearing on the next
    -- CursorMoved event.  When a *new* suggestion replaces the old one we must
    -- clear unconditionally, so reset the flag before clear_suggestion.
    if vim.api.nvim_buf_is_valid(bufnr) then
        vim.b[bufnr].nes_jump = false
    end

    M.clear_suggestion(bufnr, ns_id)
    if not edits or #edits == 0 then
        return false
    end

    local transport_edit = vim.deepcopy(edits[1])

    -- Preview payloads are render-only. The original transport edit remains the
    -- single source of truth for apply/accept logic and is stored separately.
    local preview = M._calculate_preview(bufnr, transport_edit)
    M._display_preview(bufnr, ns_id, preview)

    vim.b[bufnr].nes_state = transport_edit

    vim.b[bufnr].copilotlsp_nes_state_version = vim.lsp.util.buf_versions[bufnr]
    vim.b[bufnr].copilotlsp_nes_namespace_id = ns_id
    vim.b[bufnr].copilotlsp_nes_cursor_moves = 1
    _ensure_text_change_listener(bufnr)

    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        buffer = bufnr,
        callback = function()
            if not vim.b[bufnr].nes_state then
                return true
            end

            local config = config_module.config

            -- Get cursor position
            local cursor = vim.api.nvim_win_get_cursor(0)
            local cursor_line = cursor[1] - 1 -- 0-indexed
            local cursor_col = cursor[2]
            local suggestion_line = transport_edit.range.start.line

            -- Store previous position
            local last_line = vim.b[bufnr].copilotlsp_nes_last_line or cursor_line
            local last_col = vim.b[bufnr].copilotlsp_nes_last_col or cursor_col

            -- Update stored position
            vim.b[bufnr].copilotlsp_nes_last_line = cursor_line
            vim.b[bufnr].copilotlsp_nes_last_col = cursor_col

            -- Calculate distance to suggestion
            local line_distance = math.abs(cursor_line - suggestion_line)
            local last_line_distance = math.abs(last_line - suggestion_line)

            -- Check if cursor changed position on same line
            local moved_horizontally = (cursor_line == last_line) and (cursor_col ~= last_col)

            -- Get current mode
            local mode = vim.api.nvim_get_mode().mode

            -- Determine if we should count this movement
            local should_count = false
            local first_char = mode:sub(1, 1)

            -- In insert mode, only count cursor movements, not text changes
            if first_char == "i" then
                if moved_horizontally or line_distance ~= last_line_distance then
                    should_count = true
                end
            elseif first_char == "v" or first_char == "V" or mode == "\22" then
                should_count = true
            -- In normal mode with horizontal movement
            elseif moved_horizontally and config.nes.count_horizontal_moves then
                should_count = true
            -- In normal mode with line changes
            elseif line_distance > last_line_distance then
                should_count = true
            -- Moving toward suggestion in normal mode
            elseif line_distance < last_line_distance and config.nes.reset_on_approaching then
                if line_distance > 1 then -- Don't reset if 0 or 1 line away
                    vim.b[bufnr].copilotlsp_nes_cursor_moves = 0
                end
            end

            -- Update counter if needed
            if should_count then
                vim.b[bufnr].copilotlsp_nes_cursor_moves = (vim.b[bufnr].copilotlsp_nes_cursor_moves or 0) + 1
            end

            -- Clear if counter threshold reached
            if vim.b[bufnr].copilotlsp_nes_cursor_moves >= config.nes.move_count_threshold then
                vim.b[bufnr].copilotlsp_nes_cursor_moves = 0
                vim.schedule(function()
                    M.clear_suggestion(bufnr, ns_id)
                end)
                return true
            end

            -- Optional: Clear on large distance
            if config.nes.clear_on_large_distance and line_distance > config.nes.distance_threshold then
                M.clear_suggestion(bufnr, ns_id)
                return true
            end

            return false -- Keep the autocmd
        end,
    })
    return true
end

return M
