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
local INSTALL_SUBDIR = "security_system"
local MIN_DISK_INSTALL_FREE = 384000
local INSTALL_ROOT = ""
local INSTALL_DESCRIPTION = "computer storage"
local startupArgs = { ... }

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
  serverConfig = {
    path = CONFIG_FILE,
    target = CONFIG_FILE,
    required = false,
    minSize = 100,
    contains = { "return", "mode = \"server\"" },
  },
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
      contains = { "Facility announcement audio", "SECURITY_SYSTEM_ASSET_ROOT", "function M.loadWav", "function M.buildAnnouncementBuffer", "function M.play" },
    },
    {
      path = APP_MODULE_FILE,
      required = true,
      minSize = 2000,
      contains = { "CC: Tweaked security system", "security_system_defaults", "security_system_rednet", "security_system_notifications", "security_system_announcements", "DEFAULT_CONFIG_URL", "installRemoteConfigIfMissing", "installKioskConfigIfMissing", "function controllerMain()", "kiosk_setup", "kiosk_badge_login", "controller_credential", "kioskLocalControllerLoop", "kiosk.controller", "remove_door", "playAlarmAudioSound", "alarmAudioStreamLoop", "speaker_audio_empty", "includeAlarm", "function main()", "return {" },
    },
    {
      path = PROGRAM,
      required = true,
      minSize = 300,
      contains = { "security_system_app", "SECURITY_SYSTEM_ASSET_ROOT", "app.run" },
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

local function normalizedMode(value)
  value = string.lower(tostring(value or ""))
  if value == "door_controller" then
    return "controller"
  end
  if value == "server" or value == "kiosk" or value == "controller" or value == "door" then
    return value
  end
  return nil
end

local function readModeFile(path)
  if not fs.exists(path) then
    return nil
  end

  local handle = fs.open(path, "r")
  if not handle then
    return nil
  end
  local line = handle.readLine()
  handle.close()
  return normalizedMode(line)
end

local function modeOverride()
  local override = normalizedMode(MODE_OVERRIDE)
  if override then
    return override
  end

  override = normalizedMode(startupArgs[1])
  if override then
    return override
  end

  override = readModeFile("security_mode.txt") or readModeFile(".security_mode")
  if override then
    return override
  end

  if os.getComputerLabel then
    local label = string.lower(tostring(os.getComputerLabel() or ""))
    if string.find(label, "kiosk", 1, true) then
      return "kiosk"
    end
    if string.find(label, "controller", 1, true) or string.find(label, "door", 1, true) then
      return "controller"
    end
  end

  return nil
end

local function normalizePath(path)
  path = string.gsub(tostring(path or ""), "\\", "/")
  while string.sub(path, 1, 1) == "/" do
    path = string.sub(path, 2)
  end
  return path
end

local function combinePath(base, path)
  base = normalizePath(base)
  path = normalizePath(path)
  if base == "" then
    return path
  end
  if path == "" then
    return base
  end
  if fs.combine then
    return fs.combine(base, path)
  end
  return base .. "/" .. path
end

local function installPath(path)
  if INSTALL_ROOT == "" then
    return normalizePath(path)
  end
  return combinePath(INSTALL_ROOT, path)
end

local function configPath()
  return CONFIG_FILE
end

local function ensureDir(path)
  path = normalizePath(path)
  if path ~= "" and not fs.exists(path) then
    fs.makeDir(path)
  end
end

local function writableDir(path)
  path = normalizePath(path)
  local ok = pcall(ensureDir, path)
  if not ok then
    return false
  end

  local testPath = combinePath(path, ".security_update_write_test")
  local handle = fs.open(testPath, "w")
  if not handle then
    return false
  end
  local writeOk = pcall(handle.write, "ok")
  pcall(handle.close)
  if not writeOk then
    if fs.exists(testPath) then
      pcall(fs.delete, testPath)
    end
    return false
  end
  if fs.exists(testPath) then
    fs.delete(testPath)
  end
  return true
end

local function freeSpace(path)
  if not fs.getFreeSpace then
    return 0
  end
  local ok, value = pcall(fs.getFreeSpace, path)
  if not ok then
    return 0
  end
  if value == "unlimited" then
    return 2147483647
  end
  return tonumber(value) or 0
end

local function addCandidate(candidates, seen, mount)
  mount = normalizePath(mount)
  if mount == "" or seen[mount] or not fs.exists(mount) or not fs.isDir(mount) then
    return
  end
  seen[mount] = true
  table.insert(candidates, mount)
end

local function diskMountCandidates()
  local candidates = {}
  local seen = {}

  if peripheral and disk and peripheral.getNames then
    for _, name in ipairs(peripheral.getNames()) do
      local isDrive = false
      local types = { peripheral.getType(name) }
      for _, kind in ipairs(types) do
        if kind == "drive" then
          isDrive = true
        end
      end
      if isDrive then
        local presentOk, present = pcall(disk.isPresent, name)
        if (not disk.isPresent) or (presentOk and present) then
          local okMount, mount = pcall(disk.getMountPath, name)
          if okMount and mount then
            addCandidate(candidates, seen, mount)
          end
        end
      end
    end
  end

  if fs.list then
    local okList, names = pcall(fs.list, "")
    if okList and type(names) == "table" then
      for _, name in ipairs(names) do
        if string.sub(tostring(name), 1, 4) == "disk" then
          addCandidate(candidates, seen, name)
        end
      end
    end
  end

  return candidates
end

local function configurePackagePath()
  if INSTALL_ROOT == "" or not (package and package.path) then
    return
  end

  local modulePath = installPath("?.lua")
  if not string.find(package.path, modulePath, 1, true) then
    package.path = modulePath .. ";" .. installPath("?/init.lua") .. ";" .. package.path
  end
end

local function selectInstallRoot()
  INSTALL_ROOT = ""
  INSTALL_DESCRIPTION = "computer storage"

  local bestRoot = nil
  local bestMount = nil
  local bestFree = -1
  for _, mount in ipairs(diskMountCandidates()) do
    local root = combinePath(mount, INSTALL_SUBDIR)
    if writableDir(root) then
      local space = freeSpace(root)
      if space > bestFree then
        bestRoot = root
        bestMount = mount
        bestFree = space
      end
    end
  end

  if bestRoot then
    INSTALL_ROOT = bestRoot
    if bestFree >= MIN_DISK_INSTALL_FREE then
      INSTALL_DESCRIPTION = "disk " .. tostring(bestMount) .. " (" .. INSTALL_ROOT .. ")"
      configurePackagePath()
    else
      INSTALL_ROOT = ""
      INSTALL_DESCRIPTION = "computer storage (disk " .. tostring(bestMount) .. " only has " .. tostring(bestFree) .. " bytes free)"
    end
  end

  return INSTALL_DESCRIPTION
end

local function readConfigMode()
  local override = modeOverride()
  if override then
    return override
  end

  if not fs.exists(configPath()) then
    return "server"
  end

  local fn = loadfile(configPath())
  if not fn then
    return "server"
  end

  local ok, loaded = pcall(fn)
  if ok and type(loaded) == "table" and loaded.mode then
    return normalizedMode(loaded.mode) or "server"
  end

  return "server"
end

local function loadConfigTable()
  if not fs.exists(configPath()) then
    return {}
  end

  local fn = loadfile(configPath())
  if not fn then
    return {}
  end

  local ok, value = pcall(fn)
  if ok and type(value) == "table" then
    return value
  end
  return {}
end

local function backupExistingConfigForKiosk()
  local path = configPath()
  if not fs.exists(path) then
    return true, "no existing config"
  end

  local backupPaths = {}
  local localBackupPath = path .. ".pre_kiosk.bak"
  local installBackupPath = installPath("security_config.pre_kiosk.bak")
  if INSTALL_ROOT ~= "" then
    backupPaths[#backupPaths + 1] = installBackupPath
  end
  backupPaths[#backupPaths + 1] = localBackupPath
  if INSTALL_ROOT == "" and installBackupPath ~= localBackupPath then
    backupPaths[#backupPaths + 1] = installBackupPath
  end

  local lastError = nil
  for i = 1, #backupPaths do
    local backupPath = backupPaths[i]
    local dir = fs.getDir(backupPath)
    local dirReady = true
    if dir and dir ~= "" then
      local ok = pcall(ensureDir, dir)
      if not ok then
        dirReady = false
        lastError = "could not create backup directory " .. tostring(dir)
      end
    end

    if dirReady then
      if fs.exists(backupPath) then
        pcall(fs.delete, backupPath)
      end
      local copied, copyErr = pcall(fs.copy, path, backupPath)
      if copied then
        local deleted, deleteErr = pcall(fs.delete, path)
        if deleted then
          return true, "backed up existing config to " .. backupPath
        end
        return false, "backed up existing config but could not remove old config: " .. tostring(deleteErr)
      end
      lastError = tostring(copyErr)
    end
  end

  return false, "could not back up existing non-kiosk config: " .. tostring(lastError or "unknown error")
end

local function writeFallbackKioskConfig()
  local handle = fs.open(configPath(), "w")
  if not handle then
    return false, "could not open " .. configPath() .. " for writing"
  end

  local lines = {
    "return {",
    "  mode = \"kiosk\",",
    "  rednet = { enabled = true, protocol = \"cc_security_v1\", serverId = nil, discoverySeconds = 3, encryption = { enabled = false, key = \"change-this-facility-key\", allowPlaintext = false } },",
    "  configSync = { enabled = true, includeAlarm = true },",
    "  kiosk = { locked = true, syncSeconds = 2, alarmSoundSeconds = 1.5, quitClearance = 5, autoLogoutSeconds = 600, autoRebootLoggedOutSeconds = 1800, controller = { enabled = false, permanent = false, credentialForwarding = true, helloSeconds = 30, pollSeconds = 0.25 } },",
    "  notifications = { enabled = true, maxItems = 12, sound = true, sampleRate = 48000, maxSamples = 128000, wavKinds = { dm = true, social = true } },",
    "  announcements = { enabled = true, sound = true, voice = true, volume = 1, sampleRate = 48000, maxSamples = 128000, syncAssets = true, assetsRequired = false },",
    "  branding = { facilityName = \"Facility\", shortName = \"SEC\", kioskTitle = \"Employee Kiosk\" },",
    "}",
  }

  for i = 1, #lines do
    local ok, err = pcall(handle.writeLine, lines[i])
    if not ok then
      pcall(handle.close)
      return false, "could not write fallback kiosk config: " .. tostring(err)
    end
  end
  handle.close()
  return true, "wrote fallback kiosk config", true
end

local function copyKioskConfigIfMissing(mode)
  if mode ~= "kiosk" then
    return true, "not kiosk mode", false
  end

  local existingConfig = loadConfigTable()
  if fs.exists(configPath()) and normalizedMode(existingConfig.mode) == "kiosk" then
    return true, "existing kiosk config", false
  end

  if fs.exists(configPath()) then
    local backedUp, backupMessage = backupExistingConfigForKiosk()
    if not backedUp then
      return false, backupMessage, false
    end
  end

  local examplePath = installPath(KIOSK_CONFIG_EXAMPLE)
  if not fs.exists(examplePath) and fs.exists(KIOSK_CONFIG_EXAMPLE) then
    examplePath = KIOSK_CONFIG_EXAMPLE
  end
  if fs.exists(examplePath) then
    local ok, err = pcall(fs.copy, examplePath, configPath())
    if ok then
      return true, "copied " .. KIOSK_CONFIG_EXAMPLE, true
    end
    local fallbackOk, fallbackMessage = writeFallbackKioskConfig()
    if fallbackOk then
      return true, "could not copy " .. tostring(examplePath) .. " (" .. tostring(err) .. "); " .. tostring(fallbackMessage), true
    end
    return false, "could not copy " .. tostring(examplePath) .. ": " .. tostring(err) .. "; " .. tostring(fallbackMessage), false
  end

  return writeFallbackKioskConfig()
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
  local dir = fs.getDir(path)
  local spacePath = (dir and dir ~= "") and dir or ""
  local available = freeSpace(spacePath)
  if available > 0 and available < #data then
    return false, "not enough free space for " .. tostring(path) .. " (" .. tostring(#data) .. " bytes needed, " .. tostring(available) .. " free)"
  end

  local handle = openFile(path, binary and "wb" or "w", binary and "w" or nil)
  if not handle then
    return false, "open failed"
  end
  local ok, err = pcall(handle.write, data)
  pcall(handle.close)
  if not ok then
    if fs.exists(path) then
      pcall(fs.delete, path)
    end
    return false, tostring(err or "write failed")
  end
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

local function backupFile(path, nextSize)
  if not fs.exists(path) then
    return true, "no existing file"
  end

  local backup = path .. ".bak"
  if fs.exists(backup) then
    pcall(fs.delete, backup)
  end

  local currentSize = 0
  if fs.getSize then
    local okSize, size = pcall(fs.getSize, path)
    if okSize then
      currentSize = tonumber(size) or 0
    end
  end
  local dir = fs.getDir(path)
  local available = freeSpace((dir and dir ~= "") and dir or "")
  local neededForBackup = currentSize + (tonumber(nextSize) or 0)
  if available > 0 and neededForBackup > available then
    return false, "skipped backup: " .. tostring(neededForBackup) .. " bytes needed, " .. tostring(available) .. " free"
  end

  local ok, err = pcall(fs.copy, path, backup)
  if not ok then
    return false, tostring(err or "backup failed")
  end
  return true, "backup written"
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
  if not fs.exists(installPath(REDNET_MODULE_FILE)) then
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
        local oldText = readFile(configPath())
        local newText = "-- Synced from security server by startup_auto_update.lua.\nreturn " .. textutils.serialize(decoded.config) .. "\n"
        if oldText == newText then
          return true, "config already current from server " .. tostring(sender), false
        end
        backupFile(configPath(), #newText)
        writeFile(configPath(), newText)
        return true, "config synced from server " .. tostring(sender), true
      end
    end
  end

  return true, "no server config response", false
end

local function loadLocalManifest()
  local data = readFile(installPath(MANIFEST_FILE))
  if not data then
    return nil, "no local manifest"
  end
  return loadReturnedTable(data, "@" .. installPath(MANIFEST_FILE))
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

  local target = installPath(file.target or path)
  local binary = isBinaryFile(file)
  local body, err = fetchUrl(file.url or fileUrl(baseUrl, path), binary)
  if not body then
    return false, err or "download failed", false
  end

  local ok, validErr = validateFile(file, body)
  if not ok then
    return false, validErr, false
  end

  local current = readFile(target, binary)
  if current == body then
    return true, "current", false
  end

  local backupOk = backupFile(target, #body)
  if fs.exists(target) then
    pcall(fs.delete, target)
  end

  local writeOk, writeErr = writeFile(target, body, binary)
  if not writeOk then
    local backup = target .. ".bak"
    if fs.exists(backup) and not fs.exists(target) then
      pcall(fs.copy, backup, target)
    end
    return false, writeErr or "write failed", false
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

local function normalizeConfigEntry(manifest)
  local entry = manifest and (manifest.serverConfig or manifest.configFile or manifest.config)
  if type(entry) == "string" then
    return {
      path = entry,
      target = CONFIG_FILE,
      required = false,
      minSize = 100,
      contains = "return",
    }
  end
  if type(entry) == "table" then
    local copy = {}
    for key, value in pairs(entry) do
      copy[key] = value
    end
    copy.path = copy.path or CONFIG_FILE
    copy.target = copy.target or CONFIG_FILE
    return copy
  end
  return {
    path = CONFIG_FILE,
    target = CONFIG_FILE,
    required = false,
    minSize = 100,
    contains = "return",
  }
end

local function validateConfigText(body, label)
  local loaded, loadErr = loadReturnedTable(body, label)
  if not loaded then
    return false, loadErr
  end
  if loaded.mode and string.lower(tostring(loaded.mode)) == "kiosk" then
    return false, "downloaded config is kiosk mode"
  end
  return true
end

local function installServerConfigIfMissing(mode)
  if mode ~= "server" then
    return true, "not server mode", false
  end
  if fs.exists(configPath()) then
    return true, "existing " .. configPath(), false
  end
  if not (http and http.get) then
    return false, "missing " .. configPath() .. " and HTTP API is disabled", false
  end

  local manifest, manifestSource = fetchManifest()
  local entry = normalizeConfigEntry(manifest)
  local baseUrl = entry.baseUrl or (manifest and manifest.baseUrl) or DEFAULT_BASE_URL
  local path = tostring(entry.path or CONFIG_FILE)
  local target = configPath()
  local body, fetchErr = fetchUrl(entry.url or fileUrl(baseUrl, path), false)
  if not body then
    return false, tostring(path) .. ": " .. tostring(fetchErr or "download failed"), false
  end

  local ok, validErr = validateFile(entry, body)
  if ok then
    ok, validErr = validateConfigText(body, "@" .. tostring(entry.url or fileUrl(baseUrl, path)))
  end
  if not ok then
    return false, tostring(path) .. ": " .. tostring(validErr), false
  end

  local writeOk, writeErr = writeFile(target, body, false)
  if not writeOk then
    return false, "could not write " .. target .. ": " .. tostring(writeErr), false
  end
  return true, "installed " .. target .. " from " .. tostring(path) .. " (" .. tostring(manifestSource) .. ")", true
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
  if not fs.exists(installPath(PROGRAM)) then
    return installPath(PROGRAM)
  end
  if not fs.exists(installPath(APP_MODULE_FILE)) then
    return installPath(APP_MODULE_FILE)
  end
  if not fs.exists(installPath(DEFAULTS_MODULE_FILE)) then
    return installPath(DEFAULTS_MODULE_FILE)
  end
  if not fs.exists(installPath(REDNET_MODULE_FILE)) then
    return installPath(REDNET_MODULE_FILE)
  end
  if not fs.exists(installPath(NOTIFICATIONS_MODULE_FILE)) then
    return installPath(NOTIFICATIONS_MODULE_FILE)
  end
  if not fs.exists(installPath(ANNOUNCEMENTS_MODULE_FILE)) then
    return installPath(ANNOUNCEMENTS_MODULE_FILE)
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

  configurePackagePath()
  _G.SECURITY_SYSTEM_INSTALL_ROOT = INSTALL_ROOT
  _G.SECURITY_SYSTEM_ASSET_ROOT = INSTALL_ROOT
  local programPath = installPath(PROGRAM)

  if mode == "kiosk" then
    shell.run(programPath, "kiosk")
  elseif mode == "controller" or mode == "door" or mode == "door_controller" then
    shell.run(programPath, "controller")
  else
    shell.run(programPath)
  end
end

local function main()
  math.randomseed((os.epoch and os.epoch("utc") or math.floor(os.clock() * 100000)) % 2147483647)
  local storage = selectInstallRoot()
  local mode = readConfigMode()

  clear()
  print("Security auto-update startup")
  print("Mode: " .. tostring(mode))
  print("Storage: " .. tostring(storage))
  print("Fetching manifest and app files...")

  local ok, message, updated = fetchUpdate()
  print((ok and "Update: " or "Update failed: ") .. tostring(message))

  local kioskConfigOk, kioskConfigMessage, kioskConfigUpdated = copyKioskConfigIfMissing(mode)
  print((kioskConfigOk and "Kiosk config: " or "Kiosk config failed: ") .. tostring(kioskConfigMessage))
  if not kioskConfigOk then
    print("Refusing to start without kiosk config.")
    return
  end
  updated = updated or kioskConfigUpdated
  mode = readConfigMode()

  local serverConfigOk, serverConfigMessage, serverConfigUpdated = installServerConfigIfMissing(mode)
  print((serverConfigOk and "Server config: " or "Server config failed: ") .. tostring(serverConfigMessage))
  if not serverConfigOk then
    print("Refusing to start without " .. CONFIG_FILE .. ".")
    return
  end
  updated = updated or serverConfigUpdated
  mode = readConfigMode()

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
