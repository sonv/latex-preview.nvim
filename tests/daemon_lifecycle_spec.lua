-- Deterministic process races without starting Node or requiring MathJax.
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local function eq(expected, actual, message)
  assert(expected == actual, (message or "values differ") .. ": " .. vim.inspect(actual))
end

local scheduled, timers, processes = {}, {}, {}
local real_uv, real_schedule, real_defer, real_notify = vim.uv, vim.schedule, vim.defer_fn, vim.notify
local function handle()
  return {
    closed = false,
    is_closing = function(self) return self.closed end,
    close = function(self) self.closed = true end,
    stop = function() end,
    kill = function(self) self.killed = true end,
    read_start = function(self, callback) self.read = callback end,
    write = function(self, data, callback)
      self.writes = self.writes or {}
      self.writes[#self.writes + 1] = { data = data, callback = callback }
    end,
    start = function(self, _, _, callback) self.fire = callback end,
  }
end
local function timer()
  local t = handle()
  timers[#timers + 1] = t
  return t
end
vim.schedule = function(callback) scheduled[#scheduled + 1] = callback end
vim.defer_fn = function(callback)
  local t = timer()
  t.fire = callback
  return t
end
vim.notify = function() end
vim.uv = setmetatable({
  new_pipe = handle,
  new_timer = timer,
  spawn = function(_, options, on_exit)
    local process = handle()
    process.pipes, process.exit = options.stdio, on_exit
    processes[#processes + 1] = process
    return process
  end,
}, { __index = real_uv })
local function flush()
  while #scheduled > 0 do
    local callbacks = scheduled
    scheduled = {}
    for _, callback in ipairs(callbacks) do callback() end
  end
end
local function ready(process)
  process.pipes[2].read(nil, '{"ready":true}\n')
  flush()
end

require("latex-preview.config").setup({ daemon = { cmd = { "/bin/sh" }, max_restarts = 2 } })
local daemon = require("latex-preview.daemon")
local old_results, new_results = {}, {}
daemon.render({ equation = "old" }, function(err) old_results[#old_results + 1] = err end)
local first, old_timeout = processes[1], timers[1]
ready(first)
assert(old_timeout.closed, "ready should close the startup timeout")
local old_write = first.pipes[1].writes[1]
daemon.shutdown()
eq(1, #old_results, "shutdown should reject pending requests once")
assert(first.killed, "shutdown must terminate the process before closing its handle")

daemon.render({ equation = "new" }, function(err, svg)
  new_results[#new_results + 1] = { err = err, svg = svg }
end)
local second = processes[2]
-- Deliver stale callbacks after replacement startup (including a timeout
-- already queued in Neovim's scheduler when the old timer was closed).
first.pipes[2].read(nil, '{"ready":true}\n')
first.pipes[3].read(nil, "old process diagnostic")
first.exit(1, 0)
old_timeout.fire()
old_write.callback("EPIPE")
flush()
eq(second, daemon._state().handle, "old process exit must not reset the replacement")
eq(false, daemon.is_ready(), "old ready message must not mark the replacement ready")
eq("", daemon._state().stderr_buf, "old stderr must not contaminate the replacement")
assert(not second.killed, "old timeout must not kill the replacement")
eq(0, #new_results, "old callbacks must not reject replacement requests")

ready(second)
old_write.callback("EPIPE")
first.pipes[2].read(nil, '{"id":0,"ok":true,"svg":"stale"}\n')
flush()
eq(0, #new_results, "old responses must not complete reused request IDs")
second.pipes[2].read(nil, '{"id":0,"ok":true,"svg":"fresh"}\n')
flush()
eq("fresh", new_results[1].svg, "replacement response should complete its own request")

-- A rejected request can immediately retry without its new queue being erased.
local retry_results = {}
daemon.render({ equation = "retry" }, function(err)
  assert(err)
  daemon.render({ equation = "retry" }, function(retry_err, svg)
    retry_results[#retry_results + 1] = { err = retry_err, svg = svg }
  end)
end)
second.exit(1, 0)
flush()
local third = processes[3]
eq(third, daemon._state().handle, "retry should own the replacement state")
eq(1, #daemon._state().queue, "callback retry should remain queued")
ready(third)
third.pipes[2].read(nil, '{"id":0,"ok":true,"svg":"retry result"}\n')
flush()
eq("retry result", retry_results[1].svg)

third.exit(1, 0)
flush()
local restart = daemon._state().restart_timer
assert(restart, "unexpected exit should schedule restart")
daemon.shutdown()
assert(restart.closed, "shutdown must close the deferred restart")
restart.fire()
flush()
eq(3, #processes, "a stale restart callback must not resurrect a stopped daemon")

daemon.render({ equation = "stop on failure" }, function(err)
  assert(err)
  daemon.shutdown()
end)
processes[4].exit(1, 0)
flush()
eq(nil, daemon._state().restart_timer, "shutdown from a rejected callback must cancel automatic restart")

vim.uv, vim.schedule, vim.defer_fn, vim.notify = real_uv, real_schedule, real_defer, real_notify
print("daemon lifecycle regressions passed")
vim.cmd("qa!")
