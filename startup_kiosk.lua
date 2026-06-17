-- Kiosk autorun script for CC: Tweaked.
-- Copy this file to "startup.lua" on kiosk computers.

local CONFIG_FILE = "security_config.lua"
local KIOSK_CONFIG_EXAMPLE = "security_kiosk_config.example.lua"
local SECURITY_PROGRAM = "security_system.lua"
local SECURITY_APP_MODULE = "security_system_app.lua"
local SECURITY_DEFAULTS_MODULE = "security_system_defaults.lua"
local SECURITY_REDNET_MODULE = "security_system_rednet.lua"
local SECURITY_NOTIFICATIONS_MODULE = "security_system_notifications.lua"
local SECURITY_ANNOUNCEMENTS_MODULE = "security_system_announcements.lua"
local KIOSK_EXIT_FILE = ".security_kiosk_exit"
local RESTART_SECONDS = 3

local function clear()
  term.setCursorPos(1, 1)
  term.clear()
end

local function copyKioskConfigIfMissing()
  if fs.exists(CONFIG_FILE) then
    return
  end

  if fs.exists(KIOSK_CONFIG_EXAMPLE) then
    fs.copy(KIOSK_CONFIG_EXAMPLE, CONFIG_FILE)
    return
  end

  local handle = fs.open(CONFIG_FILE, "w")
  handle.writeLine("return {")
  handle.writeLine("  mode = \"kiosk\",")
  handle.writeLine("  rednet = { enabled = true, protocol = \"cc_security_v1\", serverId = nil, discoverySeconds = 3, encryption = { enabled = false, key = \"change-this-facility-key\", allowPlaintext = false } },")
  handle.writeLine("  configSync = { enabled = true },")
  handle.writeLine("  kiosk = { locked = true, syncSeconds = 2, alarmSoundSeconds = 1.5, quitClearance = 5, autoLogoutSeconds = 600, autoRebootLoggedOutSeconds = 1800, controller = { enabled = false, permanent = false, credentialForwarding = true, helloSeconds = 30, pollSeconds = 0.25 } },")
  handle.writeLine("  notifications = { enabled = true, maxItems = 12, sound = true },")
  handle.writeLine("  announcements = { enabled = true, sound = true, voice = true, volume = 1 },")
  handle.writeLine("  branding = {")
  handle.writeLine("    facilityName = \"Facility\",")
  handle.writeLine("    shortName = \"SEC\",")
  handle.writeLine("    kioskTitle = \"Employee Kiosk\",")
  handle.writeLine("    motto = \"Connect to the facility server to continue.\",")
  handle.writeLine("    primaryColor = \"blue\",")
  handle.writeLine("    accentColor = \"lime\",")
  handle.writeLine("    textColor = \"white\",")
  handle.writeLine("  },")
  handle.writeLine("}")
  handle.close()
end

local function missingProgramFile()
  if not fs.exists(SECURITY_PROGRAM) then
    return SECURITY_PROGRAM
  end
  if not fs.exists(SECURITY_APP_MODULE) then
    return SECURITY_APP_MODULE
  end
  if not fs.exists(SECURITY_DEFAULTS_MODULE) then
    return SECURITY_DEFAULTS_MODULE
  end
  if not fs.exists(SECURITY_REDNET_MODULE) then
    return SECURITY_REDNET_MODULE
  end
  if not fs.exists(SECURITY_NOTIFICATIONS_MODULE) then
    return SECURITY_NOTIFICATIONS_MODULE
  end
  if not fs.exists(SECURITY_ANNOUNCEMENTS_MODULE) then
    return SECURITY_ANNOUNCEMENTS_MODULE
  end
  return nil
end

local function waitForProgram()
  while missingProgramFile() do
    clear()
    print("Employee Kiosk Startup")
    print()
    print("Missing " .. missingProgramFile())
    print("Install it or run startup_auto_update.lua, then press enter.")
    read()
  end
end

local function runKiosk()
  while true do
    clear()
    copyKioskConfigIfMissing()
    waitForProgram()

    local ok, result = pcall(function()
      return shell.run(SECURITY_PROGRAM, "kiosk")
    end)

    clear()
    print("Employee Kiosk stopped.")
    if fs.exists(KIOSK_EXIT_FILE) then
      fs.delete(KIOSK_EXIT_FILE)
      print("Authorized kiosk exit.")
      return
    end

    if not ok then
      print("Error: " .. tostring(result))
    elseif result == false then
      print("The kiosk program returned false.")
    else
      print("Restarting kiosk mode.")
    end
    print("Restarting in " .. tostring(RESTART_SECONDS) .. " seconds.")
    sleep(RESTART_SECONDS)
  end
end

runKiosk()
