local util = require("copilot-lsp.util")

local M = {}

local MAX_DIFF_MS = 5000
local DIFF_OPTS = {
    ignore_trim_whitespace = false,
    max_computation_time_ms = MAX_DIFF_MS,
    compute_moves = false,
    extend_to_subwords = false,
}

---@return { compute_diff: fun(original_lines: string[], modified_lines: string[], options?: table): table }?
local function _require_backend()
    local has_backend, diff = pcall(require, "codediff.diff")
    if has_backend and type(diff) == "table" and type(diff.compute_diff) == "function" then
        return diff
    end

    local has_core_backend, core_diff = pcall(require, "codediff.core.diff")
    if has_core_backend and type(core_diff) == "table" and type(core_diff.compute_diff) == "function" then
        return core_diff
    end
end

---@param line string
---@param utf16_col integer
---@return integer
local function _utf16_1based_to_byte_0based(line, utf16_col)
    return util.character_to_byte_col(line, math.max(utf16_col - 1, 0))
end

---@param ranges copilotlsp.nes.BufferByteRange[]
---@return copilotlsp.nes.BufferByteRange[]
local function _merge_ranges(ranges)
    table.sort(ranges, function(left, right)
        if left.start_col == right.start_col then
            return left.end_col < right.end_col
        end
        return left.start_col < right.start_col
    end)

    local merged = {}
    for _, range in ipairs(ranges) do
        if range.end_col > range.start_col then
            local prev = merged[#merged]
            if prev and range.start_col <= prev.end_col then
                prev.end_col = math.max(prev.end_col, range.end_col)
            else
                merged[#merged + 1] = {
                    start_col = range.start_col,
                    end_col = range.end_col,
                }
            end
        end
    end

    return merged
end

---@param line string
---@return integer
function M.line_utf16_length(line)
    return vim.str_utfindex(line or "", "utf-16")
end

---@param original_lines string[]
---@param modified_lines string[]
---@return table?
function M.compute_diff(original_lines, modified_lines)
    local diff = _require_backend()
    if not diff then
        return nil
    end

    local ok, diff_result = pcall(diff.compute_diff, original_lines, modified_lines, DIFF_OPTS)
    if not ok or type(diff_result) ~= "table" or diff_result.hit_timeout then
        return nil
    end

    if diff_result.changes ~= nil and type(diff_result.changes) ~= "table" then
        return nil
    end

    return diff_result
end

---@param lines string[]
---@param range? { start_line?: integer, start_col?: integer, end_line?: integer, end_col?: integer }
---@return { line: integer, start_col: integer, end_col: integer }[]?
function M.expand_range_to_line_byte_ranges(lines, range)
    if type(range) ~= "table"
        or type(range.start_line) ~= "number"
        or type(range.end_line) ~= "number"
        or type(range.start_col) ~= "number"
        or type(range.end_col) ~= "number"
        or range.start_line < 1
        or range.end_line < range.start_line
        or (range.start_line == range.end_line and range.end_col < range.start_col)
    then
        return nil
    end

    local line_count = #lines
    if range.start_line > line_count + 1 or range.end_line > line_count + 1 then
        return nil
    end

    if range.start_line == line_count + 1 then
        if range.end_line ~= range.start_line then
            return nil
        end
        return {}
    end

    local expanded = {}
    local last_line = math.min(range.end_line, line_count)
    for line_number = range.start_line, last_line do
        local line = lines[line_number]
        if line == nil then
            return nil
        end

        local start_col = line_number == range.start_line and _utf16_1based_to_byte_0based(line, range.start_col) or 0
        local end_col = line_number == range.end_line and _utf16_1based_to_byte_0based(line, range.end_col) or #line
        start_col = math.min(math.max(start_col, 0), #line)
        end_col = math.min(math.max(end_col, 0), #line)
        if end_col < start_col then
            end_col = start_col
        end

        if end_col > start_col then
            expanded[#expanded + 1] = {
                line = line_number,
                start_col = start_col,
                end_col = end_col,
            }
        end
    end

    return expanded
end

---@param lines string[]
---@param inner_changes table[]?
---@param side "original"|"modified"
---@return table<integer, copilotlsp.nes.BufferByteRange[]>?
function M.collect_line_byte_ranges(lines, inner_changes, side)
    local per_line = {}
    if inner_changes == nil then
        return per_line
    end

    if type(inner_changes) ~= "table" then
        return nil
    end

    for _, inner in ipairs(inner_changes) do
        if type(inner) ~= "table" then
            return nil
        end

        local expanded = M.expand_range_to_line_byte_ranges(lines, inner[side])
        if expanded == nil then
            return nil
        end

        for _, line_range in ipairs(expanded) do
            local ranges = per_line[line_range.line]
            if not ranges then
                ranges = {}
                per_line[line_range.line] = ranges
            end

            ranges[#ranges + 1] = {
                start_col = line_range.start_col,
                end_col = line_range.end_col,
            }
        end
    end

    for line_number, ranges in pairs(per_line) do
        per_line[line_number] = _merge_ranges(ranges)
    end

    return per_line
end

return M
