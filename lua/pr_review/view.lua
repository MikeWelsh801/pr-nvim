-- Review session: buffers, windows, view modes, files panel.
local gh = require("pr_review.gh")
local state = require("pr_review.state")
local diff = require("pr_review.diff")

local M = {}
M.session = nil

local ns_ui = vim.api.nvim_create_namespace("pr_review_ui")

local function cfg()
  return require("pr_review.config").get()
end

local function notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "PR review" })
end
M.notify = notify

local function S()
  return M.session
end

function M.require_session()
  if not M.session then
    notify("No active PR review. Use :PRReview open [number|url]", vim.log.levels.WARN)
    return nil
  end
  return M.session
end

function M.current_file()
  local s = S()
  return s and s.files[s.idx]
end

function M.file_index(path)
  local s = S()
  for i, f in ipairs(s.files) do
    if f.filename == path then
      return i, f
    end
  end
end

function M.parsed(file)
  local s = S()
  s.parsed[file.filename] = s.parsed[file.filename] or diff.parse(file)
  return s.parsed[file.filename]
end

-- ---------------------------------------------------------------------------
-- Buffers
-- ---------------------------------------------------------------------------

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

local function decorate_diff_buf(buf, parsed)
  local show_nums = cfg().diff_line_numbers
  for row, info in ipairs(parsed.map) do
    if info.kind == "header" then
      vim.api.nvim_buf_set_extmark(buf, ns_ui, row - 1, 0, { line_hl_group = "PRReviewHeader" })
    elseif show_nums and info.kind == "line" then
      local o = info.old and string.format("%4d", info.old) or "    "
      local n = info.new and string.format("%4d", info.new) or "    "
      vim.api.nvim_buf_set_extmark(buf, ns_ui, row - 1, 0, {
        virt_text = { { o .. " " .. n .. " ", "LineNr" } },
        virt_text_pos = "inline",
      })
    elseif show_nums and info.kind ~= "line" then
      vim.api.nvim_buf_set_extmark(buf, ns_ui, row - 1, 0, {
        virt_text = { { "          ", "LineNr" } },
        virt_text_pos = "inline",
      })
    end
  end
end

