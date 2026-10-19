local config = require("vimtrainer.config")
local levels = require("vimtrainer.levels")
local keys = require("vimtrainer.keys")
local progress = require("vimtrainer.progress")
local ui = require("vimtrainer.ui")
local telemetry = require("vimtrainer.telemetry")

local uv = vim.uv or vim.loop

local M = {}

local ns = vim.api.nvim_create_namespace("vimtrainer_keys")
local AUGROUP = "VimTrainerSession"

local state = nil -- the active session, or nil

local REGS = {}
for c in ("abcdefghijklmnopqrstuvwxyz0123456789\"-/"):gmatch(".") do
  REGS[#REGS + 1] = c
end

local ARROWS = {
  "<Left>", "<Right>", "<Up>", "<Down>", "<Home>", "<End>", "<PageUp>", "<PageDown>",
  "<S-Left>", "<S-Right>", "<C-Left>", "<C-Right>", "<S-Up>", "<S-Down>",
}
local MOUSE = {
  "<LeftMouse>", "<RightMouse>", "<MiddleMouse>", "<2-LeftMouse>", "<LeftDrag>", "<LeftRelease>",
  "<ScrollWheelUp>", "<ScrollWheelDown>", "<ScrollWheelLeft>", "<ScrollWheelRight>",
}

local function now()
  return uv.hrtime() / 1e9
end

-- ------------------------------------------------------------ registers

local function save_registers()
  local saved = {}
  for _, r in ipairs(REGS) do
    local ok, info = pcall(vim.fn.getreginfo, r)
    saved[r] = ok and info or {}
  end
  return saved
end

local function clear_registers()
  for _, r in ipairs(REGS) do
    pcall(vim.fn.setreg, r, "")
  end
end

local function restore_registers(saved)
  for r, info in pairs(saved or {}) do
    if type(info) ~= "table" or next(info) == nil then
      pcall(vim.fn.setreg, r, "")
    else
      pcall(vim.fn.setreg, r, info)
    end
  end
end

-- ------------------------------------------------------------ window / buffer setup

local function window_options(win)
  local o = config.options
  local function set(name, value)
    pcall(vim.api.nvim_set_option_value, name, value, { win = win, scope = "local" })
  end
  set("number", true)
  set("relativenumber", o.relative_numbers)
  set("cursorline", true)
  set("wrap", false)
  set("list", false)
  set("signcolumn", "no")
  set("foldcolumn", "0")
  set("foldenable", false)
  set("colorcolumn", "")
  set("spell", false)
  set("winbar", "")
  set("statuscolumn", "")
end

local function set_maps(st, buf, ch)
  local function map(modes, lhs, rhs)
    vim.keymap.set(modes, lhs, rhs, { buffer = buf, nowait = true, silent = true })
  end
  local all = { "n", "i", "v", "x", "o", "s" }
  local k = config.options.keys
  map(all, k.hint, function()
    M.hint()
  end)
  map(all, k.restart, function()
    M.restart()
  end)
  map(all, k.quit, function()
    M.abort()
  end)
  if config.options.block_arrows then
    for _, lhs in ipairs(ARROWS) do
      map({ "n", "i", "v", "x", "o" }, lhs, "<Nop>")
    end
  end
  if config.options.block_mouse then
    for _, lhs in ipairs(MOUSE) do
      map({ "n", "i", "v", "x" }, lhs, "<Nop>")
    end
  end
  for _, lhs in ipairs(ch.forbid or {}) do
    map({ "n", "x" }, lhs, "<Nop>")
  end
end

local function enter_buffer(st, ch)
  local old = st.buf
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "vimtrainer"
  -- keep the user's own indent / formatting settings out of the exercises
  vim.bo[buf].autoindent = false
  vim.bo[buf].smartindent = false
  vim.bo[buf].cindent = false
  vim.bo[buf].indentexpr = ""
  vim.bo[buf].textwidth = 0
  vim.bo[buf].formatoptions = ""
  vim.bo[buf].comments = ""
  vim.bo[buf].omnifunc = ""
  vim.bo[buf].completefunc = ""
  -- ask common plugins to stay out of the way
  vim.b[buf].minipairs_disable = true
  vim.b[buf].autopairs_enabled = false
  vim.b[buf].completion = false
  vim.b[buf].copilot_enabled = false
  vim.b[buf].miniindentscope_disable = true
  vim.b[buf].snacks_indent = false

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, ch.text)
  vim.bo[buf].modified = false
  vim.api.nvim_win_set_buf(st.win, buf)
  st.buf = buf
  pcall(vim.api.nvim_win_set_cursor, st.win, ch.start_pos)
  clear_registers()
  pcall(vim.api.nvim_win_call, st.win, function()
    vim.cmd("clearjumps")
  end)
  set_maps(st, buf, ch)
  if old and old ~= buf and vim.api.nvim_buf_is_valid(old) then
    pcall(vim.api.nvim_buf_delete, old, { force = true })
  end
