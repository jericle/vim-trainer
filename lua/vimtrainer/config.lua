local M = {}

M.defaults = {
  -- Multiplies every level's time limit. 1.0 = as designed, 1.5 = 50% more time,
  -- 0 = no time limit at all (pure practice).
  time_scale = 1.0,
  -- Multiplies how many extra keystrokes (beyond par) a level tolerates.
  mistake_scale = 1.0,
  -- Where progress is stored. nil = stdpath("data")/vimtrainer/progress.json
  progress_path = nil,
  -- Write live session state as JSON to this file (used by the web page in web/).
  -- nil = off, unless $VIMTRAINER_STATE_FILE is set.
  state_file = nil,
  hud_width = 46,
  relative_numbers = true, -- show relative line numbers while practising (helps with counts)
  block_arrows = true, -- arrow keys / Home / End / PageUp / PageDown do nothing (and count as a wasted key)
  block_mouse = true,
  -- These three keys are never counted as keystrokes.
  keys = { hint = "<F1>", restart = "<F2>", quit = "<F4>" },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

function M.progress_path()
  return M.options.progress_path or (vim.fn.stdpath("data") .. "/vimtrainer/progress.json")
end

return M
