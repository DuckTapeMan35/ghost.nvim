local M = {}

local cfg
local job = nil -- vim.SystemObj of the server we spawned, if any
local status = "stopped" -- "stopped" | "starting" | "ready"
local probing = false
local poll = nil
local retry_after = 0 -- vim.uv.now() before which we won't try again

function M.url(path)
	return ("http://127.0.0.1:%d%s"):format(cfg.port, path)
end

function M.status()
	return status
end

function M.owned()
	return job ~= nil
end

-- GET /health, then cb("ready" | "loading" | "down").
local function health(cb)
	vim.system(
		{
			cfg.curl,
			"-s",
			"--noproxy",
			"*",
			"-o",
			"/dev/null",
			"-w",
			"%{http_code}",
			"--max-time",
			"2",
			M.url("/health"),
		},
		{ text = true },
		function(res)
			local state = "down"
			if res.code == 0 and res.stdout == "200" then
				state = "ready"
			elseif res.code == 0 and res.stdout == "503" then
				state = "loading"
			end
			vim.schedule(function()
				cb(state)
			end)
		end
	)
end

local function stop_polling()
	if poll then
		poll:stop()
		poll:close()
		poll = nil
	end
end

local function fail(msg)
	stop_polling()
	status = "stopped"
	retry_after = vim.uv.now() + 30000
	vim.notify(("ghost: %s (log: %s)"):format(msg, cfg.log_file), vim.log.levels.WARN)
end

-- Poll /health until the server reports ready, or give up.
local function wait_ready()
	stop_polling()
	local deadline = vim.uv.now() + cfg.startup_timeout_ms
	local inflight = false
	poll = vim.uv.new_timer()
	poll:start(
		250,
		250,
		vim.schedule_wrap(function()
			if not poll or inflight then
				return
			end
			inflight = true
			health(function(state)
				inflight = false
				if not poll then
					return
				end
				if state == "ready" then
					status = "ready"
					stop_polling()
				elseif vim.uv.now() > deadline then
					fail("llama-server did not become ready in time")
				end
			end)
		end)
	)
end

local function spawn()
	local cmd = vim.deepcopy(cfg.server_cmd)
	if cfg.pass_pid then
		table.insert(cmd, tostring(vim.fn.getpid()))
	end

	local log = io.open(cfg.log_file, "w")
	local function write_log(_, data)
		if data and log then
			log:write(data)
			log:flush()
		end
	end

	local ok, obj = pcall(vim.system, cmd, {
		text = true,
		stdout = write_log,
		stderr = write_log,
	}, function()
		vim.schedule(function()
			if log then
				log:close()
				log = nil
			end
			job = nil
			if status == "ready" then
				status = "stopped" -- our server went away; the next request restarts it
				return
			end
			if status == "stopped" then
				return
			end -- we stopped it on purpose
			-- Died while starting. Either another Neovim grabbed the port first
			-- (fine, use theirs) or something is actually wrong.
			health(function(state)
				if state == "down" then
					fail("llama-server exited during startup")
				end
			end)
		end)
	end)

	if not ok then
		if log then
			log:close()
		end
		fail("could not start llama-server: " .. tostring(obj))
		return
	end
	job = obj
	wait_ready()
end

--- Make sure a server is running. Cheap; safe to call on every keystroke.
function M.ensure()
	if status ~= "stopped" or probing or vim.uv.now() < retry_after then
		return
	end
	status = "starting"
	probing = true
	health(function(state)
		probing = false
		if state == "ready" then
			status = "ready" -- another Neovim already runs one
		elseif state == "loading" then
			wait_ready()
		else
			spawn()
		end
	end)
end

--- Like ensure(), but ignores the back-off after a failure.
function M.start()
	retry_after = 0
	M.ensure()
end

--- A request couldn't connect: forget that we think it's up.
function M.mark_down()
	if status == "ready" then
		status = "stopped"
	end
end

function M.stop()
	stop_polling()
	status = "stopped"
	if job then
		pcall(function()
			job:kill(15)
		end)
		job = nil
	end
end

function M.setup(c)
	cfg = c
end

return M
