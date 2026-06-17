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
local ANNOUNCEMENTS_MODULE_FILE = "security_system_announcements.lua"
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
  controller = "reboot",
  door = "reboot",
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
      contains = { "Kiosk notification", "security_system_announcements", "function M.push", "function M.playSound", "function M.wavKindAllowed" },
    },
    {
      path = ANNOUNCEMENTS_MODULE_FILE,
      required = true,
      minSize = 1000,
      contains = { "Facility announcement audio", "function M.loadWav", "function M.buildAnnouncementBuffer", "function M.play" },
    },
    {
      path = APP_MODULE_FILE,
      required = true,
      minSize = 2000,
      contains = { "CC: Tweaked security system", "security_system_defaults", "security_system_rednet", "security_system_notifications", "security_system_announcements", "function controllerMain()", "kiosk_setup", "kiosk_badge_login", "controller_credential", "kioskLocalControllerLoop", "kiosk.controller", "remove_door", "playAlarmAudioSound", "includeAlarm", "function main()", "return {" },
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
  assets = {},
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

local function loadConfigTable()
  if not fs.exists(CONFIG_FILE) then
    return {}
  end

  local fn = loadfile(CONFIG_FILE)
  if not fn then
    return {}
  end

  local ok, value = pcall(fn)
  if ok and type(value) == "table" then
    return value
  end
  return {}
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
  handle.writeLine("  configSync = { enabled = true, includeAlarm = true },")
  handle.writeLine("  kiosk = { locked = true, syncSeconds = 2, alarmSoundSeconds = 1.5, quitClearance = 5, autoLogoutSeconds = 600, autoRebootLoggedOutSeconds = 1800, controller = { enabled = false, permanent = false, credentialForwarding = true, helloSeconds = 30, pollSeconds = 0.25 } },")
  handle.writeLine("  notifications = { enabled = true, maxItems = 12, sound = true, sampleRate = 48000, maxSamples = 128000, wavKinds = { dm = true, social = true } },")
  handle.writeLine("  announcements = { enabled = true, sound = true, voice = true, volume = 1, sampleRate = 48000, maxSamples = 128000, syncAssets = true, assetsRequired = false },")
  handle.writeLine("  branding = { facilityName = \"Facility\", shortName = \"SEC\", kioskTitle = \"Employee Kiosk\" },")
  handle.writeLine("}")
  handle.close()
end

local function isWavPath(path)
  return string.sub(string.lower(tostring(path or "")), -4) == ".wav"
end

local function isBinaryFile(file)
  if type(file) == "table" then
    if file.binary == true or file.kind == "wav" or file.wav == true then
      return true
    end
    return isWavPath(file.path)
  end
  return isWavPath(file)
end

local function openFile(path, mode, fallbackMode)
  local ok, handle = pcall(fs.open, path, mode)
  if ok and handle then
    return handle
  end
  if fallbackMode then
    ok, handle = pcall(fs.open, path, fallbackMode)
    if ok and handle then
      return handle
    end
  end
  return nil
end

local function readFile(path, binary)
  if not fs.exists(path) then
    return nil
  end

  local handle = openFile(path, binary and "rb" or "r", binary and "r" or nil)
  if not handle then
    return nil
  end
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

local function writeFile(path, data, binary)
  ensureParentDir(path)
  local handle = openFile(path, binary and "wb" or "w", binary and "w" or nil)
  if not handle then
    return false
  end
  handle.write(data)
  handle.close()
  return true
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

local function fetchUrl(url, binary)
  if not http or not http.get then
    return nil, "HTTP API is disabled"
  end

  local response, err = http.get({
    url = url,
    redirect = true,
    timeout = 10,
    binary = binary and true or false,
  })

  if not response then
    return nil, err or "request failed"
  end

  if response.getResponseCode then
    local code = response.getResponseCode()
    if code and code >= 400 then
      response.close()
      return nil, "HTTP " .. tostring(code)
    end
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

local function appendManifestEntries(out, entries, optionalDefault)
  if type(entries) ~= "table" then
    return
  end

  for _, entry in ipairs(entries) do
    if type(entry) == "string" then
      table.insert(out, { path = entry, required = false, binary = isWavPath(entry) })
    elseif type(entry) == "table" then
      if optionalDefault and entry.required == nil then
        local copy = {}
        for key, value in pairs(entry) do
          copy[key] = value
        end
        copy.required = false
        table.insert(out, copy)
      else
        table.insert(out, entry)
      end
    end
  end
end

local function manifestEntries(manifest)
  local out = {}
  appendManifestEntries(out, manifest.files, false)
  appendManifestEntries(out, manifest.assets, true)
  appendManifestEntries(out, manifest.audioFiles, true)
  appendManifestEntries(out, manifest.wavs, true)
  return out
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

  if isWavPath(file.path) or file.kind == "wav" or file.wav == true then
    if #body < 44 or string.sub(body, 1, 4) ~= "RIFF" or string.sub(body, 9, 12) ~= "WAVE" then
      return false, "download was not a PCM WAV file"
    end
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

local function openRednetModems()
  if not rednet or not peripheral then
    return false
  end

  for _, name in ipairs(peripheral.getNames()) do
    local types = { peripheral.getType(name) }
    for _, kind in ipairs(types) do
      if kind == "modem" then
        local isOpen = false
        if rednet.isOpen then
          local ok, value = pcall(rednet.isOpen, name)
          isOpen = ok and value
        end
        if not isOpen then
          pcall(rednet.open, name)
        end
      end
    end
  end
  return true
end

local function makeRequestId(prefix)
  local epoch = os.epoch and os.epoch("utc") or math.floor(os.clock() * 100000)
  return tostring(prefix or "req") .. "_" .. tostring(epoch) .. "_" .. tostring(math.random(100000, 999999))
end

local function syncConfigFromSecurityServer(mode)
  if mode ~= "kiosk" then
    return true, "not kiosk mode", false
  end
  if not rednet then
    return true, "rednet unavailable; skipped config sync", false
  end
  if not fs.exists(REDNET_MODULE_FILE) then
    return true, "rednet module unavailable; skipped config sync", false
  end

  local current = loadConfigTable()
  if current.configSync and current.configSync.enabled == false then
    return true, "config sync disabled locally", false
  end

  local okModule, secure = pcall(require, "security_system_rednet")
  if not okModule then
    return true, "rednet module failed; skipped config sync", false
  end

  if not openRednetModems() then
    return true, "no rednet modem; skipped config sync", false
  end

  local rednetConfig = current.rednet or {}
  local protocol = rednetConfig.protocol or "cc_security_v1"
  local requestId = makeRequestId("config")
  local request = { op = "kiosk_config", requestId = requestId }
  local wrapped = secure.wrap(request, rednetConfig)
  local serverId = rednetConfig.serverId

  if serverId then
    pcall(rednet.send, serverId, wrapped, protocol)
  else
    pcall(rednet.broadcast, wrapped, protocol)
  end

  local timeout = tonumber(rednetConfig.discoverySeconds) or 3
  local deadline = os.clock() + timeout
  while os.clock() < deadline do
    local okReceive, sender, message = pcall(rednet.receive, protocol, math.max(0.1, deadline - os.clock()))
    if okReceive and sender then
      local decoded = secure.unwrap(message, rednetConfig)
      if type(decoded) == "table" and decoded.requestId == requestId and decoded.ok and type(decoded.config) == "table" then
        decoded.config.mode = "kiosk"
        if current.kiosk and current.kiosk.controller then
          decoded.config.kiosk = decoded.config.kiosk or {}
          decoded.config.kiosk.controller = current.kiosk.controller
        end
        local oldText = readFile(CONFIG_FILE)
        local newText = "-- Synced from security server by startup_auto_update.lua.\nreturn " .. textutils.serialize(decoded.config) .. "\n"
        if oldText == newText then
          return true, "config already current from server " .. tostring(sender), false
        end
        backupFile(CONFIG_FILE)
        writeFile(CONFIG_FILE, newText)
        return true, "config synced from server " .. tostring(sender), true
      end
    end
  end

  return true, "no server config response", false
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

  local binary = isBinaryFile(file)
  local body, err = fetchUrl(file.url or fileUrl(baseUrl, path), binary)
  if not body then
    return false, err or "download failed", false
  end

  local ok, validErr = validateFile(file, body)
  if not ok then
    return false, validErr, false
  end

  local current = readFile(path, binary)
  if current == body then
    return true, "current", false
  end

  backupFile(path)
  if not writeFile(path, body, binary) then
    return false, "write failed", false
  end
  return true, "updated", true
end

local function fetchUpdate()
  if not http or not http.get then
    return false, "HTTP API is disabled", false
  end

  local manifest, manifestSource = fetchManifest()
  local files = manifestEntries(manifest)
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

local function addWavPath(paths, seen, value)
  value = string.gsub(tostring(value or ""), "\\", "/")
  if not isWavPath(value) or seen[value] then
    return
  end
  seen[value] = true
  table.insert(paths, value)
end

local function collectWavPaths(value, paths, seen, key)
  if type(value) == "string" then
    if key == "wav" or key == "file" or key == "path" or isWavPath(value) then
      addWavPath(paths, seen, value)
    end
    return
  end

  if type(value) ~= "table" then
    return
  end

  for childKey, childValue in pairs(value) do
    if childKey ~= "pcm" and childKey ~= "tones" then
      collectWavPaths(childValue, paths, seen, tostring(childKey))
    end
  end
end

local function configuredWavFiles(configTable, includeAnnouncements, includeNotifications, includeAlarm)
  local paths = {}
  local seen = {}
  if includeAnnouncements ~= false then
    collectWavPaths(configTable and configTable.announcements, paths, seen)
  end
  if includeNotifications ~= false then
    collectWavPaths(configTable and configTable.notifications, paths, seen)
  end
  if includeAlarm ~= false then
    collectWavPaths(configTable and configTable.alarm, paths, seen)
  end
  return paths
end

local function fetchConfiguredWavs()
  local current = loadConfigTable()
  local announcements = current.announcements or {}
  local notifications = current.notifications or {}
  local alarm = current.alarm or {}
  local syncAnnouncements = announcements.syncAssets ~= false
  local syncNotifications = notifications.syncAssets ~= false
  local syncAlarm = alarm.syncAssets ~= false
  if not syncAnnouncements and not syncNotifications and not syncAlarm then
    return true, "configured wav sync disabled", false
  end

  local wavs = configuredWavFiles(current, syncAnnouncements, syncNotifications, syncAlarm)
  if #wavs == 0 then
    return true, "no configured wav assets", false
  end

  local manifest = fetchManifest()
  local baseUrl = alarm.assetBaseUrl or notifications.assetBaseUrl or announcements.assetBaseUrl or (manifest and manifest.baseUrl) or DEFAULT_BASE_URL
  local required = alarm.assetsRequired == true or notifications.assetsRequired == true or announcements.assetsRequired == true
  local updated = false
  local updatedCount = 0
  local skipped = 0

  for _, path in ipairs(wavs) do
    local ok, message, changed = updateOneFile(baseUrl, {
      path = path,
      required = required,
      binary = true,
      kind = "wav",
      minSize = 44,
    })
    if ok then
      if changed then
        updated = true
        updatedCount = updatedCount + 1
      end
    elseif required then
      return false, tostring(path) .. ": " .. tostring(message), updated
    else
      skipped = skipped + 1
    end
  end

  if updated then
    return true, "updated " .. tostring(updatedCount) .. " wav asset(s)", true
  end
  if skipped > 0 then
    return true, "wav assets current; skipped " .. tostring(skipped), false
  end
  return true, "wav assets current", false
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
  if not fs.exists(ANNOUNCEMENTS_MODULE_FILE) then
    return ANNOUNCEMENTS_MODULE_FILE
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
  elseif mode == "controller" or mode == "door" or mode == "door_controller" then
    shell.run(PROGRAM, "controller")
  else
    shell.run(PROGRAM)
  end
end

local function main()
  math.randomseed((os.epoch and os.epoch("utc") or math.floor(os.clock() * 100000)) % 2147483647)
  local mode = readConfigMode()
  copyKioskConfigIfMissing(mode)

  clear()
  print("Security auto-update startup")
  print("Mode: " .. tostring(mode))
  print("Fetching manifest and app files...")

  local ok, message, updated = fetchUpdate()
  print((ok and "Update: " or "Update failed: ") .. tostring(message))

  local configOk, configMessage, configUpdated = syncConfigFromSecurityServer(mode)
  print((configOk and "Config: " or "Config sync failed: ") .. tostring(configMessage))
  updated = updated or configUpdated

  local audioOk, audioMessage, audioUpdated = fetchConfiguredWavs()
  print((audioOk and "Audio: " or "Audio sync failed: ") .. tostring(audioMessage))
  updated = updated or audioUpdated

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
