local complete = require("ghost.complete")

local M = {}

local cfg
local enabled = function()
	return true
end
local allowed = function()
	return true
end

-- Last suggestion, so typing along with it answers instantly without asking
-- the model again: { buf, row, line_prefix, text }
local cache = nil
-- A model request that outlived its time budget; kept running to fill the
-- cache, and cancelled when a newer one starts.
local background = nil

local function first_line(s)
	return (s:match("^[^\n]*"))
end

local function make_item(buf, row, col, text)
	local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
	local keyword = line:sub(1, col):match("[%w_]*$") or ""
	local full = keyword .. text
	local label = first_line(full)
	if #label > cfg.label_width or full:find("\n") then
		label = label:sub(1, cfg.label_width) .. "…"
	end
	return {
		label = label,
		filterText = first_line(full),
		sortText = "\0", -- sort ahead of other items with an equal score
		score_offset = cfg.score_offset,
		kind = vim.lsp.protocol.CompletionItemKind.Text,
		labelDetails = { description = "ghost" },
		insertTextFormat = vim.lsp.protocol.InsertTextFormat.PlainText,
		-- Replace the word typed so far with keyword + suggestion, so the item
		-- survives fuzzy filtering on that word.
		textEdit = {
			newText = full,
			range = {
				start = { line = row - 1, character = col - #keyword },
				["end"] = { line = row - 1, character = col },
			},
		},
		documentation = {
			kind = "markdown",
			value = ("```%s\n%s\n```"):format(vim.bo[buf].filetype, full),
		},
	}
end

local function from_cache(buf, row, col)
	if not cache or cache.buf ~= buf or cache.row ~= row then
		return nil
	end
	local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
	local prefix = line:sub(1, col)
	if prefix:sub(1, #cache.line_prefix) ~= cache.line_prefix then
		return nil
	end
	local typed = prefix:sub(#cache.line_prefix + 1)
	if typed:find("\n") or cache.text:sub(1, #typed) ~= typed or #typed >= #cache.text then
		return nil
	end
	return cache.text:sub(#typed + 1)
end

local function remember(buf, row, col, text)
	local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""
	cache = { buf = buf, row = row, line_prefix = line:sub(1, col), text = text }
end

-- Answer one textDocument/completion request. reply(result) exactly once,
-- unless cancelled. Returns a cancel function.
local function completion(params, reply)
	local buf = vim.uri_to_bufnr(params.textDocument.uri)
	local row, col = params.position.line + 1, params.position.character

	local function items(list)
		-- Always incomplete: the suggestion depends on exactly what's typed.
		reply({ isIncomplete = true, items = list })
	end

	if not vim.api.nvim_buf_is_loaded(buf) or not enabled() or not allowed(buf) then
		items({})
		return function() end
	end

	local cached = from_cache(buf, row, col)
	if cached then
		items({ make_item(buf, row, col, cached) })
		return function() end
	end

	local replied, cancelled = false, false
	local debounce, budget = vim.uv.new_timer(), vim.uv.new_timer()
	local cancel_fetch = nil

	local function close(t)
		if t and not t:is_closing() then
			t:stop()
			t:close()
		end
	end

	local function respond(list)
		if replied or cancelled then
			return
		end
		replied = true
		close(budget)
		items(list)
	end

	-- Wait a moment so fast typing doesn't start model work for every key.
	debounce:start(
		cfg.debounce_ms,
		0,
		vim.schedule_wrap(function()
			close(debounce)
			if cancelled then
				return
			end
			if background then
				background()
				background = nil
			end

			local this
			this = complete.fetch(cfg, buf, row, col, function(text)
				if background == this then
					background = nil
				end
				if text then
					remember(buf, row, col, text)
				end
				respond(text and { make_item(buf, row, col, text) } or {})
			end)
			cancel_fetch = this

			-- Don't hold up the other language servers for longer than this.
			budget:start(
				cfg.lsp_timeout_ms,
				0,
				vim.schedule_wrap(function()
					if replied or cancelled then
						return
					end
					background = this -- let it finish and fill the cache
					cancel_fetch = nil
					respond({})
				end)
			)
		end)
	)

	return function()
		if replied then
			return
		end
		cancelled = true
		close(debounce)
		close(budget)
		if cancel_fetch then
			cancel_fetch()
		end
	end
end

-- The server, in the shape vim.lsp.start() accepts for `cmd`.
local function server(dispatchers)
	local closing = false
	local next_id = 0
	local pending = {}

	local srv = {}

	function srv.request(method, params, callback, notify_reply_callback)
		next_id = next_id + 1
		local id = next_id
		local function reply(err, result)
			vim.schedule(function()
				pending[id] = nil
				callback(err, result)
				if notify_reply_callback then
					notify_reply_callback(id)
				end
			end)
		end

		if method == "initialize" then
			reply(nil, {
				capabilities = {
					positionEncoding = "utf-8",
					textDocumentSync = { openClose = false, change = 0 },
					completionProvider = {
						triggerCharacters = cfg.trigger_characters,
						resolveProvider = false,
					},
				},
				serverInfo = { name = "ghost" },
			})
		elseif method == "textDocument/completion" then
			pending[id] = completion(params, function(result)
				reply(nil, result)
			end)
		elseif method == "shutdown" then
			reply(nil, nil)
		else
			reply({ code = -32601, message = "ghost: unsupported method " .. method })
		end
		return true, id
	end

	function srv.notify(method, params)
		if method == "$/cancelRequest" then
			local cancel = pending[params.id]
			pending[params.id] = nil
			if cancel then
				cancel()
			end
		elseif method == "exit" then
			closing = true
			dispatchers.on_exit(0, 0)
		end
		return true
	end

	function srv.is_closing()
		return closing
	end

	function srv.terminate()
		closing = true
	end

	return srv
end

--- Attach the ghost language server to a buffer.
function M.attach(buf)
	if not allowed(buf) then
		return
	end
	vim.lsp.start({
		name = "ghost",
		cmd = server,
		root_dir = vim.fn.getcwd(),
	}, {
		bufnr = buf,
		-- One client for everything.
		reuse_client = function(client)
			return client.name == "ghost"
		end,
	})
end

-- For debugging: the cached suggestion and whether a request is still running.
function M.debug_state()
	return { cache = cache, background = background ~= nil }
end

function M.setup(c, is_enabled, buf_allowed)
	cfg = c
	enabled = is_enabled
	allowed = buf_allowed
	cache = nil
end

return M
