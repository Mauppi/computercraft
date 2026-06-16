-- Auto-updating startup script for CC: Tweaked security computers.
-- Copy this file to "startup.lua" on server or kiosk computers.

local UPDATE_URL = "https://raw.githubusercontent.com/Mauppi/computercraft/master/security_system.lua"
local PROGRAM = "security_system.lua"
local CONFIG_FILE = "security_config.lua"
local KIOSK_CONFIG_EXAMPLE = "security_kiosk_config.example.lua"

-- Set this to "server" or "kiosk" to force a mode. Leave nil to read
-- security_config.lua, falling back to server mode.
local MODE_OVERRIDE = nil

-- After a successful update:
--   "run"      starts the security program immediately.
--   "reboot"   reboots once so the new file starts from a clean boot.
--   "shutdown" shuts down after updating.
--   "shell"    returns to CraftOS shell.
local AFTER_UPDATE = {
  server = "run",
  kiosk = "reboot",
}

local function clear()
  term.setCursorPos(1, 1)
  term.clear()
end

local function readConfigMode()
  if MODE_OVERRIDE then
    return MODE_OVERRIDE
  end

  if not fs.exists(CONFIG_FILE) then
    return "server"
  end

  local fn = loadfile(CONFIG_FILE)
  if not fn then
    return "server"
  end

  local ok, loaded = pcall(fn)
  if ok and type(loaded) == "table" and loaded.mode then
    return string.lower(tostring(loaded.mode))
  end

  return "server"
end

local function copyKioskConfigIfMissing(mode)
  if mode ~= "kiosk" or fs.exists(CONFIG_FILE) then
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
  handle.writeLine("  kiosk = { locked = true, syncSeconds = 2, alarmSoundSeconds = 1.5, quitClearance = 5 },")
  handle.writeLine("  branding = { facilityName = \"Facility\", shortName = \"SEC\", kioskTitle = \"Employee Kiosk\" },")
  handle.writeLine("}")
  handle.close()
end

local function readFile(path)
  if not fs.exists(path) then
    return nil
  end

  local handle = fs.open(path, "r")
  local data = handle.readAll()
  handle.close()
  return data
end

local function writeFile(path, data)
  local handle = fs.open(path, "w")
  handle.write(data)
  handle.close()
end

local function validProgram(data)
  return type(data) == "string"
    and #data > 2000
    and string.find(data, "CC: Tweaked security system", 1, true)
    and string.find(data, "local defaultConfig", 1, true)
    and string.find(data, "main()", 1, true)
end

local function fetchUpdate()
  if not http or not http.get then
    return false, "HTTP API is disabled"
  end

  local response, err = http.get({
    url = UPDATE_URL,
    redirect = true,
    timeout = 10,
  })

  if not response then
    return false, err or "request failed"
  end

  local body = response.readAll()
  response.close()

  if not validProgram(body) then
    return false, "downloaded file did not look like security_system.lua"
  end

  local current = readFile(PROGRAM)
  if current == body then
    return true, "already current", false
  end

  if current then
    local backup = PROGRAM .. ".bak"
    if fs.exists(backup) then
      fs.delete(backup)
    end
    fs.copy(PROGRAM, backup)
  end

  writeFile(PROGRAM, body)
  return true, "updated", true
end

local function runProgram(mode)
  while not fs.exists(PROGRAM) do
    clear()
    print("Missing " .. PROGRAM)
    print("Install it or enable HTTP updates, then press enter.")
    read()
  end

  if mode == "kiosk" then
    shell.run(PROGRAM, "kiosk")
  else
    shell.run(PROGRAM)
  end
end

local function main()
  local mode = readConfigMode()
  copyKioskConfigIfMissing(mode)

  clear()
  print("Security auto-update startup")
  print("Mode: " .. tostring(mode))
  print("Fetching update...")

  local ok, message, updated = fetchUpdate()
  print((ok and "Update: " or "Update failed: ") .. tostring(message))

  if updated then
    local action = AFTER_UPDATE[mode] or "run"
    print("After-update action: " .. action)

    if action == "reboot" then
      sleep(1)
      os.reboot()
    elseif action == "shutdown" then
      sleep(1)
      os.shutdown()
    elseif action == "shell" then
      return
    end
  else
    sleep(1)
  end

  runProgram(mode)
end

main()
