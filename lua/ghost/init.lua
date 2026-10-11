local server = require("ghost.server")

local M = {}

local ns = vim.api.nvim_create_namespace("ghost")

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

	-- "insert": start the server the first time you enter insert mode.
	-- "startup": start it as soon as Neovim opens.
	-- false: only via :Ghost start.
	autostart = "insert",
	startup_timeout_ms = 60000,
	log_file = vim.fn.stdpath("log") .. "/ghost-server.log",

	debounce_ms = 120,
	prefix_lines = 120,
	suffix_lines = 40,
	max_tokens = 64,
	max_predict_ms = 500,

	disabled_filetypes = { "help", "gitcommit", "gitrebase", "TelescopePrompt", "oil" },

	keys = {
		accept = "<Tab>",
		accept_word = "<C-Right>",
		dismiss = "<C-]>",
	},
}

local cfg = vim.deepcopy(defaults)
local enabled = true
local did_setup = false
local mapped = {}

local state = {
	timer = nil,
	job = nil,
	req_id = 0,
	suggestion = nil, -- { text, buf, row, col }
	own_tick = nil, -- changedtick of our own partial accept, not a user edit
}

-- rendering
local function clear_marks(buf)
	if buf and vim.api.nvim_buf_is_valid(buf) then
		vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	end
end

local function clear()
	clear_marks(state.suggestion and state.suggestion.buf)
	state.suggestion = nil
end

