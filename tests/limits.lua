local levels = require("vimtrainer.levels")
for i, lv in ipairs(levels.list) do
  local pars = {}
  for _, ch in ipairs(lv.challenges) do pars[#pars + 1] = ch.par end
  io.stdout:write(string.format("L%d %-26s challenges=%d par=%-3d limit=%ds allowed_extra=%d  pars=%s\n",
    i, lv.name, #lv.challenges, levels.par_total(lv), levels.base_limit(lv), levels.allowed_extra(lv), table.concat(pars, ",")))
end
