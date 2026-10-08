-- Unified-diff parsing and line mapping between the diff buffer and the
-- before (LEFT / old) and after (RIGHT / new) sides.
local M = {}

local STATUS_CHAR = {
  added = "A",
  removed = "D",
  modified = "M",
  renamed = "R",
  copied = "C",
  changed = "M",
  unchanged = "-",
}

function M.status_char(status)
  return STATUS_CHAR[status] or "?"
end

--- Parse a GitHub `patch` string into display lines plus mapping tables.
--- Returns { lines, map, rev, hunks, pairs }:
---   map[row]  = { kind = "header"|"hunk"|"meta"|"line", side, line, old, new, context }
---   rev[side][line] = row
---   hunks     = { {old_start, old_len, new_start, new_len}, ... }
---   pairs     = { {old=, new=}, ... } for context lines (used to translate positions)
function M.parse(file)
  local lines, map, hunks, pairs_ = {}, {}, {}, {}
  local rev = { LEFT = {}, RIGHT = {} }

  local function push(text, info)
    lines[#lines + 1] = text
    map[#lines] = info
  end

  push(
    string.format("%s  [%s]  +%d -%d", file.filename, file.status or "?", file.additions or 0, file.deletions or 0),
    { kind = "header" }
  )
  if file.previous_filename then
    push("renamed from " .. file.previous_filename, { kind = "header" })
  end

  if not file.patch or file.patch == "" then
    push("", { kind = "header" })
    push("(no textual diff available: binary file, or diff too large for the API)", { kind = "header" })
    return { lines = lines, map = map, rev = rev, hunks = hunks, pairs = pairs_ }
  end

  local old, new = 0, 0
  local plines = vim.split(file.patch, "\n", { plain = true })
  if plines[#plines] == "" then
    table.remove(plines)
  end
  for _, l in ipairs(plines) do
    local os_, ol, ns, nl = l:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@")
    if os_ then
      old, new = tonumber(os_), tonumber(ns)
      ol = ol == "" and 1 or tonumber(ol)
      nl = nl == "" and 1 or tonumber(nl)
      hunks[#hunks + 1] = { old_start = old, old_len = ol, new_start = new, new_len = nl }
      push(l, { kind = "hunk" })
    else
      local c = l:sub(1, 1)
      if c == "+" then
        push(l, { kind = "line", side = "RIGHT", line = new, new = new })
        rev.RIGHT[new] = #lines
        new = new + 1
      elseif c == "-" then
        push(l, { kind = "line", side = "LEFT", line = old, old = old })
        rev.LEFT[old] = #lines
        old = old + 1
      elseif c == "\\" then
        push(l, { kind = "meta" })
      else
        push(l, { kind = "line", side = "RIGHT", line = new, old = old, new = new, context = true })
        rev.RIGHT[new] = #lines
        if not rev.LEFT[old] then
          rev.LEFT[old] = #lines
        end
        pairs_[#pairs_ + 1] = { old = old, new = new }
        old = old + 1
        new = new + 1
      end
    end
  end
  return { lines = lines, map = map, rev = rev, hunks = hunks, pairs = pairs_ }
end

--- Translate a line number from one side to the other (approximate for
--- lines inside changed regions, exact for context and untouched regions).
function M.translate(parsed, from_side, line)
  local best
  for _, p in ipairs(parsed.pairs) do
    local v = from_side == "RIGHT" and p.new or p.old
    if v <= line then
      best = p
    else
      break
    end
  end
  if not best then
    if #parsed.hunks > 0 then
      local h = parsed.hunks[1]
      local start = from_side == "RIGHT" and h.new_start or h.old_start
      if line >= start then
        return from_side == "RIGHT" and h.old_start or h.new_start
      end
    end
    return line
  end
  local from = from_side == "RIGHT" and best.new or best.old
  local to = from_side == "RIGHT" and best.old or best.new
  return to + (line - from)
end

--- Diff-buffer row for a (side, line); falls back to the nearest row.
function M.row_for(parsed, side, line)
  local exact = parsed.rev[side] and parsed.rev[side][line]
  if exact then
    return exact
  end
  local key = side == "LEFT" and "old" or "new"
  local last_line_row
  for row, info in ipairs(parsed.map) do
    if info.kind == "line" then
      last_line_row = row
      if info[key] and info[key] >= line then
        return row
      end
    end
  end
  return last_line_row or #parsed.map
end

--- (side, line) for a diff-buffer row; searches nearby rows if the row has
--- no position (header / hunk line).
function M.pos_for_row(parsed, row)
  local n = #parsed.map
  for delta = 0, n do
    for _, r in ipairs({ row + delta, row - delta }) do
      local info = parsed.map[r]
      if info and info.kind == "line" then
        return info.side, info.line
      end
    end
  end
  return "RIGHT", 1
end

--- True if the given (side, line) is part of the diff (commentable on GitHub).
function M.in_hunk(parsed, side, line)
  for _, h in ipairs(parsed.hunks) do
    local s = side == "LEFT" and h.old_start or h.new_start
    local len = side == "LEFT" and h.old_len or h.new_len
    if line >= s and line < s + len then
      return true
    end
  end
  return false
end

return M
