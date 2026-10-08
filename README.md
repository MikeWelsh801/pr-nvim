# pr-nvim

Review GitHub pull requests from Neovim: flip between before/after/diff views,
leave line comments on visual selections, keep your progress in a local draft,
and submit the whole review (approve / comment / request changes) to GitHub.

## Requirements

- Neovim 0.10+ (tested on 0.11)
- [GitHub CLI (`gh`)](https://cli.github.com/), logged in (`gh auth login`).
  All GitHub access (PR metadata, file list, file contents, review submission)
  goes through `gh`, so there is no token to configure in the plugin.
- `git` (optional): when you are inside a clone of the repo, file contents are
  read from the local object store instead of the API, which is faster.

## Install

lazy.nvim:

```lua
{
  "MikeWelsh801/pr-nvim",
  cmd = "PRReview",
  opts = {}, -- see Configuration
}
```

packer / vim-plug: `use "MikeWelsh801/pr-nvim"` / `Plug 'MikeWelsh801/pr-nvim'`.

Any plugin manager works; call `require("pr_review").setup({})` once if you
want to change defaults (setup is optional).

## Usage

```
:PRReview open            " PR for the current branch
:PRReview open 123        " by number (inside a clone of the repo)
:PRReview open <pr url>   " from anywhere
:PRReview 123             " shorthand
:PRReview resume          " pick a saved draft and continue it
:PRReview files           " toggle the files panel
:PRReview comments        " toggle the comment list
:PRReview submit          " submit the review
:PRReview discard         " throw away the saved draft for this PR
:PRReview close           " close (progress is saved)
```

Opening a PR puts a files panel on the left and the first file's unified diff
in your window. The diff view shows old/new line numbers inline.

### Keys (in review buffers)

| Key        | Action                                                              |
| ---------- | ------------------------------------------------------------------- |
| `<Tab>`    | Toggle **before** / **after** full file                             |
| `gd`       | Unified diff view                                                   |
| `gs`       | Side-by-side vimdiff (before \| after)                              |
| `gb` `ga`  | Before / after full file                                            |
| `]f` `[f`  | Next / previous file                                                |
| `]c` `[c`  | Next / previous hunk                                                |
| `gc`       | Comment on the current line, or edit the comment already there      |
| `gc` (visual) | Comment on the selected lines                                    |
| `gl`       | Comment list: `<CR>` jump, `e` edit, `dd` delete, `q` close          |
| `-`        | Toggle files panel (`<CR>` opens a file, `gm` marks viewed)          |
| `gm`       | Toggle "viewed" for the current file                                |
| `gS`       | Submit review                                                       |
| `g?`       | Help                                                                |
| `q`        | Close the review                                                    |

The cursor keeps its position when you switch views: line 42 in "after" lands
on the matching line in "before" or on the corresponding row of the diff.

### Comments

`gc` opens a floating markdown buffer. `:w` saves the comment into the draft,
`q` closes it (asking if unsaved), `:wq` does both, `<C-s>` saves. Commented
lines get a sign, a subtle background, and the first line of the comment as
virtual text. Comments made in the "before" view attach to the old side of the
diff, comments in "after" or in the unified diff attach to the new side (deleted
lines map to the old side automatically).

GitHub only accepts comments on lines that are part of the diff. Comments
outside a hunk are allowed locally but flagged `[outside diff!]` in the list and
in the submit confirmation.

### Submitting

`gS` (or `:PRReview submit`) asks for Approve / Comment / Request changes, opens
an editor for the review summary, and then asks for confirmation before posting
everything in one review. On success the local draft is deleted. On failure
GitHub's error is shown and the draft is kept, so you can fix and retry.

### Leaving and coming back

Every comment, the viewed-marks, the review summary, and your current
file/view/line are saved to `stdpath("data")/pr_review/<owner>__<repo>__<n>.json`
as you go. Closing Neovim mid-review loses nothing: `:PRReview open 123` or
`:PRReview resume` puts you back where you were. If the PR gained commits since
your draft, you get a warning that line numbers may be stale.

## Configuration

Defaults:

```lua
require("pr_review").setup({
  gh_cmd = "gh",
  draft_dir = vim.fn.stdpath("data") .. "/pr_review",
  files_panel_width = 42,
  diff_line_numbers = true,     -- inline old/new numbers in the unified diff
  auto_mark_viewed = false,     -- mark a file viewed when you move to the next one
  editor = { width = 0.6, height = 0.4 },
  keymaps = {
    toggle_side = "<Tab>", view_diff = "gd", view_split = "gs",
    view_before = "gb", view_after = "ga",
    next_file = "]f", prev_file = "[f", next_hunk = "]c", prev_hunk = "[c",
    comment = "gc", list_comments = "gl", files = "-", toggle_viewed = "gm",
    submit = "gS", help = "g?", close = "q",
  },
})
```

Set a keymap to `""` to disable it. Highlight groups (all `default`, override
freely): `PRReviewHeader`, `PRReviewViewed`, `PRReviewCurrent`,
`PRReviewCommentSign`, `PRReviewCommentLine`, `PRReviewCommentText`.

## Development

`tests/run.sh` runs a headless smoke test against a stub `gh` (no network).

## Not (yet) included

- Existing review comments from GitHub are not displayed.
- Comments are drafted locally, not as a GitHub "pending review"; they only
  reach GitHub when you submit.
