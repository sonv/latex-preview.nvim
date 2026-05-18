-- lua/latex-preview/daemon.lua
--
-- Long-running MathJax daemon manager.
--
-- Spawns one Node process running `scripts/mathjax-daemon.mjs --daemon` on
-- first request, keeps it alive across the Neovim session, and multiplexes
-- equation-render requests over its stdin/stdout pipes via newline-
-- delimited JSON.
--
-- This exists because spawning Node + loading MathJax per equation
-- costs ~1.5 s per call. With a persistent daemon, per-equation latency
-- drops to ~10-50 ms, which is what live preview needs.
--
-- Lifecycle:
--   * lazy spawn on first M.render() call
--   * auto-restart with backoff on unexpected exit
--   * killed on Neovim VimLeavePre
--
-- Concurrency:
--   * The daemon processes requests serially (single Node event loop).
--   * On the Lua side, multiple concurrent M.render() calls are queued
--     by id; responses are dispatched back to the right callback regardless
--     of arrival order.

local M = {}

local uv = vim.uv or vim.loop
local config = require("latex-preview.config")

---@class LatexPreview.daemon.State
---@field handle? uv.uv_process_t
---@field stdin? uv.uv_pipe_t
---@field stdout? uv.uv_pipe_t
---@field stderr? uv.uv_pipe_t
---@field ready boolean
---@field starting boolean
---@field next_id integer
---@field pending table<integer, fun(err: string?, svg: string?)>
---@field queue { req: table, cb: fun(err: string?, svg: string?) }[]
---@field stdout_buf string
---@field stderr_buf string
---@field restart_count integer
---@field cmd string[]?
local state = {
  handle = nil,
  stdin = nil, stdout = nil, stderr = nil,
  ready = false,
  starting = false,
  next_id = 0,
  pending = {},
  queue = {},
  stdout_buf = "",
  stderr_buf = "",
  restart_count = 0,
  cmd = nil,
}

local function close(h)
  if h and not h:is_closing() then h:close() end
end

---Reset state. Rejects in-flight + queued callbacks.
local function reset(reason)
  for id, cb in pairs(state.pending) do
    pcall(cb, reason or "daemon stopped", nil)
    state.pending[id] = nil
  end
  for _, q in ipairs(state.queue) do
    pcall(q.cb, reason or "daemon stopped", nil)
  end
  state.queue = {}
  close(state.stdin); close(state.stdout); close(state.stderr); close(state.handle)
  state.stdin, state.stdout, state.stderr, state.handle = nil, nil, nil, nil
  state.ready = false
  state.starting = false
  state.stdout_buf = ""
  state.stderr_buf = ""
  state.next_id = 0
end

