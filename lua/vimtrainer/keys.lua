-- Helpers for key strings such as "ciwfoo<Esc>".
local M = {}

local function utf8_char(s, i)
  return s:match("^[%z\1-\127\194-\244][\128-\191]*", i) or s:sub(i, i)
end

-- "ciwx<Esc>" -> { "c", "i", "w", "x", "<Esc>" }
-- Anything in <...> that Neovim recognises as a key name is one key.
function M.tokens(s)
  local out, i, n = {}, 1, #s
  while i <= n do
    local took = false
    if s:sub(i, i) == "<" then
      local j = s:find(">", i + 1, true)
      if j then
        local name = s:sub(i, j)
        if #name > 2 and not name:find("%s") and vim.keycode(name) ~= name then
          out[#out + 1] = name
          i = j + 1
          took = true
        end
      end
    end
    if not took then
      local ch = utf8_char(s, i)
      out[#out + 1] = ch
      i = i + #ch
    end
  end
  return out
end

function M.count(s)
  return #M.tokens(s)
end

return M
