-- Thin wrapper around the `gh` CLI (and local git for file contents).
local M = {}

local function cfg()
  return require("pr_review.config").get()
end

local JSON_OPTS = { luanil = { object = true, array = true } }

local function run(cmd, opts)
  opts = opts or {}
  local ok, res = pcall(function()
    return vim.system(cmd, { text = true, stdin = opts.stdin }):wait()
  end)
  if not ok then
    return false, "", tostring(res)
  end
  return res.code == 0, res.stdout or "", res.stderr or ""
end
M.run = run

local function gh(args, opts)
  local cmd = { cfg().gh_cmd }
  vim.list_extend(cmd, args)
  return run(cmd, opts)
end

local function fail(what, err)
  err = vim.trim(err or "")
  error(string.format("%s: %s", what, err ~= "" and err or "unknown error"), 0)
end

local function decode(s)
  return vim.json.decode(s, JSON_OPTS)
end

--- Fetch PR metadata. `spec` may be a number, branch, URL, or nil (current branch).
function M.pr_meta(spec)
  local args = { "pr", "view" }
  if spec and spec ~= "" then
    table.insert(args, spec)
  end
  vim.list_extend(args, {
    "--json",
    "number,title,url,headRefOid,baseRefOid,headRefName,baseRefName,author,state,isDraft",
  })
  local ok, out, err = gh(args)
  if not ok then
    fail("gh pr view failed", err)
  end
  local j = decode(out)
  local owner, repo = tostring(j.url):match("^https?://[^/]+/([^/]+)/([^/]+)/pull/")
  if not owner then
    fail("could not parse owner/repo from PR url", j.url)
  end
  local meta = {
    owner = owner,
    repo = repo,
    number = j.number,
    title = j.title,
    url = j.url,
    head_sha = j.headRefOid,
    base_sha = j.baseRefOid,
    head_ref = j.headRefName,
    base_ref = j.baseRefName,
    author = j.author and j.author.login or "?",
    state = j.state,
    is_draft = j.isDraft,
  }
  -- The PR diff is computed against the merge base, not the base branch tip.
  local ok2, out2 = gh({
    "api",
    string.format("repos/%s/%s/compare/%s...%s", owner, repo, j.baseRefOid, j.headRefOid),
    "--jq",
    ".merge_base_commit.sha",
  })
  if ok2 and vim.trim(out2) ~= "" then
    meta.base_sha = vim.trim(out2)
  end
  return meta
end

--- List changed files (with per-file patches).
function M.pr_files(meta)
  local files, page = {}, 1
  while true do
    local ok, out, err = gh({
      "api",
      string.format("repos/%s/%s/pulls/%d/files?per_page=100&page=%d", meta.owner, meta.repo, meta.number, page),
    })
    if not ok then
      fail("fetching PR files failed", err)
    end
    local chunk = decode(out)
    for _, f in ipairs(chunk) do
      files[#files + 1] = {
        filename = f.filename,
        previous_filename = f.previous_filename,
        status = f.status,
        additions = f.additions or 0,
        deletions = f.deletions or 0,
        patch = f.patch,
      }
    end
    if #chunk < 100 or page >= 30 then
      break
    end
    page = page + 1
  end
  return files
end

local function url_encode_path(path)
  local segs = vim.split(path, "/", { plain = true })
  for i, s in ipairs(segs) do
    segs[i] = s:gsub("[^%w%-%._~]", function(c)
      return string.format("%%%02X", c:byte())
    end)
  end
  return table.concat(segs, "/")
end

--- Full contents of `path` at `sha`. Uses the local git object store when
--- available, otherwise the GitHub contents API.
function M.file_content(meta, path, sha)
  local ok = run({ "git", "cat-file", "-e", sha .. ":" .. path })
  if ok then
    local ok2, out = run({ "git", "show", sha .. ":" .. path })
    if ok2 then
      return out
    end
  end
  local ok3, out3, err = gh({
    "api",
    "-H",
    "Accept: application/vnd.github.raw+json",
    string.format("repos/%s/%s/contents/%s?ref=%s", meta.owner, meta.repo, url_encode_path(path), sha),
  })
  if not ok3 then
    fail(string.format("fetching %s@%s failed", path, sha:sub(1, 7)), err)
  end
  return out3
end

--- POST a review. Returns the decoded response.
function M.submit_review(meta, payload)
  local ok, out, err = gh({
    "api",
    "-X",
    "POST",
    string.format("repos/%s/%s/pulls/%d/reviews", meta.owner, meta.repo, meta.number),
    "--input",
    "-",
  }, { stdin = vim.json.encode(payload) })
  if not ok then
    fail("submitting review failed", (err or "") .. "\n" .. (out or ""))
  end
  local ok2, res = pcall(decode, out)
  return ok2 and res or {}
end

return M
