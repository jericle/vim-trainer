local config = require("vimtrainer.config")
local levels = require("vimtrainer.levels")
local progress = require("vimtrainer.progress")

local M = {}

local ns = vim.api.nvim_create_namespace("vimtrainer_ui")

M._menu_win = nil
M._summary_win = nil

function M.define_highlights()
  local function hl(name, def)
    def.default = true
    vim.api.nvim_set_hl(0, name, def)
  end
  hl("VimTrainerTitle", { link = "Title" })
  hl("VimTrainerDim", { link = "Comment" })
  hl("VimTrainerGood", { link = "DiagnosticOk" })
  hl("VimTrainerWarn", { link = "DiagnosticWarn" })
  hl("VimTrainerBad", { link = "DiagnosticError" })
  hl("VimTrainerKey", { link = "Special" })
  hl("VimTrainerTask", { bold = true })
end

-- ---------------------------------------------------------------- helpers

function M.fmt_time(s)
  s = math.max(0, math.ceil(s - 1e-9))
  return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

function M.fmt_secs(s)
  return string.format("%.1fs", s)
end

function M.stars(n)
  return string.rep("★", n) .. string.rep("☆", 3 - n)
end

local function pad(s, w)
  return s .. string.rep(" ", math.max(0, w - vim.fn.strdisplaywidth(s)))
end

local function rpad(s, w)
  return string.rep(" ", math.max(0, w - vim.fn.strdisplaywidth(s))) .. s
end

local function wrap(text, width)
  local out, line = {}, ""
  for word in text:gmatch("%S+") do
    if line == "" then
      line = word
    elseif #line + 1 + #word <= width then
      line = line .. " " .. word
    else
      out[#out + 1] = line
      line = word
    end
  end
  if line ~= "" then
    out[#out + 1] = line
  end
  return out
end

local function keyname(k)
  return (k:gsub("^<", ""):gsub(">$", ""))
end

-- rows: list of strings or list of segments { {text, highlight?}, ... }
local function put(buf, rows)
  local lines, marks = {}, {}
  for r, row in ipairs(rows) do
    if type(row) == "string" then
      row = { { row } }
    end
    local text = ""
    for _, seg in ipairs(row) do
      local t, hl = seg[1], seg[2]
      if hl and #t > 0 then
        marks[#marks + 1] = { r - 1, #text, #text + #t, hl }
      end
      text = text .. t
    end
    lines[r] = text
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, m in ipairs(marks) do
    vim.api.nvim_buf_set_extmark(buf, ns, m[1], m[2], { end_col = m[3], hl_group = m[4] })
  end
  return lines
end

local function scratch()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  return buf
end

local function float(buf, lines, opts)
  local maxw = opts.min_width or 20
  for _, l in ipairs(lines) do
    maxw = math.max(maxw, vim.fn.strdisplaywidth(l))
  end
  local width = math.min(vim.o.columns - 4, maxw + 2)
  local height = math.min(vim.o.lines - 4, #lines)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - height) / 2) - 1),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = "rounded",
    title = opts.title,
    title_pos = "center",
    zindex = 60,
  })
  vim.wo[win].cursorline = opts.cursorline or false
  vim.wo[win].wrap = false
  return win
end

local function map(buf, lhs, fn)
  vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, silent = true })
end

local function rule(width)
  return { { " " .. string.rep("─", width), "VimTrainerDim" } }
end

-- ---------------------------------------------------------------- HUD

local function hud_width(host)
  local want = config.options.hud_width
  return math.max(30, math.min(want, vim.api.nvim_win_get_width(host) - 20))
end

function M.hud_open(host)
  M.define_highlights()
  local buf = scratch()
  local width = hud_width(host)
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "win",
    win = host,
    anchor = "NE",
    row = 0,
    col = vim.api.nvim_win_get_width(host),
    width = width,
    height = 8,
    style = "minimal",
    border = "rounded",
    title = " Vim Trainer ",
    title_pos = "center",
    focusable = false,
    zindex = 40,
    noautocmd = true,
  })
  return { buf = buf, win = win, host = host, width = width }
end

function M.hud_reposition(hud)
  if not (hud and vim.api.nvim_win_is_valid(hud.win) and vim.api.nvim_win_is_valid(hud.host)) then
    return
  end
  hud.width = hud_width(hud.host)
  pcall(vim.api.nvim_win_set_config, hud.win, {
    relative = "win",
    win = hud.host,
    anchor = "NE",
    row = 0,
    col = vim.api.nvim_win_get_width(hud.host),
    width = hud.width,
  })