local function show(text, buf, row, col)
	text = text:gsub("%s+$", "")
	if text == "" then
		return
	end

	local lines = vim.split(text, "\n", { plain = true })
	local opts = {
		virt_text = { { lines[1], "GhostText" } },
		virt_text_pos = "inline",
		hl_mode = "combine",
	}
	if #lines > 1 then
		opts.virt_lines = {}
		for i = 2, #lines do
			opts.virt_lines[#opts.virt_lines + 1] = { { lines[i], "GhostText" } }
		end
	end

	vim.api.nvim_buf_set_extmark(buf, ns, row - 1, col, opts)
	state.suggestion = { text = text, buf = buf, row = row, col = col }
end

-- requests
local function buf_allowed(buf)
	return vim.bo[buf].buftype == ""
		and vim.bo[buf].modifiable
		and not vim.tbl_contains(cfg.disabled_filetypes, vim.bo[buf].filetype)
end

local function get_context()
	local buf = vim.api.nvim_get_current_buf()
	local row, col = unpack(vim.api.nvim_win_get_cursor(0))
	local total = vim.api.nvim_buf_line_count(buf)
	local line = vim.api.nvim_get_current_line()

	local before = vim.api.nvim_buf_get_lines(buf, math.max(0, row - 1 - cfg.prefix_lines), row - 1, false)
	table.insert(before, line:sub(1, col))

	local after = { line:sub(col + 1) }
	vim.list_extend(after, vim.api.nvim_buf_get_lines(buf, row, math.min(total, row + cfg.suffix_lines), false))

	return table.concat(before, "\n"), table.concat(after, "\n"), buf, row, col
end

local function cancel()
	if state.timer then
		state.timer:stop()
	end
	if state.job then
		pcall(function()
			state.job:kill(9)
		end)
		state.job = nil
	end
end

local function still_at(buf, row, col)
	if vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i" then
		return false
	end
	if vim.api.nvim_get_current_buf() ~= buf then
		return false
	end
	local cur = vim.api.nvim_win_get_cursor(0)
	return cur[1] == row and cur[2] == col
end

local function request()
	if not enabled or vim.api.nvim_get_mode().mode:sub(1, 1) ~= "i" then
		return
	end
	if not buf_allowed(0) then
		return
	end

	if server.status() ~= "ready" then
		server.ensure() -- first suggestions arrive once the model has loaded
		return
	end

	local prefix, suffix, buf, row, col = get_context()
	state.req_id = state.req_id + 1
	local id = state.req_id

	local body = vim.json.encode({
		input_prefix = prefix,
		input_suffix = suffix,
		n_predict = cfg.max_tokens,
		t_max_predict_ms = cfg.max_predict_ms,
		cache_prompt = true,
		top_k = 40,
		top_p = 0.99,
		stream = false,
		samplers = { "top_k", "top_p", "infill" },
	})

	state.job = vim.system(
		{
			cfg.curl,
			"-s",
			"-f",
			"--noproxy",
			"*",
			"--max-time",
			"10",
			"-X",
			"POST",
			server.url("/infill"),
			"-H",
			"Content-Type: application/json",
			"--data-binary",
			"@-",
		},
		{ stdin = body, text = true },
		function(res)
			vim.schedule(function()
				if id ~= state.req_id then
					return
				end
				state.job = nil
				if res.code == 7 then -- connection refused: server went away
					server.mark_down()
					server.ensure()
					return
				end
				if res.code ~= 0 or not still_at(buf, row, col) then
					return
				end

				local ok, data = pcall(vim.json.decode, res.stdout)
				if not ok or type(data) ~= "table" or type(data.content) ~= "string" then
					return
				end

				clear()
				show(data.content, buf, row, col)
			end)
		end
	)
end

local function schedule_request()
	if state.own_tick and vim.b.changedtick == state.own_tick then
		return
	end
	state.own_tick = nil
	cancel()
	clear()
	if not enabled then
		return
	end
	state.timer = state.timer or vim.uv.new_timer()
	state.timer:start(cfg.debounce_ms, 0, vim.schedule_wrap(request))
end

-- accept/dismiss
local function insert(s, text)
	local lines = vim.split(text, "\n", { plain = true })
	vim.api.nvim_buf_set_text(s.buf, s.row - 1, s.col, s.row - 1, s.col, lines)
	local end_row = s.row + #lines - 1
	local end_col = (#lines == 1 and s.col or 0) + #lines[#lines]
	vim.api.nvim_win_set_cursor(0, { end_row, end_col })
	return end_row, end_col
end

function M.accept(s)
	s = s or state.suggestion
	if not s then
		return false
	end
	clear_marks(s.buf)
	state.suggestion = nil
	insert(s, s.text)
	return true
end

function M.accept_word(s)
	s = s or state.suggestion
	if not s then
		return false
	end
	local word = s.text:match("^%s*[%w_]+") or s.text:match("^%s*[^%w_%s]+") or s.text:match("^%s+")
	if not word then
		return M.accept(s)
	end
	local rest = s.text:sub(#word + 1)
	clear_marks(s.buf)
	state.suggestion = nil
	cancel()
	local row, col = insert(s, word)
	state.own_tick = vim.api.nvim_buf_get_var(s.buf, "changedtick")
	if rest ~= "" then
		show(rest, s.buf, row, col)
	end
	return true
end

function M.dismiss(s)
	cancel()
	clear_marks(s and s.buf)
	clear()
end

function M.is_visible()
	return state.suggestion ~= nil
end

-- setup
local function map(lhs, fn, desc)
	if not lhs or lhs == "" then
		return
	end
	mapped[#mapped + 1] = lhs
	-- Expr mapping: if no suggestion is shown, the key does what it normally does.
	vim.keymap.set("i", lhs, function()
		local s = state.suggestion
		if s then
			-- Take it now so keys typed right after this one see the new state;
			-- the buffer edit itself has to wait until the mapping returns.
			state.suggestion = nil
			vim.schedule(function()
				fn(s)
			end)
			return ""
		end
		return lhs
	end, { expr = true, replace_keycodes = true, desc = desc })
end

local function command(opts)
	local sub = opts.fargs[1] or "status"
	if sub == "start" then
		enabled = true
		server.start()
	elseif sub == "stop" then
		M.dismiss()
		server.stop()
	elseif sub == "toggle" then
		enabled = not enabled
		if not enabled then
			M.dismiss()
		end
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

	vim.api.nvim_set_hl(0, "GhostText", { link = "Comment", default = true })

	for _, lhs in ipairs(mapped) do
		pcall(vim.keymap.del, "i", lhs)
	end
	mapped = {}
	map(cfg.keys.accept, M.accept, "Accept ghost completion")
	map(cfg.keys.accept_word, M.accept_word, "Accept next word of ghost completion")
	map(cfg.keys.dismiss, M.dismiss, "Dismiss ghost completion")

	local group = vim.api.nvim_create_augroup("Ghost", { clear = true })

	vim.api.nvim_create_autocmd("TextChangedI", { group = group, callback = schedule_request })
	vim.api.nvim_create_autocmd({ "InsertLeave", "BufLeave" }, {
		group = group,
		callback = function()
			M.dismiss()
		end,
	})

	vim.api.nvim_create_autocmd("CursorMovedI", {
		group = group,
		callback = function()
			local s = state.suggestion
			if s and not still_at(s.buf, s.row, s.col) then
				clear()
			end
		end,
	})

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

	-- The whole point: no model running once Neovim is gone.
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
