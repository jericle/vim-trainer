local config = require("vimtrainer.config")

local M = {}

local data

local function empty()
  return { levels = {}, history = {} }
end

local function round1(x)
  return math.floor(x * 10 + 0.5) / 10
end

function M.load()
  data = empty()
  local f = io.open(config.progress_path(), "r")
  if f then
    local text = f:read("*a")
    f:close()
    local ok, decoded = pcall(vim.json.decode, text)
    if ok and type(decoded) == "table" then
      data.levels = type(decoded.levels) == "table" and decoded.levels or {}
      data.history = type(decoded.history) == "table" and decoded.history or {}
    end
  end
  return data
end

local function ensure()
  if not data then
    M.load()
  end
  return data
end

function M.data()
  return ensure()
end

function M.save()
  local path = config.progress_path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f, err = io.open(path, "w")
  if not f then
    vim.notify("vimtrainer: cannot save progress: " .. tostring(err), vim.log.levels.WARN)
    return false
  end
  f:write(vim.json.encode(ensure()))
  f:close()
  return true
end

function M.get(level)
  return ensure().levels[tostring(level)]
end

-- Records one attempt. Returns true when it set a new best time for the level.
function M.record(level, res)
  local d = ensure()
  local key = tostring(level)
  local e = d.levels[key] or { attempts = 0, passes = 0, stars = 0 }
  e.attempts = e.attempts + 1
  local improved = false
  if res.passed then
    e.passed = true
    e.passes = (e.passes or 0) + 1
    local t = round1(res.elapsed)
    if not e.best_time or t < e.best_time then
      e.best_time = t
      improved = true
    end
    if not e.best_extra or res.extra < e.best_extra then
      e.best_extra = res.extra
    end
    if res.stars > (e.stars or 0) then
      e.stars = res.stars
    end
  end
  d.levels[key] = e
  d.history[#d.history + 1] = {
    level = level,
    ts = os.date("%Y-%m-%d %H:%M"),
    passed = res.passed,
    time = round1(res.elapsed),
    keys = res.keys,
    extra = res.extra,
    stars = res.stars,
  }
  while #d.history > 200 do
    table.remove(d.history, 1)
  end
  M.save()
  return improved
end

-- First level that has not been passed yet (or the last level when all are done).
function M.next_level(count)
  local d = ensure()
  for i = 1, count do
    local e = d.levels[tostring(i)]
    if not (e and e.passed) then
      return i
    end
  end
  return count
end

function M.reset()
  data = empty()
  M.save()
end

return M
