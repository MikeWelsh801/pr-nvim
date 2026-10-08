local M = {}

local function set_highlights()
  local hl = function(name, val)
    val.default = true
    vim.api.nvim_set_hl(0, name, val)
  end
  hl("PRReviewHeader", { link = "Title" })
  hl("PRReviewViewed", { link = "Comment" })
  hl("PRReviewCurrent", { link = "CursorLine" })
  hl("PRReviewCommentSign", { link = "DiagnosticInfo" })
  hl("PRReviewCommentLine", { link = "ColorColumn" })
  hl("PRReviewCommentText", { link = "DiagnosticVirtualTextInfo" })
end

function M.setup(opts)
  require("pr_review.config").setup(opts)
  set_highlights()
end

local subcommands = {
  open = function(args)
    require("pr_review.view").open(args[1])
  end,
  resume = function()
    local drafts = require("pr_review.state").list()
    if #drafts == 0 then
      vim.notify("No saved review drafts", vim.log.levels.INFO, { title = "PR review" })
      return
    end
    vim.ui.select(drafts, {
      prompt = "Resume review:",
      format_item = function(d)
        return string.format(
          "%s/%s #%d  %s  (%d comments, %s)",
          d.draft.owner,
          d.draft.repo,
          d.draft.number,
          d.draft.title or "",
          #(d.draft.comments or {}),
          os.date("%Y-%m-%d %H:%M", d.draft.updated or 0)
        )
      end,
    }, function(d)
      if d then
        require("pr_review.view").open(d.draft.url or tostring(d.draft.number))
      end
    end)
  end,
  files = function()
    require("pr_review.view").toggle_panel()
  end,
  comments = function()
    require("pr_review.comments").toggle_list()
  end,
  submit = function()
    require("pr_review.submit").submit()
  end,
  close = function()
    require("pr_review.view").close()
  end,
  help = function()
    if require("pr_review.view").require_session() then
      require("pr_review.view").help()
    end
  end,
  discard = function()
    local v = require("pr_review.view")
    local s = v.require_session()
    if not s then
      return
    end
    if vim.fn.confirm("Discard the saved draft for PR #" .. s.meta.number .. "?", "&Yes\n&No", 2) == 1 then
      require("pr_review.state").delete(s.meta)
      s.draft = require("pr_review.state").new(s.meta)
      require("pr_review.comments").after_change()
      vim.notify("Draft discarded", vim.log.levels.INFO, { title = "PR review" })
    end
  end,
}

function M.command(fargs)
  set_highlights()
  local sub = fargs[1]
  if not sub then
    if require("pr_review.view").session then
      subcommands.files()
    else
      subcommands.open({})
    end
    return
  end
  local fn = subcommands[sub]
  if not fn then
    -- allow `:PRReview 123` / `:PRReview <url>` as shorthand for open
    if sub:match("^%d+$") or sub:match("^https?://") then
      return subcommands.open({ sub })
    end
    vim.notify("Unknown subcommand: " .. sub, vim.log.levels.ERROR, { title = "PR review" })
    return
  end
  fn(vim.list_slice(fargs, 2))
end

function M.complete(arg)
  local out = {}
  for k in pairs(subcommands) do
    if k:sub(1, #arg) == arg then
      out[#out + 1] = k
    end
  end
  table.sort(out)
  return out
end

return M
