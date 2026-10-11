local server = require("ghost.server")

local M = {}

--- Text before and after (row, col) in buf, limited to cfg.prefix_lines /
--- cfg.suffix_lines. row is 1-based, col is a 0-based byte offset.
function M.context(cfg, buf, row, col)
	local total = vim.api.nvim_buf_line_count(buf)
	local line = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1] or ""

	local before = vim.api.nvim_buf_get_lines(buf, math.max(0, row - 1 - cfg.prefix_lines), row - 1, false)
	table.insert(before, line:sub(1, col))

	local after = { line:sub(col + 1) }
	vim.list_extend(after, vim.api.nvim_buf_get_lines(buf, row, math.min(total, row + cfg.suffix_lines), false))

	return table.concat(before, "\n"), table.concat(after, "\n")
end

--- Request a completion. cb(text) is called on the main loop with the
--- suggestion, or with nil if there is none (server not ready, error,
--- cancelled). Returns a cancel function.
function M.fetch(cfg, buf, row, col, cb)
	if server.status() ~= "ready" then
		server.ensure() -- first suggestions arrive once the model has loaded
		vim.schedule(function()
			cb(nil)
		end)
		return function() end
	end

	local prefix, suffix = M.context(cfg, buf, row, col)
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

	local cancelled = false
	local job = vim.system(
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
				if cancelled then
					return
				end
				if res.code == 7 then -- connection refused: server went away
					server.mark_down()
					server.ensure()
					return cb(nil)
				end
				if res.code ~= 0 then
					return cb(nil)
				end
				local ok, data = pcall(vim.json.decode, res.stdout)
				if not ok or type(data) ~= "table" or type(data.content) ~= "string" then
					return cb(nil)
				end
				local text = data.content:gsub("%s+$", "")
				cb(text ~= "" and text or nil)
			end)
		end
	)

	return function()
		cancelled = true
		pcall(function()
			job:kill(9)
		end)
	end
end

return M
