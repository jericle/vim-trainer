local keys = require("vimtrainer.keys")
local config = require("vimtrainer.config")

local M = {}

local function col_of(line, needle, off)
  local s = line:find(needle, 1, true)
  assert(s, ("pattern %q not found in %q"):format(needle, line))
  return s - 1 + (off or 0)
end

-- A position is { row, col } (row 1-based, col 0-based) or { row, "text", offset }
-- where the column is where "text" first occurs on that row, plus the optional offset.
local function resolve(lines, spec)
  local row, col, off = spec[1], spec[2], spec[3]
  if type(col) == "string" then
    assert(lines[row], "bad row in position spec")
    col = col_of(lines[row], col, off)
  end
  return { row, col }
end

local function prepare(level, id)
  level.id = id
  for i, ch in ipairs(level.challenges) do
    ch.index = i
    ch.par = keys.count(ch.solution)
    ch.start_pos = resolve(ch.text, ch.start or { 1, 0 })
    assert(ch.goal_text or ch.goal_cursor, ("%s #%d needs goal_text or goal_cursor"):format(level.name, i))
    local goal_lines = ch.goal_text or ch.text
    if ch.goal_cursor then
      ch.goal_pos = resolve(goal_lines, ch.goal_cursor)
    end
    ch.goal_text = goal_lines
  end
  return level
end

M.list = {}
for i, name in ipairs({ "level1", "level2", "level3", "level4", "level5", "level6" }) do
  M.list[i] = prepare(require("vimtrainer.levels." .. name), i)
end

function M.par_total(level)
  local total = 0
  for _, ch in ipairs(level.challenges) do
    total = total + ch.par
  end
  return total
end

-- Time budget: for every challenge, `think` seconds to read the task and decide,
-- plus `per_key` seconds for each keystroke of the reference solution.
-- Rounded up to the next 5 seconds.
function M.base_limit(level)
  local total = 0
  for _, ch in ipairs(level.challenges) do
    total = total + level.think + ch.par * level.per_key
  end
  return math.ceil(total / 5) * 5
end

-- Limit actually applied (after the user's time_scale). 0 means no limit.
function M.limit(level)
  local scale = config.options.time_scale
  if not scale or scale <= 0 then
    return 0
  end
  return M.base_limit(level) * scale
end

-- How many extra keystrokes (beyond par, summed over the level) are tolerated.
function M.allowed_extra(level)
  local scale = config.options.mistake_scale or 1
  return math.max(5, math.ceil(M.par_total(level) * level.mistake_ratio * scale))
end

return M
