-- Compatibility loader for configs that still require the old Docker module.
local sourcePath = debug.getinfo(1, "S").source
local widgetDir = sourcePath:sub(2):match("^(.*)docker%.lua$")

assert(widgetDir, "Unable to locate the Podman widget module")
return dofile(widgetDir .. "podman.lua")