end

-- ------------------------------------------------------------ HUD

local function hud_data()
  local st = state
  local ch = st.ch
  local total = st.carried + st.keys
  return {
    level = st.level_idx,
    level_name = st.def.name,
    index = st.idx,
    total = #st.def.challenges,
    elapsed = now() - st.t0,
    limit = st.limit,
    keys = total,
    par = ch.par,
    extra = math.max(0, total - ch.par),
    prompt = ch.prompt,
    hint = st.hint_level >= 1 and ch.hint or nil,
    solution = st.hint_level >= 2 and ch.solution or nil,
    forbid = ch.forbid,
    last = st.last,
  }
end

-- What the web page's KPI bar shows. Works with no session too (status "idle").
local function snapshot()
  local records = {}
  for i = 1, #levels.list do
    local e = progress.get(i)
    if e and e.best_time then
      records[tostring(i)] = e.best_time
    end
  end
  local st = state
  if not st then
    return { status = "idle", records = records, levels_total = #levels.list }
  end
  local snap = {
    levels_total = #levels.list,
    status = st.active and "playing" or "finished",
    level = st.level_idx,
    level_name = st.def.name,
    challenges = #st.def.challenges,
    limit = st.limit,
    allowed = levels.allowed_extra(st.def),
    record = records[tostring(st.level_idx)],
    records = records,
  }
  if st.active then
    local total = st.carried + st.keys
    local mistakes = 0
    for _, r in pairs(st.rows) do
      mistakes = mistakes + r.extra
    end
    snap.challenge = st.idx
    snap.elapsed = now() - st.t0
    snap.keys = total
    snap.par = st.ch and st.ch.par or 0
    snap.mistakes = mistakes + (st.ch and math.max(0, total - st.ch.par) or 0)
  elseif st.result then
    local r = st.result
    snap.challenge = r.done
    snap.elapsed = r.elapsed
    snap.keys = r.keys
    snap.par = r.par
    snap.mistakes = r.extra
    snap.result = {
      passed = r.passed,
      stars = r.stars,
      fail_reason = r.fail_reason,
      improved = r.improved,
    }
  end
  return snap
end

local function refresh()
  if state and state.active and state.hud and state.ch then
    ui.hud_update(state.hud, hud_data())
  end
  if state and telemetry.enabled() then
    telemetry.emit(snapshot())
  end
end

-- ------------------------------------------------------------ goal checking

local function matches(st)
  local ch = st.ch
  if not (st.buf and vim.api.nvim_buf_is_valid(st.buf) and vim.api.nvim_win_is_valid(st.win)) then
    return false
  end
  if vim.api.nvim_get_mode().mode ~= "n" then
    return false
  end
  if vim.api.nvim_win_get_buf(st.win) ~= st.buf then
    return false
  end
  if not vim.deep_equal(vim.api.nvim_buf_get_lines(st.buf, 0, -1, false), ch.goal_text) then
    return false
  end
  if ch.goal_pos then
    local c = vim.api.nvim_win_get_cursor(st.win)
    if c[1] ~= ch.goal_pos[1] or c[2] ~= ch.goal_pos[2] then
      return false
    end
  end
  return true
end

local load_challenge

local function complete_challenge()
  local st = state
  if not st or not st.active then
    return
  end
  local ch = st.ch
  local total = st.carried + st.keys
  local row = {
    name = ch.name,
    keys = total,
    par = ch.par,
    extra = math.max(0, total - ch.par),
    time = now() - st.ch_t0,
    done = true,
    hint_level = st.hint_level,
    solution = ch.solution,
  }
  st.rows[st.idx] = row
  st.last = row
  if st.idx < #st.def.challenges then
    load_challenge(st.idx + 1)
  else
    M._finish("complete")
  end
end

local function check()
  local st = state
  if not st or not st.active then
    return
  end
  if matches(st) then
    complete_challenge()
  else
    refresh()
  end
end

-- Counts what the user physically types. Keys that come from a macro (@a), a dot-repeat,
-- or a mapping expansion have an empty `typed`, so they are not counted twice.
local function on_key(_, typed)
  local st = state
  if not st or not st.active then
    return
  end
  if typed == nil or typed == "" then
    return
  end
  if vim.api.nvim_get_current_win() ~= st.win then
    return
  end
  for _, k in ipairs(st.control_keys) do
    if typed == k then
      return
    end
  end
  local name = vim.fn.keytrans(typed)
  if name == "<MouseMove>" then
    return
  end
  st.keys = st.keys + math.max(1, #keys.tokens(name))
  vim.schedule(check)
end

-- ------------------------------------------------------------ challenge flow

load_challenge = function(i)
  local st = state
  local ch = st.def.challenges[i]
  st.idx = i
  st.ch = ch
  st.keys = 0
  st.carried = 0
  st.hint_level = 0
  st.ch_t0 = now()
  enter_buffer(st, ch)
  refresh()
  telemetry.emit(snapshot(), true)
end

function M.hint()
  local st = state
  if not st or not st.active then
    return
  end
  if st.hint_level < 2 then
    st.hint_level = st.hint_level + 1
    if st.hint_level == 1 then
      st.hints = st.hints + 1
    else
      st.solutions = st.solutions + 1
    end
  end
  refresh()
end

-- Restart the current challenge. Keys already spent stay on the bill and the clock keeps running.
function M.restart()
  local st = state
  if not st or not st.active then
    return
  end
  vim.schedule(function()
    if state ~= st or not st.active then
      return
    end
    vim.cmd("stopinsert")
    vim.api.nvim_feedkeys(vim.keycode("<C-\\><C-n>"), "nx", false)
    st.carried = st.carried + st.keys
    st.keys = 0
    enter_buffer(st, st.ch)
    refresh()
  end)
end

function M.abort()
  vim.schedule(function()
    if state then
      M.teardown()
      vim.notify("Vim Trainer: stopped (this attempt was not recorded)", vim.log.levels.INFO)
    end
  end)
end

-- ------------------------------------------------------------ finishing

local function rate(res)
  if not res.passed then
    return 0
  end
  local lim = res.limit > 0 and res.limit or res.base_limit
  local time_ratio = res.elapsed / lim
  local extra_ratio = res.extra / math.max(1, res.par)
  local stars = 1
  if time_ratio <= 0.85 and extra_ratio <= 0.30 then
    stars = 2
  end
  if time_ratio <= 0.60 and extra_ratio <= 0.10 then
    stars = 3
  end
  if res.solutions > 0 then
    stars = math.min(stars, 1)
  elseif res.hints > 0 then
    stars = math.min(stars, 2)
  end
  return stars
end

local function show_summary(st, res)
  ui.hud_close(st.hud)
  ui.summary(res, {
    retry = function()
      local idx = st.level_idx
      M.teardown()
      M.start(idx)
    end,
    next = function()
      local idx = st.level_idx + 1
      M.teardown()
      if levels.list[idx] then
        M.start(idx)
      else
        require("vimtrainer").menu()
      end
    end,
    menu = function()
      M.teardown()
      require("vimtrainer").menu()
    end,
    close = function()
      M.teardown()
    end,
  })
end

local halt

function M._finish(reason)
  local st = state
  if not st or not st.active then
    return
  end
  st.active = false
  halt(st)

  local def = st.def
  local el = now() - st.t0
  local timed_out = reason == "timeout" or (st.limit > 0 and el > st.limit)
  if timed_out and st.limit > 0 then
    el = math.min(el, st.limit)
  end

  local rows, keys_total, par_done, extra_total, done = {}, 0, 0, 0, 0
  for i, ch in ipairs(def.challenges) do
    local r = st.rows[i]
    if r then
      rows[i] = r
      keys_total = keys_total + r.keys
      par_done = par_done + r.par
      extra_total = extra_total + r.extra
      done = done + 1
    else
      rows[i] = { name = ch.name, par = ch.par, done = false }
    end
  end

  local allowed = levels.allowed_extra(def)
  local passed, fail_reason = false, nil
  if timed_out then
    fail_reason = "time"
  elseif done < #def.challenges then
    fail_reason = "incomplete"
  elseif extra_total > allowed then
    fail_reason = "mistakes"
  else
    passed = true
  end

  local res = {
    level = st.level_idx,
    name = def.name,
    reason = reason,
    passed = passed,
    fail_reason = fail_reason,
    elapsed = el,
    limit = st.limit,
    base_limit = levels.base_limit(def),
    keys = keys_total,
    par = par_done,
    par_total = levels.par_total(def),
    extra = extra_total,
    allowed = allowed,
    done = done,
    total = #def.challenges,
    hints = st.hints,
    solutions = st.solutions,
    rows = rows,
    has_next = levels.list[st.level_idx + 1] ~= nil,
  }
  res.stars = rate(res)
  res.improved = progress.record(st.level_idx, res)
  res.best = progress.get(st.level_idx)
  st.result = res
  telemetry.emit(snapshot(), true)

  -- leave insert / pending-operator / command-line state before the summary opens
  pcall(vim.cmd, "stopinsert")
  vim.api.nvim_feedkeys(vim.keycode("<C-\\><C-n>"), "n", false)
  vim.defer_fn(function()
    if state == st then
      show_summary(st, res)
    end
  end, 60)
end

function M._tick()
  local st = state
  if not st or not st.active then
    return
  end
  if st.limit > 0 and now() - st.t0 >= st.limit then
    M._finish("timeout")
  else
    refresh()
  end
end

-- ------------------------------------------------------------ lifecycle

halt = function(st)
  if st.timer then
    local t = st.timer
    st.timer = nil
    pcall(function()
      t:stop()
    end)
    pcall(function()
      if not t:is_closing() then
        t:close()
      end
    end)
  end
  pcall(vim.on_key, nil, ns)
end

function M.teardown()
  local st = state
  if not st then
    return
  end
  state = nil
  st.active = false
  halt(st)
  pcall(vim.api.nvim_del_augroup_by_name, AUGROUP)
  ui.hud_close(st.hud)
  ui.close_summary()
  restore_registers(st.saved_regs)
  if st.tab and vim.api.nvim_tabpage_is_valid(st.tab) and #vim.api.nvim_list_tabpages() > 1 then
    pcall(vim.cmd, vim.api.nvim_tabpage_get_number(st.tab) .. "tabclose!")
  end
  if st.prev_tab and vim.api.nvim_tabpage_is_valid(st.prev_tab) then
    pcall(vim.api.nvim_set_current_tabpage, st.prev_tab)
  end
  telemetry.emit(snapshot(), true) -- state is nil now: reports "idle"
end

function M.stop()
  M.teardown()
end

function M.start(level_idx)
  M.teardown()
  local def = levels.list[level_idx]
  if not def then
    vim.notify("Vim Trainer: there is no level " .. tostring(level_idx), vim.log.levels.ERROR)
    return
  end

  local prev_tab = vim.api.nvim_get_current_tabpage()
  vim.cmd("tab split")
  local win = vim.api.nvim_get_current_win()
  local k = config.options.keys
  local st = {
    level_idx = level_idx,
    def = def,
    win = win,
    tab = vim.api.nvim_get_current_tabpage(),
    prev_tab = prev_tab,
    idx = 0,
    rows = {},
    active = true,
    limit = levels.limit(def),
    hints = 0,
    solutions = 0,
    keys = 0,
    carried = 0,
    hint_level = 0,
    saved_regs = save_registers(),
    control_keys = { vim.keycode(k.hint), vim.keycode(k.restart), vim.keycode(k.quit) },
  }
  state = st
  window_options(win)
  st.hud = ui.hud_open(win)

  local group = vim.api.nvim_create_augroup(AUGROUP, { clear = true })
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    pattern = tostring(win),
    once = true,
    callback = function()
      vim.schedule(function()
        if state == st then
          M.teardown()
        end
      end)
    end,
  })
  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      if state == st then
        ui.hud_reposition(st.hud)
        refresh()
      end
    end,
  })
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = group,
    callback = function()
      halt(st)
    end,
  })

  vim.on_key(on_key, ns)
  st.t0 = now()
  st.timer = uv.new_timer()
  st.timer:start(200, 200, vim.schedule_wrap(M._tick))
  load_challenge(1)
end

-- Push the current state (idle or playing) to the state file, if one is configured.
function M.publish()
  telemetry.emit(snapshot(), true)
end

-- for tests
function M._state()
  return state
end

return M
