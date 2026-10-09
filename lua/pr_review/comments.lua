-- Draft comments: editor, marks, list.
local state = require("pr_review.state")
local diff = require("pr_review.diff")

local M = {}
local ns = vim.api.nvim_create_namespace("pr_review_comments")
local editor_seq = 0

local function cfg()
  return require("pr_review.config").get()
end

local function view()
  return require("pr_review.view")
end

local function notify(msg, level)
  view().notify(msg, level)
end

local function first_line(body)
  local l = vim.split(body or "", "\n", { plain = true })[1] or ""
  if #l > 60 then
    l = l:sub(1, 57) .. "..."
  end
  return l
end

local function snippet(body)
  local lines = vim.split(body or "", "\n", { plain = true })
  local l = lines[1] or ""
  if #lines > 1 then
    l = l .. " (+" .. (#lines - 1) .. " lines)"
  end
  return l
end

-- ---------------------------------------------------------------------------
-- Editor (floating markdown buffer)
-- ---------------------------------------------------------------------------

--- opts: { title, body, cursor, on_save(body), on_close(saved_body) }
--- :w / <C-s> saves, q closes (asks if unsaved), :wq saves and closes.
function M.open_editor(opts)
  editor_seq = editor_seq + 1
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, "prreview://editor/" .. editor_seq)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "markdown"
  local body = opts.body or ""
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, body ~= "" and vim.split(body, "\n", { plain = true }) or {})
  vim.bo[buf].modified = false

  local e = cfg().editor
  local width = math.max(40, math.floor(vim.o.columns * e.width))
  local height = math.max(5, math.floor(vim.o.lines * e.height))
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2) - 1,
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. (opts.title or "Comment") .. " ",
    footer = " :w save • q close • :wq both ",
    footer_pos = "right",
  })
  vim.wo[win].wrap = true
  vim.wo[win].linebreak = true
  vim.wo[win].number = false
  vim.wo[win].signcolumn = "no"

  local last_saved = body
  local function save()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    while #lines > 0 and vim.trim(lines[#lines]) == "" do
      table.remove(lines)
    end
    local text = table.concat(lines, "\n")
    local ok, err = pcall(opts.on_save, text)
    if ok then
      last_saved = text
      vim.bo[buf].modified = false
    else
      notify(tostring(err), vim.log.levels.ERROR)
    end
  end
  local function close(force)
    if vim.bo[buf].modified and not force then
      local choice = vim.fn.confirm("Comment has unsaved changes.", "&Save\n&Discard\n&Cancel", 1)
      if choice == 1 then
        save()
      elseif choice ~= 2 then
        return
      end
    end
    pcall(vim.api.nvim_win_close, win, true)
  end

  vim.api.nvim_create_autocmd("BufWriteCmd", { buffer = buf, callback = save })
  vim.api.nvim_create_autocmd("WinClosed", {
    pattern = tostring(win),
    once = true,
    callback = function()
      if opts.on_close then
        vim.schedule(function()
          opts.on_close(last_saved)
        end)
      end
    end,
  })
  vim.keymap.set("n", "q", function() close(false) end, { buffer = buf, nowait = true })
  vim.keymap.set({ "n", "i" }, "<C-s>", function()
    save()
    vim.cmd("stopinsert")
  end, { buffer = buf })
  if opts.cursor then
    pcall(vim.api.nvim_win_set_cursor, win, opts.cursor)
  elseif body == "" then
    vim.cmd("startinsert")
  end
  return buf, win
end

-- ---------------------------------------------------------------------------
-- CRUD
-- ---------------------------------------------------------------------------

function M.find_at(path, side, line)
  local s = view().session
  for _, c in ipairs(s.draft.comments) do
    if c.path == path then
      local lo = math.min(c.start_line or c.line, c.line)
      if (c.side == side or c.start_side == side) and line >= lo and line <= c.line then
        return c
      end
    end
  end
end

function M.find_by_id(id)
  local s = view().session
  for i, c in ipairs(s.draft.comments) do
    if c.id == id then
      return c, i
    end
  end
end

local function location_label(loc)
  local range = loc.start_line ~= loc.line and (loc.start_line .. "-" .. loc.line) or tostring(loc.line)
  return string.format("%s:%s (%s)", loc.path, range, loc.side == "LEFT" and "old" or "new")
end

