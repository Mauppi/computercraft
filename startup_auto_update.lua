-- Manifest-driven auto-updating startup script for CC: Tweaked security computers.
-- Copy this file to "startup.lua" on server or kiosk computers.

local DEFAULT_BASE_URL = "https://raw.githubusercontent.com/Mauppi/computercraft/master/"
local MANIFEST_FILE = "security_system_manifest.lua"
local MANIFEST_URL = DEFAULT_BASE_URL .. MANIFEST_FILE
local PROGRAM = "security_system.lua"
local APP_MODULE_FILE = "security_system_app.lua"
local DEFAULTS_MODULE_FILE = "security_system_defaults.lua"
local REDNET_MODULE_FILE = "security_system_rednet.lua"
local NOTIFICATIONS_MODULE_FILE = "security_system_notifications.lua"
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

local FALLBACK_MANIFEST = {
  baseUrl = DEFAULT_BASE_URL,
  entry = PROGRAM,
  files = {
    {
      path = DEFAULTS_MODULE_FILE,
      required = true,
      minSize = 2000,
      contains = { "Default configuration", "return {", "alarm = {" },
    },
    {
      path = REDNET_MODULE_FILE,
      required = true,
      minSize = 2000,
      contains = { "Rednet message wrapping", "__securitySystem", "function M.wrap" },
    },
    {
      path = NOTIFICATIONS_MODULE_FILE,
      required = true,
      minSize = 1000,
      contains = { "Kiosk notification", "function M.push", "function M.playSound" },
    },
    {
      path = APP_MODULE_FILE,
      required = true,
      minSize = 2000,
      contains = { "CC: Tweaked security system", "security_system_defaults", "security_system_rednet", "security_system_notifications", "function main()", "return {" },
    },
    {
      path = PROGRAM,
      required = true,
      minSize = 300,
      contains = { "security_system_app", "app.run" },
    },
    {
      path = MANIFEST_FILE,
      required = false,
      minSize = 300,
      contains = APP_MODULE_FILE,
    },
  },
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
  handle.writeLine("  rednet = { enabled = true, protocol = \"cc_security_v1\", serverId = nil, discoverySeconds = 3, encryption = { enabled = false, key = \"change-this-facility-key\", allowPlaintext = false } },")
  handle.writeLine("  kiosk = { locked = true, syncSeconds = 2, alarmSoundSeconds = 1.5, quitClearance = 5 },")
  handle.writeLine("  notifications = { enabled = true, maxItems = 12, sound = true },")
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

local function ensureParentDir(path)
  local dir = fs.getDir(path)
  if dir and dir ~= "" and not fs.exists(dir) then
    fs.makeDir(dir)
  end
end

local function writeFile(path, data)
  ensureParentDir(path)
  local handle = fs.open(path, "w")
  handle.write(data)
  handle.close()
end

local function loadReturnedTable(source, label)
  local loader, err
  if loadstring then
    loader, err = loadstring(source, label)
  else
    loader, err = load(source, label)
  end

  if not loader then
    return nil, err or "load failed"
  end

  local ok, value = pcall(loader)
  if not ok then
    return nil, value
  end
  if type(value) ~= "table" then
    return nil, "file did not return a table"
  end
  return value
end

local function fetchUrl(url)
  if not http or not http.get then
    return nil, "HTTP API is disabled"
  end

  local response, err = http.get({
    url = url,
    redirect = true,
    timeout = 10,
  })

  if not response then
    return nil, err or "request failed"
  end

  local body = response.readAll()
  response.close()
  return body
end

local function normalizeBaseUrl(baseUrl)
  baseUrl = tostring(baseUrl or DEFAULT_BASE_URL)
  if string.sub(baseUrl, -1) ~= "/" then
    baseUrl = baseUrl .. "/"
  end
  return baseUrl
end

local function fileUrl(baseUrl, path)
  path = string.gsub(tostring(path or ""), "\\", "/")
  while string.sub(path, 1, 1) == "/" do
    path = string.sub(path, 2)
  end
  return normalizeBaseUrl(baseUrl) .. path
end

local function containsAll(data, contains)
  if not contains then
    return true
  end

  if type(contains) == "string" then
    return string.find(data, contains, 1, true) ~= nil
  end

  if type(contains) == "table" then
    for _, needle in ipairs(contains) do
      if string.find(data, tostring(needle), 1, true) == nil then
        return false
      end
    end
    return true
  end

  return true
end

local function validateFile(file, body)
  if type(body) ~= "string" or body == "" then
    return false, "empty download"
  end

  if file.minSize and #body < tonumber(file.minSize) then
    return false, "download was too small"
  end

  if not containsAll(body, file.contains) then
    return false, "download failed content checks"
  end

  return true
end

local function backupFile(path)
  if not fs.exists(path) then
    return
  end

  local backup = path .. ".bak"
  if fs.exists(backup) then
    fs.delete(backup)
  end
  fs.copy(path, backup)
end

local function loadLocalManifest()
  local data = readFile(MANIFEST_FILE)
  if not data then
    return nil, "no local manifest"
  end
  return loadReturnedTable(data, "@" .. MANIFEST_FILE)
end

local function fetchManifest()
  local body, fetchErr = fetchUrl(MANIFEST_URL)
  if body then
    local manifest, loadErr = loadReturnedTable(body, "@" .. MANIFEST_URL)
    if manifest then
      return manifest, "remote manifest"
    end
    fetchErr = loadErr
  end

  local localManifest = loadLocalManifest()
  if localManifest then
    return localManifest, "local manifest"
  end

  return FALLBACK_MANIFEST, "fallback manifest: " .. tostring(fetchErr or "remote unavailable")
end

local function updateOneFile(baseUrl, file)
  local path = tostring(file.path or "")
  if path == "" then
    return false, "manifest entry missing path", false
  end

  local body, err = fetchUrl(file.url or fileUrl(baseUrl, path))
  if not body then
    return false, err or "download failed", false
  end

  local ok, validErr = validateFile(file, body)
  if not ok then
    return false, validErr, false
  end

  local current = readFile(path)
  if current == body then
    return true, "current", false
  end

  backupFile(path)
  writeFile(path, body)
  return true, "updated", true
end

local function fetchUpdate()
  if not http or not http.get then
    return false, "HTTP API is disabled", false
  end

  local manifest, manifestSource = fetchManifest()
  local files = manifest.files or {}
  local baseUrl = manifest.baseUrl or DEFAULT_BASE_URL
  local updated = false
  local updatedCount = 0
  local skipped = 0

  for _, file in ipairs(files) do
    local ok, message, changed = updateOneFile(baseUrl, file)
    if ok then
      if changed then
        updated = true
        updatedCount = updatedCount + 1
      end
    elseif file.required ~= false then
      return false, tostring(file.path) .. ": " .. tostring(message), updated
    else
      skipped = skipped + 1
    end
  end

  if updated then
    return true, manifestSource .. ", updated " .. tostring(updatedCount) .. " file(s)", true
  end

  if skipped > 0 then
    return true, manifestSource .. ", already current; skipped " .. tostring(skipped) .. " optional file(s)", false
  end

  return true, manifestSource .. ", already current", false
end

local function missingProgramFile()
  if not fs.exists(PROGRAM) then
    return PROGRAM
  end
  if not fs.exists(APP_MODULE_FILE) then
    return APP_MODULE_FILE
  end
  if not fs.exists(DEFAULTS_MODULE_FILE) then
    return DEFAULTS_MODULE_FILE
  end
  if not fs.exists(REDNET_MODULE_FILE) then
    return REDNET_MODULE_FILE
  end
  if not fs.exists(NOTIFICATIONS_MODULE_FILE) then
    return NOTIFICATIONS_MODULE_FILE
  end
  return nil
end

local function runProgram(mode)
  while missingProgramFile() do
    clear()
    print("Missing " .. missingProgramFile())
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
  print("Fetching manifest and app files...")

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
