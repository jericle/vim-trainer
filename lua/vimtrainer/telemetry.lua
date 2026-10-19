-- Optional live state export. When `state_file` (or $VIMTRAINER_STATE_FILE) is set, the current
-- session state is written there as JSON a few times per second. The web page in web/ uses it
-- to drive its KPI bar. Nothing is written when no path is configured.
local config = require("vimtrainer.config")

local uv = vim.uv or vim.loop

local M = {}

local last = 0

function M.path()
  local p = config.options.state_file or vim.env.VIMTRAINER_STATE_FILE
  if p == nil or p == "" then
    return nil
  end
  return p
end

function M.enabled()
  return M.path() ~= nil
end

-- `tbl` is encoded as JSON. Non-forced writes are limited to ~10 per second.
function M.emit(tbl, force)
  local path = M.path()
  if not path then
    return
  end
  local t = uv.hrtime() / 1e9
  if not force and t - last < 0.1 then
    return
  end
  last = t
  tbl.ts = os.time()
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then
    return
  end
  f:write(vim.json.encode(tbl))
  f:close()
  uv.fs_rename(tmp, path)
end

return M
