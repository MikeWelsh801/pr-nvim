local gh = require("pr_review.gh")
local state = require("pr_review.state")
local diff = require("pr_review.diff")

local M = {}

local EVENTS = {
  { label = "Approve", event = "APPROVE" },
  { label = "Comment", event = "COMMENT" },
  { label = "Request changes", event = "REQUEST_CHANGES" },
}

local function view()
  return require("pr_review.view")
end

--- Build the GitHub review payload from the draft.
function M.build_payload(s, event)
  local comments = {}
  for _, c in ipairs(s.draft.comments) do
    local item = { path = c.path, body = c.body, line = c.line, side = c.side }
    if c.start_line and c.start_line ~= c.line then
      item.start_line = c.start_line
      item.start_side = c.start_side or c.side
    end
    comments[#comments + 1] = item
  end
  local payload = { commit_id = s.meta.head_sha, event = event }
  if s.draft.body and vim.trim(s.draft.body) ~= "" then
    payload.body = s.draft.body
  end
  if #comments > 0 then
    payload.comments = comments
  end
  return payload
end

function M.outside_diff_count(s)
  local n = 0
  for _, c in ipairs(s.draft.comments) do
    local _, file = view().file_index(c.path)
    if not file or not diff.in_hunk(view().parsed(file), c.side, c.line) then
      n = n + 1
    end
  end
  return n
end

--- Post the review for `event` using the saved draft. Returns ok, result|error.
function M.post(event)
  local s = view().session
  local payload = M.build_payload(s, event)
  if event ~= "APPROVE" and not payload.body and not payload.comments then
    return false, "A " .. event:lower() .. " review needs a summary or at least one comment"
  end
  local ok, res = pcall(gh.submit_review, s.meta, payload)
  if not ok then
    return false, res
  end
  state.delete(s.meta)
  s.draft = state.new(s.meta)
  s.draft.viewed = {}
  require("pr_review.comments").after_change()
  -- Nothing left to resume: stop persisting until the user adds something new.
  s.submitted = true
  state.delete(s.meta)
  return true, res
end

function M.submit()
  local s = view().require_session()
  if not s then
    return
  end
  local labels = {}
  for _, e in ipairs(EVENTS) do
    labels[#labels + 1] = e.label
  end
  vim.ui.select(labels, { prompt = "Submit review as:" }, function(choice)
    if not choice then
      return
    end
    local event
    for _, e in ipairs(EVENTS) do
      if e.label == choice then
        event = e.event
      end
    end
    local n = #s.draft.comments
    local outside = M.outside_diff_count(s)
    require("pr_review.comments").open_editor({
      title = string.format("%s — summary (%d comment%s)", choice, n, n == 1 and "" or "s"),
      body = s.draft.body or "",
      on_save = function(body)
        s.draft.body = body
        state.save(s.meta, s.draft)
      end,
      on_close = function(body)
        s.draft.body = body
        state.save(s.meta, s.draft)
        local msg = string.format("Submit review as %s with %d comment%s", choice:upper(), n, n == 1 and "" or "s")
        if outside > 0 then
          msg = msg .. string.format("\n%d comment(s) are outside the diff and will likely be rejected by GitHub", outside)
        end
        if vim.fn.confirm(msg .. "?", "&Submit\n&Not now", 1) ~= 1 then
          view().notify("Not submitted; draft kept")
          return
        end
        local ok, res = M.post(event)
        if ok then
          view().notify(
            string.format("Review submitted (%s): %s", choice, res.html_url or s.meta.url),
            vim.log.levels.INFO
          )
        else
          view().notify("Submit failed; draft kept.\n" .. tostring(res), vim.log.levels.ERROR)
        end
      end,
    })
  end)
end

return M
