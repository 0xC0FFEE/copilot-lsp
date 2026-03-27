local M = {}
local codediff = require("copilot-lsp.nes.codediff")
local util = require("copilot-lsp.util")

---@param text string
---@return string[]
local function _split_chars(text)
    if text == "" then
        return {}
    end
    return vim.fn.split(text, [[\zs]])
end

---@param left string
---@param right string
---@return string, string, string, string
local function _shared_char_affixes(left, right)
    local left_chars = _split_chars(left)
    local right_chars = _split_chars(right)
    local limit = math.min(#left_chars, #right_chars)

    local prefix_len = 0
    while prefix_len < limit and left_chars[prefix_len + 1] == right_chars[prefix_len + 1] do
        prefix_len = prefix_len + 1
    end

    local suffix_len = 0
    local suffix_limit = limit - prefix_len
    while suffix_len < suffix_limit and left_chars[#left_chars - suffix_len] == right_chars[#right_chars - suffix_len] do
        suffix_len = suffix_len + 1
    end

    local prefix = prefix_len > 0 and table.concat(left_chars, "", 1, prefix_len) or ""
    local suffix = suffix_len > 0 and table.concat(left_chars, "", #left_chars - suffix_len + 1, #left_chars) or ""
    local left_middle = table.concat(left_chars, "", prefix_len + 1, #left_chars - suffix_len)
    local right_middle = table.concat(right_chars, "", prefix_len + 1, #right_chars - suffix_len)

    return prefix, left_middle, right_middle, suffix
end

---@param old_line string
---@param new_line string
---@return copilotlsp.nes.CanonicalLineDiff
function M.canonicalize_line_diff(old_line, new_line)
    local outer_prefix, old_middle, new_middle, outer_suffix = _shared_char_affixes(old_line, new_line)
    local canonical = {
        old_line = old_line,
        new_line = new_line,
        outer_prefix = outer_prefix,
        old_middle = old_middle,
        new_middle = new_middle,
        outer_suffix = outer_suffix,
        old_start_col = #outer_prefix,
        old_end_col = #outer_prefix + #old_middle,
        new_start_col = #outer_prefix,
        new_end_col = #outer_prefix + #new_middle,
    }

    assert(canonical.outer_prefix .. canonical.old_middle .. canonical.outer_suffix == old_line, "Canonical old line must reconstruct exactly")
    assert(canonical.outer_prefix .. canonical.new_middle .. canonical.outer_suffix == new_line, "Canonical new line must reconstruct exactly")

    return canonical
end

---@param line string
---@param start_character integer
---@param end_character integer
---@param new_text string
---@return copilotlsp.nes.CanonicalLineDiff?
function M.extract_change(line, start_character, end_character, new_text)
    if new_text:find("\n", 1, true) then
        return nil
    end

    local transport_start_col = util.character_to_byte_col(line, start_character)
    local transport_end_col = util.character_to_byte_col(line, end_character)
    if transport_start_col > transport_end_col then
        return nil
    end

    local new_line = line:sub(1, transport_start_col) .. new_text .. line:sub(transport_end_col + 1)
    return M.canonicalize_line_diff(line, new_line)
end

---@param line string
---@param utf16_col integer
---@return integer
local function _utf16_1based_to_byte_0based(line, utf16_col)
    -- The real codediff backend reports same-line inner-change columns as
    -- 1-based UTF-16 positions with exclusive end columns. Convert them to
    -- Neovim's 0-based byte columns here, clamping during conversion so
    -- insertion/deletion boundaries stay usable even when the backend is loose.
    return util.character_to_byte_col(line, math.max(utf16_col - 1, 0))
end

---@param line string
---@param range { start_col: integer, end_col: integer }
---@return copilotlsp.nes.BufferByteRange
local function _char_range_to_byte_range(line, range)
    local max_col = #line
    local start_col = math.min(math.max(_utf16_1based_to_byte_0based(line, range.start_col), 0), max_col)
    local end_col = math.min(math.max(_utf16_1based_to_byte_0based(line, range.end_col), 0), max_col)
    if end_col < start_col then
        end_col = start_col
    end
    return {
        start_col = start_col,
        end_col = end_col,
    }
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
---@param changes { start_col: integer, end_col: integer }[]
---@return copilotlsp.nes.BufferByteRange[]
local function _collect_byte_ranges(line, changes)
    local ranges = {}
    for _, change in ipairs(changes) do
        local byte_range = _char_range_to_byte_range(line, change)
        if byte_range.end_col > byte_range.start_col then
            ranges[#ranges + 1] = byte_range
        end
    end
    return _merge_ranges(ranges)
end

---@param change copilotlsp.nes.CanonicalLineDiff
---@return copilotlsp.nes.BufferByteRange[], copilotlsp.nes.BufferByteRange[]
local function _canonical_byte_ranges(change)
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

---@param range? { start_line?: integer, start_col?: integer, end_line?: integer, end_col?: integer }
---@return { start_col: integer, end_col: integer }?
local function _validate_inner_range(range)
    if type(range) ~= "table"
        or range.start_line ~= 1
        or range.end_line ~= 1
        or type(range.start_col) ~= "number"
        or type(range.end_col) ~= "number"
        or range.end_col < range.start_col
    then
        return nil
    end

    return {
        start_col = range.start_col,
        end_col = range.end_col,
    }
end

---@param change copilotlsp.nes.CanonicalLineDiff
---@return copilotlsp.nes.BufferByteRange[]?, copilotlsp.nes.BufferByteRange[]?
local function _diff_byte_ranges(change)
    local diff_result = codediff.compute_diff({ change.old_line }, { change.new_line })
    if not diff_result then
        return nil, nil
    end

    if diff_result.changes ~= nil and type(diff_result.changes) ~= "table" then
        return nil, nil
    end

    local original_changes = {}
    local modified_changes = {}
    for _, mapping in ipairs(diff_result.changes or {}) do
        if type(mapping) ~= "table" or (mapping.inner_changes ~= nil and type(mapping.inner_changes) ~= "table") then
            return nil, nil
        end

        for _, inner in ipairs(mapping.inner_changes or {}) do
            if type(inner) ~= "table" then
                return nil, nil
            end

            local original = _validate_inner_range(inner.original)
            local modified = _validate_inner_range(inner.modified)
            if not original or not modified then
                return nil, nil
            end

            original_changes[#original_changes + 1] = original
            modified_changes[#modified_changes + 1] = modified
        end
    end

    return _collect_byte_ranges(change.old_line, original_changes), _collect_byte_ranges(change.new_line, modified_changes)
end

---@param ranges copilotlsp.nes.BufferByteRange[]
---@param canonical_ranges copilotlsp.nes.BufferByteRange[]
---@return boolean
local function _ranges_fit_canonical(ranges, canonical_ranges)
    if #ranges == 0 or #canonical_ranges == 0 then
        return #ranges == #canonical_ranges
    end

    local lower_bound = canonical_ranges[1].start_col
    local upper_bound = canonical_ranges[#canonical_ranges].end_col
    local prev_end = lower_bound

    for index, range in ipairs(ranges) do
        if type(range.start_col) ~= "number" or type(range.end_col) ~= "number" or range.end_col <= range.start_col then
            return false
        end

        if range.start_col < lower_bound or range.end_col > upper_bound then
            return false
        end

        if index > 1 and range.start_col < prev_end then
            return false
        end

        prev_end = range.end_col
    end

    return true
end

---@param line_number integer
---@param change copilotlsp.nes.CanonicalLineDiff
---@return copilotlsp.nes.InlineDiffPreview?
function M.build_inline_preview(line_number, change)
    if change.old_line == change.new_line then
        return nil
    end

    local canonical_old_ranges, canonical_new_ranges = _canonical_byte_ranges(change)
    local old_ranges, new_ranges = _diff_byte_ranges(change)
    if not old_ranges
        or not new_ranges
        or not _ranges_fit_canonical(old_ranges, canonical_old_ranges)
        or not _ranges_fit_canonical(new_ranges, canonical_new_ranges)
    then
        old_ranges, new_ranges = canonical_old_ranges, canonical_new_ranges
    end

    return {
        line = line_number,
        old_line = change.old_line,
        new_line = change.new_line,
        old_ranges = old_ranges,
        new_ranges = new_ranges,
    }
end

---@param line_number integer
---@param change copilotlsp.nes.CanonicalLineDiff
---@return copilotlsp.nes.InlineEditPreview
function M.build_compact_preview(line_number, change)
    return {
        deletion = {
            range = {
                start_row = line_number,
                start_col = 0,
                end_row = line_number,
                end_col = #change.old_line,
            },
        },
        lines_insertion = {
            text = change.new_line,
            line = line_number,
        },
    }
end

return M
