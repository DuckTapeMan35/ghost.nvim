if vim.g.loaded_ghost then
	return
end
vim.g.loaded_ghost = true

if vim.fn.has("nvim-0.10") == 0 or vim.g.ghost_no_autosetup then
	return
end
require("ghost")._autosetup()
