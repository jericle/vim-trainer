if vim.g.loaded_vimtrainer then
  return
end
vim.g.loaded_vimtrainer = 1

if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("vim-trainer needs Neovim 0.10 or newer", vim.log.levels.ERROR)
  return
end

vim.api.nvim_create_user_command("VimTrainer", function(opts)
  require("vimtrainer").command(opts.fargs)
end, {
  nargs = "*",
  desc = "Vim motion trainer: menu, a level number, next, stats, reset, quit",
  complete = function(arglead)
    local all = { "menu", "next", "stats", "reset", "quit", "1", "2", "3", "4", "5" }
    return vim.tbl_filter(function(item)
      return item:find(arglead, 1, true) == 1
    end, all)
  end,
})
