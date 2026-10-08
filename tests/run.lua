-- Headless smoke test. Run via tests/run.sh
local function eq(a, b, msg)
  if not vim.deep_equal(a, b) then
    error(("ASSERT %s: expected %s got %s"):format(msg, vim.inspect(b), vim.inspect(a)), 2)
  end
end
local tmp = os.getenv("PR_REVIEW_TMP")
require("pr_review").setup({ draft_dir = tmp .. "/drafts" })
local view = require("pr_review.view")
local comments = require("pr_review.comments")
local submit = require("pr_review.submit")

view.open("7")
local s = assert(view.session, "session opened")
eq(#s.files, 3, "file count")
eq(s.meta.base_sha, "base000000000000000000000000000000000000", "merge base used")
eq(s.mode, "diff", "initial mode")
local dbuf = vim.api.nvim_get_current_buf()
eq(vim.b[dbuf].pr_review.kind, "diff", "diff buffer current")
local lines = vim.api.nvim_buf_get_lines(dbuf, 0, -1, false)
eq(lines[2], "@@ -1,7 +1,12 @@", "hunk header row")
eq(lines[7], "+    for i in range(retries):", "plus row")

-- comment on a visual range in diff view (rows 6..8 = new lines 3..5)
comments.add_range(6, 8)
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "Consider exponential backoff", "", "here" })
vim.cmd("write")
vim.cmd("q")
eq(#s.draft.comments, 1, "one comment")
local c = s.draft.comments[1]
eq({ c.path, c.start_side, c.start_line, c.side, c.line, c.body }, { "src/app.py", "RIGHT", 3, "RIGHT", 5, "Consider exponential backoff\n\nhere" }, "comment location")

-- toggle to after / before, cursor translation
vim.api.nvim_win_set_cursor(0, { 7, 0 }) -- +    for i in range(retries)  -> new line 4
view.toggle_side()
eq(s.mode, "after", "after mode")
eq(vim.api.nvim_win_get_cursor(0)[1], 4, "cursor on new line 4")
eq(vim.api.nvim_buf_get_lines(0, 3, 4, false)[1], "    for i in range(retries):", "after content")
view.toggle_side()
eq(s.mode, "before", "before mode")
eq(vim.api.nvim_buf_get_lines(0, 0, -1, false)[3], "def fetch(url):", "before content")
-- comment on old side line 4 ("return get(url)")
comments.add_range(4, 4)
vim.api.nvim_buf_set_lines(0, 0, -1, false, { "old impl" })
vim.cmd("wq")
eq(s.draft.comments[2].side, "LEFT", "left side comment")
eq(s.draft.comments[2].line, 4, "left line")
-- editing: gc on the same line opens existing comment
comments.add_range(4, 4)
eq(vim.api.nvim_buf_get_lines(0, 0, -1, false), { "old impl" }, "edit opens existing body")
vim.cmd("q")

view.set_mode("split")
eq(s.mode, "split", "split mode")
assert(vim.api.nvim_win_is_valid(s.split_win), "split window")
eq(vim.wo[s.win].diff, true, "diff on")
view.set_mode("diff")
assert(s.split_win == nil, "split torn down")

-- marks exist in diff buffer
local marks = vim.api.nvim_buf_get_extmarks(dbuf, vim.api.nvim_create_namespace("pr_review_comments"), 0, -1, {})
assert(#marks >= 4, "extmarks placed: " .. #marks)

-- files: added + binary
view.next_file(1)
eq(view.current_file().filename, "docs/new.md", "second file")
view.set_mode("before")
eq(vim.api.nvim_buf_line_count(0), 1, "added file has empty before")
view.next_file(1)
view.set_mode("diff")
assert(vim.api.nvim_buf_get_lines(0, 2, 3, false)[1]:match("no textual diff"), "binary notice")
view.toggle_viewed()
eq(s.draft.viewed["img.png"], true, "viewed")

-- list
comments.toggle_list()
local ll = vim.api.nvim_buf_get_lines(s.list_buf, 0, -1, false)
eq(#ll, 2, "two list rows")
assert(ll[2]:match("^src/app%.py:3%-5 %(new%)"), "list row: " .. ll[2])
comments.toggle_list()

-- resume
view.close()
assert(view.session == nil, "closed")
view.open("7")
s = view.session
eq(#s.draft.comments, 2, "comments restored")
eq(view.current_file().filename, "img.png", "resumed on last file")
eq(s.draft.viewed["img.png"], true, "viewed restored")

-- submit
s.draft.body = "LGTM with nits"
local payload = submit.build_payload(s, "APPROVE")
eq(payload.comments[1], { path = "src/app.py", body = "Consider exponential backoff\n\nhere", line = 5, side = "RIGHT", start_line = 3, start_side = "RIGHT" }, "payload multi-line")
eq(payload.comments[2], { path = "src/app.py", body = "old impl", line = 4, side = "LEFT" }, "payload single-line")
eq(submit.outside_diff_count(s), 0, "all inside diff")
local ok, res = submit.post("APPROVE")
assert(ok, "post ok: " .. tostring(res))
local posted = vim.json.decode(table.concat(vim.fn.readfile(os.getenv("PR_REVIEW_POST_OUT")), "\n"))
eq(posted.event, "APPROVE", "posted event")
eq(posted.commit_id, "head00000000000000000000000000000000000", "commit id")
eq(posted.body, "LGTM with nits", "body")
eq(#posted.comments, 2, "posted comments")
eq(#s.draft.comments, 0, "draft cleared")
eq(vim.fn.glob(tmp .. "/drafts/*.json"), "", "draft file deleted")
print("ALL TESTS PASSED")
