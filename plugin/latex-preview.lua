-- plugin/latex-preview.lua
--
-- :LatexPreview [subcommand]
--
-- With no argument: show the hover popup for the equation under the cursor
-- (or close it if it's already visible).
--
-- Subcommands:
--   show     - show hover (no-op if already shown)
--   close    - close hover
--   toggle   - default: show or close
--   auto     - toggle automatic hover
--   auto-on  - enable automatic hover
--   auto-off - disable automatic hover
--   refs     - toggle referenced-equation previews
--   refs-on  - enable referenced-equation previews
--   refs-off - disable referenced-equation previews
--   thms     - toggle theorem-like reference previews
--   thms-on  - enable theorem-like reference previews
--   thms-off - disable theorem-like reference previews
--   cites    - toggle citation previews
--   cites-on - enable citation previews
--   cites-off - disable citation previews
--   density [N|reset]         - set/show buffer-local render density
--   display-density [N|reset] - set/show buffer-local display render density
--   clear    - delete cached SVG/PNG files
--   stop     - stop the MathJax daemon
--   status   - print daemon state

if vim.g.loaded_latex_preview == 1 then return end
vim.g.loaded_latex_preview = 1

local function no_math()
  vim.notify("latex-preview: no math expression under cursor", vim.log.levels.INFO)
end

local function status()
  local daemon = require("latex-preview.daemon")
  local hover = require("latex-preview.hover")
  local lp = require("latex-preview")
  print(string.format(
    "latex-preview:\n"
    .. "  daemon ready:    %s\n"
    .. "  hover open:      %s\n"
    .. "  auto hover:      %s\n"
    .. "  references:      %s\n"
    .. "  theorem refs:    %s\n"
    .. "  citations:       %s\n"
    .. "  terminal supports graphics: %s\n",
    tostring(daemon.is_ready()),
    tostring(hover.is_open()),
    tostring(lp.auto_hover_enabled()),
    tostring(lp.references_enabled()),
    tostring(lp.theorem_references_enabled()),
    tostring(lp.citations_enabled()),
    tostring(hover.is_supported())
  ))
end

local function set_density_command(kind, value)
  local key = kind == "display" and "latex_preview_display_density" or "latex_preview_density"
  if not value or value == "" then
    vim.notify("latex-preview: buffer " .. (kind == "display" and "display " or "")
      .. "density " .. tostring(vim.b[key] or "default"))
    return
  end
  if value == "reset" or value == "default" or value == "clear" then
    vim.b[key] = nil
    local hover = require("latex-preview.hover")
    if hover.is_active() then hover.open() end
    vim.notify("latex-preview: buffer " .. (kind == "display" and "display " or "") .. "density reset")
    return
  end
  local density = tonumber(value)
  if not density or density ~= density or density == math.huge or density < 0.5 then
    vim.notify("[latex-preview] density must round to a finite positive integer", vim.log.levels.ERROR)
    return
  end
  local result = math.floor(density + 0.5)
  vim.b[key] = result
  local hover = require("latex-preview.hover")
  if hover.is_active() then hover.open() end
  vim.notify("latex-preview: buffer " .. (kind == "display" and "display " or "")
    .. "density set to " .. tostring(result))
end

local subcommands = {
  show = function()
    if not require("latex-preview").hover() then no_math() end
  end,
  close = function() require("latex-preview").close() end,
  toggle = function()
    local lp = require("latex-preview")
    if require("latex-preview.hover").is_active() then lp.close() else
      if not lp.hover() then no_math() end
    end
  end,
  auto = function()
    local state = require("latex-preview").toggle_auto_hover()
    vim.notify("latex-preview: auto hover " .. (state and "enabled" or "disabled"))
  end,
  ["auto-on"] = function()
    require("latex-preview").set_auto_hover(true)
    vim.notify("latex-preview: auto hover enabled")
  end,
  ["auto-off"] = function()
    require("latex-preview").set_auto_hover(false)
    vim.notify("latex-preview: auto hover disabled")
  end,
  refs = function()
    local state = require("latex-preview").toggle_references()
    vim.notify("latex-preview: referenced equations " .. (state and "enabled" or "disabled"))
  end,
  ["refs-on"] = function()
    require("latex-preview").set_references(true)
    vim.notify("latex-preview: referenced equations enabled")
  end,
  ["refs-off"] = function()
    require("latex-preview").set_references(false)
    vim.notify("latex-preview: referenced equations disabled")
  end,
  thms = function()
    local state = require("latex-preview").toggle_theorem_references()
    vim.notify("latex-preview: theorem references " .. (state and "enabled" or "disabled"))
  end,
  ["thms-on"] = function()
    require("latex-preview").set_theorem_references(true)
    vim.notify("latex-preview: theorem references enabled")
  end,
  ["thms-off"] = function()
    require("latex-preview").set_theorem_references(false)
    vim.notify("latex-preview: theorem references disabled")
  end,
  cites = function()
    local state = require("latex-preview").toggle_citations()
    vim.notify("latex-preview: citations " .. (state and "enabled" or "disabled"))
  end,
  ["cites-on"] = function()
    require("latex-preview").set_citations(true)
    vim.notify("latex-preview: citations enabled")
  end,
  ["cites-off"] = function()
    require("latex-preview").set_citations(false)
    vim.notify("latex-preview: citations disabled")
  end,
  density = function(args)
    set_density_command("all", args[2])
  end,
  ["display-density"] = function(args)
    set_density_command("display", args[2])
  end,
  clear = function()
    local n = require("latex-preview").clear_cache()
    vim.notify("latex-preview: cleared " .. n .. " cached files")
  end,
  stop = function()
    require("latex-preview").stop_daemon()
    vim.notify("latex-preview: daemon stopped")
  end,
  status = status,
  debug = function()
    -- Dump everything that would be sent to the daemon for the equation
    -- under the cursor. Useful for "why isn't my \newcommand picked up"
    -- — copy this output and we can see whether the issue is in the
    -- extractor, the parser, or somewhere else.
    local buf = vim.api.nvim_get_current_buf()
    local cursor = vim.api.nvim_win_get_cursor(0)
    local config = require("latex-preview.config")
    local parse = require("latex-preview.parse")
    local extract = require("latex-preview.extract")

    local equations = parse.find_equations(buf)
    local crow, ccol = cursor[1] - 1, cursor[2]
    local current_eq = nil
    for _, eq in ipairs(equations) do
      local after = (crow > eq.start_row)
        or (crow == eq.start_row and ccol >= eq.start_col)
      local before = (crow < eq.end_row)
        or (crow == eq.end_row and ccol < eq.end_col)
      if after and before then current_eq = eq; break end
    end

    local preamble = extract.get_preamble(buf)
    local lines = {
      "=== latex-preview debug ===",
      "buffer:    " .. (vim.api.nvim_buf_get_name(buf) ~= "" and vim.api.nvim_buf_get_name(buf) or "(unsaved)"),
      "filetype:  " .. vim.bo[buf].filetype,
      "cursor:    row=" .. cursor[1] .. " col=" .. cursor[2],
      "cache_dir: " .. config.get_cache_dir(buf),
      "",
      "equations found in buffer: " .. #equations,
    }
    for i, eq in ipairs(equations) do
      lines[#lines + 1] = string.format(
        "  [%d] rows %d-%d display=%s text=%q",
        i, eq.start_row, eq.end_row, tostring(eq.display), eq.text:sub(1, 80))
    end
    lines[#lines + 1] = ""
    if current_eq then
      lines[#lines + 1] = "equation under cursor:"
      lines[#lines + 1] = "  display: " .. tostring(current_eq.display)
      lines[#lines + 1] = "  text:    " .. vim.inspect(current_eq.text)
    else
      lines[#lines + 1] = "equation under cursor: NONE"
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "extracted preamble (" .. #preamble .. " bytes):"
    if preamble == "" then
      lines[#lines + 1] = "  (empty)"
    else
      -- nvim_buf_set_lines requires each list element to be a single line,
      -- so we split the multi-line preamble.
      for _, pl in ipairs(vim.split(preamble, "\n", { plain = true })) do
        lines[#lines + 1] = pl
      end
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "=== end debug ==="

    -- Open in a scratch buffer so the user can copy/paste from it.
    vim.cmd("new")
    local out_buf = vim.api.nvim_get_current_buf()
    vim.bo[out_buf].buftype = "nofile"
    vim.bo[out_buf].bufhidden = "wipe"
    vim.bo[out_buf].swapfile = false
    vim.api.nvim_buf_set_lines(out_buf, 0, -1, false, lines)
  end,
}

vim.api.nvim_create_user_command("LatexPreview", function(opts)
  local sub = opts.fargs[1] or "toggle"
  local fn = subcommands[sub]
  if not fn then
    vim.notify("[latex-preview] unknown subcommand: " .. sub, vim.log.levels.ERROR)
    return
  end
  fn(opts.fargs)
end, {
  nargs = "*",
  complete = function(arglead, line)
    local args = vim.split(line, "%s+", { trimempty = true })
    if (args[2] == "density" or args[2] == "display-density")
        and (#args >= 3 or line:match("%s$")) then
      local matches = {}
      for _, item in ipairs({ "reset", "default", "clear", "300", "600" }) do
        if item:sub(1, #arglead) == arglead then matches[#matches + 1] = item end
      end
      return matches
    end
    if #args <= 2 then
      local prefix = args[2] or ""
      local matches = {}
      for k in pairs(subcommands) do
        if k:sub(1, #prefix) == prefix then matches[#matches + 1] = k end
      end
      table.sort(matches)
      return matches
    end
    return {}
  end,
})