---Resolve the daemon command via config or runtimepath lookup.
---@return string[]?
local function resolve_cmd()
  local cfg = config.options.daemon
  if cfg.cmd and #cfg.cmd > 0 then
    state.cmd = vim.deepcopy(cfg.cmd)
    if state.cmd[#state.cmd] ~= "--daemon" then
      state.cmd[#state.cmd + 1] = "--daemon"
    end
    return state.cmd
  end
  -- Find the bundled script via runtimepath.
  for _, rtp in ipairs(vim.api.nvim_list_runtime_paths()) do
    local p = rtp .. "/scripts/mathjax-daemon.mjs"
    if uv.fs_stat(p) then
      state.cmd = { "node", p, "--daemon" }
      return state.cmd
    end
  end
  return nil
end

---Process a single complete JSON line from the daemon.
local function on_line(line)
  if line == "" then return end
  local ok, msg = pcall(vim.json.decode, line)
  if not ok or type(msg) ~= "table" then
    vim.schedule(function()
      vim.notify("[latex-preview] malformed daemon line: " .. line:sub(1, 200),
        vim.log.levels.WARN)
    end)
    return
  end
  if msg.ready then
    state.ready = true
    state.starting = false
    state.restart_count = 0
    -- Flush queued requests.
    local q = state.queue
    state.queue = {}
    for _, item in ipairs(q) do
      M.render(item.req, item.cb)
    end
    return
  end
  local cb = state.pending[msg.id]
  if not cb then return end -- stale (post-restart)
  state.pending[msg.id] = nil
  if msg.ok then pcall(cb, nil, msg.svg)
  else pcall(cb, msg.err or "mathjax error", nil) end
end

local function on_stdout_chunk(data)
  state.stdout_buf = state.stdout_buf .. data
  while true do
    local nl = state.stdout_buf:find("\n", 1, true)
    if not nl then break end
    local line = state.stdout_buf:sub(1, nl - 1)
    state.stdout_buf = state.stdout_buf:sub(nl + 1)
    on_line(line)
  end
end

local autocmd_registered = false

---Spawn the daemon. Idempotent during boot.
local function spawn()
  if state.handle or state.starting then return true end
  local cmd = resolve_cmd()
  if not cmd then
    vim.notify(
      "[latex-preview] cannot find daemon script. "
        .. "Make sure the plugin's `scripts/mathjax-daemon.mjs` is on your runtimepath, "
        .. "or set `daemon.cmd` in setup().",
      vim.log.levels.ERROR
    )
    return false
  end
  if vim.fn.executable(cmd[1]) == 0 then
    vim.notify(
      "[latex-preview] `" .. cmd[1] .. "` not found in PATH. Install Node.js.",
      vim.log.levels.ERROR
    )
    return false
  end

  state.starting = true
  state.stdin = assert(uv.new_pipe())
  state.stdout = assert(uv.new_pipe())
  state.stderr = assert(uv.new_pipe())

  local args = {}
  for i = 2, #cmd do args[#args + 1] = cmd[i] end

  state.handle = uv.spawn(cmd[1], {
    args = args,
    stdio = { state.stdin, state.stdout, state.stderr },
    hide = true,
  }, function(code, signal)
    vim.schedule(function()
      local err_msg = ("daemon exited code=%d signal=%d"):format(code or -1, signal or 0)
      if state.stderr_buf ~= "" then
        err_msg = err_msg .. "\nstderr: " .. state.stderr_buf:sub(1, 400)
      end
      reset(err_msg)
      local cfg = config.options.daemon
      if (code or 0) ~= 0 and state.restart_count < cfg.max_restarts then
        state.restart_count = state.restart_count + 1
        vim.notify(
          "[latex-preview] " .. err_msg
            .. "\nrestart " .. state.restart_count .. "/" .. cfg.max_restarts,
          vim.log.levels.WARN
        )
        vim.defer_fn(spawn, 200 * state.restart_count)
      end
    end)
  end)

  if not state.handle then
    reset("spawn failed")
    return false
  end

  state.stdout:read_start(function(_, data)
    if data then vim.schedule(function() on_stdout_chunk(data) end) end
  end)
  state.stderr:read_start(function(_, data)
    if data then
      vim.schedule(function()
        state.stderr_buf = (state.stderr_buf .. data):sub(-2048)
      end)
    end
  end)

  -- Ready timeout — fail loudly if @mathjax/src isn't installed.
  local timer = assert(uv.new_timer())
  timer:start(config.options.daemon.ready_timeout_ms, 0, function()
    timer:stop(); timer:close()
    if not state.ready and state.handle then
      vim.schedule(function()
        if state.ready then return end
        local hint = state.stderr_buf ~= ""
          and ("\n" .. state.stderr_buf:sub(1, 400))
          or "\n(install with `npm install -g @mathjax/src@4`)"
        vim.notify(
          "[latex-preview] daemon failed to become ready within "
            .. config.options.daemon.ready_timeout_ms .. " ms" .. hint,
          vim.log.levels.ERROR
        )
        if state.handle then state.handle:kill("sigterm") end
      end)
    end
  end)

  if not autocmd_registered then
    autocmd_registered = true
    vim.api.nvim_create_autocmd("VimLeavePre", {
      group = vim.api.nvim_create_augroup("latex_preview_daemon_shutdown", { clear = true }),
      callback = function() M.shutdown() end,
    })
  end

  return true
end

-- Public API ----------------------------------------------------------------

---Render an equation via the daemon. Async; cb(err, svg) on the main loop.
---@param req { preamble: string, equation: string, display: boolean, color: string }
---@param cb fun(err: string?, svg: string?)
function M.render(req, cb)
  if not state.handle then
    if not spawn() then
      vim.schedule(function() cb("daemon spawn failed", nil) end)
      return
    end
  end
  if not state.ready then
    table.insert(state.queue, { req = req, cb = cb })
    return
  end
  local id = state.next_id
  state.next_id = state.next_id + 1
  state.pending[id] = cb
  local payload = vim.json.encode({
    id = id,
    preamble = req.preamble or "",
    equation = req.equation or "",
    display = req.display and true or false,
    color = req.color or "000000",
    font_size = req.font_size or 11,
    display_math_style = req.display_math_style or "display",
  }) .. "\n"
  state.stdin:write(payload, function(err)
    if err then
      vim.schedule(function()
        local pending_cb = state.pending[id]
        if pending_cb then
          state.pending[id] = nil
          pcall(pending_cb, "stdin write failed: " .. err, nil)
        end
      end)
    end
  end)
end

---Shut down the daemon. Idempotent.
function M.shutdown()
  if state.stdin and not state.stdin:is_closing() then
    pcall(function() state.stdin:write(vim.json.encode({ quit = true }) .. "\n") end)
  end
  local h = state.handle
  vim.defer_fn(function()
    if h and not h:is_closing() then pcall(function() h:kill("sigterm") end) end
  end, 200)
  reset("vim shutdown")
end

function M.is_ready()
  return state.handle ~= nil and state.ready
end

function M._state()
  return state -- exposed for :checkhealth
end

return M
