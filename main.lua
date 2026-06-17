local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = _dir .. "?.lua;" .. _dir .. "common/?.lua;" .. _dir .. "../game-common/?.lua;" .. package.path

local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local PluginBase    = require("plugin_base")
local _             = require("gettext")
local LightUpScreen = lrequire("screen")

local LightUp = PluginBase:extend{
    name      = "lightup",
    menu_text = _("Light Up"),
    menu_hint = "tools",
}

function LightUp:createScreen()
    return LightUpScreen:new{ plugin = self }
end

return LightUp
