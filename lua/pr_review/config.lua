local M = {}

local defaults = {
  gh_cmd = "gh",
  draft_dir = vim.fn.stdpath("data") .. "/pr_review",
  files_panel_width = 42,
  diff_line_numbers = true,
  auto_mark_viewed = false, -- mark a file viewed when moving to the next file
  editor = { width = 0.6, height = 0.4 },
  keymaps = {
    toggle_side = "<Tab>", -- before <-> after (full file)
    view_diff = "gd", -- unified diff
    view_split = "gs", -- side-by-side vimdiff (before | after)
    view_before = "gb",
    view_after = "ga",
    next_file = "]f",
    prev_file = "[f",
    next_hunk = "]c",
    prev_hunk = "[c",
    comment = "gc", -- normal: current line (or edit existing); visual: selection
    list_comments = "gl",
    files = "-", -- toggle files panel
    toggle_viewed = "gm",
    submit = "gS",
    help = "g?",
    close = "q",
  },
}

M.options = vim.deepcopy(defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
end

function M.get()
  return M.options
end

return M
