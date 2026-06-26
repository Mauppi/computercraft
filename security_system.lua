-- CC: Tweaked facility security system launcher.
-- Keep this file small; the implementation lives in security_system_app.lua.

local APP_MODULE = "security_system_app"
local DEFAULTS_MODULE = "security_system_defaults"
local REDNET_MODULE = "security_system_rednet"
local NOTIFICATIONS_MODULE = "security_system_notifications"
local ANNOUNCEMENTS_MODULE = "security_system_announcements"
local AUDIO_MODULE = "security_system_audio"
local AUKIT_MODULE = "aukit"

if shell and shell.getRunningProgram and fs and package and package.path then
  local running = shell.getRunningProgram()
  local dir = fs.getDir(running or "")
  if dir and dir ~= "" then
    local modulePath = fs.combine(dir, "?.lua")
    if not string.find(package.path, modulePath, 1, true) then
      package.path = modulePath .. ";" .. fs.combine(dir, "?/init.lua") .. ";" .. package.path
    end
    _G.SECURITY_SYSTEM_INSTALL_ROOT = _G.SECURITY_SYSTEM_INSTALL_ROOT or dir
    _G.SECURITY_SYSTEM_ASSET_ROOT = _G.SECURITY_SYSTEM_ASSET_ROOT or dir
  end
end

if package and package.loaded then
  package.loaded[APP_MODULE] = nil
  package.loaded[DEFAULTS_MODULE] = nil
  package.loaded[REDNET_MODULE] = nil
  package.loaded[NOTIFICATIONS_MODULE] = nil
  package.loaded[ANNOUNCEMENTS_MODULE] = nil
  package.loaded[AUDIO_MODULE] = nil
  package.loaded[AUKIT_MODULE] = nil
end

local ok, app = pcall(require, APP_MODULE)
if not ok then
  error("Failed to load " .. APP_MODULE .. ": " .. tostring(app), 0)
end

if type(app) ~= "table" or type(app.run) ~= "function" then
  error(APP_MODULE .. " did not return a runnable app module", 0)
end

return app.run(...)
