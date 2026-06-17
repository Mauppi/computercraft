-- CC: Tweaked facility security system launcher.
-- Keep this file small; the implementation lives in security_system_app.lua.

local APP_MODULE = "security_system_app"
local DEFAULTS_MODULE = "security_system_defaults"
local REDNET_MODULE = "security_system_rednet"
local NOTIFICATIONS_MODULE = "security_system_notifications"
local ANNOUNCEMENTS_MODULE = "security_system_announcements"

if package and package.loaded then
  package.loaded[APP_MODULE] = nil
  package.loaded[DEFAULTS_MODULE] = nil
  package.loaded[REDNET_MODULE] = nil
  package.loaded[NOTIFICATIONS_MODULE] = nil
  package.loaded[ANNOUNCEMENTS_MODULE] = nil
end

local ok, app = pcall(require, APP_MODULE)
if not ok then
  error("Failed to load " .. APP_MODULE .. ": " .. tostring(app), 0)
end

if type(app) ~= "table" or type(app.run) ~= "function" then
  error(APP_MODULE .. " did not return a runnable app module", 0)
end

return app.run(...)
