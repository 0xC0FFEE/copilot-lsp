local codediff = require("copilot-lsp.nes.codediff")
local single_line_preview = require("copilot-lsp.nes.single_line_preview")
local util = require("copilot-lsp.util")

local M = {}

---@param text string
---@return copilotlsp.nes.BufferByteRange[]
local function _full_line_ranges(text)
    if text == "" then
        return {}
    end

    return {
        {
            start_col = 0,
            end_col = #text,
        },
    }
end

---@param old_line string
---@param new_line string
---@return copilotlsp.nes.BufferByteRange[], copilotlsp.nes.BufferByteRange[]
local function _canonical_line_ranges(old_line, new_line)
    local change = single_line_preview.canonicalize_line_diff(old_line, new_line)
    local old_ranges = {}
    local new_ranges = {}

    if change.old_end_col > change.old_start_col then
        old_ranges[1] = {
            start_col = change.old_start_col,
            end_col = change.old_end_col,
        }
    end

    if change.new_end_col > change.new_start_col then
        new_ranges[1] = {
            start_col = change.new_start_col,
            end_col = change.new_end_col,
        }
    end

    return old_ranges, new_ranges
end

---@param blocks copilotlsp.nes.MultiLineVirtualBlockPreview[]
---@param anchor_line integer
---@param above boolean
---@param text string
---@param changed_ranges copilotlsp.nes.BufferByteRange[]
local function _append_virtual_line(blocks, anchor_line, above, text, changed_ranges)
    local block = blocks[#blocks]
    if not block or block.anchor_line ~= anchor_line or block.above ~= above then
        block = {
            anchor_line = anchor_line,
            above = above,
            lines = {},
        }
        blocks[#blocks + 1] = block
    end

    block.lines[#block.lines + 1] = {
        text = text,
        changed_ranges = vim.deepcopy(changed_ranges),
    }
end

---@param line_count integer
---@param range? { start_line?: integer, end_line?: integer }
---@return boolean
local function _valid_line_mapping(range, line_count)
    return type(range) == "table"
        and type(range.start_line) == "number"
        and type(range.end_line) == "number"
        and range.start_line >= 1
        and range.end_line >= range.start_line
        and range.start_line <= line_count + 1
        and range.end_line <= line_count + 1
end

---@param range? { start_line?: integer, start_col?: integer, end_line?: integer, end_col?: integer }
---@return boolean
local function _valid_inner_range(range)
    return type(range) == "table"
        and type(range.start_line) == "number"
        and type(range.start_col) == "number"
        and type(range.end_line) == "number"
        and type(range.end_col) == "number"
        and range.start_line >= 1
        and range.end_line >= range.start_line
        and (range.start_line ~= range.end_line or range.end_col >= range.start_col)
end

---@param start_line integer
---@param old_lines string[]
---@param new_lines string[]
---@param alignment { orig_start: integer, orig_end: integer, mod_start: integer, mod_end: integer }
---@param old_ranges_by_line table<integer, copilotlsp.nes.BufferByteRange[]>
---@param new_ranges_by_line table<integer, copilotlsp.nes.BufferByteRange[]>
---@param preview copilotlsp.nes.MultiLineDiffPreview
local function _append_alignment(start_line, old_lines, new_lines, alignment, old_ranges_by_line, new_ranges_by_line, preview)
    local orig_len = alignment.orig_end - alignment.orig_start
    local mod_len = alignment.mod_end - alignment.mod_start
    local paired = math.min(orig_len, mod_len)

    for offset = 0, paired - 1 do
        local orig_idx = alignment.orig_start + offset
        local mod_idx = alignment.mod_start + offset
        local old_line = old_lines[orig_idx] or ""
        local new_line = new_lines[mod_idx] or ""
        local old_ranges = vim.deepcopy(old_ranges_by_line[orig_idx] or {})
        local new_ranges = vim.deepcopy(new_ranges_by_line[mod_idx] or {})
        if old_line ~= new_line and #old_ranges == 0 and #new_ranges == 0 then
            old_ranges, new_ranges = _canonical_line_ranges(old_line, new_line)
        end

        if old_line ~= new_line or #old_ranges > 0 or #new_ranges > 0 then
            local buffer_row = start_line + orig_idx - 1
            preview.buffer_lines[#preview.buffer_lines + 1] = {
                line = buffer_row,
                text = old_line,
                changed_ranges = old_ranges,
            }
            _append_virtual_line(preview.virtual_blocks, buffer_row, false, new_line, new_ranges)
        end
    end

    if orig_len > mod_len then
        for orig_idx = alignment.orig_start + paired, alignment.orig_end - 1 do
            local old_line = old_lines[orig_idx] or ""
            preview.buffer_lines[#preview.buffer_lines + 1] = {
                line = start_line + orig_idx - 1,
                text = old_line,
                changed_ranges = _full_line_ranges(old_line),
                whole_line = true,
            }
        end
    elseif mod_len > orig_len then
        local anchor_line
        local above
        if paired > 0 then
            anchor_line = start_line + alignment.orig_start + paired - 2
            above = false
        elseif alignment.orig_start > 1 then
            anchor_line = start_line + alignment.orig_start - 2
            above = false
        else
            anchor_line = start_line
            above = true
        end

        for mod_idx = alignment.mod_start + paired, alignment.mod_end - 1 do
            _append_virtual_line(
                preview.virtual_blocks,
                anchor_line,
                above,
                new_lines[mod_idx] or "",
                _full_line_ranges(new_lines[mod_idx] or "")
            )
        end
    end
end

---@param mapping table
---@param original_lines string[]
---@param modified_lines string[]
---@return { orig_start: integer, orig_end: integer, mod_start: integer, mod_end: integer }[]?
local function _compute_alignments(mapping, original_lines, modified_lines)
    if not _valid_line_mapping(mapping.original, #original_lines) or not _valid_line_mapping(mapping.modified, #modified_lines) then
        return nil
    end

    if mapping.inner_changes ~= nil and type(mapping.inner_changes) ~= "table" then
        return nil
    end

    if not mapping.inner_changes or #mapping.inner_changes == 0 then
        return {
            {
                orig_start = mapping.original.start_line,
                orig_end = mapping.original.end_line,
                mod_start = mapping.modified.start_line,
                mod_end = mapping.modified.end_line,
            },
        }
    end

    local alignments = {}
    local last_orig_line = mapping.original.start_line
    local last_mod_line = mapping.modified.start_line
    local first = true

    local function emit_alignment(orig_line_exclusive, mod_line_exclusive)
        if orig_line_exclusive < last_orig_line or mod_line_exclusive < last_mod_line then
            return
        end

        if first then
            first = false
        elseif orig_line_exclusive == last_orig_line or mod_line_exclusive == last_mod_line then
            return
        end

        local orig_len = orig_line_exclusive - last_orig_line
        local mod_len = mod_line_exclusive - last_mod_line
        if orig_len > 0 or mod_len > 0 then
            alignments[#alignments + 1] = {
                orig_start = last_orig_line,
                orig_end = orig_line_exclusive,
                mod_start = last_mod_line,
                mod_end = mod_line_exclusive,
            }
        end

        last_orig_line = orig_line_exclusive
        last_mod_line = mod_line_exclusive
    end

    for _, inner in ipairs(mapping.inner_changes) do
        if type(inner) ~= "table" or not _valid_inner_range(inner.original) or not _valid_inner_range(inner.modified) then
            return nil
        end

        local orig = inner.original
        local mod = inner.modified
        if orig.start_col > 1 and mod.start_col > 1 then
            emit_alignment(orig.start_line, mod.start_line)
        end

        local orig_line = original_lines[orig.end_line]
        local mod_line = modified_lines[mod.end_line]
        if orig_line == nil and orig.end_line ~= #original_lines + 1 then
            return nil
        end
        if mod_line == nil and mod.end_line ~= #modified_lines + 1 then
            return nil
        end

        if orig.end_line <= #original_lines and mod.end_line <= #modified_lines then
            if orig.end_col <= codediff.line_utf16_length(orig_line or "") and mod.end_col <= codediff.line_utf16_length(mod_line or "") then
                emit_alignment(orig.end_line, mod.end_line)
            end
        end
    end

    emit_alignment(mapping.original.end_line, mapping.modified.end_line)
    return alignments
end

---@param bufnr integer
---@param edit lsp.TextEdit
---@return copilotlsp.nes.MultiLineChange?
function M.extract_change(bufnr, edit)
    local text = edit.newText or edit.text or ""
    local range = edit.range
    local start_line = range.start.line
    local end_line = range["end"].line
    local old_lines = vim.api.nvim_buf_get_lines(bufnr, start_line, end_line + 1, false)
    if #old_lines == 0 then
        return nil
    end

    local start_line_text = old_lines[1] or ""
    local end_line_text = old_lines[#old_lines] or start_line_text
    local start_col = util.character_to_byte_col(start_line_text, range.start.character)
    local end_col = util.character_to_byte_col(end_line_text, range["end"].character)

    local new_lines = vim.split(text, "\n", { plain = true })
    if #new_lines == 0 then
        new_lines = { "" }
    end

    new_lines = vim.deepcopy(new_lines)
    new_lines[1] = start_line_text:sub(1, start_col) .. new_lines[1]
    new_lines[#new_lines] = new_lines[#new_lines] .. end_line_text:sub(end_col + 1)

    return {
        start_line = start_line,
        old_lines = old_lines,
        new_lines = new_lines,
    }
end

---@param start_line integer
---@param old_lines string[]
---@param new_lines string[]
---@return copilotlsp.nes.MultiLineDiffPreview?
function M.build_preview(start_line, old_lines, new_lines)
    if not old_lines or not new_lines or (#old_lines == 1 and #new_lines == 1) or vim.deep_equal(old_lines, new_lines) then
        return nil
    end

    local diff_result = codediff.compute_diff(old_lines, new_lines)
    if not diff_result or type(diff_result.changes) ~= "table" or #diff_result.changes == 0 then
        return nil
    end

    local preview = {
        start_line = start_line,
        old_lines = vim.deepcopy(old_lines),
        buffer_lines = {},
        virtual_blocks = {},
    }

    for _, mapping in ipairs(diff_result.changes) do
        if type(mapping) ~= "table" then
            return nil
        end

        local alignments = _compute_alignments(mapping, old_lines, new_lines)
        if not alignments then
            return nil
        end

        local old_ranges_by_line = codediff.collect_line_byte_ranges(old_lines, mapping.inner_changes, "original")
        local new_ranges_by_line = codediff.collect_line_byte_ranges(new_lines, mapping.inner_changes, "modified")
        if old_ranges_by_line == nil or new_ranges_by_line == nil then
            return nil
        end

        for _, alignment in ipairs(alignments) do
            _append_alignment(start_line, old_lines, new_lines, alignment, old_ranges_by_line, new_ranges_by_line, preview)
        end
    end

    if #preview.buffer_lines == 0 and #preview.virtual_blocks == 0 then
        return nil
    end

    return preview
end

return M
