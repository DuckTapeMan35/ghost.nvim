local server = require("ghost.server")
local lsp = require("ghost.lsp")

local M = {}

-- Paths baked in by the Nix package; absent when installed some other way.
local ok_nix, nix = pcall(require, "ghost.nix")
if not ok_nix then
	nix = nil
end

local defaults = {
	-- How to run the server. The Nix build fills these in; otherwise llama.cpp's
	-- built-in preset downloads Qwen2.5-Coder 1.5B on first use.
	server_cmd = nix and nix.server_cmd or { "llama-server", "--fim-qwen-1.5b-default", "--host", "127.0.0.1" },
	pass_pid = nix and nix.pass_pid or false, -- append Neovim's PID (for the Nix watchdog)
	curl = nix and nix.curl or "curl",
	port = nix and nix.port or 8012,

	-- "insert": start the model the first time you enter insert mode.
	-- "startup": start it as soon as Neovim opens.
	-- false: only via :Ghost start.
	autostart = "insert",
	startup_timeout_ms = 60000,
	log_file = vim.fn.stdpath("log") .. "/ghost-server.log",

	-- Completion menus wait for every language server, so the model gets this
	-- long to answer. If it's slower, the menu shows without it and the answer
	-- is kept for your next keystroke.
	lsp_timeout_ms = 1000,
	debounce_ms = 80,
	trigger_characters = {},
	label_width = 60,

	prefix_lines = 120,
	suffix_lines = 40,
	max_tokens = 64,
	max_predict_ms = 500,

	disabled_filetypes = { "help", "gitcommit", "gitrebase", "TelescopePrompt", "oil" },
}

local cfg = vim.deepcopy(defaults)
local enabled = true
local did_setup = false

local function buf_allowed(buf)
	buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
	return vim.api.nvim_buf_is_valid(buf)
		and vim.bo[buf].buftype == ""
		and vim.bo[buf].modifiable
		and vim.bo[buf].filetype ~= ""
		and not vim.tbl_contains(cfg.disabled_filetypes, vim.bo[buf].filetype)
end

function M.config()
	return cfg
end

function M.is_enabled()
	return enabled
end

M.buf_allowed = buf_allowed

local function command(opts)
	local sub = opts.fargs[1] or "status"
	if sub == "start" then
		enabled = true
		server.start()
	elseif sub == "stop" then
		server.stop()
	elseif sub == "toggle" then
		enabled = not enabled
		vim.notify("ghost: " .. (enabled and "enabled" or "disabled"))
	elseif sub == "log" then
		vim.cmd.split(vim.fn.fnameescape(cfg.log_file))
	else
		vim.notify(
			("ghost: %s, server %s%s on port %d"):format(
				enabled and "enabled" or "disabled",
				server.status(),
				server.owned() and " (owned by this Neovim)" or "",
				cfg.port
			)
		)
	end
end

function M.setup(opts)
	cfg = vim.tbl_deep_extend("force", vim.deepcopy(defaults), opts or {})
	did_setup = true
	server.setup(cfg)
	lsp.setup(cfg, function()
		return enabled
	end, buf_allowed)

	local group = vim.api.nvim_create_augroup("Ghost", { clear = true })

	-- Attach the language server to every code buffer.
	vim.api.nvim_create_autocmd("FileType", {
		group = group,
		callback = function(ev)
			lsp.attach(ev.buf)
		end,
	})
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(buf) then
			lsp.attach(buf)
		end
	end

	if cfg.autostart == "insert" then
		vim.api.nvim_create_autocmd("InsertEnter", {
			group = group,
			callback = function(ev)
				if enabled and buf_allowed(ev.buf) then
					server.ensure()
				end
			end,
		})
	elseif cfg.autostart == "startup" then
		if vim.v.vim_did_enter == 1 then
			server.ensure()
		else
			vim.api.nvim_create_autocmd("VimEnter", { group = group, once = true, callback = server.ensure })
		end
	end

	-- No model running once Neovim is gone.
	vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = server.stop })

	vim.api.nvim_create_user_command("Ghost", command, {
		nargs = "?",
		complete = function()
			return { "status", "start", "stop", "toggle", "log" }
		end,
		desc = "ghost.nvim: status | start | stop | toggle | log",
	})
end

--- Called from plugin/ghost.lua so installing the plugin is enough.
function M._autosetup()
	if not did_setup then
		M.setup({})
	end
end

return M
