---@class copilotlsp.InlineEdit : lsp.TextEdit
---@field command lsp.Command
---@field text string
---@field textDocument lsp.VersionedTextDocumentIdentifier

---@class copilotlsp.copilotInlineEditResponse
---@field edits copilotlsp.InlineEdit[]

---@class copilotlsp.nes.BufferByteRange
---@field start_col integer 0-based inclusive byte column
---@field end_col integer 0-based exclusive byte column

---@class copilotlsp.nes.BufferRange
---@field start_row integer 0-based row
---@field start_col integer 0-based inclusive byte column
---@field end_row integer 0-based row
---@field end_col integer 0-based exclusive byte column

---@class copilotlsp.nes.TextDeletion
---@field range copilotlsp.nes.BufferRange

---@class copilotlsp.nes.TextInsertion
---@field text string
---@field line integer insert lines at this line
---@field above? boolean above the line

---@class copilotlsp.nes.CanonicalLineDiff
---@field old_line string Original line text from the buffer. Byte indexed for extmark safety.
---@field new_line string Resulting line after applying the transport edit.
---@field outer_prefix string Maximal shared prefix across `old_line` and `new_line`.
---@field old_middle string Minimal replaced span in `old_line` after canonicalization.
---@field new_middle string Minimal replaced span in `new_line` after canonicalization.
---@field outer_suffix string Maximal shared suffix across `old_line` and `new_line`.
---@field old_start_col integer Byte column where `old_middle` starts in `old_line`.
---@field old_end_col integer Byte column where `old_middle` ends in `old_line`.
---@field new_start_col integer Byte column where `new_middle` starts in `new_line`.
---@field new_end_col integer Byte column where `new_middle` ends in `new_line`.

---Render-only preview payload for a same-line diff.
---`old_line` stays in the real buffer, `new_line` is rendered as a virtual preview
---line below it, and both range lists use byte columns only.
---@class copilotlsp.nes.InlineDiffPreview
---@field line integer
---@field old_line string Original buffer line expected at render time for stale-preview guards.
---@field new_line string
---@field old_ranges copilotlsp.nes.BufferByteRange[]
---@field new_ranges copilotlsp.nes.BufferByteRange[]

---@class copilotlsp.nes.MultiLineChange
---@field start_line integer
---@field old_lines string[]
---@field new_lines string[]

---@class copilotlsp.nes.MultiLineBufferLinePreview
---@field line integer
---@field text string
---@field changed_ranges copilotlsp.nes.BufferByteRange[]
---@field whole_line? boolean

---@class copilotlsp.nes.MultiLineVirtualLinePreview
---@field text string
---@field changed_ranges copilotlsp.nes.BufferByteRange[]

---@class copilotlsp.nes.MultiLineVirtualBlockPreview
---@field anchor_line integer
---@field above? boolean
---@field lines copilotlsp.nes.MultiLineVirtualLinePreview[]

---Render-only preview payload for a multi-line diff.
---The original buffer lines stay in place, `buffer_lines` describe delete-side
---highlights on those lines, and `virtual_blocks` describe the modified-side
---preview rendered with virtual lines.
---@class copilotlsp.nes.MultiLineDiffPreview
---@field start_line integer
---@field old_lines string[] Original buffer slice expected at render time for stale-preview guards.
---@field buffer_lines copilotlsp.nes.MultiLineBufferLinePreview[]
---@field virtual_blocks copilotlsp.nes.MultiLineVirtualBlockPreview[]

---Render-only preview payload derived from the original LSP edit.
---It is never reused as the semantic source of truth when applying edits.
---@class copilotlsp.nes.InlineEditPreview
---@field deletion? copilotlsp.nes.TextDeletion
---@field lines_insertion? copilotlsp.nes.TextInsertion
---@field inline_diff? copilotlsp.nes.InlineDiffPreview
---@field multi_line_diff? copilotlsp.nes.MultiLineDiffPreview
