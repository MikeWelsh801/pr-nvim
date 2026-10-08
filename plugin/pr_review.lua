if vim.g.loaded_pr_review then
  return
end
vim.g.loaded_pr_review = true

vim.api.nvim_create_user_command("PRReview", function(o)
  require("pr_review").command(o.fargs)
end, {
  nargs = "*",
  complete = function(arg, line)
    if #vim.split(vim.trim(line), "%s+") > 2 or (#vim.split(vim.trim(line), "%s+") == 2 and arg == "") then
      return {}
    end
    return require("pr_review").complete(arg)
  end,
  desc = "Review a GitHub pull request",
})
