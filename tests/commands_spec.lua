package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local refreshes, notices = 0, {}
package.loaded["latex-preview.hover"] = {
  is_open = function() return true end,
  is_active = function() return true end,
  open = function() refreshes = refreshes + 1 end,
}
vim.notify = function(message, level) notices[#notices + 1] = { message = message, level = level } end
dofile("plugin/latex-preview.lua")

local failures = {}
local function check(ok, message)
  if not ok then failures[#failures + 1] = message end
end

for _, command in ipairs({ "density", "display-density" }) do
  local key = command == "density" and "latex_preview_density" or "latex_preview_display_density"
  vim.cmd("LatexPreview " .. command .. " 600")
  check(vim.b[key] == 600, command .. " must set buffer density")
  local before = refreshes
  vim.cmd("LatexPreview " .. command .. " reset")
  check(vim.b[key] == nil, command .. " reset must clear buffer density")
  check(refreshes == before + 1, command .. " reset must refresh the current preview")

  for _, value in ipairs({ "0.1", "inf", "nan", "1e309", "0", "-2" }) do
    vim.b[key] = 450
    before = refreshes
    vim.cmd("LatexPreview " .. command .. " " .. value)
    check(vim.b[key] == 450, command .. " accepted invalid density " .. value)
    check(refreshes == before, command .. " refreshed after invalid density " .. value)
    check(notices[#notices].level == vim.log.levels.ERROR, command .. " must report invalid density " .. value)
  end
end

assert(#failures == 0, table.concat(failures, "\n"))
print("command regressions passed")
vim.cmd("qa!")