end

local function hud_rows(d, width)
  local inner = width - 2
  local rows = {}
  local function add(r)
    rows[#rows + 1] = r
  end

  add({ { (" Level %d · %s"):format(d.level, d.level_name), "VimTrainerTitle" } })
  local done = d.index - 1
  add({
    { " " .. string.rep("▰", done) .. string.rep("▱", d.total - done), "VimTrainerKey" },
    { ("  challenge %d of %d"):format(d.index, d.total), "VimTrainerDim" },
  })
  if d.limit > 0 then
    local left = d.limit - d.elapsed
    local hl = "VimTrainerGood"
    if left <= d.limit * 0.2 then
      hl = "VimTrainerBad"
    elseif left <= d.limit * 0.4 then
      hl = "VimTrainerWarn"
    end
    add({
      { " Time  " },
      { M.fmt_time(left), hl },
      { ("  left of %s"):format(M.fmt_time(d.limit)), "VimTrainerDim" },
    })
  else
    add({ { " Time  " }, { M.fmt_time(d.elapsed) }, { "  (no limit)", "VimTrainerDim" } })
  end
  add({
    { " Keys  " },
    { tostring(d.keys) },
    { ("   par %d   "):format(d.par), "VimTrainerDim" },
    { ("extra +%d"):format(d.extra), d.extra > 0 and "VimTrainerWarn" or "VimTrainerDim" },
  })
  add(rule(inner - 2))
  for _, line in ipairs(wrap(d.prompt, inner - 2)) do
    add({ { " " .. line, "VimTrainerTask" } })
  end
  if d.forbid and #d.forbid > 0 then
    add({ { " Not allowed: ", "VimTrainerBad" }, { table.concat(d.forbid, " ") } })
  end
  if d.hint then
    for i, line in ipairs(wrap("Hint: " .. d.hint, inner - 2)) do
      add({ { " " .. line, "VimTrainerDim" } })
    end
  end
  if d.solution then
    add({ { " Solution: ", "VimTrainerDim" }, { d.solution, "VimTrainerKey" } })
  end
  if d.last then
    local l = d.last
    local used = ("%d %s"):format(l.keys, l.keys == 1 and "key" or "keys")
    if l.extra > 0 then
      add({
        { " Last ✓ ", "VimTrainerGood" },
        { ("%s, par %d. Best: "):format(used, l.par), "VimTrainerDim" },
        { l.solution, "VimTrainerKey" },
      })
    else
      add({ { " Last ✓ ", "VimTrainerGood" }, { ("%s, par %d. Perfect!"):format(used, l.par), "VimTrainerDim" } })
    end
  end
  add(rule(inner - 2))
  local k = config.options.keys
  add({ { (" %s hint · %s restart · %s quit"):format(keyname(k.hint), keyname(k.restart), keyname(k.quit)), "VimTrainerDim" } })
  return rows
end

function M.hud_update(hud, d)
  if not (hud and vim.api.nvim_buf_is_valid(hud.buf) and vim.api.nvim_win_is_valid(hud.win)) then
    return
  end
  local rows = hud_rows(d, hud.width)
  put(hud.buf, rows)
  pcall(vim.api.nvim_win_set_config, hud.win, { height = #rows, width = hud.width })
end

function M.hud_close(hud)
  if hud and hud.win and vim.api.nvim_win_is_valid(hud.win) then
    pcall(vim.api.nvim_win_close, hud.win, true)
  end
end

-- ---------------------------------------------------------------- menu

function M.close_menu()
  if M._menu_win and vim.api.nvim_win_is_valid(M._menu_win) then
    pcall(vim.api.nvim_win_close, M._menu_win, true)
  end
  M._menu_win = nil
end

function M.menu(opts)
  M.define_highlights()
  M.close_menu()
  progress.load()
  local list = levels.list
  local n = #list
  local nxt = progress.next_level(n)

  local rows = {
    { { " Vim Motion Trainer", "VimTrainerTitle" } },
    { { " Pass a level inside its time limit to move up. Start anywhere.", "VimTrainerDim" } },
    "",
  }
  local first = #rows + 1
  for i, lv in ipairs(list) do
    local e = progress.get(i)
    local stars = e and e.stars or 0
    local best = (e and e.best_time) and M.fmt_time(e.best_time) or "—"
    local limit = levels.limit(lv)
    local row = {
      { (" %d  "):format(i) },
      { pad(lv.name, 25), "VimTrainerTitle" },
      { M.stars(stars) .. "  ", stars > 0 and "VimTrainerWarn" or "VimTrainerDim" },
      { pad("best " .. best, 11), "VimTrainerDim" },
      { "limit " .. (limit > 0 and M.fmt_time(limit) or "none") .. "  ", "VimTrainerDim" },
    }
    if e and e.passed then
      row[#row + 1] = { "✓", "VimTrainerGood" }
    elseif i == nxt then
      row[#row + 1] = { "◀ next", "VimTrainerGood" }
    end
    rows[#rows + 1] = row
  end
  local last = #rows
  rows[#rows + 1] = ""
  local blurb_row = #rows + 1
  rows[#rows + 1] = ""
  rows[#rows + 1] = { { " j/k move · Enter start · 1-" .. n .. " jump to level · r reset progress · q close", "VimTrainerDim" } }

  local buf = scratch()
  local lines = put(buf, rows)
  local win = float(buf, lines, { title = " Levels ", cursorline = true, min_width = 70 })
  M._menu_win = win

  local function show_blurb()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    if row < first then
      row = first
    elseif row > last then
      row = last
    end
    local lv = list[row - first + 1]
    if not lv then
      return
    end
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, blurb_row - 1, blurb_row, false, {
      (" %s  ·  %d challenges, par %d keys"):format(lv.blurb, #lv.challenges, levels.par_total(lv)),
    })
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, ns, blurb_row - 1, blurb_row)
    vim.api.nvim_buf_set_extmark(buf, ns, blurb_row - 1, 0, { end_row = blurb_row, hl_group = "VimTrainerKey" })
  end

  vim.api.nvim_win_set_cursor(win, { first + nxt - 1, 0 })
  show_blurb()

  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      local row = vim.api.nvim_win_get_cursor(win)[1]
      if row < first then
        vim.api.nvim_win_set_cursor(win, { first, 0 })
      elseif row > last then
        vim.api.nvim_win_set_cursor(win, { last, 0 })
      end
      show_blurb()
    end,
  })

  local function start(i)
    M.close_menu()
    opts.on_start(i)
  end

  map(buf, "<CR>", function()
    local row = vim.api.nvim_win_get_cursor(win)[1]
    start(math.max(1, math.min(n, row - first + 1)))
  end)
  for i = 1, n do
    map(buf, tostring(i), function()
      start(i)
    end)
  end
  map(buf, "q", M.close_menu)
  map(buf, "<Esc>", M.close_menu)
  map(buf, "r", function()
    if vim.fn.confirm("Reset all Vim Trainer progress?", "&Yes\n&No", 2) == 1 then
      progress.reset()
      M.menu(opts)
    end
  end)
  return win
end

-- ---------------------------------------------------------------- summary

function M.close_summary()
  if M._summary_win and vim.api.nvim_win_is_valid(M._summary_win) then
    pcall(vim.api.nvim_win_close, M._summary_win, true)
  end
  M._summary_win = nil
end

function M.summary(res, actions)
  M.define_highlights()
  M.close_summary()
  local W = 54
  local rows = {}
  local function add(r)
    rows[#rows + 1] = r
  end

  if res.passed then
    add({ { (" ✓ LEVEL %d PASSED   "):format(res.level), "VimTrainerGood" }, { M.stars(res.stars), "VimTrainerWarn" } })
  elseif res.fail_reason == "time" then
    add({ { (" ✗ LEVEL %d: TIME'S UP"):format(res.level), "VimTrainerBad" } })
  else
    add({ { (" ✗ LEVEL %d: TOO MANY EXTRA KEYS"):format(res.level), "VimTrainerBad" } })
  end
  add({ { " " .. res.name, "VimTrainerTitle" } })
  add(rule(W))
  add({ { string.format(" %2s  %-22s %4s %4s %5s  %7s", "#", "Skill", "Keys", "Par", "Extra", "Time"), "VimTrainerDim" } })
  for i, r in ipairs(res.rows) do
    if r.done then
      local line = string.format(" %2d  %-22s %4d %4d %5d  %7s", i, r.name:sub(1, 22), r.keys, r.par, r.extra, M.fmt_secs(r.time))
      local seg = { { line } }
      if r.hint_level == 1 then
        seg[#seg + 1] = { " hint", "VimTrainerDim" }
      elseif r.hint_level >= 2 then
        seg[#seg + 1] = { " solution", "VimTrainerWarn" }
      end
      add(seg)
    else
      add({
        {
          string.format(" %2d  ", i) .. pad(r.name:sub(1, 22), 22) .. " " .. rpad("—", 4) .. " " .. rpad("—", 4) .. " " .. rpad("—", 5) .. "  " .. rpad("—", 7),
          "VimTrainerDim",
        },
      })
    end
  end
  add(rule(W))

  local time_hl = (res.fail_reason == "time") and "VimTrainerBad" or "VimTrainerGood"
  if res.limit > 0 then
    add({ { " Time        " }, { M.fmt_time(res.elapsed), time_hl }, { " of " .. M.fmt_time(res.limit) .. " allowed", "VimTrainerDim" } })
  else
    add({ { " Time        " }, { M.fmt_time(res.elapsed) }, { " (no limit)", "VimTrainerDim" } })
  end
  add({ { " Keystrokes  " }, { tostring(res.keys) }, { ("  (par %d)"):format(res.par), "VimTrainerDim" } })
  local mistake_hl = res.extra > res.allowed and "VimTrainerBad" or (res.extra == 0 and "VimTrainerGood" or nil)
  add({
    { " Mistakes    " },
    { ("%d extra keys"):format(res.extra), mistake_hl },
    { ("  (up to %d allowed)"):format(res.allowed), "VimTrainerDim" },
  })
  if res.hints > 0 or res.solutions > 0 then
    add({
      {
        (" Help        %d %s, %d %s shown"):format(
          res.hints, res.hints == 1 and "hint" or "hints",
          res.solutions, res.solutions == 1 and "solution" or "solutions"
        ),
        "VimTrainerDim",
      },
    })
  end
  if res.done < res.total then
    add({ { (" Progress    %d of %d challenges done"):format(res.done, res.total), "VimTrainerDim" } })
  end
  if res.passed then
    if res.improved then
      add({ { " New personal best time!", "VimTrainerGood" } })
    elseif res.best and res.best.best_time then
      add({ { (" Best time    %s  %s"):format(M.fmt_time(res.best.best_time), M.stars(res.best.stars or 0)), "VimTrainerDim" } })
    end
  end
  add(rule(W))
  local primary
  if res.passed and res.has_next then
    primary = "Enter next level"
  elseif res.passed then
    primary = "Enter menu"
  else
    primary = "Enter retry"
  end
  add({ { (" %s · r retry · n next · m menu · q close"):format(primary), "VimTrainerDim" } })

  local buf = scratch()
  local lines = put(buf, rows)
  local win = float(buf, lines, { title = " Result ", min_width = W })
  M._summary_win = win

  map(buf, "<CR>", function()
    if res.passed and res.has_next then
      actions.next()
    elseif res.passed then
      actions.menu()
    else
      actions.retry()
    end
  end)
  map(buf, "r", actions.retry)
  map(buf, "n", actions.next)
  map(buf, "m", actions.menu)
  map(buf, "q", actions.close)
  map(buf, "<Esc>", actions.close)
  return win
end

-- ---------------------------------------------------------------- stats

function M.stats()
  M.define_highlights()
  progress.load()
  local d = progress.data()
  local rows = { { { " Vim Trainer: history (latest first)", "VimTrainerTitle" } }, "" }
  if #d.history == 0 then
    rows[#rows + 1] = { { " Nothing recorded yet. Run :VimTrainer and play a level.", "VimTrainerDim" } }
  else
    rows[#rows + 1] = { { " when              level  result  time   keys  extra  stars", "VimTrainerDim" } }
    local shown = 0
    for i = #d.history, 1, -1 do
      local h = d.history[i]
      rows[#rows + 1] = {
        {
          string.format(
            " %-17s  %d      %-6s  %-5s  %-4d  %-5d  %s",
            h.ts or "?",
            h.level or 0,
            h.passed and "PASS" or "fail",
            M.fmt_time(h.time or 0),
            h.keys or 0,
            h.extra or 0,
            M.stars(h.stars or 0)
          ),
          h.passed and "VimTrainerGood" or "VimTrainerDim",
        },
      }
      shown = shown + 1
      if shown >= 15 then
        break
      end
    end
  end
  rows[#rows + 1] = ""
  rows[#rows + 1] = { { " q close", "VimTrainerDim" } }
  local buf = scratch()
  local lines = put(buf, rows)
  float(buf, lines, { title = " Stats ", min_width = 58 })
  map(buf, "q", function()
    vim.cmd("close")
  end)
  map(buf, "<Esc>", function()
    vim.cmd("close")
  end)
end

return M
