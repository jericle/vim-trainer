-- Run with:
--   nvim --headless -u NONE --cmd "set rtp+=/path/to/vim-trainer" -c "luafile tests/validate.lua"
-- Replays every reference solution as typed keys through the real engine and checks the
-- timer, key counting, hints, restart, blocked keys, progress file and clean-up.

local failures = {}

local function out(s)
  io.stdout:write(s .. "\n")
end

local function check(cond, msg)
  if cond then
    out("  ok   " .. msg)
  else
    out("  FAIL " .. msg)
    failures[#failures + 1] = msg
  end
end

local config = require("vimtrainer.config")
local engine = require("vimtrainer.engine")
local levels = require("vimtrainer.levels")
local progress = require("vimtrainer.progress")
local ui = require("vimtrainer.ui")
local trainer = require("vimtrainer")

local tmp = vim.fn.tempname()
local function fresh_config(extra)
  config.setup(vim.tbl_extend("force", { progress_path = tmp .. "/progress.json" }, extra or {}))
end
fresh_config()

local function feed(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "xt", false)
  vim.wait(40)
end

local function dump(st)
  local cur = vim.api.nvim_win_get_cursor(st.win)
  return ("       buffer=%s cursor=%d,%d mode=%s keys=%d\n       goal_text=%s goal_pos=%s"):format(
    vim.inspect(vim.api.nvim_buf_get_lines(st.buf, 0, -1, false)),
    cur[1], cur[2], vim.api.nvim_get_mode().mode, st.keys,
    vim.inspect(st.ch.goal_text), vim.inspect(st.ch.goal_pos)
  )
end

-- Plays one level with its reference solutions. `before` runs ahead of each solution.
local function play_level(li, before)
  trainer.start(li)
  local st = engine._state()
  local lv = levels.list[li]
  for ci, ch in ipairs(lv.challenges) do
    if before then
      feed(before)
    end
    feed(ch.solution)
    local advanced = (ci < #lv.challenges and st.idx == ci + 1) or (ci == #lv.challenges and st.result ~= nil)
    if not advanced or not st.rows[ci] then
      return st, false, ("L%d #%d %s did not complete"):format(li, ci, ch.name), dump(st)
    end
  end
  return st, true
end

-- ---------------------------------------------------------------------------
out("== 1. every reference solution completes its challenge, counted at par")
for li, lv in ipairs(levels.list) do
  trainer.start(li)
  local st = engine._state()
  local ok = true
  for ci, ch in ipairs(lv.challenges) do
    feed(ch.solution)
    local advanced = (ci < #lv.challenges and st.idx == ci + 1) or (ci == #lv.challenges and st.result ~= nil)
    local row = st.rows[ci]
    if not advanced or not row then
      check(false, ("L%d #%d %-14s solution %q completes the challenge"):format(li, ci, ch.name, ch.solution))
      out(dump(st))
      ok = false
      break
    end
    check(row.keys == ch.par, ("L%d #%d %-14s typed keys counted = %d (par %d)"):format(li, ci, ch.name, row.keys, ch.par))
  end
  if ok then
    vim.wait(150)
    local res = st.result
    check(res and res.passed, ("L%d level passed"):format(li))
    check(res and res.extra == 0 and res.stars == 3, ("L%d zero extra keys, 3 stars (got extra=%s stars=%s)"):format(li, res and res.extra, res and res.stars))
    check(ui._summary_win and vim.api.nvim_win_is_valid(ui._summary_win), ("L%d summary window opened"):format(li))
  end
  engine.teardown()
end

out("== 2. progress file")
progress.load()
check(vim.fn.filereadable(tmp .. "/progress.json") == 1, "progress.json written")
for li = 1, #levels.list do
  local e = progress.get(li)
  check(e and e.passed and type(e.best_time) == "number" and e.stars == 3, ("level %d stored as passed, 3 stars, best_time=%s"):format(li, e and e.best_time))
end
check(progress.next_level(#levels.list) == #levels.list, "all passed -> next_level is the last level")
check(#progress.data().history == #levels.list, "history has one entry per attempt")

out("== 3. blocked arrow keys, forbidden keys, control keys not counted")
trainer.start(1)
local st = engine._state()
feed("<Right>")
local cur = vim.api.nvim_win_get_cursor(st.win)
check(cur[1] == 1 and cur[2] == 0, "<Right> is blocked (cursor did not move)")
check(st.keys == 1, "the blocked key still counts as a (wasted) keystroke")
feed("<F1>")
check(st.hint_level == 1 and st.keys == 1, "<F1> shows the hint and is not counted")
feed("<F1>")
check(st.hint_level == 2 and st.solutions == 1, "second <F1> reveals the solution")
engine.teardown()

trainer.start(5)
st = engine._state()
for ci = 1, 4 do
  feed(levels.list[5].challenges[ci].solution)
end
check(st.idx == 5 and st.ch.name == "macro", "reached the macro challenge")
feed(":")
check(vim.api.nvim_get_mode().mode == "n", "':' is forbidden on the macro challenge (no command line opened)")
feed(".")
check(vim.api.nvim_buf_get_lines(st.buf, 0, -1, false)[1] == "a = 1", "'.' is forbidden too (text unchanged)")
engine.teardown()

out("== 4. restart keeps spent keys on the bill")
trainer.start(1)
st = engine._state()
feed("jjl")
feed("<F2>")
vim.wait(80)
check(st.carried == 3 and st.keys == 0, ("restart carried 3 keys (carried=%d keys=%d)"):format(st.carried, st.keys))
local c = vim.api.nvim_win_get_cursor(st.win)
check(c[1] == 1 and c[2] == 0, "restart put the cursor back at the start")
feed("jjll")
check(st.rows[1] and st.rows[1].keys == 7 and st.rows[1].extra == 3, ("challenge recorded 7 keys, 3 extra (got %s/%s)"):format(st.rows[1] and st.rows[1].keys, st.rows[1] and st.rows[1].extra))
engine.teardown()

out("== 5. hints cap the star rating")
trainer.start(1)
st = engine._state()
feed("<F1>")
feed("<F1>")
for ci, ch in ipairs(levels.list[1].challenges) do
  feed(ch.solution)
end
vim.wait(150)
check(st.result and st.result.passed and st.result.stars == 1, ("solution shown -> max 1 star (got %s)"):format(st.result and st.result.stars))
engine.teardown()

out("== 6. time limit")
fresh_config({ time_scale = 0.01 })
trainer.start(1)
st = engine._state()
vim.wait(1700, function()
  return st.result ~= nil
end)
check(st.result and st.result.fail_reason == "time" and not st.result.passed, "level fails when the clock runs out")
vim.wait(200)
check(ui._summary_win and vim.api.nvim_win_is_valid(ui._summary_win), "summary opened after timeout")
check(st.result and st.result.done == 0, "no challenges done -> done=0")
engine.teardown()
fresh_config({ time_scale = 0 })
check(levels.limit(levels.list[1]) == 0, "time_scale = 0 disables the limit")
fresh_config()
check(levels.limit(levels.list[1]) == 90, "default limit for level 1 is 90s")

out("== 7. too many extra keys fails the level even inside the time limit")
fresh_config({ mistake_scale = 0.1 })
local st2, ok2, why, d = play_level(1, "<Esc><Esc>")
check(ok2, "played level 1 with 2 wasted keys per challenge")
if not ok2 then
  out(why)
  out(d)
end
vim.wait(150)
check(st2.result and st2.result.fail_reason == "mistakes" and not st2.result.passed, ("fails on mistakes (extra=%s allowed=%s)"):format(st2.result and st2.result.extra, st2.result and st2.result.allowed))
engine.teardown()
fresh_config()

out("== 8. registers and tabs are restored")
vim.fn.setreg("x", "hello")
vim.fn.setreg('"', "unnamed-text")
local tabs_before = #vim.api.nvim_list_tabpages()
local win_before = vim.api.nvim_get_current_win()
trainer.start(3)
check(vim.fn.getreg("x") == "", "registers are cleared during practice")
check(#vim.api.nvim_list_tabpages() == tabs_before + 1, "practice runs in its own tab")
engine.teardown()
check(vim.fn.getreg("x") == "hello" and vim.fn.getreg('"') == "unnamed-text", "registers restored afterwards")
check(#vim.api.nvim_list_tabpages() == tabs_before, "practice tab closed")
check(vim.api.nvim_get_current_win() == win_before, "back in the original window")
check(engine._state() == nil, "no session left")
local leftover = 0
for _, w in ipairs(vim.api.nvim_list_wins()) do
  if vim.api.nvim_win_get_config(w).relative ~= "" then
    leftover = leftover + 1
  end
end
check(leftover == 0, "no floating windows left behind")

out("== 8b. live state export (for the web page)")
local state_path = tmp .. "/state.json"
fresh_config({ state_file = state_path })
local function read_state()
  local f = io.open(state_path, "r")
  if not f then
    return nil
  end
  local txt = f:read("*a")
  f:close()
  local ok, t = pcall(vim.json.decode, txt)
  return ok and t or nil
end
trainer.start(1)
st = engine._state()
feed("jjl")
vim.wait(700)
local s = read_state()
check(s and s.status == "playing" and s.level == 1 and s.level_name == "Basic Movement", "state: playing level 1")
check(s and s.challenge == 1 and s.challenges == 9 and s.keys == 3 and s.par == 4, "state: challenge 1/9, 3 keys, par 4")
check(s and s.limit == 90 and s.allowed == 16 and s.mistakes == 0, "state: limit 90s, 16 allowed, 0 mistakes so far")
check(s and type(s.elapsed) == "number" and s.elapsed > 0.3, "state: elapsed is counting")
feed("<Esc>")
vim.wait(300)
s = read_state()
check(s and s.mistakes == 0, "state: mistakes counted against par only (3 + 1 = 4 keys, par 4)")
feed("x")
vim.wait(300)
s = read_state()
check(s and s.mistakes == 1, ("state: a wasted key shows up as 1 mistake (got %s)"):format(s and s.mistakes))
engine.teardown()
s = read_state()
check(s and s.status == "idle" and s.records and s.records["1"] ~= nil, "state: idle after teardown, records still included")
local st3 = play_level(1)
vim.wait(150)
s = read_state()
check(s and s.status == "finished" and s.result and s.result.passed and s.record ~= nil, "state: finished + passed + record time")
engine.teardown()
fresh_config()

out("== 9. screens (for eyeballing)")
trainer.start(3)
st = engine._state()
feed("x")
vim.wait(50)
out("-- HUD")
for _, l in ipairs(vim.api.nvim_buf_get_lines(st.hud.buf, 0, -1, false)) do
  out("   |" .. l)
end
engine.teardown()
trainer.menu()
out("-- MENU")
for _, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
  out("   |" .. l)
end
ui.close_menu()
-- a failed attempt summary
fresh_config({ time_scale = 0.01 })
trainer.start(2)
st = engine._state()
feed(levels.list[2].challenges[1].solution)
vim.wait(1600, function()
  return st.result ~= nil
end)
vim.wait(200)
out("-- SUMMARY (timeout)")
for _, l in ipairs(vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(ui._summary_win), 0, -1, false)) do
  out("   |" .. l)
end
engine.teardown()
fresh_config()

out("")
if #failures == 0 then
  out("ALL CHECKS PASSED")
  vim.cmd("qa!")
else
  out(("%d CHECK(S) FAILED"):format(#failures))
  vim.cmd("cquit")
end
