-- Kiosk autorun script for CC: Tweaked.
-- Copy this file to "startup.lua" on kiosk computers.

local CONFIG_FILE = "security_config.lua"
local KIOSK_CONFIG_EXAMPLE = "security_kiosk_config.example.lua"
local SECURITY_PROGRAM = "security_system.lua"
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
  handle.writeLine("  rednet = { enabled = true, protocol = \"cc_security_v1\", serverId = nil, discoverySeconds = 3 },")
  handle.writeLine("  kiosk = { locked = true, syncSeconds = 2, alarmSoundSeconds = 1.5 },")
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

local function waitForProgram()
  while not fs.exists(SECURITY_PROGRAM) do
    clear()
    print("Employee Kiosk Startup")
    print()
    print("Missing " .. SECURITY_PROGRAM)
    print("Install it on this computer, then press enter.")
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
