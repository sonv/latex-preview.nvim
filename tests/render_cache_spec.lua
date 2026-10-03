local uv = vim.uv or vim.loop

local function fail(msg)
  error(msg, 2)
end

local function assert_eq(expected, actual, msg)
  if expected ~= actual then
    fail((msg or "values differ") .. "\nexpected: " .. vim.inspect(expected) .. "\nactual: " .. vim.inspect(actual))
  end
end

local function assert_true(value, msg)
  if not value then fail(msg or "assertion failed") end
end

local function count_files(dir)
  local handle = uv.fs_scandir(dir)
  if not handle then return 0 end
  local count = 0
  while true do
    local name = uv.fs_scandir_next(handle)
    if not name then break end
    count = count + 1
  end
  return count
end

local function list_files(dir)
  local handle = uv.fs_scandir(dir)
  local files = {}
  if not handle then return files end
  while true do
    local name = uv.fs_scandir_next(handle)
    if not name then break end
    files[#files + 1] = name
  end
  table.sort(files)
  return files
end

local function file_set(dir)
  local names = {}
  for _, name in ipairs(list_files(dir)) do
    names[name] = true
  end
  return names
end

local function render_stem(name)
  return name:gsub("%.tmp$", ""):gsub("%.[^.]+$", "")
end

local function render_group(name, names)
  local image_name = name:match("^(.*)%.info$")
  if image_name then
    if names and names[image_name] then
      return render_stem(image_name)
    end
    local unprefixed = image_name:match("^%x%x%x%x%x%x%x%x%-(.+)$")
    if unprefixed and names and names[unprefixed] then
      return render_stem(unprefixed)
    end
    return render_stem(image_name)
  end
  return render_stem(name)
end

local function assert_grouped_pairs(dir)
  local names = file_set(dir)
  local stems = {}
  for _, name in ipairs(list_files(dir)) do
    local stem = render_group(name, names)
    local ext = name:match("%.([^.]+)$")
    stems[stem] = stems[stem] or {}
    stems[stem][ext] = true
  end
  for stem, exts in pairs(stems) do
    assert_true(exts.svg and exts.png, "temp cache kept a partial render group for " .. stem)
  end
end

local function count_render_groups(dir)
  local names = file_set(dir)
  local groups = {}
  for _, name in ipairs(list_files(dir)) do
    groups[render_group(name, names)] = true
  end
  local count = 0
  for _ in pairs(groups) do
    count = count + 1
  end
  return count
end

local function assert_info_maps_to_image(dir)
  local names = file_set(dir)
  for _, name in ipairs(list_files(dir)) do
    local image_name = name:match("^(.*)%.info$")
    if image_name then
      local unprefixed = image_name:match("^%x%x%x%x%x%x%x%x%-(.+)$")
      assert_true(
        names[image_name] or (unprefixed and names[unprefixed]),
        "info file does not map to a sibling image: " .. name
      )
    end
  end
end

local function snacks_group(name)
  return name
    :gsub("%.info$", "")
    :gsub("%.[^.]+$", "")
end

local function count_snacks_groups(dir)
  local groups = {}
  for _, name in ipairs(list_files(dir)) do
    groups[snacks_group(name)] = true
  end
  local count = 0
  for _ in pairs(groups) do
    count = count + 1
  end
  return count
end

local function assert_snacks_groups(dir)
  local groups = {}
  for _, name in ipairs(list_files(dir)) do
    local group = snacks_group(name)
    groups[group] = groups[group] or {}
    if name:match("%.info$") then
      groups[group].info = true
    else
      groups[group].image = true
    end
  end
  for group, files in pairs(groups) do
    assert_true(files.info and files.image, "snacks cache kept a partial group for " .. group)
  end
end

local function write_file(path, body)
  local fd = assert(io.open(path, "w"))
  fd:write(body)
  fd:close()
end

local root = vim.env.LATEX_PREVIEW_TEST_ROOT or vim.fn.tempname()
local fake_bin = root .. "/bin"
vim.fn.mkdir(fake_bin, "p")
write_file(fake_bin .. "/magick", [[#!/bin/sh
out=""
for arg do
  out="$arg"
done
out="${out#PNG:}"
printf 'png' > "$out"
]])
uv.fs_chmod(fake_bin .. "/magick", 493)
vim.env.PATH = fake_bin .. ":" .. (vim.env.PATH or "")

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local daemon_calls = 0
package.loaded["latex-preview.daemon"] = {
  render = function(_, cb)
    daemon_calls = daemon_calls + 1
    vim.defer_fn(function()
      cb(nil, "<svg></svg>")
    end, 10)
  end,
}

local config = require("latex-preview.config")
config.setup({
  cache = false,
  render = {
    fg = "#000000",
    font_size = 12,
    display_font_size = 12,
    display_math_style = "display",
    pad_to_cells = false,
    density = 300,
    svg_to_png = "magick",
  },
  snacks = {
    max_cache_files = 2,
    max_cache_bytes = 0,
    cache_grace_ms = 0,
  },
})

local render = require("latex-preview.render")
local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(buf)

local function render_async(equation, cb, opts)
  opts = opts or {}
  render.render({
    preamble = "",
    equation = equation,
    display = opts.display == true,
    buf = buf,
    live = true,
    live_id = equation,
  }, cb)
end

local function render_once(equation, opts)
  local done = false
  local err
  local path
  render_async(equation, function(render_err, png_path)
    err = render_err
    path = png_path
    done = true
  end, opts)
  assert_true(vim.wait(2000, function() return done end, 10), "render timed out")
  assert_eq(nil, err, "render failed")
  assert_true(path and uv.fs_stat(path), "render did not create a png")
  return path
end

local callbacks = {}
render_async("x + y", function(err, path)
  callbacks[#callbacks + 1] = { err = err, path = path }
end)
render_async("x + y", function(err, path)
  callbacks[#callbacks + 1] = { err = err, path = path }
end)

assert_true(vim.wait(2000, function() return #callbacks == 2 end, 10), "coalesced renders timed out")
assert_eq(1, daemon_calls, "duplicate in-flight live renders should share one daemon render")
assert_eq(nil, callbacks[1].err, "first coalesced render failed")
assert_eq(nil, callbacks[2].err, "second coalesced render failed")
assert_eq(callbacks[1].path, callbacks[2].path, "coalesced renders should return the same png path")

local reused_path = render_once("x + y")
assert_eq(callbacks[1].path, reused_path, "same live render should reuse the existing temp png")
assert_eq(1, daemon_calls, "same live render should not call the daemon again")

vim.b[buf].latex_preview_display_density = 300
local display_path = render_once("x + y", { display = true })
vim.b[buf].latex_preview_display_density = 600
local hidpi_display_path = render_once("x + y", { display = true })
assert_true(display_path ~= hidpi_display_path, "buffer-local display density should change the render key")
assert_eq(3, daemon_calls, "changing buffer-local display density should rerender display math")
vim.b[buf].latex_preview_display_density = nil

render_once("a + b")
render_once("c + d")

local temp_dir = vim.fn.stdpath("run") .. "/latex-preview/" .. tostring(uv.os_getpid())
assert_true(vim.wait(3000, function()
  return count_files(temp_dir) <= 4
end, 10), "temp cache was not trimmed to snacks.max_cache_files")
assert_true(count_files(temp_dir) <= 4, "temp cache kept more files than configured")
assert_grouped_pairs(temp_dir)

config.options.snacks.max_cache_files = 10
vim.fn.delete(temp_dir, "rf")
daemon_calls = 0
for i = 1, 8 do
  render_once("equation " .. i)
end
assert_true(vim.wait(3000, function()
  return count_files(temp_dir) <= 20
end, 10), "temp cache was not trimmed to max_cache_files=10")
assert_true(count_files(temp_dir) <= 20, "temp cache kept more than 10 render pairs")
assert_grouped_pairs(temp_dir)

for _, name in ipairs(list_files(temp_dir)) do
  if name:match("%.png$") then
    write_file(temp_dir .. "/" .. name .. ".info", "info")
    write_file(temp_dir .. "/deadbeef-" .. name .. ".info", "snacks info")
  end
end
config.options.snacks.max_cache_files = 1
render_once("trigger trim after stale info")
assert_true(vim.wait(3000, function()
  return count_render_groups(temp_dir) <= 1
end, 10), "temp cache did not trim .info with its render group")
assert_true(count_render_groups(temp_dir) <= 1, "temp cache kept more than one render group")
assert_grouped_pairs(temp_dir)
assert_info_maps_to_image(temp_dir)

local snacks_cache = root .. "/snacks-cache"
vim.fn.mkdir(snacks_cache, "p")
for i = 1, 12 do
  write_file(snacks_cache .. ("/%02d-preview.png"):format(i), "png")
  write_file(snacks_cache .. ("/%02d-preview.png.info"):format(i), "info")
end

package.loaded["snacks"] = {
  image = {
    config = {
      cache = snacks_cache,
      doc = { float = false },
    },
    placement = {
      clean = function() end,
    },
  },
}

require("latex-preview").setup({
  setup_keymap = false,
  hover = { auto_open = false },
  snacks = {
    disable_document_images = false,
    clean_info_on_exit = false,
    max_cache_files = 10,
    max_cache_bytes = 0,
    cache_grace_ms = 0,
  },
})

assert_true(vim.wait(3000, function()
  return count_snacks_groups(snacks_cache) <= 10
end, 10), "snacks cache was not trimmed to max_cache_files=10 groups")
assert_true(count_snacks_groups(snacks_cache) <= 10, "snacks cache kept more than 10 groups")
assert_true(count_files(snacks_cache) <= 20, "snacks cache kept more than 10 image/info pairs")
assert_snacks_groups(snacks_cache)

vim.fn.delete(temp_dir, "rf")
vim.fn.delete(root, "rf")
vim.cmd("qa")
