-- Draft persistence: one JSON file per PR under `draft_dir`.
local M = {}

local JSON_OPTS = { luanil = { object = true, array = true } }

local function dir()
  return require("pr_review.config").get().draft_dir
end

local function path_for(meta)
  return string.format("%s/%s__%s__%d.json", dir(), meta.owner, meta.repo, meta.number)
end

function M.new(meta)
  return {
    owner = meta.owner,
    repo = meta.repo,
    number = meta.number,
    title = meta.title,
    url = meta.url,
    head_sha = meta.head_sha,
    body = "",
    comments = {},
    viewed = {},
    current = nil,
    next_id = 1,
    created = os.time(),
    updated = os.time(),
  }
end

function M.load(meta)
  local p = path_for(meta)
  if vim.fn.filereadable(p) == 0 then
    return nil
  end
  local ok, data = pcall(function()
    return vim.json.decode(table.concat(vim.fn.readfile(p), "\n"), JSON_OPTS)
  end)
  if not ok or type(data) ~= "table" then
    return nil
  end
  data.comments = data.comments or {}
  data.viewed = data.viewed or {}
  data.body = data.body or ""
  data.next_id = data.next_id or (#data.comments + 1)
  return data
end

function M.save(meta, draft)
  vim.fn.mkdir(dir(), "p")
  draft.updated = os.time()
  vim.fn.writefile({ vim.json.encode(draft) }, path_for(meta))
end

function M.delete(meta)
  vim.fn.delete(path_for(meta))
end

--- All saved drafts, newest first.
function M.list()
  local out = {}
  for _, p in ipairs(vim.fn.glob(dir() .. "/*.json", false, true)) do
    local ok, data = pcall(function()
      return vim.json.decode(table.concat(vim.fn.readfile(p), "\n"), JSON_OPTS)
    end)
    if ok and type(data) == "table" and data.number then
      out[#out + 1] = { file = p, draft = data }
    end
  end
  table.sort(out, function(a, b)
    return (a.draft.updated or 0) > (b.draft.updated or 0)
  end)
  return out
end

return M