--- Get (creating on demand) the buffer for `file` of kind "diff" | "before" | "after".
function M.get_buf(file, kind)
  local s = S()
  local key = file.filename
  s.bufs[key] = s.bufs[key] or {}
  local b = s.bufs[key][kind]
  if b and vim.api.nvim_buf_is_valid(b) then
    return b
  end

  local lines, ft
  if kind == "diff" then
    lines = M.parsed(file).lines
    ft = "diff"
  else
    local sha = kind == "before" and s.meta.base_sha or s.meta.head_sha
    local path = kind == "before" and (file.previous_filename or file.filename) or file.filename
    if (kind == "before" and file.status == "added") or (kind == "after" and file.status == "removed") then
      lines = {}
    else
      local ok, content = pcall(gh.file_content, s.meta, path, sha)
      if ok then
        lines = vim.split(content, "\n", { plain = true })
        if lines[#lines] == "" then
          table.remove(lines)
        end
      else
        notify(content, vim.log.levels.ERROR)
        lines = { "(could not fetch file)", content }
      end
    end
  end

  b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(b, string.format("prreview://%s/%s", kind, file.filename))
  set_lines(b, lines)
  vim.bo[b].buftype = "nofile"
  vim.bo[b].bufhidden = "hide"
  vim.bo[b].swapfile = false
  vim.bo[b].modifiable = false
  if kind == "diff" then
    vim.bo[b].filetype = "diff"
    decorate_diff_buf(b, M.parsed(file))
  else
    ft = vim.filetype.match({ buf = b, filename = file.filename })
    if ft then
      vim.bo[b].filetype = ft
    end
  end
  vim.b[b].pr_review = { path = file.filename, kind = kind }
  M.apply_keymaps(b)
  s.bufs[key][kind] = b
  return b
end

-- ---------------------------------------------------------------------------
-- Positions
-- ---------------------------------------------------------------------------

--- (side, line) of the cursor in the current window, if it shows a buffer of
--- the current file.
function M.cursor_position()
  local s = S()
  local buf = vim.api.nvim_get_current_buf()
  local info = vim.b[buf].pr_review
  local file = M.current_file()
  if not info or not file or info.path ~= file.filename or info.kind == "panel" then
    return nil
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  if info.kind == "diff" then
    return diff.pos_for_row(M.parsed(file), row)
  elseif info.kind == "before" then
    return "LEFT", row
  else
    return "RIGHT", row
  end
end

--- Resolve buffer rows [s, e] to a GitHub comment location.
function M.resolve_range(buf, s, e)
  local info = vim.b[buf].pr_review
  if not info or info.kind == "panel" then
    return nil
  end
  local _, file = M.file_index(info.path)
  if not file then
    return nil
  end
  if s > e then
    s, e = e, s
  end
  if info.kind == "diff" then
    local parsed = M.parsed(file)
    local first, last
    for row = s, e do
      local m = parsed.map[row]
      if m and m.kind == "line" then
        first = first or m
        last = m
      end
    end
    if not first then
      return nil
    end
    return {
      path = file.filename,
      start_side = first.side,
      start_line = first.line,
      side = last.side,
      line = last.line,
    }
  end
  local side = info.kind == "before" and "LEFT" or "RIGHT"
  return { path = file.filename, start_side = side, start_line = s, side = side, line = e }
end

local function row_for_target(file, kind, target)
  local parsed = M.parsed(file)
  if not target then
    if kind == "diff" then
      return 1
    end
    local h = parsed.hunks[1]
    if h then
      return kind == "before" and h.old_start or h.new_start
    end
    return 1
  end
  if kind == "diff" then
    return diff.row_for(parsed, target.side, target.line)
  end
  local want = kind == "before" and "LEFT" or "RIGHT"
  if target.side == want then
    return target.line
  end
  return diff.translate(parsed, target.side, target.line)
end

local function set_cursor(win, buf, row)
  local n = vim.api.nvim_buf_line_count(buf)
  row = math.max(1, math.min(row or 1, n))
  pcall(vim.api.nvim_win_set_cursor, win, { row, 0 })
end

-- ---------------------------------------------------------------------------
-- Windows / modes
-- ---------------------------------------------------------------------------

local function win_valid(w)
  return w and vim.api.nvim_win_is_valid(w)
end

function M.ensure_main_win()
  local s = S()
  if win_valid(s.win) then
    return s.win
  end
  local cur = vim.api.nvim_get_current_win()
  if cur == s.panel_win or cur == s.list_win or vim.api.nvim_win_get_config(cur).relative ~= "" then
    vim.api.nvim_set_current_win(win_valid(s.panel_win) and s.panel_win or cur)
    vim.cmd("rightbelow vsplit")
    cur = vim.api.nvim_get_current_win()
  end
  s.win = cur
  return cur
end

local function teardown_split()
  local s = S()
  if win_valid(s.split_win) then
    pcall(vim.api.nvim_win_call, s.split_win, function()
      vim.cmd("diffoff")
    end)
    pcall(vim.api.nvim_win_close, s.split_win, true)
  end
  s.split_win = nil
  if win_valid(s.win) then
    pcall(vim.api.nvim_win_call, s.win, function()
      vim.cmd("diffoff")
    end)
  end
end

--- Show the current file in `mode` ("diff" | "before" | "after" | "split"),
--- placing the cursor at `target` = { side =, line = } (defaults to the
--- current cursor position translated across views).
function M.set_mode(mode, target)
  local s = S()
  local file = M.current_file()
  if not file then
    return
  end
  if not target then
    local side, line = M.cursor_position()
    if side then
      target = { side = side, line = line }
    end
  end
  local win = M.ensure_main_win()
  teardown_split()
  s.mode = mode

  if mode == "split" then
    local after = M.get_buf(file, "after")
    local before = M.get_buf(file, "before")
    vim.api.nvim_win_set_buf(win, after)
    vim.api.nvim_set_current_win(win)
    vim.cmd("leftabove vsplit")
    s.split_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(s.split_win, before)
    vim.wo[s.split_win].winfixwidth = false
    vim.api.nvim_win_call(s.split_win, function()
      vim.cmd("diffthis")
    end)
    vim.api.nvim_win_call(win, function()
      vim.cmd("diffthis")
    end)
    set_cursor(s.split_win, before, row_for_target(file, "before", target))
    set_cursor(win, after, row_for_target(file, "after", target))
    vim.api.nvim_set_current_win(win)
  else
    local buf = M.get_buf(file, mode)
    vim.api.nvim_win_set_buf(win, buf)
    set_cursor(win, buf, row_for_target(file, mode, target))
    vim.api.nvim_set_current_win(win)
  end
  require("pr_review.comments").refresh_marks(file)
  M.refresh_panel()
  M.save_progress()
end

--- Switch to file `idx`, optionally in `mode`, at `target`.
function M.show_file(idx, mode, target)
  local s = S()
  local file = s.files[idx]
  if not file then
    notify("No such file", vim.log.levels.WARN)
    return
  end
  local prev = M.current_file()
  if prev and prev ~= file then
    local side, line = M.cursor_position()
    if side then
      s.pos[prev.filename] = { mode = s.mode, side = side, line = line }
    end
    if cfg().auto_mark_viewed then
      s.draft.viewed[prev.filename] = true
    end
  end
  s.idx = idx
  local remembered = s.pos[file.filename]
  mode = mode or (remembered and remembered.mode) or s.mode or "diff"
  target = target or (remembered and { side = remembered.side, line = remembered.line }) or nil
  M.set_mode(mode, target)
end

function M.next_file(delta)
  local s = S()
  local idx = s.idx + delta
  if idx < 1 or idx > #s.files then
    notify(delta > 0 and "Last file" or "First file")
    return
  end
  M.show_file(idx)
end

function M.toggle_side()
  M.set_mode(S().mode == "after" and "before" or "after")
end

function M.next_hunk(delta)
  local s = S()
  local file = M.current_file()
  if not file then
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local info = vim.b[buf].pr_review
  if not info then
    return
  end
  local parsed = M.parsed(file)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  if s.mode == "split" then
    pcall(vim.cmd, "normal! " .. (delta > 0 and "]c" or "[c"))
    return
  end
  local candidates = {}
  if info.kind == "diff" then
    for r, m in ipairs(parsed.map) do
      if m.kind == "hunk" then
        candidates[#candidates + 1] = r
      end
    end
  else
    for _, h in ipairs(parsed.hunks) do
      candidates[#candidates + 1] = info.kind == "before" and h.old_start or h.new_start
    end
  end
  local best
  if delta > 0 then
    for _, r in ipairs(candidates) do
      if r > row then
        best = r
        break
      end
    end
  else
    for _, r in ipairs(candidates) do
      if r < row then
        best = r
      end
    end
  end
  if best then
    set_cursor(0, buf, best)
  else
    notify(delta > 0 and "No next hunk" or "No previous hunk")
  end
end

function M.toggle_viewed(idx)
  local s = S()
  local file = s.files[idx or s.idx]
  if not file then
    return
  end
  s.draft.viewed[file.filename] = not s.draft.viewed[file.filename] or nil
  M.save_progress()
  M.refresh_panel()
end

-- ---------------------------------------------------------------------------
-- Progress
-- ---------------------------------------------------------------------------

function M.save_progress()
  local s = S()
  if not s then
    return
  end
  local file = M.current_file()
  if file then
    local side, line = M.cursor_position()
    s.draft.current = { path = file.filename, mode = s.mode, side = side, line = line }
  end
  if s.submitted then
    return
  end
  state.save(s.meta, s.draft)
end

-- ---------------------------------------------------------------------------
-- Files panel
-- ---------------------------------------------------------------------------

function M.refresh_panel()
  local s = S()
  if not s or not win_valid(s.panel_win) then
    return
  end
  local buf = s.panel_buf
  local lines = {
    string.format("PR #%d: %s", s.meta.number, s.meta.title or ""),
    string.format("%s/%s  %s <- %s", s.meta.owner, s.meta.repo, s.meta.base_ref or "", s.meta.head_ref or ""),
    string.format("%d files  •  %d comments  •  [%s]", #s.files, #s.draft.comments, s.mode),
    "",
  }
  local counts = {}
  for _, c in ipairs(s.draft.comments) do
    counts[c.path] = (counts[c.path] or 0) + 1
  end
  local row_to_idx = {}
  local offset = #lines
  for i, f in ipairs(s.files) do
    local n = counts[f.filename]
    lines[#lines + 1] = string.format(
      "%s %s %s  +%d -%d%s",
      s.draft.viewed[f.filename] and "✓" or " ",
      diff.status_char(f.status),
      f.filename,
      f.additions,
      f.deletions,
      n and ("  ●" .. n) or ""
    )
    row_to_idx[#lines] = i
  end
  set_lines(buf, lines)
  vim.b[buf].pr_review_rows = row_to_idx
  vim.api.nvim_buf_clear_namespace(buf, ns_ui, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, ns_ui, 0, 0, { line_hl_group = "PRReviewHeader" })
  for i, f in ipairs(s.files) do
    local row = offset + i - 1
    local hl = ({ A = "DiffAdd", D = "DiffDelete", M = "DiffChange", R = "DiffText", C = "DiffText" })[diff.status_char(
      f.status
    )]
    if hl then
      vim.api.nvim_buf_set_extmark(buf, ns_ui, row, 2, { end_col = 3, hl_group = hl })
    end
    if s.draft.viewed[f.filename] then
      vim.api.nvim_buf_set_extmark(buf, ns_ui, row, 0, { line_hl_group = "PRReviewViewed" })
    end
    if i == s.idx then
      vim.api.nvim_buf_set_extmark(buf, ns_ui, row, 0, { line_hl_group = "PRReviewCurrent" })
    end
  end
end

function M.toggle_panel()
  local s = M.require_session()
  if not s then
    return
  end
  if win_valid(s.panel_win) then
    vim.api.nvim_win_close(s.panel_win, true)
    s.panel_win = nil
    return
  end
  M.open_panel()
end

function M.open_panel()
  local s = S()
  if win_valid(s.panel_win) then
    M.refresh_panel()
    return
  end
  if not (s.panel_buf and vim.api.nvim_buf_is_valid(s.panel_buf)) then
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "prreview://files")
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = "prreview_files"
    vim.b[buf].pr_review = { kind = "panel" }
    s.panel_buf = buf
    local km = cfg().keymaps
    local function map(lhs, fn, desc)
      vim.keymap.set("n", lhs, fn, { buffer = buf, silent = true, nowait = true, desc = "PR review: " .. desc })
    end
    local function idx_under_cursor()
      local rows = vim.b[buf].pr_review_rows or {}
      return rows[tostring(vim.api.nvim_win_get_cursor(0)[1])] or rows[vim.api.nvim_win_get_cursor(0)[1]]
    end
    map("<CR>", function()
      local i = idx_under_cursor()
      if i then
        M.show_file(i)
      end
    end, "open file")
    map(km.toggle_viewed, function()
      local i = idx_under_cursor()
      if i then
        M.toggle_viewed(i)
      end
    end, "toggle viewed")
    map(km.close, M.toggle_panel, "close panel")
    map(km.files, M.toggle_panel, "close panel")
    map(km.list_comments, function()
      require("pr_review.comments").toggle_list()
    end, "list comments")
    map(km.submit, function()
      require("pr_review.submit").submit()
    end, "submit review")
    map(km.help, M.help, "help")
  end
  local prev = vim.api.nvim_get_current_win()
  vim.cmd("topleft " .. cfg().files_panel_width .. "vsplit")
  s.panel_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(s.panel_win, s.panel_buf)
  local wo = vim.wo[s.panel_win]
  wo.winfixwidth = true
  wo.number = false
  wo.relativenumber = false
  wo.signcolumn = "no"
  wo.cursorline = true
  wo.wrap = false
  wo.foldcolumn = "0"
  wo.statusline = " PR files"
  M.refresh_panel()
  if win_valid(prev) then
    vim.api.nvim_set_current_win(prev)
  end
end

-- ---------------------------------------------------------------------------
-- Keymaps / help
-- ---------------------------------------------------------------------------

function M.apply_keymaps(buf)
  local km = cfg().keymaps
  local comments = require("pr_review.comments")
  local function map(mode, lhs, rhs, desc)
    if lhs and lhs ~= "" then
      vim.keymap.set(mode, lhs, rhs, { buffer = buf, silent = true, nowait = true, desc = "PR review: " .. desc })
    end
  end
  map("n", km.toggle_side, M.toggle_side, "toggle before/after")
  map("n", km.view_diff, function() M.set_mode("diff") end, "unified diff")
  map("n", km.view_split, function() M.set_mode("split") end, "side-by-side diff")
  map("n", km.view_before, function() M.set_mode("before") end, "before (full file)")
  map("n", km.view_after, function() M.set_mode("after") end, "after (full file)")
  map("n", km.next_file, function() M.next_file(1) end, "next file")
  map("n", km.prev_file, function() M.next_file(-1) end, "previous file")
  map("n", km.next_hunk, function() M.next_hunk(1) end, "next hunk")
  map("n", km.prev_hunk, function() M.next_hunk(-1) end, "previous hunk")
  map("n", km.comment, function()
    local r = vim.api.nvim_win_get_cursor(0)[1]
    comments.add_range(r, r)
  end, "comment on line")
  map("x", km.comment, ":<C-u>lua require('pr_review.comments').add_range(vim.fn.line(\"'<\"), vim.fn.line(\"'>\"))<CR>", "comment on selection")
  map("n", km.list_comments, comments.toggle_list, "list comments")
  map("n", km.files, M.toggle_panel, "files panel")
  map("n", km.toggle_viewed, function() M.toggle_viewed() end, "toggle viewed")
  map("n", km.submit, function() require("pr_review.submit").submit() end, "submit review")
  map("n", km.help, M.help, "help")
  map("n", km.close, M.close, "close review")
end

function M.help()
  local km = cfg().keymaps
  local rows = {
    { km.toggle_side, "toggle before / after (full file)" },
    { km.view_diff, "unified diff" },
    { km.view_split, "side-by-side vimdiff (before | after)" },
    { km.view_before, "before (full file)" },
    { km.view_after, "after (full file)" },
    { km.next_file .. " / " .. km.prev_file, "next / previous file" },
    { km.next_hunk .. " / " .. km.prev_hunk, "next / previous hunk" },
    { km.comment, "comment: line (normal) or selection (visual); on an existing comment: edit" },
    { km.list_comments, "list comments (jump / edit / delete)" },
    { km.files, "toggle files panel" },
    { km.toggle_viewed, "toggle file viewed" },
    { km.submit, "submit review (approve / comment / request changes)" },
    { km.close, "close review (progress is saved)" },
    { ":PRReview resume", "pick a saved draft to continue" },
  }
  local lines = {}
  for _, r in ipairs(rows) do
    lines[#lines + 1] = string.format("  %-18s %s", r[1], r[2])
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width + 2,
    height = #lines,
    row = math.floor((vim.o.lines - #lines) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " PR review keys ",
  })
  for _, k in ipairs({ "q", "<Esc>", km.help }) do
    vim.keymap.set("n", k, function()
      pcall(vim.api.nvim_win_close, win, true)
    end, { buffer = buf, nowait = true })
  end
end

-- ---------------------------------------------------------------------------
-- Open / close
-- ---------------------------------------------------------------------------

function M.open(spec)
  if M.session then
    M.close()
  end
  notify("Fetching PR " .. (spec and spec ~= "" and spec or "for current branch") .. " ...")
  vim.cmd("redraw")
  local ok, meta = pcall(gh.pr_meta, spec)
  if not ok then
    notify(meta, vim.log.levels.ERROR)
    return
  end
  local ok2, files = pcall(gh.pr_files, meta)
  if not ok2 then
    notify(files, vim.log.levels.ERROR)
    return
  end
  if #files == 0 then
    notify("PR has no changed files", vim.log.levels.WARN)
    return
  end

  local draft = state.load(meta)
  local resumed = draft ~= nil
  if not draft then
    draft = state.new(meta)
  end

  M.session = {
    meta = meta,
    files = files,
    draft = draft,
    parsed = {},
    bufs = {},
    pos = {},
    idx = 1,
    mode = "diff",
  }
  M.session.win = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_config(M.session.win).relative ~= "" then
    M.session.win = nil
  end

  M.session.augroup = vim.api.nvim_create_augroup("pr_review_session", { clear = true })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = M.session.augroup,
    callback = function()
      pcall(M.save_progress)
    end,
  })
  vim.api.nvim_create_autocmd("CursorHold", {
    group = M.session.augroup,
    pattern = "prreview://*",
    callback = function()
      pcall(M.save_progress)
    end,
  })

  M.open_panel()

  local idx, mode, target = 1, "diff", nil
  if resumed and draft.current and draft.current.path then
    local i = M.file_index(draft.current.path)
    if i then
      idx = i
      mode = draft.current.mode or "diff"
      if draft.current.side and draft.current.line then
        target = { side = draft.current.side, line = draft.current.line }
      end
    end
  end
  M.show_file(idx, mode, target)

  local msg = string.format("PR #%d: %s (%d files)", meta.number, meta.title or "", #files)
  if resumed then
    msg = msg .. string.format(" — resumed draft with %d comment(s)", #draft.comments)
    if draft.head_sha ~= meta.head_sha then
      msg = msg .. "\nPR has new commits since your draft; comment line numbers may be stale."
      notify(msg, vim.log.levels.WARN)
      return
    end
  end
  notify(msg)
end

function M.close()
  local s = M.session
  if not s then
    return
  end
  pcall(M.save_progress)
  teardown_split()
  for _, w in ipairs({ s.list_win, s.panel_win }) do
    if win_valid(w) then
      pcall(vim.api.nvim_win_close, w, true)
    end
  end
  if win_valid(s.win) and #vim.api.nvim_list_wins() > 1 then
    -- leave the main window alone, but drop our buffer from it
    pcall(vim.api.nvim_win_call, s.win, function()
      vim.cmd("enew")
    end)
  elseif win_valid(s.win) then
    pcall(vim.api.nvim_win_call, s.win, function()
      vim.cmd("enew")
    end)
  end
  for _, kinds in pairs(s.bufs) do
    for _, b in pairs(kinds) do
      if vim.api.nvim_buf_is_valid(b) then
        pcall(vim.api.nvim_buf_delete, b, { force = true })
      end
    end
  end
  for _, b in ipairs({ s.panel_buf, s.list_buf }) do
    if b and vim.api.nvim_buf_is_valid(b) then
      pcall(vim.api.nvim_buf_delete, b, { force = true })
    end
  end
  if s.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, s.augroup)
  end
  M.session = nil
  notify("Review closed; progress saved. Reopen with :PRReview open " .. s.meta.number)
end

return M