function M.after_change()
  local s = view().session
  s.submitted = false
  state.save(s.meta, s.draft)
  for _, f in ipairs(s.files) do
    if s.bufs[f.filename] then
      M.refresh_marks(f)
    end
  end
  view().refresh_panel()
  M.refresh_list()
end

--- Comment on buffer rows [s, e] of the current review buffer.
--- With `suggest`, pre-fill a ```suggestion block with the lines' current content.
function M.add_range(s, e, suggest)
  local sess = view().require_session()
  if not sess then
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local loc = view().resolve_range(buf, s, e)
  if not loc then
    notify("No diff lines in the selection", vim.log.levels.WARN)
    return
  end
  if s == e and not suggest then
    local existing = M.find_at(loc.path, loc.side, loc.line)
    if existing then
      return M.edit(existing)
    end
  end
  local _, file = view().file_index(loc.path)
  local body = ""
  if suggest then
    if loc.side ~= "RIGHT" or loc.start_side ~= "RIGHT" then
      notify("Suggestions can only target lines on the new (after) side", vim.log.levels.WARN)
      return
    end
    local after = view().get_buf(file, "after")
    local code = vim.api.nvim_buf_get_lines(after, loc.start_line - 1, loc.line, false)
    body = "```suggestion\n" .. table.concat(code, "\n") .. "\n```"
  end
  local outside = not diff.in_hunk(view().parsed(file), loc.side, loc.line)
  M.open_editor({
    title = (suggest and "New suggestion " or "New comment ") .. location_label(loc) .. (outside and " [outside diff]" or ""),
    body = body,
    cursor = suggest and { 2, 0 } or nil,
    on_save = function(body)
      if vim.trim(body) == "" then
        error("empty comment not saved", 0)
      end
      if loc.id then
        local c = M.find_by_id(loc.id)
        if c then
          c.body = body
        end
      else
        loc.id = sess.draft.next_id
        sess.draft.next_id = sess.draft.next_id + 1
        sess.draft.comments[#sess.draft.comments + 1] = {
          id = loc.id,
          path = loc.path,
          side = loc.side,
          start_side = loc.start_side,
          start_line = loc.start_line,
          line = loc.line,
          body = body,
          created = os.time(),
        }
      end
      M.after_change()
      notify("Comment saved" .. (outside and " (line is outside the diff; GitHub may reject it)" or ""))
    end,
  })
end

function M.edit(c)
  M.open_editor({
    title = "Edit comment " .. location_label(c),
    body = c.body,
    on_save = function(body)
      if vim.trim(body) == "" then
        error("empty comment not saved (delete it from the list instead)", 0)
      end
      c.body = body
      M.after_change()
      notify("Comment updated")
    end,
  })
end

function M.delete(c)
  local sess = view().session
  local _, i = M.find_by_id(c.id)
  if i then
    table.remove(sess.draft.comments, i)
    M.after_change()
    notify("Comment deleted")
  end
end

-- ---------------------------------------------------------------------------
-- Marks
-- ---------------------------------------------------------------------------

local function rows_for(parsed, kind, c)
  if kind == "diff" then
    local a = parsed.rev[c.start_side or c.side][c.start_line or c.line]
    local b = parsed.rev[c.side][c.line]
    a, b = a or b, b or a
    if not a then
      return nil
    end
    if a > b then
      a, b = b, a
    end
    return a, b
  end
  local want = kind == "before" and "LEFT" or "RIGHT"
  if c.side == want then
    local a = (c.start_side == want and c.start_line) or c.line
    return a, c.line
  elseif c.start_side == want then
    return c.start_line, c.start_line
  end
  return nil
end

function M.refresh_marks(file)
  local s = view().session
  local kinds = s.bufs[file.filename]
  if not kinds then
    return
  end
  local parsed = view().parsed(file)
  for kind, buf in pairs(kinds) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
      local n = vim.api.nvim_buf_line_count(buf)
      for _, c in ipairs(s.draft.comments) do
        if c.path == file.filename then
          local a, b = rows_for(parsed, kind, c)
          if a then
            a, b = math.min(a, n), math.min(b, n)
            for row = a, b do
              vim.api.nvim_buf_set_extmark(buf, ns, row - 1, 0, {
                sign_text = "┃",
                sign_hl_group = "PRReviewCommentSign",
                line_hl_group = "PRReviewCommentLine",
                priority = 50,
              })
            end
            vim.api.nvim_buf_set_extmark(buf, ns, b - 1, 0, {
              virt_text = { { "  ● " .. snippet(c.body), "PRReviewCommentText" } },
              virt_text_pos = "eol",
              priority = 60,
            })
          end
        end
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- List
-- ---------------------------------------------------------------------------

local function list_lines()
  local s = view().session
  local lines, ids = {}, {}
  local sorted = vim.list_slice(s.draft.comments)
  table.sort(sorted, function(a, b)
    if a.path ~= b.path then
      return a.path < b.path
    end
    return a.line < b.line
  end)
  for _, c in ipairs(sorted) do
    local _, file = view().file_index(c.path)
    local outside = file and not diff.in_hunk(view().parsed(file), c.side, c.line)
    lines[#lines + 1] = string.format("%s%s  %s", location_label(c), outside and "  [outside diff!]" or "", first_line(c.body))
    ids[#lines] = c.id
  end
  if #lines == 0 then
    lines[1] = "(no comments yet — use " .. cfg().keymaps.comment .. " on a line or visual selection)"
  end
  return lines, ids
end

function M.refresh_list()
  local s = view().session
  if not (s and s.list_win and vim.api.nvim_win_is_valid(s.list_win)) then
    return
  end
  local lines, ids = list_lines()
  vim.bo[s.list_buf].modifiable = true
  vim.api.nvim_buf_set_lines(s.list_buf, 0, -1, false, lines)
  vim.bo[s.list_buf].modifiable = false
  vim.b[s.list_buf].pr_review_ids = ids
  pcall(vim.api.nvim_win_set_height, s.list_win, math.max(3, math.min(#lines + 1, 15)))
end

local function list_comment_under_cursor()
  local s = view().session
  local ids = vim.b[s.list_buf].pr_review_ids or {}
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local id = ids[row] or ids[tostring(row)]
  return id and M.find_by_id(id)
end

function M.jump_to(c)
  local v = view()
  local s = v.session
  local idx = v.file_index(c.path)
  if not idx then
    notify("File not in this PR anymore: " .. c.path, vim.log.levels.WARN)
    return
  end
  local mode = s.mode
  if mode == "after" and c.side == "LEFT" then
    mode = "before"
  elseif mode == "before" and c.side == "RIGHT" then
    mode = "after"
  end
  v.show_file(idx, mode, { side = c.side, line = c.line })
end

function M.toggle_list()
  local s = view().require_session()
  if not s then
    return
  end
  if s.list_win and vim.api.nvim_win_is_valid(s.list_win) then
    vim.api.nvim_win_close(s.list_win, true)
    s.list_win = nil
    return
  end
  if not (s.list_buf and vim.api.nvim_buf_is_valid(s.list_buf)) then
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "prreview://comments")
    vim.bo[buf].buftype = "acwrite"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "prreview_comments"
    vim.b[buf].pr_review = { kind = "list" }
    s.list_buf = buf
    local function map(lhs, fn, desc)
      vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "PR review: " .. desc })
    end
    map("<CR>", function()
      local c = list_comment_under_cursor()
      if c then
        M.jump_to(c)
      end
    end, "jump to comment")
    map("e", function()
      local c = list_comment_under_cursor()
      if c then
        M.edit(c)
      end
    end, "edit comment")
    map("dd", function()
      local c = list_comment_under_cursor()
      if c and vim.fn.confirm("Delete comment at " .. location_label(c) .. "?", "&Yes\n&No", 2) == 1 then
        M.delete(c)
      end
    end, "delete comment")
    map("q", M.toggle_list, "close list")
    map(cfg().keymaps.list_comments, M.toggle_list, "close list")
    map(cfg().keymaps.submit, function() require("pr_review.submit").submit() end, "submit review")
    map(cfg().keymaps.help, view().help, "help")
  end
  local main = view().ensure_main_win()
  vim.api.nvim_set_current_win(main)
  vim.cmd("belowright 8split")
  s.list_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(s.list_win, s.list_buf)
  vim.wo[s.list_win].winfixheight = true
  vim.wo[s.list_win].number = false
  vim.wo[s.list_win].relativenumber = false
  vim.wo[s.list_win].signcolumn = "no"
  vim.wo[s.list_win].cursorline = true
  vim.wo[s.list_win].wrap = false
  vim.wo[s.list_win].statusline = " PR comments  <CR> jump • e edit • dd delete • q close"
  M.refresh_list()
end

return M
