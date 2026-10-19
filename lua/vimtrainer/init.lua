local M = {}

function M.setup(opts)
  require("vimtrainer.config").setup(opts)
end

function M.menu()
  require("vimtrainer.engine").publish()
  require("vimtrainer.ui").menu({
    on_start = function(i)
      M.start(i)
    end,
  })
end

function M.start(level)
  require("vimtrainer.engine").start(level)
end

function M.command(args)
  local arg = args[1]
  local progress = require("vimtrainer.progress")
  local levels = require("vimtrainer.levels")
  if arg == nil or arg == "" or arg == "menu" then
    return M.menu()
  end
  local n = tonumber(arg)
  if n then
    return M.start(n)
  end
  if arg == "next" then
    progress.load()
    return M.start(progress.next_level(#levels.list))
  end
  if arg == "stats" then
    return require("vimtrainer.ui").stats()
  end
  if arg == "reset" then
    if vim.fn.confirm("Reset all Vim Trainer progress?", "&Yes\n&No", 2) == 1 then
      progress.reset()
      vim.notify("Vim Trainer: progress reset")
    end
    return
  end
  if arg == "quit" or arg == "stop" then
    return require("vimtrainer.engine").stop()
  end
  vim.notify("Usage: :VimTrainer [menu | <level> | next | stats | reset | quit]", vim.log.levels.WARN)
end

return M
