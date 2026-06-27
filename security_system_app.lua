-- CC: Tweaked security system for doors, badges, alarms, sensors, and rednet.
-- Loaded by security_system.lua. Run security_system.lua directly with:
--   security_system
--
-- The first run fetches security_config.lua from the update repository if it
-- does not exist. Create the file manually when running without HTTP.

local CONFIG_FILE = "security_config.lua"
local DEFAULT_CONFIG_URL = "https://raw.githubusercontent.com/Mauppi/computercraft/master/security_config.lua"
local LOG_FILE = "security_audit.log"
local ACCOUNTS_FILE = "security_accounts.lua"
local SOCIAL_FILE = "security_social.lua"
local KIOSK_CONFIG_EXAMPLE = "security_kiosk_config.example.lua"
local KIOSK_EXIT_FILE = ".security_kiosk_exit"
local PROTOCOL = "cc_security_v1"
local args = {}

local secureRednet = require("security_system_rednet")
local kioskNotifications = require("security_system_notifications")
local facilityAnnouncements = require("security_system_announcements")
local securityAudio = require("security_system_audio")

local sides = { "top", "bottom", "left", "right", "front", "back" }
local unpackArgs = table.unpack or unpack

-- Helper functions are intentionally top-level functions instead of
-- "local function" declarations. CC:Tweaked uses Lua 5.1 semantics, where the
-- main chunk has a 200-local limit; this file has too many helpers for that.
local defaultConfig = require("security_system_defaults")

local config
local employeeClearance
local openRednet
local state = {
  running = true,
  doors = {},
  timers = {},
  timerKeys = {},
  peripheralCache = {
    names = nil,
    types = {},
    methods = {},
  },
  lastBadge = {},
  denied = {},
  sensors = {},
  sessions = {},
  accounts = {
    users = {},
    notes = {},
  },
  social = {
    feed = {},
    messages = {},
  },
  kiosk = {
    netLoop = false,
    running = false,
    serverId = nil,
    inbox = {},
    status = nil,
    branding = nil,
    lastSync = 0,
    lastAlarmSound = 0,
    user = nil,
    token = nil,
    notifications = {},
    notificationSeen = {},
    lastActivity = 0,
    loggedOutSince = 0,
    clockOffsetMillis = 0,
  },
  announcements = {
    index = 0,
    queue = {},
    cooldowns = {},
    audioStreams = {},
    audioGeneration = 0,
    audioPlayingUntil = 0,
  },
  remoteAudio = {
    streams = {},
  },
  sensorDetails = {},
  alarm = {
    active = false,
    reason = nil,
    actor = nil,
    door = nil,
    profile = nil,
    since = nil,
    sinceMillis = nil,
    soundStartAt = nil,
    soundIndex = 1,
    audioCache = {},
    preparedAudioCache = {},
    audioStreams = {},
    pendingAudioStreams = {},
    audioGeneration = 0,
    audioPlayingUntil = 0,
    sourceKey = nil,
    sourceAutoReset = false,
    sourceAutoResetAfter = nil,
  },
  lockdown = false,
  consoleAdminUntil = 0,
  screenDirty = true,
}

function shallowCopy(value)
  if type(value) ~= "table" then
    return value
  end

  local copy = {}
  for k, v in pairs(value) do
    copy[k] = shallowCopy(v)
  end
  return copy
end

function listContains(list, value)
  if type(list) == "string" or type(list) == "number" then
    return tostring(list) == tostring(value) or tostring(list) == "*"
  end

  if type(list) ~= "table" then
    return false
  end

  if list["*"] == true or list[tostring(value)] == true then
    return true
  end

  for _, item in ipairs(list) do
    if tostring(item) == "*" or tostring(item) == tostring(value) then
      return true
    end
  end

  return false
end

function listContainsIgnoreCase(list, value)
  if value == nil then
    return false
  end

  local target = string.lower(tostring(value))
  if type(list) == "string" or type(list) == "number" then
    local item = string.lower(tostring(list))
    return item == target or item == "*"
  end

  if type(list) ~= "table" then
    return false
  end

  if list["*"] == true or list[value] == true or list[target] == true then
    return true
  end

  for _, item in ipairs(list) do
    local text = string.lower(tostring(item))
    if text == "*" or text == target then
      return true
    end
  end

  return false
end

function appendUnique(list, value)
  if value == nil then
    return
  end

  local text = tostring(value)
  if text == "" then
    return
  end

  for _, item in ipairs(list) do
    if item == text then
      return
    end
  end

  table.insert(list, text)
end

function tableKeys(map)
  local out = {}
  if type(map) == "table" then
    for key in pairs(map) do
      table.insert(out, key)
    end
    table.sort(out, function(a, b)
      return tostring(a) < tostring(b)
    end)
  end
  return out
end

function compact(value)
  if type(value) == "table" then
    local ok, encoded = pcall(textutils.serialize, value)
    if ok then
      return encoded
    end
  end
  return tostring(value)
end

function auditClearance(action)
  local logs = config and config.logs or {}
  local clearances = logs.clearances or {}
  return tonumber(clearances[action]) or tonumber(logs.defaultClearance) or 2
end

function timestamp()
  if os.date then
    return os.date("%Y-%m-%d %H:%M:%S")
  end
  return tostring(os.time())
end

function audit(action, detail)
  local path = LOG_FILE
  if config and config.logFile then
    path = config.logFile
  end

  local ok, handle = pcall(fs.open, path, "a")
  if ok and handle then
    local detailText = string.gsub(compact(detail or ""), "[\r\n]+", " ")
    handle.writeLine(timestamp() .. " C" .. tostring(auditClearance(action)) .. " " .. action .. " " .. detailText)
    handle.close()
  end

  if config and type(broadcastActionAnnouncement) == "function" then
    pcall(broadcastActionAnnouncement, action, detail)
  end
end

function readFacilityLogsFor(record, limit)
  local path = config.logFile or LOG_FILE
  if not fs.exists(path) then
    return {}
  end

  local handle = fs.open(path, "r")
  local lines = {}
  while true do
    local line = handle.readLine()
    if not line then
      break
    end
    table.insert(lines, line)
  end
  handle.close()

  local clearance = employeeClearance and employeeClearance(record) or 0
  local visible = {}
  for index = #lines, 1, -1 do
    local line = lines[index]
    local required = tonumber(string.match(line, "%sC(%d+)%s")) or tonumber(config.logs and config.logs.defaultClearance) or 2
    if required <= clearance then
      table.insert(visible, line)
      if #visible >= (tonumber(limit) or tonumber(config.logs and config.logs.readLines) or 80) then
        break
      end
    end
  end

  return visible
end

function loadConfigFromText(source, label)
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
    return nil, "config did not return a table"
  end
  return value
end

function fetchRemoteConfigText()
  if not (http and http.get) then
    return nil, "HTTP API is disabled"
  end

  local ok, response, err = pcall(http.get, {
    url = DEFAULT_CONFIG_URL,
    redirect = true,
    timeout = 10,
  })
  if (not ok) or not response then
    ok, response, err = pcall(http.get, DEFAULT_CONFIG_URL)
  end
  if (not ok) or not response then
    return nil, err or response or "request failed"
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

function installRemoteConfigIfMissing()
  if fs.exists(CONFIG_FILE) then
    return true
  end

  local body, fetchErr = fetchRemoteConfigText()
  if not body or body == "" then
    return false, fetchErr or "empty download"
  end

  local loaded, loadErr = loadConfigFromText(body, "@" .. DEFAULT_CONFIG_URL)
  if not loaded then
    return false, loadErr
  end
  if loaded.mode and string.lower(tostring(loaded.mode)) == "kiosk" then
    return false, "remote config is kiosk mode"
  end

  local handle = fs.open(CONFIG_FILE, "w")
  if not handle then
    return false, "could not write " .. CONFIG_FILE
  end
  handle.write(body)
  handle.close()
  return true
end

function appInstallPath(path)
  local root = (_G and (_G.SECURITY_SYSTEM_INSTALL_ROOT or _G.SECURITY_SYSTEM_ASSET_ROOT)) or ""
  root = tostring(root or "")
  path = tostring(path or "")
  if root == "" then
    return path
  end
  if fs and fs.combine then
    return fs.combine(root, path)
  end
  return root .. "/" .. path
end

function installKioskConfigIfMissing()
  if fs.exists(CONFIG_FILE) then
    return true
  end

  local source = KIOSK_CONFIG_EXAMPLE
  if not fs.exists(source) then
    source = appInstallPath(KIOSK_CONFIG_EXAMPLE)
  end
  if fs.exists(source) then
    local ok, err = pcall(fs.copy, source, CONFIG_FILE)
    if ok then
      return true
    end
    return false, err or "copy failed"
  end

  local handle = fs.open(CONFIG_FILE, "w")
  if not handle then
    return false, "could not write " .. CONFIG_FILE
  end
  handle.writeLine("return {")
  handle.writeLine("  mode = \"kiosk\",")
  handle.writeLine("  rednet = { enabled = true, protocol = \"cc_security_v1\", serverId = nil, discoverySeconds = 3, encryption = { enabled = false, key = \"change-this-facility-key\", allowPlaintext = false, audioPlaintext = true } },")
  handle.writeLine("  configSync = { enabled = true, includeMonitors = true, includeAnnouncements = true, includeAlarm = true },")
  handle.writeLine("  kiosk = { locked = true, area = \"\", locationArea = \"\", syncSeconds = 2, alarmSoundSeconds = 1.5, quitClearance = 5, autoLogoutSeconds = 600, autoRebootLoggedOutSeconds = 1800, controller = { enabled = false, permanent = false, credentialForwarding = true, helloSeconds = 30, pollSeconds = 0.5, idlePollSeconds = 5 } },")
  handle.writeLine("  notifications = { enabled = true, maxItems = 12, sound = true, sampleRate = 48000, maxSamples = 128000, wavKinds = { dm = true, social = true } },")
  handle.writeLine("  announcements = { enabled = true, sound = true, voice = false, syntheticVoice = false, requireVoiceLine = true, volume = 1, sampleRate = 48000, maxSamples = 128000, chunkSamples = 24000, streamGraceSeconds = 30, watchdogSeconds = 0.25, idleWatchdogSeconds = 2, tailSeconds = 0.5, maxChunksPerFeed = 8, prebufferSeconds = 2.5, refillSeconds = 0.75, syncLeadSeconds = 1.5, syncToleranceSeconds = 0.08, syncSkipLate = true, serverPlayback = true, serverPreparedAudio = true, clientAudioSynthesis = false, remoteAudioChunkSamples = 4096, remoteAudioYieldChunks = 4, remoteAudioYieldSeconds = 0.03, remoteAudioLeadSeconds = 1, alarmAnnouncements = true, queueLimit = 12, syncAssets = true, assetsRequired = false },")
  handle.writeLine("  branding = { facilityName = \"Facility\", shortName = \"SEC\", kioskTitle = \"Employee Kiosk\" },")
  handle.writeLine("}")
  handle.close()
  return true
end

function applyDefaults(userConfig)
  local merged = userConfig or {}
  for key, value in pairs(defaultConfig) do
    if merged[key] == nil then
      merged[key] = shallowCopy(value)
    end
  end

  merged.alarm = merged.alarm or shallowCopy(defaultConfig.alarm)
  for key, value in pairs(defaultConfig.alarm) do
    if merged.alarm[key] == nil then
      merged.alarm[key] = shallowCopy(value)
    end
  end
  merged.alarm.profiles = merged.alarm.profiles or shallowCopy(defaultConfig.alarm.profiles)
  for key, value in pairs(defaultConfig.alarm.profiles) do
    if merged.alarm.profiles[key] == nil then
      merged.alarm.profiles[key] = shallowCopy(value)
    end
  end
  merged.alarm.dsp = merged.alarm.dsp or shallowCopy(defaultConfig.alarm.dsp)
  for key, value in pairs(defaultConfig.alarm.dsp) do
    if merged.alarm.dsp[key] == nil then
      merged.alarm.dsp[key] = shallowCopy(value)
    end
  end
  merged.alarm.dsp.patterns = merged.alarm.dsp.patterns or shallowCopy(defaultConfig.alarm.dsp.patterns)
  for key, value in pairs(defaultConfig.alarm.dsp.patterns) do
    if merged.alarm.dsp.patterns[key] == nil then
      merged.alarm.dsp.patterns[key] = shallowCopy(value)
    end
  end

  merged.rednet = merged.rednet or shallowCopy(defaultConfig.rednet)
  for key, value in pairs(defaultConfig.rednet) do
    if merged.rednet[key] == nil then
      merged.rednet[key] = shallowCopy(value)
    end
  end
  merged.rednet.encryption = merged.rednet.encryption or shallowCopy(defaultConfig.rednet.encryption)
  for key, value in pairs(defaultConfig.rednet.encryption) do
    if merged.rednet.encryption[key] == nil then
      merged.rednet.encryption[key] = shallowCopy(value)
    end
  end

  merged.notifications = merged.notifications or shallowCopy(defaultConfig.notifications)
  for key, value in pairs(defaultConfig.notifications) do
    if merged.notifications[key] == nil then
      merged.notifications[key] = shallowCopy(value)
    end
  end
  merged.notifications.sounds = merged.notifications.sounds or shallowCopy(defaultConfig.notifications.sounds)
  for key, value in pairs(defaultConfig.notifications.sounds) do
    if merged.notifications.sounds[key] == nil then
      merged.notifications.sounds[key] = shallowCopy(value)
    end
  end

  merged.configSync = merged.configSync or shallowCopy(defaultConfig.configSync)
  for key, value in pairs(defaultConfig.configSync) do
    if merged.configSync[key] == nil then
      merged.configSync[key] = shallowCopy(value)
    end
  end

  merged.announcements = merged.announcements or shallowCopy(defaultConfig.announcements)
  for key, value in pairs(defaultConfig.announcements) do
    if merged.announcements[key] == nil then
      merged.announcements[key] = shallowCopy(value)
    end
  end
  merged.announcements.auto = merged.announcements.auto or shallowCopy(defaultConfig.announcements.auto)
  for key, value in pairs(defaultConfig.announcements.auto) do
    if merged.announcements.auto[key] == nil then
      merged.announcements.auto[key] = shallowCopy(value)
    end
  end
  merged.announcements.events = merged.announcements.events or shallowCopy(defaultConfig.announcements.events or {})
  for key, value in pairs(defaultConfig.announcements.events or {}) do
    if merged.announcements.events[key] == nil then
      merged.announcements.events[key] = shallowCopy(value)
    end
  end
  merged.announcements.actions = merged.announcements.actions or shallowCopy(defaultConfig.announcements.actions or {})
  for key, value in pairs(defaultConfig.announcements.actions or {}) do
    if merged.announcements.actions[key] == nil then
      merged.announcements.actions[key] = shallowCopy(value)
    end
  end
  merged.announcements.voiceLines = merged.announcements.voiceLines or shallowCopy(defaultConfig.announcements.voiceLines or {})
  for key, value in pairs(defaultConfig.announcements.voiceLines or {}) do
    if merged.announcements.voiceLines[key] == nil then
      merged.announcements.voiceLines[key] = shallowCopy(value)
    end
  end
  merged.announcements.personnelTitles = merged.announcements.personnelTitles or shallowCopy(defaultConfig.announcements.personnelTitles or {})
  for key, value in pairs(defaultConfig.announcements.personnelTitles or {}) do
    if merged.announcements.personnelTitles[key] == nil then
      merged.announcements.personnelTitles[key] = shallowCopy(value)
    end
  end
  merged.announcements.personnelReasons = merged.announcements.personnelReasons or shallowCopy(defaultConfig.announcements.personnelReasons or {})
  for key, value in pairs(defaultConfig.announcements.personnelReasons or {}) do
    if merged.announcements.personnelReasons[key] == nil then
      merged.announcements.personnelReasons[key] = shallowCopy(value)
    end
  end

  merged.employees = merged.employees or shallowCopy(defaultConfig.employees)
  for key, value in pairs(defaultConfig.employees) do
    if merged.employees[key] == nil then
      merged.employees[key] = shallowCopy(value)
    end
  end
  merged.employees.permissions = merged.employees.permissions or shallowCopy(defaultConfig.employees.permissions)
  for key, value in pairs(defaultConfig.employees.permissions) do
    if merged.employees.permissions[key] == nil then
      merged.employees.permissions[key] = value
    end
  end

  merged.logs = merged.logs or shallowCopy(defaultConfig.logs)
  for key, value in pairs(defaultConfig.logs) do
    if merged.logs[key] == nil then
      merged.logs[key] = shallowCopy(value)
    end
  end
  merged.logs.clearances = merged.logs.clearances or shallowCopy(defaultConfig.logs.clearances)
  for key, value in pairs(defaultConfig.logs.clearances) do
    if merged.logs.clearances[key] == nil then
      merged.logs.clearances[key] = value
    end
  end

  merged.setup = merged.setup or shallowCopy(defaultConfig.setup)
  for key, value in pairs(defaultConfig.setup) do
    if merged.setup[key] == nil then
      merged.setup[key] = shallowCopy(value)
    end
  end

  merged.kiosk = merged.kiosk or shallowCopy(defaultConfig.kiosk)
  for key, value in pairs(defaultConfig.kiosk) do
    if merged.kiosk[key] == nil then
      merged.kiosk[key] = shallowCopy(value)
    end
  end
  merged.kiosk.controller = merged.kiosk.controller or shallowCopy(defaultConfig.kiosk.controller)
  for key, value in pairs(defaultConfig.kiosk.controller) do
    if merged.kiosk.controller[key] == nil then
      merged.kiosk.controller[key] = shallowCopy(value)
    end
  end

  merged.branding = merged.branding or shallowCopy(defaultConfig.branding)
  for key, value in pairs(defaultConfig.branding) do
    if merged.branding[key] == nil then
      merged.branding[key] = shallowCopy(value)
    end
  end

  merged.facility = merged.facility or shallowCopy(defaultConfig.facility)
  for key, value in pairs(defaultConfig.facility) do
    if merged.facility[key] == nil then
      merged.facility[key] = shallowCopy(value)
    end
  end
  merged.facility.hostileEntityDetection = merged.facility.hostileEntityDetection or shallowCopy(defaultConfig.facility.hostileEntityDetection or {})
  for key, value in pairs(defaultConfig.facility.hostileEntityDetection or {}) do
    if merged.facility.hostileEntityDetection[key] == nil then
      merged.facility.hostileEntityDetection[key] = shallowCopy(value)
    end
  end

  merged.monitors = merged.monitors or shallowCopy(defaultConfig.monitors)
  for key, value in pairs(defaultConfig.monitors) do
    if merged.monitors[key] == nil then
      merged.monitors[key] = shallowCopy(value)
    end
  end

  merged.credentials = merged.credentials or {}
  merged.doors = merged.doors or shallowCopy(defaultConfig.doors)
  merged.readers = merged.readers or shallowCopy(defaultConfig.readers)
  merged.sensors = merged.sensors or {}
  merged.emergencyButtons = merged.emergencyButtons or {}
  merged.generators = merged.generators or {}
  merged.facilityName = merged.facilityName or merged.siteName or merged.branding.facilityName
  if merged.branding.facilityName == defaultConfig.branding.facilityName and merged.facilityName ~= defaultConfig.facilityName then
    merged.branding.facilityName = merged.facilityName
  else
    merged.branding.facilityName = merged.branding.facilityName or merged.facilityName
  end

  return merged
end

function loadConfig(requestedMode)
  if not fs.exists(CONFIG_FILE) then
    local installed
    local installErr
    if requestedMode == "kiosk" then
      installed, installErr = installKioskConfigIfMissing()
    else
      installed, installErr = installRemoteConfigIfMissing()
    end
    if not installed then
      error("Missing " .. CONFIG_FILE .. ": " .. tostring(installErr))
    end
  end

  local fn, err = loadfile(CONFIG_FILE)
  if not fn then
    error("Could not load " .. CONFIG_FILE .. ": " .. tostring(err))
  end

  local ok, loaded = pcall(fn)
  if not ok then
    error("Could not run " .. CONFIG_FILE .. ": " .. tostring(loaded))
  end

  if type(loaded) ~= "table" then
    error(CONFIG_FILE .. " must return a table")
  end

  return applyDefaults(loaded)
end

function saveConfig()
  local handle = fs.open(CONFIG_FILE, "w")
  handle.writeLine("-- Saved by security_system.lua. Comments from the example file are not preserved.")
  handle.writeLine("return " .. textutils.serialize(config))
  handle.close()
  audit("CONFIG_SAVE", "saved")
end

function loadDataFile(path, defaultValue)
  if not path or not fs.exists(path) then
    return shallowCopy(defaultValue)
  end

  local fn, err = loadfile(path)
  if not fn then
    audit("DATA_LOAD_ERROR", { path = path, error = err })
    return shallowCopy(defaultValue)
  end

  local ok, value = pcall(fn)
  if not ok or type(value) ~= "table" then
    audit("DATA_LOAD_ERROR", { path = path, error = value })
    return shallowCopy(defaultValue)
  end

  return value
end

function saveDataFile(path, value)
  local handle = fs.open(path, "w")
  handle.writeLine("-- Saved by security_system.lua.")
  handle.writeLine("return " .. textutils.serialize(value or {}))
  handle.close()
end

function nowMillis()
  if os.epoch then
    local ok, value = pcall(os.epoch, "utc")
    if ok and value then
      return value
    end
  end
  return math.floor(os.clock() * 1000)
end

function rednetTimestampMillis()
  return nowMillis()
end

function stampOutboundRednetMessage(message)
  if type(message) ~= "table" then
    return message
  end

  local sentAt = rednetTimestampMillis()
  message.sentAtMillis = sentAt
  local mode = string.lower(tostring(config and config.mode or "server"))
  if mode == "" or mode == "server" then
    message.serverTimeMillis = sentAt
  end
  return message
end

function updateKioskClockOffset(message, sender)
  if type(message) ~= "table" then
    return
  end

  local serverMillis = tonumber(message.serverTimeMillis or (message.status and message.status.serverTimeMillis))
  if not serverMillis and sender and state.kiosk and state.kiosk.serverId and tostring(sender) == tostring(state.kiosk.serverId) then
    serverMillis = tonumber(message.sentAtMillis)
  end
  if not serverMillis then
    return
  end

  state.kiosk.clockOffsetMillis = serverMillis - nowMillis()
end

function serverMillisToLocalMillis(value)
  value = tonumber(value)
  if not value then
    return nil
  end
  local mode = string.lower(tostring(config and config.mode or "server"))
  if mode ~= "kiosk" and mode ~= "controller" and mode ~= "door" and mode ~= "door_controller" then
    return value
  end
  return value - (tonumber(state.kiosk and state.kiosk.clockOffsetMillis) or 0)
end

function makeId(prefix)
  return tostring(prefix or "id") .. "_" .. tostring(nowMillis()) .. "_" .. tostring(math.random(100000, 999999))
end

function normalizeUsername(username)
  local text = tostring(username or "")
  text = string.gsub(text, "^%s+", "")
  text = string.gsub(text, "%s+$", "")
  return string.lower(text)
end

function displayBranding()
  local branding = config and config.branding or {}
  if config and tostring(config.mode or "") == "kiosk" and state and state.kiosk and type(state.kiosk.branding) == "table" then
    local remote = state.kiosk.branding
    branding = {
      facilityName = remote.facilityName or branding.facilityName,
      shortName = remote.shortName or branding.shortName,
      kioskTitle = remote.kioskTitle or branding.kioskTitle,
      motto = remote.motto or branding.motto,
      primaryColor = remote.primaryColor or branding.primaryColor,
      accentColor = remote.accentColor or branding.accentColor,
      textColor = remote.textColor or branding.textColor,
    }
  end

  return {
    facilityName = branding.facilityName or (config and config.facilityName) or (config and config.siteName) or "Facility",
    shortName = branding.shortName or "SEC",
    kioskTitle = branding.kioskTitle or "Employee Kiosk",
    motto = branding.motto or "Authorized staff only",
    primaryColor = branding.primaryColor or "blue",
    accentColor = branding.accentColor or "lime",
    textColor = branding.textColor or "white",
  }
end

function colorValue(name, fallback)
  if type(name) == "number" then
    return name
  end

  if type(name) == "string" and colors and colors[name] then
    return colors[name]
  end

  return fallback or colors.white
end

function truncate(text, limit)
  text = tostring(text or "")
  limit = tonumber(limit) or 80
  if string.len(text) <= limit then
    return text
  end
  return string.sub(text, 1, math.max(0, limit - 3)) .. "..."
end

function peripheralNames()
  state.peripheralCache = state.peripheralCache or { types = {}, methods = {} }
  if type(state.peripheralCache.names) == "table" then
    return state.peripheralCache.names
  end

  local names = {}
  if peripheral and peripheral.getNames then
    for _, name in ipairs(peripheral.getNames()) do
      table.insert(names, name)
    end
  end

  state.peripheralCache.names = names
  return names
end

function invalidatePeripheralCache()
  state.peripheralCache = {
    names = nil,
    types = {},
    methods = {},
  }
  if type(invalidateMonitorCache) == "function" then
    invalidateMonitorCache()
  end
end

function getTypes(name)
  state.peripheralCache = state.peripheralCache or { types = {}, methods = {} }
  state.peripheralCache.types = state.peripheralCache.types or {}
  local cached = state.peripheralCache.types[name]
  if cached then
    return cached
  end

  local types = { peripheral.getType(name) }
  local map = {}
  for _, item in ipairs(types) do
    if item then
      map[tostring(item)] = true
    end
  end
  state.peripheralCache.types[name] = map
  return map
end

function hasPeripheralType(name, wanted)
  local types = getTypes(name)
  return types[wanted] == true
end

function methodMap(name)
  state.peripheralCache = state.peripheralCache or { types = {}, methods = {} }
  state.peripheralCache.methods = state.peripheralCache.methods or {}
  local cached = state.peripheralCache.methods[name]
  if cached then
    return cached
  end

  local ok, methods = pcall(peripheral.getMethods, name)
  local out = {}
  if ok and type(methods) == "table" then
    for _, method in ipairs(methods) do
      out[method] = true
    end
  end
  state.peripheralCache.methods[name] = out
  return out
end

function endpointList(value)
  if value == nil then
    return {}
  end

  if type(value) ~= "table" then
    return { value }
  end

  if value[1] ~= nil then
    return value
  end

  return { value }
end

function localComputerId()
  if os.getComputerID then
    return os.getComputerID()
  end
  return nil
end

function serverSenderAllowed(sender)
  local serverId = config and config.rednet and config.rednet.serverId
  if not serverId and state and state.kiosk then
    serverId = state.kiosk.serverId
  end
  return serverId == nil or tostring(sender) == tostring(serverId)
end

function endpointController(endpoint)
  if type(endpoint) ~= "table" then
    return nil
  end
  return endpoint.controller or endpoint.computerId or endpoint.computer or endpoint.remote
end

function endpointIsRemote(endpoint)
  local controller = endpointController(endpoint)
  if controller == nil or controller == "" or controller == "server" or controller == "local" then
    return false
  end

  local localId = localComputerId()
  return tostring(controller) ~= tostring(localId or "")
end

function stripEndpointController(endpoint)
  if type(endpoint) ~= "table" then
    return endpoint
  end

  local copy = shallowCopy(endpoint)
  copy.controller = nil
  copy.computerId = nil
  copy.computer = nil
  copy.remote = nil
  return copy
end

function handleInlineRednetWhileWaiting(sender, message)
  if type(message) ~= "table" or not message.op then
    return
  end
  if not handleRednetOperation then
    return
  end

  local reply = { ok = false }
  handleRednetOperation(sender, message, reply)
  reply.requestId = message.requestId
  pcall(sendRednet, sender, reply)
end

function remoteControllerRequest(controller, payload)
  controller = tonumber(controller)
  if not controller then
    return false, "invalid controller id"
  end
  if not (config and config.rednet and config.rednet.enabled and rednet) then
    return false, "rednet unavailable"
  end

  openRednet()
  payload = payload or {}
  local requestId = payload.requestId or makeId("controller")
  payload.requestId = requestId

  local sent, sendErr = sendRednet(controller, payload)
  if not sent then
    return false, sendErr or "send failed"
  end

  local timeout = tonumber(config.setup and config.setup.remoteEndpointTimeout) or 0.75
  local deadline = os.clock() + timeout
  while os.clock() < deadline do
    local ok, sender, message, err = receiveRednet(math.max(0.05, deadline - os.clock()))
    if ok and sender then
      if sender == controller and type(message) == "table" and message.requestId == requestId then
        return message.ok and true or false, message.error, message
      end
      handleInlineRednetWhileWaiting(sender, message)
    elseif not ok then
      return false, err or "receive failed"
    end
  end

  return false, "controller timeout"
end

function remoteEndpointRequest(endpoint, action, extra)
  local payload = extra or {}
  payload.op = "controller_endpoint"
  payload.action = action
  payload.endpoint = stripEndpointController(endpoint)
  return remoteControllerRequest(endpointController(endpoint), payload)
end

function remoteSetEndpoint(endpoint, active)
  local ok, err = remoteEndpointRequest(endpoint, "write", { active = active and true or false })
  return ok, err
end

function remoteReadEndpoint(endpoint)
  local ok, err, reply = remoteEndpointRequest(endpoint, "read")
  if ok and reply then
    return reply.active and true or false, reply.raw
  end
  return false, nil, err
end

function normalizeEndpoint(endpoint)
  if type(endpoint) == "string" then
    return { side = endpoint }
  end
  return endpoint
end

function normalizeRedstoneSide(side, fallback)
  local value = string.lower(tostring(side or fallback or "back"))
  local aliases = {
    up = "top",
    down = "bottom",
    north = "front",
    south = "back",
    east = "right",
    west = "left",
  }
  return aliases[value] or value
end

function endpointSide(endpoint, fallback)
  if type(endpoint) ~= "table" then
    return normalizeRedstoneSide(nil, fallback)
  end
  return normalizeRedstoneSide(endpoint.side or endpoint.outputSide or endpoint.redstoneSide or endpoint.relaySide or endpoint.face, fallback)
end

function endpointPeripheralName(endpoint)
  if type(endpoint) ~= "table" then
    return nil
  end
  return endpoint.peripheral or endpoint.relay or endpoint.redstoneRelay or endpoint.integrator or endpoint.device
end

function wrapEndpointPeripheral(name)
  local target = tostring(name or "")
  if target == "" then
    return nil, nil
  end

  local device = peripheral.wrap(target)
  if device then
    return device, target
  end

  local wanted = string.lower(target)
  wanted = string.gsub(wanted, "%s+", "_")
  if wanted == "relay" or wanted == "redstonerelay" then
    wanted = "redstone_relay"
  elseif wanted == "integrator" or wanted == "redstoneintegrator" then
    wanted = "redstone_integrator"
  end

  for _, name in ipairs(peripheralNames()) do
    if string.lower(tostring(name)) == wanted or hasPeripheralType(name, wanted) then
      device = peripheral.wrap(name)
      if device then
        return device, name
      end
    end
  end

  return nil, nil
end

function endpointAnalogLevel(endpoint)
  if type(endpoint) ~= "table" then
    return 15
  end
  return tonumber(endpoint.level or endpoint.analogLevel or endpoint.strength or endpoint.power or endpoint.threshold) or 15
end

function endpointPulseSeconds(endpoint)
  if type(endpoint) ~= "table" then
    return nil
  end
  local value = endpoint.pulseSeconds or endpoint.pulseLength or endpoint.pulse
  if value == true then
    return 0.1
  end
  value = tonumber(value)
  if value and value > 0 then
    return math.max(0.05, math.min(2, value))
  end
  return nil
end

function callOutputMethod(device, methodName, side, value)
  if not (device and device[methodName]) then
    return false, "missing method " .. tostring(methodName)
  end
  local ok, err = pcall(device[methodName], side, value)
  if ok then
    return true
  end
  return false, err
end

function writePeripheralOutput(device, side, value, level, analogPreferred)
  local ok, err
  if analogPreferred then
    ok, err = callOutputMethod(device, "setAnalogOutput", side, value and level or 0)
    if ok then
      return true
    end
    ok, err = callOutputMethod(device, "setAnalogueOutput", side, value and level or 0)
    if ok then
      return true
    end
  end

  ok, err = callOutputMethod(device, "setOutput", side, value and true or false)
  if ok then
    return true
  end

  ok, err = callOutputMethod(device, "setAnalogOutput", side, value and level or 0)
  if ok then
    return true
  end
  ok, err = callOutputMethod(device, "setAnalogueOutput", side, value and level or 0)
  if ok then
    return true
  end
  return false, err or "peripheral cannot output redstone"
end

function setEndpoint(endpoint, active)
  endpoint = normalizeEndpoint(endpoint)
  if type(endpoint) ~= "table" then
    return false, "invalid endpoint"
  end
  if endpointIsRemote(endpoint) then
    return remoteSetEndpoint(endpoint, active)
  end

  local value = active and true or false
  if endpoint.invert then
    value = not value
  end

  local side = endpointSide(endpoint, "back")
  local level = endpointAnalogLevel(endpoint)
  local pulseSeconds = endpointPulseSeconds(endpoint)

  local peripheralName = endpointPeripheralName(endpoint)
  if peripheralName then
    local device, resolvedName = wrapEndpointPeripheral(peripheralName)
    if not device then
      return false, "missing peripheral " .. tostring(peripheralName)
    end

    if pulseSeconds and value then
      local offOk, offErr = writePeripheralOutput(device, side, false, level, endpoint.analog or endpoint.level or endpoint.analogLevel or endpoint.strength)
      if not offOk then
        return false, offErr
      end
      sleep(pulseSeconds)
    end
    local ok, err = writePeripheralOutput(device, side, value, level, endpoint.analog or endpoint.level or endpoint.analogLevel or endpoint.strength)
    if not ok then
      return false, tostring(err or "peripheral cannot output redstone") .. " on " .. tostring(resolvedName or peripheralName) .. ":" .. tostring(side)
    end
    return true
  end

  if pulseSeconds and value then
    if endpoint.analog or endpoint.level or endpoint.analogLevel then
      redstone.setAnalogOutput(side, 0)
    else
      redstone.setOutput(side, false)
    end
    sleep(pulseSeconds)
  end
  if endpoint.analog or endpoint.level or endpoint.analogLevel then
    redstone.setAnalogOutput(side, value and level or 0)
  else
    redstone.setOutput(side, value)
  end

  return true
end

function readEndpoint(endpoint)
  endpoint = normalizeEndpoint(endpoint)
  if type(endpoint) ~= "table" then
    return false, nil
  end
  if endpointIsRemote(endpoint) then
    return remoteReadEndpoint(endpoint)
  end

  local side = endpointSide(endpoint, "back")
  local threshold = endpoint.threshold or 1
  local active
  local raw

  local peripheralName = endpointPeripheralName(endpoint)
  if peripheralName then
    local device = wrapEndpointPeripheral(peripheralName)
    if not device then
      return false, nil
    end

    if endpoint.analog or endpoint.threshold then
      if device.getAnalogInput then
        local ok, value = pcall(device.getAnalogInput, side)
        raw = ok and value or 0
        active = raw >= threshold
      elseif device.getAnalogueInput then
        local ok, value = pcall(device.getAnalogueInput, side)
        raw = ok and value or 0
        active = raw >= threshold
      elseif device.getInput then
        local ok, value = pcall(device.getInput, side)
        raw = ok and value or false
        active = raw and true or false
      end
    elseif device.getInput then
      local ok, value = pcall(device.getInput, side)
      raw = ok and value or false
      active = raw and true or false
    elseif device.getAnalogInput then
      local ok, value = pcall(device.getAnalogInput, side)
      raw = ok and value or 0
      active = raw >= threshold
    elseif device.getAnalogueInput then
      local ok, value = pcall(device.getAnalogueInput, side)
      raw = ok and value or 0
      active = raw >= threshold
    end
  else
    if endpoint.analog or endpoint.threshold then
      raw = redstone.getAnalogInput(side)
      active = raw >= threshold
    else
      raw = redstone.getInput(side)
      active = raw and true or false
    end
  end

  if endpoint.invert then
    active = not active
  end

  return active and true or false, raw
end

function setOutputList(outputs, active)
  local allOk = true
  local lastErr

  for _, endpoint in ipairs(endpointList(outputs)) do
    local ok, err = setEndpoint(endpoint, active)
    if not ok then
      allOk = false
      lastErr = err
    end
  end

  return allOk, lastErr
end

function endpointWithController(endpoint, controller)
  endpoint = normalizeEndpoint(endpoint)
  if type(endpoint) ~= "table" then
    return endpoint
  end
  if controller == nil or controller == "" or controller == "server" or controller == "local" or endpointController(endpoint) ~= nil then
    return endpoint
  end

  local copy = shallowCopy(endpoint)
  copy.controller = controller
  return copy
end

function endpointListWithController(value, controller)
  local out = {}
  for _, endpoint in ipairs(endpointList(value)) do
    table.insert(out, endpointWithController(endpoint, controller))
  end
  return out
end

function setOutputListWithController(outputs, active, controller)
  return setOutputList(endpointListWithController(outputs, controller), active)
end

function getDoorState(doorId)
  if not state.doors[doorId] then
    state.doors[doorId] = {
      locked = true,
      openUntil = nil,
      authorizedUntil = 0,
      lastActor = nil,
      lockTimer = nil,
    }
  end
  return state.doors[doorId]
end

function setDoorOpen(doorId, open)
  local door = config.doors[doorId]
  if not door then
    return false, "unknown door " .. tostring(doorId)
  end

  local active = open and true or false
  if door.activeOpen == false then
    active = not active
  end

  local outputs = door.outputs or door.output
  if outputs == nil then
    return false, "door has no output"
  end

  return setOutputListWithController(outputs, active, door.controller or door.computerId)
end

function normalizedSeconds(value, fallback, minSeconds, maxSeconds)
  local seconds = tonumber(value)
  if seconds == nil or seconds <= 0 then
    seconds = tonumber(fallback) or 1
  end
  if minSeconds and seconds < minSeconds then
    seconds = minSeconds
  end
  if maxSeconds and seconds > maxSeconds then
    seconds = maxSeconds
  end
  return seconds
end

function credentialPollSeconds()
  return normalizedSeconds(
    config.credentialPollSeconds or config.badgePollSeconds or config.readerPollSeconds or config.pollSeconds,
    1,
    0.1
  )
end

function inputPollSeconds()
  return normalizedSeconds(config.inputPollSeconds or config.doorPollSeconds or config.pollSeconds, 1, 0.1)
end

function sensorPollSeconds()
  local facility = config.facility or {}
  return normalizedSeconds(
    config.sensorPollSeconds or config.facilitySensorPollSeconds or facility.sensorPollSeconds or facility.pollSeconds,
    config.pollSeconds or 1,
    0.25
  )
end

function redstoneDebounceSeconds()
  local timers = config.updateTimers or config.timers or {}
  return normalizedSeconds(timers.redstoneSeconds or config.redstoneDebounceSeconds, 0.05, 0.05, 1)
end

function stressDebounceSeconds()
  local timers = config.updateTimers or config.timers or {}
  return normalizedSeconds(timers.stressSeconds or config.stressDebounceSeconds, 0.2, 0.05, 2)
end

function monitorRefreshSeconds()
  return normalizedSeconds(config.monitors and config.monitors.refreshSeconds, 2, 0.25)
end

function alarmBroadcastSeconds()
  return normalizedSeconds(config.kiosk and config.kiosk.syncSeconds, 2, 0.25)
end

function scheduleTimer(seconds, payload)
  seconds = tonumber(seconds)
  if seconds == nil then
    seconds = 1
  elseif seconds < 0.05 then
    seconds = 0.05
  end
  local id = os.startTimer(seconds)
  state.timers[id] = payload
  if payload and payload.key then
    state.timerKeys[payload.key] = id
  end
  return id
end

function scheduleKeyedTimer(key, seconds, payload)
  if key and state.timerKeys[key] then
    local existing = state.timerKeys[key]
    if state.timers[existing] then
      return existing
    end
    state.timerKeys[key] = nil
  end
  payload = payload or {}
  payload.key = key
  return scheduleTimer(seconds, payload)
end

function clearTimerKey(payload, id)
  if payload and payload.key and state.timerKeys[payload.key] == id then
    state.timerKeys[payload.key] = nil
  end
end

function markDirty()
  state.screenDirty = true
end

function lockDoor(doorId, reason, quiet)
  local door = config.doors[doorId]
  if not door then
    return false, "unknown door"
  end

  local ok, err = setDoorOpen(doorId, false)
  local doorState = getDoorState(doorId)
  doorState.locked = true
  doorState.openUntil = nil
  doorState.authorizedUntil = 0
  doorState.lockTimer = nil

  if not quiet then
    audit("DOOR_LOCK", {
      door = doorId,
      reason = reason or "manual",
      ok = ok,
      error = err,
    })
  end

  markDirty()
  return ok, err
end

function peripheralLooksLikeSpeaker(name)
  if hasPeripheralType(name, "speaker") then
    return true
  end
  local methods = methodMap(name)
  return methods.playAudio == true or methods.playSound == true or methods.playNote == true
end

function findSpeakers()
  local out = {}
  for _, name in ipairs(peripheralNames()) do
    if peripheralLooksLikeSpeaker(name) then
      local device = peripheral.wrap(name)
      if device then
        table.insert(out, device)
      end
    end
  end
  return out
end

function findSpeakerEntries()
  local out = {}
  for _, name in ipairs(peripheralNames()) do
    if peripheralLooksLikeSpeaker(name) then
      local device = peripheral.wrap(name)
      if device then
        table.insert(out, { name = name, speaker = device })
      end
    end
  end
  return out
end

function findChatBox()
  for _, name in ipairs(peripheralNames()) do
    local methods = methodMap(name)
    if methods.sendMessage then
      local device = peripheral.wrap(name)
      if device then
        return device
      end
    end
  end
  return nil
end

function alarmProfile(profileName)
  local alarm = config.alarm or {}
  local profile = {}
  if profileName and type(alarm.profiles) == "table" and type(alarm.profiles[profileName]) == "table" then
    profile = alarm.profiles[profileName]
  end

  return {
    name = profileName,
    label = profile.label or alarm.label or "Alarm",
    chat = profile.chat ~= nil and profile.chat or alarm.chat,
    repeatSeconds = profile.repeatSeconds or alarm.repeatSeconds or 1.5,
    sounds = profile.sounds or alarm.sounds or {},
    dsp = profile.dsp or alarm.dsp,
    audio = profile.audio or alarm.audio,
    syncLeadSeconds = profile.syncLeadSeconds or alarm.syncLeadSeconds or 1.5,
    syncToleranceSeconds = profile.syncToleranceSeconds or alarm.syncToleranceSeconds,
    syncSkipLate = profile.syncSkipLate ~= nil and profile.syncSkipLate or alarm.syncSkipLate,
    sampleRate = profile.sampleRate or alarm.sampleRate,
    maxSamples = profile.maxSamples or alarm.maxSamples,
    volume = profile.volume or alarm.volume,
    outputs = profile.outputs or profile.output or alarm.outputs or alarm.output,
  }
end

function sendChat(message, profileName)
  local profile = alarmProfile(profileName)
  if not profile.chat then
    return
  end

  local chat = findChatBox()
  if not chat then
    return
  end

  local brand = displayBranding()
  local prefix = brand.shortName or config.siteName or "Security"
  local ok = pcall(chat.sendMessage, message, prefix)
  if not ok then
    pcall(chat.sendMessage, "[" .. prefix .. "] " .. message)
  end
end

function setAlarmOutputs(active)
  local profile = alarmProfile(state.alarm.profile)
  setOutputList(profile.outputs, active)
end

function alarmStatePayload()
  local brand = displayBranding()
  return {
    op = "alarm_state",
    serverTimeMillis = nowMillis(),
    branding = {
      facilityName = brand.facilityName,
      shortName = brand.shortName,
      kioskTitle = brand.kioskTitle,
      motto = brand.motto,
      primaryColor = brand.primaryColor,
      accentColor = brand.accentColor,
      textColor = brand.textColor,
      permissions = {
        quitKiosk = config.employees and config.employees.permissions and config.employees.permissions.quitKiosk or 5,
        setupFacility = config.employees and config.employees.permissions and config.employees.permissions.setupFacility or 5,
        issueBadges = config.employees and config.employees.permissions and config.employees.permissions.issueBadges or 5,
      },
    },
    alarm = {
      active = state.alarm.active,
      reason = state.alarm.reason,
      door = state.alarm.door,
      actor = state.alarm.actor,
      profile = state.alarm.profile,
      sinceMillis = state.alarm.sinceMillis,
      soundStartAt = state.alarm.soundStartAt,
      sourceKey = state.alarm.sourceKey,
      sourceAutoReset = state.alarm.sourceAutoReset,
    },
    lockdown = state.lockdown,
  }
end

function broadcastAlarmState()
  if not (config and config.rednet and config.rednet.enabled and rednet) then
    return
  end

  openRednet()
  pcall(broadcastRednet, alarmStatePayload())
end

function notificationConfig()
  return config.notifications or {}
end

function makeNotification(kind, title, text, severity, extra)
  local notification = extra or {}
  notification.id = notification.id or makeId("notice")
  notification.kind = kind or notification.kind or "notice"
  notification.title = title or notification.title or "Facility Notice"
  notification.text = text or notification.text or ""
  notification.severity = severity or notification.severity or "info"
  notification.createdAt = notification.createdAt or timestamp()
  notification.createdAtMillis = notification.createdAtMillis or nowMillis()
  return notification
end

function sendNotificationPayload(target, notification, targetUser)
  local payload = {
    op = "notification",
    notification = notification,
    target = targetUser,
    serverTimeMillis = nowMillis(),
  }
  return pcall(sendRednet, target, payload)
end

function notificationUsesAnnouncementAudio(notification)
  if type(notification) ~= "table" then
    return false
  end
  local kind = tostring(notification.kind or notification.type or "")
  return notification.announcement == true or kind == "announcement" or kind == "alarm" or kind == "emergency" or kind == "lockdown" or kind == "lockdown_clear"
end

function notificationIsActiveAlarmEvent(notification)
  if type(notification) ~= "table" then
    return false
  end
  local kind = tostring(notification.kind or notification.type or "")
  return kind == "alarm" or kind == "emergency"
end

function announcementSyncLeadMillis()
  local announcements = config and config.announcements or {}
  local audio = type(announcements.audio) == "table" and announcements.audio or {}
  local seconds = tonumber(audio.syncLeadSeconds or announcements.syncLeadSeconds) or 1.5
  if seconds < 0 then
    seconds = 0
  end
  return math.floor((seconds * 1000) + 0.5)
end

function notificationScheduledStartMillis(notification)
  if type(notification) ~= "table" then
    return nil
  end
  return tonumber(notification.soundStartAt or notification.announcementStartAt or notification.playAtMillis or notification.startAtMillis)
end

function setNotificationScheduledStart(notification, startAt)
  if type(notification) ~= "table" or not startAt then
    return
  end
  notification.soundStartAt = startAt
  notification.announcementStartAt = startAt
  notification.playAtMillis = startAt
end

function clearNotificationScheduledStart(notification)
  if type(notification) ~= "table" then
    return
  end
  notification.soundStartAt = nil
  notification.announcementStartAt = nil
  notification.playAtMillis = nil
  notification.startAtMillis = nil
end

function ensureNotificationPlaybackSchedule(notification)
  if type(notification) ~= "table" then
    return notification
  end

  notification.sentAtMillis = nowMillis()
  if not notificationUsesAnnouncementAudio(notification) then
    return notification
  end

  local startAt = notificationScheduledStartMillis(notification)
  if not startAt and type(notification.alarm) == "table" then
    startAt = tonumber(notification.alarm.soundStartAt)
  end
  if not startAt then
    startAt = nowMillis() + announcementSyncLeadMillis()
  end
  setNotificationScheduledStart(notification, startAt)
  return notification
end

function normalizeNotificationTimingFromServer(notification, envelope, sender)
  updateKioskClockOffset(envelope, sender)
  if type(notification) ~= "table" then
    return
  end

  local startAt = notificationScheduledStartMillis(notification)
  if startAt then
    setNotificationScheduledStart(notification, serverMillisToLocalMillis(startAt))
  end
end

function announcementKindValue(announcement)
  if type(announcement) == "table" then
    return tostring(announcement.kind or announcement.type or "")
  end
  return tostring(announcement or "")
end

function announcementIsAlarmOrEmergencyKind(kind)
  kind = tostring(kind or "")
  return kind == "alarm" or kind == "emergency"
end

function announcementKeyIsAlarmOrEmergency(kind)
  kind = tostring(kind or "")
  return kind == "alarm"
    or kind == "emergency"
    or string.find(kind, "alarm:", 1, true) == 1
    or string.find(kind, "emergency:", 1, true) == 1
    or string.find(kind, "event:alarm", 1, true) == 1
    or string.find(kind, "event:emergency", 1, true) == 1
end

function alarmAnnouncementSuppressionActive()
  if state.alarm and state.alarm.active then
    return true
  end
  if type(alarmAudioBusy) == "function" and alarmAudioBusy() then
    return true
  end
  return false
end

function announcementCanPlayDuringAlarm(announcement)
  return announcementIsAlarmOrEmergencyKind(announcementKindValue(announcement))
end

function configuredAnnouncementAllowedDuringAlarm(key, fallbackKey, spec)
  if not alarmAnnouncementSuppressionActive() then
    return true
  end
  if announcementKeyIsAlarmOrEmergency(key) or announcementKeyIsAlarmOrEmergency(fallbackKey) then
    return true
  end
  if type(spec) == "table" and announcementIsAlarmOrEmergencyKind(spec.kind or spec.type) then
    return true
  end
  return false
end

function broadcastKioskNotification(notification, targetUser)
  local options = notificationConfig()
  if options.enabled == false then
    return
  end

  ensureNotificationPlaybackSchedule(notification)
  local useAnnouncementAudio = notificationUsesAnnouncementAudio(notification)
  local playOnServer = false
  if not targetUser and useAnnouncementAudio then
    local announcements = config.announcements or {}
    playOnServer = announcements.serverPlayback ~= false
      and announcements.localPlayback ~= false
      and not notificationIsActiveAlarmEvent(notification)
  end
  local playedBeforeNotify = false
  if playOnServer and useAnnouncementAudio and not targetUser then
    notification.serverPreparedAudio = false
    pcall(playFacilityAnnouncement, notification)
    playedBeforeNotify = true
  end

  if not (config and config.rednet and config.rednet.enabled and rednet) then
    if playOnServer and not playedBeforeNotify then
      pcall(playFacilityAnnouncement, notification)
    end
    return
  end

  openRednet()
  if targetUser and targetUser ~= "" then
    for _, session in pairs(state.sessions or {}) do
      if session.username == targetUser and session.sender then
        sendNotificationPayload(session.sender, notification, targetUser)
      end
    end
    return
  end

  pcall(broadcastRednet, {
    op = "notification",
    notification = notification,
    serverTimeMillis = nowMillis(),
  })
  if playOnServer and not playedBeforeNotify then
    pcall(playFacilityAnnouncement, notification)
  end
end

function announcementConfig()
  return (config and config.announcements) or {}
end

function firstTextValue(...)
  for index = 1, select("#", ...) do
    local value = select(index, ...)
    if value ~= nil and tostring(value) ~= "" then
      return tostring(value)
    end
  end
  return nil
end

function chooseAnnouncementValue(value)
  if type(value) == "table" and #value > 0 then
    return chooseAnnouncementValue(value[math.random(1, #value)])
  end
  return value
end

function copyContextFields(context, source)
  if type(source) ~= "table" then
    return
  end
  for key, value in pairs(source) do
    if type(value) ~= "table" and context[key] == nil then
      context[key] = value
    end
  end
end

function announcementKey(value)
  local text = string.lower(tostring(value or ""))
  text = string.gsub(text, "%s+", "_")
  text = string.gsub(text, "[^%w_%-]", "")
  if text == "" then
    text = "unknown"
  end
  return text
end

function configuredVoiceLineExists(id)
  id = tostring(id or "")
  if id == "" then
    return false
  end

  local lines = config and config.announcements and config.announcements.voiceLines or {}
  return lines[id] ~= nil or lines[tostring(id)] ~= nil
end

function personnelTitleSpec(roleKey, rawRole)
  local titles = config and config.announcements and config.announcements.personnelTitles or {}
  if type(titles) ~= "table" then
    return nil
  end
  return titles[roleKey] or titles[tostring(rawRole or "")]
end

function personnelTitleLabel(roleKey, rawRole)
  local spec = personnelTitleSpec(roleKey, rawRole)
  if type(spec) == "table" then
    return spec.label or spec.title or spec.name or tostring(rawRole or roleKey or "employee")
  end
  if type(spec) == "string" then
    return spec
  end

  local labels = {
    admin = "Admin",
    doctor = "Doctor",
    employee = "Employee",
    engineer = "Engineer",
    maintenance = "Maintenance",
    security = "Security",
  }
  return labels[roleKey] or tostring(rawRole or roleKey or "employee")
end

function personnelReasonSpec(reasonKey, rawReason)
  local reasons = config and config.announcements and config.announcements.personnelReasons or {}
  if type(reasons) ~= "table" then
    return nil
  end
  return reasons[reasonKey] or reasons[tostring(rawReason or "")]
end

function personnelReasonLabel(reasonKey, rawReason)
  local spec = personnelReasonSpec(reasonKey, rawReason)
  if type(spec) == "table" then
    return spec.label or spec.title or spec.name or tostring(rawReason or reasonKey or "general assistance")
  end
  if type(spec) == "string" and not configuredVoiceLineExists(spec) then
    return spec
  end

  local labels = {
    engineering = "engineering",
    general = "general assistance",
    maintenance = "maintenance",
    medical = "medical assistance",
    meeting = "meeting",
    questioning = "questioning",
    security = "security",
  }
  return labels[reasonKey] or tostring(rawReason or reasonKey or "general assistance")
end

function employeeRecordByName(value)
  local target = normalizeUsername(value)
  if target == "" then
    return nil
  end

  local direct = employeeRecord(target)
  if direct then
    return direct
  end

  for _, record in pairs(state.accounts and state.accounts.users or {}) do
    if normalizeUsername(record.displayName or record.username) == target then
      return record
    end
  end
  return nil
end

function personnelRoleFromText(value)
  local key = announcementKey(value)
  if key == "admin" or key == "administrator" then
    return "admin"
  end
  if key == "doctor" or key == "medic" or key == "medical" then
    return "doctor"
  end
  if key == "engineer" or key == "engineering" then
    return "engineer"
  end
  if key == "maintenance" or key == "mechanic" or key == "technician" then
    return "maintenance"
  end
  if key == "security" or key == "guard" then
    return "security"
  end
  if key == "employee" or key == "staff" or key == "personnel" then
    return "employee"
  end
  return nil
end

function personnelRequestFields(message, personnel)
  message = type(message) == "table" and message or {}
  local record = employeeRecordByName(personnel)
  local rawRole = firstTextValue(message.personnelRole, message.role, message.title, message.personnelTitle)
  rawRole = rawRole or (record and record.role) or personnelRoleFromText(personnel) or "employee"

  local roleKey = announcementKey(rawRole)
  local spec = personnelTitleSpec(roleKey, rawRole)
  local voiceLine = type(spec) == "table" and spec.voiceLine or nil
  if not voiceLine or tostring(voiceLine) == "" then
    voiceLine = "personnel_request_" .. roleKey
  end
  if not configuredVoiceLineExists(voiceLine) then
    roleKey = "employee"
    rawRole = "employee"
    spec = personnelTitleSpec(roleKey, rawRole)
    voiceLine = type(spec) == "table" and spec.voiceLine or "personnel_request_employee"
  end
  if not configuredVoiceLineExists(voiceLine) then
    voiceLine = "personnel_request"
  end

  return {
    personnelRole = rawRole,
    personnelRoleKey = roleKey,
    personnelTitle = personnelTitleLabel(roleKey, rawRole),
    personnelTitleKey = announcementKey(personnelTitleLabel(roleKey, rawRole)),
    personnelVoiceLine = voiceLine,
    personnelUsername = record and record.username or nil,
  }
end

function configuredVoiceLineOrEmpty(id)
  id = tostring(id or "")
  if configuredVoiceLineExists(id) then
    return id
  end
  return ""
end

function personVoiceLineId(value)
  local id = "person_" .. announcementKey(value)
  return configuredVoiceLineOrEmpty(id)
end

function placeVoiceLineId(value)
  local id = "place_" .. announcementKey(value)
  return configuredVoiceLineOrEmpty(id)
end

function personnelReasonFields(message)
  message = type(message) == "table" and message or {}
  local rawReason = firstTextValue(message.personnelReason, message.requestReason, message.paReason, message.reason)
  if not rawReason or rawReason == "" then
    rawReason = "general"
  end

  local reasonKey = announcementKey(rawReason)
  local spec = personnelReasonSpec(reasonKey, rawReason)
  local voiceLine = nil
  if type(spec) == "table" then
    voiceLine = spec.voiceLine or spec.voice or spec.id
  elseif type(spec) == "string" and configuredVoiceLineExists(spec) then
    voiceLine = spec
  end
  if not voiceLine or tostring(voiceLine) == "" then
    voiceLine = "personnel_reason_" .. reasonKey
  end
  if not configuredVoiceLineExists(voiceLine) then
    voiceLine = configuredVoiceLineOrEmpty("personnel_reason_general")
  end

  return {
    personnelReason = rawReason,
    personnelReasonKey = reasonKey,
    personnelReasonLabel = personnelReasonLabel(reasonKey, rawReason),
    personnelReasonVoiceLine = voiceLine,
  }
end

function doorAnnouncementFields(doorId)
  local id = tostring(doorId or "")
  local door = config and config.doors and config.doors[id] or nil
  local label = id
  local area = nil
  if type(door) == "table" then
    label = door.label or door.name or id
    area = door.area or door.zone or door.sector or door.location or door.wing
  end
  area = area or "unspecified area"
  return {
    door = id,
    doorLabel = label,
    doorKey = announcementKey(id),
    area = tostring(area),
    areaKey = announcementKey(area),
  }
end

function applyDoorAnnouncementContext(context, doorId)
  if not (type(context) == "table" and doorId and tostring(doorId) ~= "") then
    return
  end

  local fields = doorAnnouncementFields(doorId)
  for key, value in pairs(fields) do
    if context[key] == nil or context[key] == "" then
      context[key] = value
    end
  end
end

function announcementContextValue(context, key)
  local current = context
  for part in string.gmatch(tostring(key or ""), "[^%.]+") do
    if type(current) ~= "table" then
      return nil
    end
    current = current[part]
    if current == nil then
      return nil
    end
  end
  return current
end

function formatAnnouncementTemplate(text, context)
  text = tostring(text or "")
  return (string.gsub(text, "{([%w_%.%-]+)}", function(key)
    local value = announcementContextValue(context or {}, key)
    if value == nil then
      return ""
    end
    return tostring(value)
  end))
end

function formatAnnouncementValue(value, context)
  if type(value) == "string" or type(value) == "number" then
    return formatAnnouncementTemplate(value, context)
  end
  if type(value) == "table" then
    local out = {}
    for key, child in pairs(value) do
      out[key] = formatAnnouncementValue(child, context)
    end
    return out
  end
  return value
end

function eventAnnouncementContext(kind, title, text, severity, extra)
  local context = {
    kind = kind,
    event = kind,
    title = title,
    text = text,
    message = text,
    severity = severity,
    facility = displayBranding().facilityName or config.siteName or "Facility",
    shortName = displayBranding().shortName or "SEC",
  }
  copyContextFields(context, extra)
  if type(extra) == "table" and type(extra.alarm) == "table" then
    context.reason = context.reason or extra.alarm.reason
    context.actor = context.actor or extra.alarm.actor
    context.door = context.door or extra.alarm.door
    context.profile = context.profile or extra.alarm.profile
  end
  context.reason = context.reason or context.text or ""
  applyDoorAnnouncementContext(context, context.door)
  context.personnel = context.personnel or context.person or context.actor or context.user
  context.personnelKey = context.personnelKey or announcementKey(context.personnel)
  context.personnelRole = context.personnelRole or "employee"
  context.personnelRoleKey = context.personnelRoleKey or announcementKey(context.personnelRole)
  context.personnelTitle = context.personnelTitle or personnelTitleLabel(context.personnelRoleKey, context.personnelRole)
  context.personnelTitleKey = context.personnelTitleKey or announcementKey(context.personnelTitle)
  context.personnelVoiceLine = context.personnelVoiceLine or "personnel_request_" .. tostring(context.personnelRoleKey)
  context.personnelNameVoiceLine = context.personnelNameVoiceLine or personVoiceLineId(context.personnel)
  context.personnelReason = context.personnelReason or context.requestReason or context.paReason or context.reason or "general"
  context.personnelReasonKey = context.personnelReasonKey or announcementKey(context.personnelReason)
  context.personnelReasonLabel = context.personnelReasonLabel or personnelReasonLabel(context.personnelReasonKey, context.personnelReason)
  context.personnelReasonVoiceLine = context.personnelReasonVoiceLine or configuredVoiceLineOrEmpty("personnel_reason_" .. tostring(context.personnelReasonKey))
  context.areaVoiceLine = context.areaVoiceLine or placeVoiceLineId(context.area)
  context.requester = context.requester or context.actor or context.user
  context.requesterKey = context.requesterKey or announcementKey(context.requester)
  return context
end

function actionAnnouncementContext(action, detail)
  local context = {
    kind = "action",
    event = action,
    action = action,
    detail = type(detail) == "table" and compact(detail) or tostring(detail or ""),
    facility = displayBranding().facilityName or config.siteName or "Facility",
    shortName = displayBranding().shortName or "SEC",
  }
  copyContextFields(context, detail)
  applyDoorAnnouncementContext(context, context.door)
  context.personnel = context.personnel or context.person or context.actor or context.user
  context.personnelKey = context.personnelKey or announcementKey(context.personnel)
  context.personnelRole = context.personnelRole or "employee"
  context.personnelRoleKey = context.personnelRoleKey or announcementKey(context.personnelRole)
  context.personnelTitle = context.personnelTitle or personnelTitleLabel(context.personnelRoleKey, context.personnelRole)
  context.personnelTitleKey = context.personnelTitleKey or announcementKey(context.personnelTitle)
  context.personnelVoiceLine = context.personnelVoiceLine or "personnel_request_" .. tostring(context.personnelRoleKey)
  context.personnelNameVoiceLine = context.personnelNameVoiceLine or personVoiceLineId(context.personnel)
  context.personnelReason = context.personnelReason or context.requestReason or context.paReason or context.reason or "general"
  context.personnelReasonKey = context.personnelReasonKey or announcementKey(context.personnelReason)
  context.personnelReasonLabel = context.personnelReasonLabel or personnelReasonLabel(context.personnelReasonKey, context.personnelReason)
  context.personnelReasonVoiceLine = context.personnelReasonVoiceLine or configuredVoiceLineOrEmpty("personnel_reason_" .. tostring(context.personnelReasonKey))
  context.areaVoiceLine = context.areaVoiceLine or placeVoiceLineId(context.area)
  context.requester = context.requester or context.actor or context.user
  context.requesterKey = context.requesterKey or announcementKey(context.requester)
  return context
end

function announcementCooldownReady(key, spec)
  local seconds = tonumber(spec and spec.cooldownSeconds)
  if not seconds or seconds <= 0 then
    return true
  end

  state.announcements.cooldowns = state.announcements.cooldowns or {}
  local now = os.clock()
  local last = tonumber(state.announcements.cooldowns[key]) or 0
  if now - last < seconds then
    return false
  end
  return true
end

function markAnnouncementCooldown(key, spec)
  local seconds = tonumber(spec and spec.cooldownSeconds)
  if seconds and seconds > 0 then
    state.announcements.cooldowns = state.announcements.cooldowns or {}
    state.announcements.cooldowns[key] = os.clock()
  end
end

function announcementSpecAllowed(key, spec)
  if type(spec) ~= "table" then
    return true
  end
  if spec.enabled == false then
    return false
  end
  if not announcementCooldownReady(key, spec) then
    return false
  end
  local chance = tonumber(spec.chance)
  if chance then
    if chance > 1 then
      chance = chance / 100
    end
    if math.random() > math.max(0, math.min(1, chance)) then
      return false
    end
  end
  return true
end

function announcementVariation(spec)
  if type(spec) ~= "table" then
    return spec
  end
  local variants = spec.variations or spec.variants or spec.lines or spec.messages or spec.texts
  if type(variants) == "table" and #variants > 0 then
    return variants[math.random(1, #variants)]
  end
  return spec
end

function configuredAnnouncementText(spec, variant)
  if type(variant) == "string" or type(variant) == "number" then
    return tostring(variant)
  end
  if type(variant) == "table" then
    return firstTextValue(variant.text, variant.message, variant.body, variant.title, variant[1])
  end
  if type(spec) == "string" or type(spec) == "number" then
    return tostring(spec)
  end
  if type(spec) == "table" then
    return firstTextValue(spec.text, spec.message, spec.body, spec.title, spec[1])
  end
  return nil
end

function configuredAnnouncementVoice(spec, variant)
  local value = nil
  if type(variant) == "table" then
    value = variant.voiceLine or variant.voice or variant.id
  end
  if value == nil and type(spec) == "table" then
    value = spec.voiceLine or spec.voice or spec.id
  end
  return chooseAnnouncementValue(value)
end

function configuredAnnouncementVoiceLines(spec, variant)
  local value = nil
  if type(variant) == "table" then
    value = variant.voiceLines or variant.voiceLineParts or variant.voiceSequence
  end
  if value == nil and type(spec) == "table" then
    value = spec.voiceLines or spec.voiceLineParts or spec.voiceSequence
  end
  return value
end

function configuredAnnouncementAudioField(spec, variant, field)
  if type(variant) == "table" and variant[field] ~= nil then
    return variant[field]
  end
  if type(spec) == "table" and spec[field] ~= nil then
    return spec[field]
  end
  return nil
end

function configuredAnnouncementHasAudio(spec, variant, voiceLine)
  if voiceLine ~= nil and tostring(voiceLine) ~= "" then
    return true
  end
  local fields = { "voiceLines", "voiceLineParts", "voiceSequence", "wav", "file", "path", "files", "pcm", "samples", "mix", "layers", "overlay", "overlays", "parts", "segments" }
  for _, field in ipairs(fields) do
    local value = configuredAnnouncementAudioField(spec, variant, field)
    if value ~= nil then
      return true
    end
  end
  return false
end

function configuredAnnouncement(key, fallbackKey, context)
  local announcements = announcementConfig()
  if announcements.enabled == false or announcements.eventAnnouncements == false then
    return nil
  end

  local events = announcements.events or {}
  local actions = announcements.actions or {}
  local spec = events[key] or events[fallbackKey] or actions[key] or actions[fallbackKey]
  if spec == nil then
    return nil
  end
  if not configuredAnnouncementAllowedDuringAlarm(key, fallbackKey, spec) then
    return nil
  end
  if not announcementSpecAllowed(key, spec) then
    return nil
  end

  local variant = announcementVariation(spec)
  if type(variant) == "table" and variant.enabled == false then
    return nil
  end

  local text = configuredAnnouncementText(spec, variant)
  local voiceLine = configuredAnnouncementVoice(spec, variant)
  if type(voiceLine) == "string" then
    voiceLine = formatAnnouncementTemplate(voiceLine, context)
  end
  local voiceLines = configuredAnnouncementVoiceLines(spec, variant)
  if voiceLines ~= nil then
    voiceLines = formatAnnouncementValue(voiceLines, context)
  end
  if announcements.requireVoiceLine and not configuredAnnouncementHasAudio(spec, variant, voiceLine) then
    return nil
  end
  if not text or text == "" then
    text = firstTextValue(type(variant) == "table" and variant.title or nil, type(spec) == "table" and spec.title or nil, "Facility announcement")
  end

  local out = {
    text = formatAnnouncementTemplate(text, context),
    voiceLine = voiceLine,
    voiceLines = voiceLines,
  }

  if type(spec) == "table" then
    out.kind = spec.kind
    out.title = spec.title
    out.severity = spec.severity
    out.announcement = spec.announcement
    out.wav = spec.wav
    out.files = spec.files
    out.pcm = spec.pcm
    out.samples = spec.samples
    out.mix = spec.mix
    out.layers = spec.layers
    out.overlay = spec.overlay
    out.overlays = spec.overlays
    out.parts = spec.parts
    out.segments = spec.segments
    out.voiceLineParts = spec.voiceLineParts
    out.voiceSequence = spec.voiceSequence
  end
  if type(variant) == "table" then
    out.kind = variant.kind or out.kind
    out.title = variant.title or out.title
    out.severity = variant.severity or out.severity
    if variant.announcement ~= nil then
      out.announcement = variant.announcement
    end
    if variant.wav ~= nil then
      out.wav = variant.wav
    end
    if variant.files ~= nil then
      out.files = variant.files
    end
    if variant.pcm ~= nil then
      out.pcm = variant.pcm
    end
    if variant.samples ~= nil then
      out.samples = variant.samples
    end
    if variant.mix ~= nil then
      out.mix = variant.mix
    end
    if variant.layers ~= nil then
      out.layers = variant.layers
    end
    if variant.overlay ~= nil then
      out.overlay = variant.overlay
    end
    if variant.overlays ~= nil then
      out.overlays = variant.overlays
    end
    if variant.parts ~= nil then
      out.parts = variant.parts
    end
    if variant.segments ~= nil then
      out.segments = variant.segments
    end
    if variant.voiceLineParts ~= nil then
      out.voiceLineParts = formatAnnouncementValue(variant.voiceLineParts, context)
    end
    if variant.voiceSequence ~= nil then
      out.voiceSequence = formatAnnouncementValue(variant.voiceSequence, context)
    end
  end
  out.title = out.title and formatAnnouncementTemplate(out.title, context) or nil
  out.severity = out.severity and formatAnnouncementTemplate(out.severity, context) or nil
  markAnnouncementCooldown(key, spec)
  return out
end

function configuredEventAnnouncement(kind, context)
  local profile = context and context.profile
  if profile and tostring(profile) ~= "" then
    local profileKey = announcementKey(profile)
    local candidates = {
      "event:" .. tostring(kind or "") .. ":" .. profileKey,
      tostring(kind or "") .. ":" .. profileKey,
    }
    for _, key in ipairs(candidates) do
      local configured = configuredAnnouncement(key, nil, context)
      if configured then
        return configured
      end
    end
  end

  return configuredAnnouncement("event:" .. tostring(kind or ""), kind, context)
end

function applyConfiguredAnnouncement(notification, configured)
  if not (type(notification) == "table" and type(configured) == "table") then
    return notification
  end
  notification.text = configured.text or notification.text
  notification.message = notification.text
  notification.title = configured.title or notification.title
  notification.severity = configured.severity or notification.severity
  notification.voiceLine = configured.voiceLine or notification.voiceLine
  if configured.voiceLines ~= nil then
    notification.voiceLines = configured.voiceLines
  end
  if configured.voiceLineParts ~= nil then
    notification.voiceLineParts = configured.voiceLineParts
  end
  if configured.voiceSequence ~= nil then
    notification.voiceSequence = configured.voiceSequence
  end
  if configured.kind then
    notification.kind = configured.kind
  end
  if configured.announcement ~= nil then
    notification.announcement = configured.announcement and true or false
  else
    notification.announcement = true
  end
  if configured.wav ~= nil then
    notification.wav = configured.wav
  end
  if configured.files ~= nil then
    notification.files = configured.files
  end
  if configured.pcm ~= nil then
    notification.pcm = configured.pcm
  end
  if configured.samples ~= nil then
    notification.samples = configured.samples
  end
  if configured.mix ~= nil then
    notification.mix = configured.mix
  end
  if configured.layers ~= nil then
    notification.layers = configured.layers
  end
  if configured.overlay ~= nil then
    notification.overlay = configured.overlay
  end
  if configured.overlays ~= nil then
    notification.overlays = configured.overlays
  end
  if configured.parts ~= nil then
    notification.parts = configured.parts
  end
  if configured.segments ~= nil then
    notification.segments = configured.segments
  end
  return notification
end

function broadcastActionAnnouncement(action, detail)
  if action == "ANNOUNCEMENT" then
    return
  end
  local context = actionAnnouncementContext(action, detail)
  local configured = configuredAnnouncement("action:" .. tostring(action or ""), action, context)
  if not configured then
    return
  end
  local notification = makeNotification("announcement", configured.title or "Facility Announcement", configured.text, configured.severity or "info", {
    actor = context.actor or context.user or "system",
    action = action,
    detail = context.detail,
    voiceLine = configured.voiceLine,
  })
  applyConfiguredAnnouncement(notification, configured)
  broadcastKioskNotification(notification)
end

function broadcastEventNotification(kind, title, text, severity, extra)
  local context = eventAnnouncementContext(kind, title, text, severity, extra)
  local notification = makeNotification(kind, title, text, severity, extra)
  local configured = configuredEventAnnouncement(kind, context)
  if configured then
    applyConfiguredAnnouncement(notification, configured)
  end
  broadcastKioskNotification(notification)
end

function broadcastLockdownNotification(active, actor, source)
  if active then
    broadcastEventNotification("lockdown", "Lockdown Active", "Lockdown started by " .. tostring(actor or source or "system"), "critical", {
      actor = actor,
      source = source,
    })
  else
    broadcastEventNotification("lockdown_clear", "Lockdown Clear", "Lockdown cleared by " .. tostring(actor or source or "system"), "info", {
      actor = actor,
      source = source,
    })
  end
end

function announcementEnabled()
  return not (config.announcements and config.announcements.enabled == false)
end

function broadcastAnnouncement(text, actor, voiceLine)
  if not announcementEnabled() then
    return false, "announcements disabled"
  end
  if alarmAnnouncementSuppressionActive() then
    return false, "normal announcements suppressed while alarm is active"
  end

  text = tostring(text or "")
  if text == "" then
    return false, "empty announcement"
  end

  local notification = makeNotification("announcement", "Facility Announcement", text, "info", {
    actor = actor or "system",
    voiceLine = voiceLine,
  })
  broadcastKioskNotification(notification)
  audit("ANNOUNCEMENT", {
    actor = actor or "system",
    text = text,
    voiceLine = voiceLine,
  })
  return true
end

function nextConfiguredAnnouncement()
  if alarmAnnouncementSuppressionActive() then
    return nil
  end

  local lines = config.announcements and config.announcements.lines or {}
  if type(lines) ~= "table" or #lines == 0 then
    return nil
  end

  local announcements = config.announcements or {}
  local candidates = {}
  local context = eventAnnouncementContext("announcement", "Facility Announcement", "", "info", {})
  for lineIndex = 1, #lines do
    local line = lines[lineIndex]
    local variant = announcementVariation(line)
    local text = configuredAnnouncementText(line, variant)
    local voiceLine = configuredAnnouncementVoice(line, variant)
    if (not announcements.requireVoiceLine) or configuredAnnouncementHasAudio(line, variant, voiceLine) then
      text = text or firstTextValue(type(variant) == "table" and variant.title or nil, type(line) == "table" and line.title or nil, "Facility announcement")
      table.insert(candidates, {
        index = lineIndex,
        text = formatAnnouncementTemplate(text, context),
        voiceLine = voiceLine,
      })
    end
  end

  if #candidates == 0 then
    return nil
  end
  if #candidates > 1 then
    for index = #candidates, 1, -1 do
      if candidates[index].index == state.announcements.lastAutoLineIndex then
        table.remove(candidates, index)
        break
      end
    end
  end

  local chosen = candidates[math.random(#candidates)]
  state.announcements.index = chosen.index
  state.announcements.lastAutoLineIndex = chosen.index
  return chosen.text, chosen.voiceLine
end

function scheduleAnnouncementTimer()
  local auto = config.announcements and config.announcements.auto or {}
  if auto.enabled then
    scheduleTimer(tonumber(auto.intervalSeconds) or 900, { type = "announcement" })
  end
end

function clampSample(value)
  value = math.floor(value)
  if value > 127 then
    return 127
  end
  if value < -128 then
    return -128
  end
  return value
end

function dspPattern(profile)
  local dsp = profile.dsp or {}
  local patterns = dsp.patterns or {}
  return patterns[profile.name or "security"] or patterns.security
end

function buildDspAlarmBuffer(profile)
  local dsp = profile.dsp or {}
  if dsp.enabled == false then
    return nil
  end

  local pattern = dspPattern(profile)
  if type(pattern) ~= "table" or #pattern == 0 then
    return nil
  end

  local sampleRate = tonumber(dsp.sampleRate) or 48000
  local buffer = {}
  local phase = 0

  for _, tone in ipairs(pattern) do
    local duration = tonumber(tone.duration) or tonumber(dsp.duration) or 0.25
    local samples = math.max(1, math.floor(sampleRate * duration))
    local startFreq = tonumber(tone.freq) or 660
    local sweep = tonumber(tone.sweep) or 0
    local gain = tonumber(tone.gain) or 0.75
    local subGain = tonumber(tone.sub) or 0.18
    local harmonicGain = tonumber(tone.harmonic) or 0.24
    local tremoloRate = tonumber(tone.tremolo) or 0
    local noiseGain = tonumber(tone.noise) or 0
    local detuneGain = tonumber(tone.detune) or 0
    local pulseRate = tonumber(tone.pulse) or 0
    local crush = tonumber(tone.crush) or 0

    for index = 1, samples do
      local progress = index / samples
      local freq = startFreq + sweep * progress
      phase = (phase + (2 * math.pi * freq / sampleRate)) % (2 * math.pi)

      local envelope = 1
      if progress < 0.12 then
        envelope = progress / 0.12
      elseif progress > 0.88 then
        envelope = (1 - progress) / 0.12
      end

      local tremolo = tremoloRate > 0 and (0.72 + 0.28 * math.sin(progress * math.pi * 2 * tremoloRate)) or 1
      local warble = math.sin(progress * math.pi * 16) * 0.18
      local harmonic = math.sin(phase * 2.013) * harmonicGain
      local sub = math.sin(phase * 0.5) * subGain
      local detune = math.sin(phase * 0.973 + progress * math.pi * 7) * detuneGain
      local pulse = pulseRate > 0 and (math.sin(progress * math.pi * 2 * pulseRate) > -0.25 and 1 or 0.32) or 1
      local gritSeed = math.sin((index + startFreq) * 12.9898) * 43758.5453
      local grit = (gritSeed - math.floor(gritSeed) - 0.5) * noiseGain
      local sample = (math.sin(phase) + harmonic + sub + detune + warble + grit) * 88 * gain * envelope * tremolo * pulse
      if crush > 0 then
        local step = math.max(1, crush)
        sample = math.floor(sample / step + 0.5) * step
      end
      buffer[#buffer + 1] = clampSample(sample)
    end
  end

  return buffer
end

function alarmIsWavPath(path)
  return string.sub(string.lower(tostring(path or "")), -4) == ".wav"
end

function alarmAudioConfig(profile)
  local audio = type(profile.audio) == "table" and profile.audio or {}
  local announcements = config.announcements or {}
  local dsp = profile.dsp or {}
  return {
    sampleRate = audio.sampleRate or profile.sampleRate or dsp.sampleRate or 48000,
    maxSamples = audio.maxSamples or profile.maxSamples or dsp.maxSamples or 128000,
    chunkSamples = audio.chunkSamples or profile.chunkSamples or audio.playbackSamples or profile.playbackSamples or 24000,
    loopGapSeconds = audio.loopGapSeconds or profile.loopGapSeconds or 0.05,
    streamGraceSeconds = audio.streamGraceSeconds or profile.streamGraceSeconds or announcements.streamGraceSeconds or 30,
    tailSeconds = audio.tailSeconds or profile.tailSeconds or announcements.tailSeconds or 0.5,
    maxChunksPerFeed = audio.maxChunksPerFeed or profile.maxChunksPerFeed or announcements.maxChunksPerFeed or 4,
    prebufferSeconds = audio.prebufferSeconds or profile.prebufferSeconds or announcements.prebufferSeconds or 2.5,
    refillSeconds = audio.refillSeconds or profile.refillSeconds or announcements.refillSeconds or 0.75,
    syncToleranceSeconds = audio.syncToleranceSeconds or profile.syncToleranceSeconds or 0.08,
    syncSkipLate = audio.syncSkipLate ~= false and profile.syncSkipLate ~= false,
  }
end

function alarmSoundPath(sound)
  if type(sound) == "string" then
    return alarmIsWavPath(sound) and sound or nil
  end
  if type(sound) ~= "table" then
    return nil
  end
  return sound.wav or sound.file or sound.path
end

function appendAlarmSamples(buffer, samples)
  if type(samples) ~= "table" then
    return
  end
  for index = 1, #samples do
    buffer[#buffer + 1] = clampSample(samples[index])
    if index % 4096 == 0 then
      cooperativeAudioYield()
    end
  end
end

function loadAlarmWav(path, audioConfig)
  path = tostring(path or "")
  if path == "" or not (facilityAnnouncements and facilityAnnouncements.loadWav) then
    return nil
  end

  state.alarm.audioCache = state.alarm.audioCache or {}
  local cacheKey = path .. "|" .. tostring(audioConfig and audioConfig.sampleRate or "")
  if state.alarm.audioCache[cacheKey] == false then
    return nil
  end
  if state.alarm.audioCache[cacheKey] then
    return state.alarm.audioCache[cacheKey]
  end

  local ok, samples = pcall(facilityAnnouncements.loadWav, path, audioConfig)
  if ok and type(samples) == "table" and #samples > 0 then
    state.alarm.audioCache[cacheKey] = samples
    return samples
  end
  state.alarm.audioCache[cacheKey] = false
  return nil
end

function buildAlarmSoundBuffer(profile, sound)
  if type(sound) ~= "table" then
    local path = alarmSoundPath(sound)
    if path then
      return loadAlarmWav(path, alarmAudioConfig(profile))
    end
    return nil
  end

  if type(sound.pcm) == "table" then
    local buffer = {}
    appendAlarmSamples(buffer, sound.pcm)
    return buffer
  end

  local audioConfig = alarmAudioConfig(profile)
  local buffer = {}
  if type(sound.files) == "table" then
    for _, path in ipairs(sound.files) do
      appendAlarmSamples(buffer, loadAlarmWav(path, audioConfig))
    end
  else
    appendAlarmSamples(buffer, loadAlarmWav(alarmSoundPath(sound), audioConfig))
  end

  if #buffer > 0 then
    return buffer
  end
  return nil
end

function clearAlarmPreparedAudioCache()
  state.alarm.preparedAudioCache = {}
end

function alarmPreparedAudioCacheEnabled(profile)
  local alarm = config and config.alarm or {}
  local audio = type(profile and profile.audio) == "table" and profile.audio or {}
  if alarm.cacheOnStart == false or alarm.cacheAudio == false or audio.cacheOnStart == false or audio.cacheAudio == false then
    return false
  end
  return true
end

function alarmPreparedAudioCacheKey(profile, soundIndex)
  local audioConfig = alarmAudioConfig(profile or {})
  return tostring(profile and profile.name or state.alarm.profile or "alarm")
    .. "|"
    .. tostring(soundIndex or 1)
    .. "|"
    .. tostring(audioConfig.sampleRate or "")
end

function preparedAlarmSoundBuffer(profile, sound, soundIndex)
  if not alarmPreparedAudioCacheEnabled(profile) then
    local buffer = buildAlarmSoundBuffer(profile, sound)
    if not buffer then
      buffer = buildDspAlarmBuffer(profile)
    end
    return buffer
  end

  state.alarm.preparedAudioCache = state.alarm.preparedAudioCache or {}
  local key = alarmPreparedAudioCacheKey(profile, soundIndex)
  local cached = state.alarm.preparedAudioCache[key]
  if cached ~= nil then
    return cached ~= false and cached or nil
  end

  local buffer = buildAlarmSoundBuffer(profile, sound)
  if not buffer then
    buffer = buildDspAlarmBuffer(profile)
  end
  if type(buffer) == "table" and #buffer > 0 then
    pcall(securityAudio.preparePlaybackPcm, buffer, {
      sampleRate = alarmAudioConfig(profile).sampleRate,
    })
    state.alarm.preparedAudioCache[key] = buffer
    return buffer
  end

  state.alarm.preparedAudioCache[key] = false
  return nil
end

function prepareAlarmSoundCache(profileName)
  local profile = alarmProfile(profileName)
  if not alarmPreparedAudioCacheEnabled(profile) then
    return
  end

  clearAlarmPreparedAudioCache()
  local sounds = profile.sounds or {}
  if #sounds == 0 then
    preparedAlarmSoundBuffer(profile, nil, 1)
    return
  end

  for index, sound in ipairs(sounds) do
    preparedAlarmSoundBuffer(profile, sound, index)
    if index % 2 == 0 then
      sleep(0)
    end
  end
end

function alarmPlaybackChunkSize(profile)
  local audioConfig = alarmAudioConfig(profile)
  local chunkSamples = tonumber(audioConfig.chunkSamples) or 24000
  if chunkSamples <= 0 then
    chunkSamples = 24000
  end
  chunkSamples = math.floor(chunkSamples)
  if chunkSamples < 1024 then
    chunkSamples = 1024
  elseif chunkSamples > 48000 then
    chunkSamples = 48000
  end
  return chunkSamples
end

function alarmPcmDuration(profile, pcm)
  if type(pcm) ~= "table" or #pcm == 0 then
    return 0
  end

  local audioConfig = alarmAudioConfig(profile)
  local sampleRate = tonumber(audioConfig.sampleRate) or 48000
  if sampleRate <= 0 then
    sampleRate = 48000
  end
  return #pcm / sampleRate
end

function alarmLoopGap(profile)
  local audioConfig = alarmAudioConfig(profile)
  local gap = tonumber(audioConfig.loopGapSeconds)
  if gap == nil then
    gap = 0.05
  end
  return math.max(0, gap)
end

function alarmPreloadSeconds(profile)
  local alarm = config and config.alarm or {}
  local audio = type(profile and profile.audio) == "table" and profile.audio or {}
  local seconds = tonumber(audio.preloadSeconds or profile and profile.preloadSeconds or alarm.preloadSeconds)
  if seconds == nil then
    seconds = math.max(0.25, math.min(1.5, (preparedAudioLeadMillis() / 1000) + 0.25))
  end
  if seconds < 0 then
    return 0
  elseif seconds > 5 then
    return 5
  end
  return seconds
end

function alarmCanPreloadNextPulse(profile)
  if alarmHasPendingAudioStream() then
    return false
  end
  local hasActive = false
  for _ in pairs(state.alarm.audioStreams or {}) do
    hasActive = true
    break
  end
  local remaining = (tonumber(state.alarm.audioPlayingUntil) or 0) - os.clock()
  return hasActive and remaining <= alarmPreloadSeconds(profile)
end

function alarmSyncLeadMillis(profile)
  local seconds = tonumber(profile and profile.syncLeadSeconds) or 1.5
  if seconds < 0 then
    seconds = 0
  end
  return math.floor((seconds * 1000) + 0.5)
end

function alarmDelayUntilMillis(targetMillis)
  targetMillis = tonumber(targetMillis)
  if not targetMillis then
    return 0
  end
  return math.max(0, (targetMillis - nowMillis()) / 1000)
end

function alarmWaitingForStart()
  local mode = string.lower(tostring(config and config.mode or "server"))
  if mode ~= "kiosk" and mode ~= "controller" and mode ~= "door" and mode ~= "door_controller" then
    return false
  end
  return state.alarm.active and tonumber(state.alarm.soundStartAt) and nowMillis() < tonumber(state.alarm.soundStartAt)
end

function pruneAlarmAudioStreams()
  state.alarm.audioStreams = state.alarm.audioStreams or {}
  state.alarm.pendingAudioStreams = state.alarm.pendingAudioStreams or {}
  local now = os.clock()
  for name, stream in pairs(state.alarm.audioStreams) do
    local queuedUntil = tonumber(stream.queuedUntil)
    local tailSeconds = tonumber(stream.tailSeconds) or 0.5
    local queueFinished = stream.queueComplete and queuedUntil and now >= queuedUntil + tailSeconds
    local expired = stream.deadline and now > stream.deadline
    if not state.alarm.active or stream.generation ~= state.alarm.audioGeneration or queueFinished or expired then
      state.alarm.audioStreams[name] = nil
    end
  end
  for name, stream in pairs(state.alarm.pendingAudioStreams) do
    local expired = stream.deadline and now > stream.deadline
    if not state.alarm.active or stream.generation ~= state.alarm.audioGeneration or expired then
      state.alarm.pendingAudioStreams[name] = nil
    end
  end
end

function alarmAudioBusy()
  pruneAlarmAudioStreams()
  if (tonumber(state.alarm.audioPlayingUntil) or 0) > os.clock() then
    return true
  end
  for _ in pairs(state.alarm.audioStreams or {}) do
    return true
  end
  for _ in pairs(state.alarm.pendingAudioStreams or {}) do
    return true
  end
  return false
end

function clearAlarmAudioStreams(stopSpeakers)
  state.alarm.audioStreams = {}
  state.alarm.pendingAudioStreams = {}
  state.alarm.audioPlayingUntil = 0
  state.alarm.audioGeneration = (state.alarm.audioGeneration or 0) + 1

  if stopSpeakers then
    for _, entry in ipairs(findSpeakerEntries()) do
      if entry.speaker and entry.speaker.stop then
        pcall(entry.speaker.stop)
      end
    end
  end
end

function streamPrebufferSeconds(stream)
  local seconds = tonumber(stream and stream.prebufferSeconds) or 2.5
  if seconds < 0.25 then
    return 0.25
  end
  if seconds > 8 then
    return 8
  end
  return seconds
end

function streamRefillSeconds(stream)
  local prebufferSeconds = streamPrebufferSeconds(stream)
  local seconds = tonumber(stream and stream.refillSeconds) or math.min(1, math.max(0.25, prebufferSeconds * 0.35))
  if seconds < 0.1 then
    return 0.1
  end
  if seconds > prebufferSeconds then
    return prebufferSeconds
  end
  return seconds
end

function pcmChunk(pcm, firstIndex, lastIndex, clampSamples)
  return securityAudio.pcmChunk(pcm, firstIndex, lastIndex, clampSamples)
end

function preparedAudioConfig()
  local announcements = config and config.announcements or {}
  local audio = type(announcements.audio) == "table" and announcements.audio or {}
  return {
    enabled = announcements.serverPreparedAudio ~= false
      and announcements.remoteAudio ~= false
      and announcements.networkAudio ~= false,
    clientSynthesis = announcements.clientAudioSynthesis == true or announcements.localAudioSynthesis == true,
    chunkSamples = tonumber(audio.networkChunkSamples or announcements.networkChunkSamples or announcements.remoteAudioChunkSamples) or 4096,
    leadSeconds = tonumber(audio.networkLeadSeconds or announcements.networkLeadSeconds or announcements.remoteAudioLeadSeconds) or 1,
    streamTtlSeconds = tonumber(audio.networkStreamTtlSeconds or announcements.networkStreamTtlSeconds) or 45,
    yieldChunks = tonumber(audio.networkYieldChunks or announcements.networkYieldChunks or announcements.remoteAudioYieldChunks) or 4,
    yieldSeconds = tonumber(audio.networkYieldSeconds or announcements.networkYieldSeconds or announcements.remoteAudioYieldSeconds) or 0.03,
  }
end

function preparedAudioEnabled()
  return preparedAudioConfig().enabled
end

function preparedAudioBroadcastEnabled()
  local mode = string.lower(tostring(config and config.mode or "server"))
  local serverMode = mode ~= "kiosk" and mode ~= "controller" and mode ~= "door" and mode ~= "door_controller"
  return serverMode and preparedAudioEnabled() and config and config.rednet and config.rednet.enabled and rednet ~= nil
end

function kioskServerPreparedAudioOnly()
  local mode = string.lower(tostring(config and config.mode or ""))
  if mode ~= "kiosk" and mode ~= "controller" and mode ~= "door" and mode ~= "door_controller" then
    return false
  end
  local audioConfig = preparedAudioConfig()
  return audioConfig.enabled and not audioConfig.clientSynthesis
end

function preparedAudioChunkSamples()
  local chunkSamples = math.floor(tonumber(preparedAudioConfig().chunkSamples) or 4096)
  if chunkSamples < 512 then
    return 512
  end
  local rednetConfig = config and config.rednet or {}
  if secureRednet.enabled(rednetConfig) and not secureRednet.audioPlaintext(rednetConfig) and chunkSamples > 2048 then
    chunkSamples = 2048
  end
  if chunkSamples > 4096 then
    return 4096
  end
  return chunkSamples
end

function preparedAudioLeadMillis()
  local seconds = tonumber(preparedAudioConfig().leadSeconds) or 1
  if seconds < 0 then
    seconds = 0
  elseif seconds > 5 then
    seconds = 5
  end
  return math.floor((seconds * 1000) + 0.5)
end

function preparedAudioYieldChunks()
  local chunks = math.floor(tonumber(preparedAudioConfig().yieldChunks) or 4)
  if chunks < 1 then
    return 1
  elseif chunks > 64 then
    return 64
  end
  return chunks
end

function preparedAudioYieldSeconds()
  local seconds = tonumber(preparedAudioConfig().yieldSeconds) or 0
  if seconds < 0 then
    return 0
  elseif seconds > 0.25 then
    return 0.25
  end
  return seconds
end

function preparedAudioStartMillis(startAtMillis)
  local startAt = tonumber(startAtMillis)
  local minimum = nowMillis() + preparedAudioLeadMillis()
  if not startAt or startAt < minimum then
    startAt = minimum
  end
  return startAt
end

function cooperativeAudioYield()
  if sleep then
    sleep(0)
  end
end

function packPcmSamples(pcm, firstIndex, lastIndex)
  return securityAudio.packPcmSamples(pcm, firstIndex, lastIndex)
end

function appendPackedPcmSamples(buffer, packed, allowYield)
  securityAudio.appendPackedPcmSamples(buffer, packed, allowYield)
end

function alarmHasPendingAudioStream()
  pruneAlarmAudioStreams()
  for _ in pairs(state.alarm.pendingAudioStreams or {}) do
    return true
  end
  return false
end

function promotePendingAlarmStream(speakerName, previousQueuedUntil)
  state.alarm.pendingAudioStreams = state.alarm.pendingAudioStreams or {}
  local pending = state.alarm.pendingAudioStreams[speakerName]
  if not pending then
    return false
  end

  state.alarm.pendingAudioStreams[speakerName] = nil
  if previousQueuedUntil then
    pending.queuedUntil = math.max(tonumber(pending.queuedUntil) or 0, tonumber(previousQueuedUntil) or 0)
  end
  pending.promoted = true
  state.alarm.audioStreams[speakerName] = pending
  return alarmFeedSpeakerStream(speakerName)
end

function appendPcmSampleTable(buffer, samples, allowYield)
  securityAudio.appendPcmSampleTable(buffer, samples, allowYield)
end

function preparedAudioSenderAllowed(sender)
  local mode = string.lower(tostring(config and config.mode or ""))
  if mode ~= "kiosk" and mode ~= "controller" and mode ~= "door" and mode ~= "door_controller" then
    return false
  end
  local serverId = state.kiosk and state.kiosk.serverId or nil
  serverId = serverId or (config and config.rednet and config.rednet.serverId)
  return serverId == nil or tostring(sender) == tostring(serverId)
end

function cleanupRemoteAudioStreams()
  state.remoteAudio = state.remoteAudio or { streams = {} }
  state.remoteAudio.streams = state.remoteAudio.streams or {}
  local ttl = tonumber(preparedAudioConfig().streamTtlSeconds) or 45
  local now = os.clock()
  for id, stream in pairs(state.remoteAudio.streams) do
    if stream.played or (stream.createdAt and now - stream.createdAt > ttl) then
      state.remoteAudio.streams[id] = nil
    end
  end
end

function remoteAudioStream(id)
  state.remoteAudio = state.remoteAudio or { streams = {} }
  state.remoteAudio.streams = state.remoteAudio.streams or {}
  id = tostring(id or "")
  if id == "" then
    return nil
  end
  local stream = state.remoteAudio.streams[id]
  if not stream then
    stream = {
      id = id,
      chunks = {},
      receivedChunks = 0,
      createdAt = os.clock(),
    }
    state.remoteAudio.streams[id] = stream
  end
  return stream
end

function remoteAudioSamples(stream)
  if type(stream) ~= "table" or type(stream.chunks) ~= "table" then
    return nil
  end
  local totalChunks = math.floor(tonumber(stream.totalChunks) or 0)
  if totalChunks <= 0 then
    return nil
  end

  local pcm = {}
  for index = 1, totalChunks do
    local chunk = stream.chunks[index]
    if type(chunk) == "string" then
      appendPackedPcmSamples(pcm, chunk, true)
    elseif type(chunk) == "table" then
      appendPcmSampleTable(pcm, chunk, true)
    else
      return nil
    end
    if index % 4 == 0 then
      cooperativeAudioYield()
    end
  end
  return pcm
end

function remoteAudioKind(stream)
  return tostring(stream and stream.kind or "announcement")
end

function queueRemoteAudioWork()
  state.remoteAudio = state.remoteAudio or { streams = {} }
  if state.remoteAudio.workQueued then
    return
  end
  state.remoteAudio.workQueued = true
  if os and os.queueEvent then
    os.queueEvent("security_audio_work")
  end
end

function queueAudioStreamWork()
  if os and os.queueEvent then
    os.queueEvent("security_audio_work")
  end
end

function appendRemoteAudioReadyChunks(stream, maxChunks)
  if type(stream) ~= "table" or type(stream.chunks) ~= "table" then
    return false
  end
  local totalChunks = math.floor(tonumber(stream.totalChunks) or 0)
  if totalChunks <= 0 then
    return false
  end

  stream.pcm = stream.pcm or {}
  stream.nextAppendChunk = math.max(1, math.floor(tonumber(stream.nextAppendChunk) or 1))

  local appended = false
  local processed = 0
  local limit = math.max(1, math.floor(tonumber(maxChunks) or 4))
  while stream.nextAppendChunk <= totalChunks and processed < limit do
    local chunkIndex = stream.nextAppendChunk
    local chunk = stream.chunks[chunkIndex]
    if chunk == nil then
      break
    end
    if type(chunk) == "string" then
      appendPackedPcmSamples(stream.pcm, chunk, true)
    elseif type(chunk) == "table" then
      appendPcmSampleTable(stream.pcm, chunk, true)
    else
      break
    end
    stream.chunks[chunkIndex] = nil
    stream.nextAppendChunk = chunkIndex + 1
    processed = processed + 1
    appended = true
  end

  stream.appendComplete = stream.nextAppendChunk > totalChunks
  if stream.nextAppendChunk <= totalChunks and stream.chunks[stream.nextAppendChunk] ~= nil then
    queueRemoteAudioWork()
  end
  return appended
end

function alarmRemoteSourceFinished(source, availableSamples)
  if type(source) ~= "table" then
    return true
  end
  if source.appendComplete then
    return true
  end
  local totalSamples = tonumber(source.totalSamples)
  if totalSamples and tonumber(availableSamples) and availableSamples >= totalSamples then
    return true
  end
  return false
end

function alarmStreamSourceFinished(stream)
  if type(stream) ~= "table" then
    return true
  end
  local availableSamples = type(stream.pcm) == "table" and #stream.pcm or 0
  if stream.source then
    return alarmRemoteSourceFinished(stream.source, availableSamples)
  end
  if stream.sourceFinished ~= nil then
    return stream.sourceFinished and true or false
  end
  local expectedSamples = tonumber(stream.expectedSamples)
  if expectedSamples and availableSamples < expectedSamples then
    return false
  end
  return true
end

function remoteAlarmMinStartSamples(source, profile)
  local audioConfig = alarmAudioConfig(profile)
  local sampleRate = tonumber(source and source.sampleRate or audioConfig.sampleRate) or 48000
  if sampleRate <= 0 then
    sampleRate = 48000
  end
  local minimum = math.max(alarmPlaybackChunkSize(profile), math.floor((sampleRate * 0.25) + 0.5))
  local totalSamples = tonumber(source and source.totalSamples)
  if totalSamples and totalSamples > 0 then
    minimum = math.min(minimum, totalSamples)
  end
  return math.max(1, minimum)
end

function updateRemoteAlarmSpeakerStreams(source)
  if type(source) ~= "table" then
    return
  end
  local function update(streams)
    for _, speakerStream in pairs(streams or {}) do
      if speakerStream.source == source then
        speakerStream.sourceFinished = alarmRemoteSourceFinished(source, type(speakerStream.pcm) == "table" and #speakerStream.pcm or 0)
        speakerStream.expectedSamples = tonumber(source.totalSamples) or speakerStream.expectedSamples
      end
    end
  end
  update(state.alarm.audioStreams)
  update(state.alarm.pendingAudioStreams)
end

function startPreparedAlarmAudioPlayback(stream)
  if type(stream) ~= "table" or stream.played then
    return false
  end

  appendRemoteAudioReadyChunks(stream, 3)
  if not (type(stream.pcm) == "table" and #stream.pcm > 0) then
    return false
  end

  local startAtMillis = stream.queueAfterCurrent and nil or serverMillisToLocalMillis(stream.startAtMillis)
  local volume = tonumber(stream.volume) or 1

  if not state.alarm.active then
    state.alarm.active = true
    state.alarm.profile = stream.profile or state.alarm.profile
    state.alarm.sinceMillis = nowMillis()
    state.alarm.soundStartAt = startAtMillis or nowMillis()
    state.alarm.soundIndex = 1
  elseif stream.profile and state.alarm.profile ~= stream.profile then
    state.alarm.profile = stream.profile
  end

  if not stream.playbackStarted then
    if stream.clearExisting ~= false and not stream.queueAfterCurrent then
      clearAlarmAudioStreams(not announcementAudioBusy())
    end
    local profile = alarmProfile(stream.profile or state.alarm.profile)
    local played = false
    for _, entry in ipairs(findSpeakerEntries()) do
      if startAlarmAudioStream(profile, entry.name, entry.speaker, stream.pcm, volume, {
        startAtMillis = startAtMillis,
        replaceExisting = stream.clearExisting ~= false,
        queueAfterCurrent = stream.queueAfterCurrent and true or false,
        source = stream,
        sourceFinished = alarmRemoteSourceFinished(stream, #stream.pcm),
        expectedSamples = tonumber(stream.totalSamples),
        sampleRate = tonumber(stream.sampleRate),
        aukitPrepared = true,
        minStartSamples = remoteAlarmMinStartSamples(stream, profile),
        syncSkipLate = stream.appendComplete and nil or false,
      }) then
        played = true
      end
    end
    stream.playbackStarted = played
  else
    updateRemoteAlarmSpeakerStreams(stream)
    feedAlarmAudioStreams()
  end

  if stream.finished and stream.appendComplete and stream.playbackStarted then
    stream.played = true
  end
  return stream.playbackStarted and true or false
end

function startPreparedAudioPlayback(stream)
  if type(stream) ~= "table" or stream.played then
    return false
  end

  if remoteAudioKind(stream) == "alarm" then
    return startPreparedAlarmAudioPlayback(stream)
  end

  if not stream.finished or (tonumber(stream.receivedChunks) or 0) < (tonumber(stream.totalChunks) or 0) then
    return false
  end

  local pcm = remoteAudioSamples(stream)
  if not (type(pcm) == "table" and #pcm > 0) then
    return false
  end

  local startAtMillis = stream.queueAfterCurrent and nil or serverMillisToLocalMillis(stream.startAtMillis)
  local volume = tonumber(stream.volume) or 1
  local played = false

  local allowDuringAlarm = stream.allowDuringAlarm and true or false
  if state.alarm.active and not allowDuringAlarm then
    stream.played = true
    return false
  end
  if stream.clearExisting ~= false then
    clearAnnouncementAudioStreams(true)
  end
  local generation = state.announcements.audioGeneration or 0
  for _, entry in ipairs(findSpeakerEntries()) do
    if startAnnouncementAudioStream(entry.name, entry.speaker, pcm, volume, {
      allowExisting = true,
      allowDuringAlarm = allowDuringAlarm,
      generation = generation,
      startAtMillis = startAtMillis,
      aukitPrepared = true,
    }) then
      played = true
    end
  end

  stream.played = true
  return played
end

function handlePreparedAudioMessage(message, sender)
  if type(message) ~= "table" or not preparedAudioSenderAllowed(sender) then
    return false
  end
  updateKioskClockOffset(message, sender)
  cleanupRemoteAudioStreams()

  local stream = remoteAudioStream(message.streamId or message.id)
  if not stream then
    return false
  end

  local action = tostring(message.action or message.phase or "")
  if action == "start" then
    stream.kind = message.kind or stream.kind or "announcement"
    stream.profile = message.profile or stream.profile
    stream.volume = message.volume or stream.volume
    stream.sampleRate = message.sampleRate or stream.sampleRate
    stream.startAtMillis = message.startAtMillis or stream.startAtMillis
    stream.totalSamples = tonumber(message.totalSamples) or stream.totalSamples
    stream.totalChunks = tonumber(message.totalChunks) or stream.totalChunks
    stream.allowDuringAlarm = message.allowDuringAlarm and true or false
    stream.clearExisting = message.clearExisting ~= false
    stream.queueAfterCurrent = message.queueAfterCurrent and true or false
    stream.finished = false
    queueRemoteAudioWork()
    return true
  elseif action == "chunk" then
    local index = math.floor(tonumber(message.index or message.chunkIndex) or 0)
    if index > 0 and (type(message.samples) == "string" or type(message.samples) == "table") then
      if stream.chunks[index] == nil then
        stream.receivedChunks = (tonumber(stream.receivedChunks) or 0) + 1
      end
      stream.chunks[index] = message.samples
      if message.totalChunks then
        stream.totalChunks = tonumber(message.totalChunks) or stream.totalChunks
      end
      if message.startAtMillis and not stream.finished then
        stream.startAtMillis = message.startAtMillis
      end
      queueRemoteAudioWork()
      return true
    end
  elseif action == "finish" or action == "end" then
    stream.kind = message.kind or stream.kind or "announcement"
    stream.profile = message.profile or stream.profile
    stream.volume = message.volume or stream.volume
    stream.sampleRate = message.sampleRate or stream.sampleRate
    stream.totalSamples = tonumber(message.totalSamples) or stream.totalSamples
    stream.queueAfterCurrent = message.queueAfterCurrent and true or false
    stream.finished = true
    stream.totalChunks = tonumber(message.totalChunks) or stream.totalChunks
    stream.startAtMillis = message.startAtMillis or stream.startAtMillis
    if message.allowDuringAlarm ~= nil then
      stream.allowDuringAlarm = message.allowDuringAlarm and true or false
    end
    if message.clearExisting ~= nil then
      stream.clearExisting = message.clearExisting ~= false
    end
    queueRemoteAudioWork()
    return true
  elseif action == "stop" then
    if message.kind == "alarm" then
      clearAlarmAudioStreams(not announcementAudioBusy())
    else
      clearAnnouncementAudioStreams(true)
    end
    state.remoteAudio.streams[tostring(message.streamId or message.id or "")] = nil
    return true
  end

  return false
end

function processRemoteAudioStreams()
  state.remoteAudio = state.remoteAudio or { streams = {} }
  state.remoteAudio.workQueued = false
  cleanupRemoteAudioStreams()

  local moreWork = false
  for _, stream in pairs(state.remoteAudio.streams or {}) do
    if remoteAudioKind(stream) == "alarm" then
      appendRemoteAudioReadyChunks(stream, 3)
      startPreparedAlarmAudioPlayback(stream)
      updateRemoteAlarmSpeakerStreams(stream)
      if not stream.appendComplete then
        local nextIndex = math.max(1, math.floor(tonumber(stream.nextAppendChunk) or 1))
        if stream.chunks and stream.chunks[nextIndex] ~= nil then
          moreWork = true
        end
      end
    elseif stream.finished and not stream.played then
      startPreparedAudioPlayback(stream)
    end
  end

  if moreWork then
    queueRemoteAudioWork()
  end
end

function broadcastPreparedAudio(kind, pcm, options)
  options = options or {}
  if not (preparedAudioBroadcastEnabled() and type(pcm) == "table" and #pcm > 0) then
    return false, options.startAtMillis
  end

  local sampleRate = tonumber(options.sampleRate) or 48000
  local preparedPcm, _, preparedRate = securityAudio.preparePlaybackPcm(pcm, {
    sampleRate = sampleRate,
  })
  if type(preparedPcm) == "table" and #preparedPcm > 0 then
    pcm = preparedPcm
    sampleRate = tonumber(preparedRate) or sampleRate
  end

  openRednet()
  local chunkSamples = preparedAudioChunkSamples()
  local yieldChunks = preparedAudioYieldChunks()
  local yieldSeconds = preparedAudioYieldSeconds()
  local totalChunks = math.ceil(#pcm / chunkSamples)
  local streamId = options.streamId or makeId("audio")
  local queueAfterCurrent = options.queueAfterCurrent and true or false
  local startAtMillis = queueAfterCurrent and nil or preparedAudioStartMillis(options.startAtMillis)
  local base = {
    op = "audio_stream",
    streamId = streamId,
    kind = kind or "announcement",
    profile = options.profile,
    sampleRate = sampleRate,
    volume = tonumber(options.volume) or 1,
    startAtMillis = startAtMillis,
    totalSamples = #pcm,
    totalChunks = totalChunks,
    allowDuringAlarm = options.allowDuringAlarm and true or false,
    clearExisting = options.clearExisting ~= false,
    queueAfterCurrent = queueAfterCurrent,
  }

  local sentAll = true
  local function sendPreparedAudioMessage(message)
    local ok, sent = pcall(broadcastRednet, message)
    if not ok or sent == false then
      sentAll = false
    end
  end

  local startMessage = shallowCopy(base)
  startMessage.action = "start"
  sendPreparedAudioMessage(startMessage)

  for chunkIndex = 1, totalChunks do
    local firstIndex = ((chunkIndex - 1) * chunkSamples) + 1
    local lastIndex = math.min(#pcm, firstIndex + chunkSamples - 1)
    sendPreparedAudioMessage({
      op = "audio_stream",
      action = "chunk",
      streamId = streamId,
      index = chunkIndex,
      totalChunks = totalChunks,
      samples = packPcmSamples(pcm, firstIndex, lastIndex),
      sampleEncoding = "s8",
      startAtMillis = startAtMillis,
      queueAfterCurrent = queueAfterCurrent,
    })
    if chunkIndex % yieldChunks == 0 then
      sleep(yieldSeconds)
    end
  end

  if not queueAfterCurrent then
    startAtMillis = preparedAudioStartMillis(startAtMillis)
  end
  local finishMessage = shallowCopy(base)
  finishMessage.action = "finish"
  finishMessage.startAtMillis = startAtMillis
  sendPreparedAudioMessage(finishMessage)
  return sentAll, startAtMillis
end

function alarmFeedSpeakerStream(speakerName)
  local stream = state.alarm.audioStreams and state.alarm.audioStreams[speakerName]
  if not stream then
    return false
  end
  if not state.alarm.active or stream.generation ~= state.alarm.audioGeneration then
    state.alarm.audioStreams[speakerName] = nil
    return false
  end
  if not securityAudio.canPlayAudio(stream.speaker) then
    state.alarm.audioStreams[speakerName] = nil
    return false
  end

  local startAtMillis = tonumber(stream.startAtMillis)
  if startAtMillis and nowMillis() < startAtMillis then
    stream.deadline = math.max(tonumber(stream.deadline) or 0, os.clock() + alarmDelayUntilMillis(startAtMillis) + (tonumber(stream.graceSeconds) or 30))
    return true
  end

  if not stream.started and not alarmStreamSourceFinished(stream) then
    local minimum = math.floor(tonumber(stream.minStartSamples) or 0)
    local availableSamples = type(stream.pcm) == "table" and #stream.pcm or 0
    if minimum > 0 and availableSamples < minimum then
      local graceSeconds = tonumber(stream.graceSeconds) or 30
      stream.deadline = math.max(tonumber(stream.deadline) or 0, os.clock() + graceSeconds)
      return true
    end
  end

  if startAtMillis and not stream.started then
    local lateSeconds = (nowMillis() - startAtMillis) / 1000
    local toleranceSeconds = tonumber(stream.syncToleranceSeconds) or 0.08
    if lateSeconds > math.max(0, toleranceSeconds) and stream.syncSkipLate ~= false and alarmStreamSourceFinished(stream) then
      local sampleRate = math.max(1, tonumber(stream.sampleRate) or 48000)
      local trimmed = trimPcmStart(stream.pcm, math.floor((lateSeconds * sampleRate) + 0.5))
      if not (type(trimmed) == "table" and #trimmed > 0) then
        state.alarm.audioStreams[speakerName] = nil
        return false
      end
      stream.pcm = trimmed
      stream.nextIndex = 1
    end
    stream.started = true
  end

  if stream.queueComplete then
    local queuedUntil = tonumber(stream.queuedUntil) or os.clock()
    if state.alarm.pendingAudioStreams and state.alarm.pendingAudioStreams[speakerName] then
      state.alarm.audioStreams[speakerName] = nil
      return promotePendingAlarmStream(speakerName, queuedUntil)
    end
    if os.clock() >= queuedUntil + (tonumber(stream.tailSeconds) or 0.5) then
      state.alarm.audioStreams[speakerName] = nil
      return false
    end
    return true
  end

  local fedChunks = 0
  local maxChunks = math.max(1, tonumber(stream.maxChunksPerFeed) or 2)
  local targetQueuedUntil = os.clock() + streamPrebufferSeconds(stream)
  local availableSamples = type(stream.pcm) == "table" and #stream.pcm or 0
  if stream.nextIndex > availableSamples then
    if not alarmStreamSourceFinished(stream) then
      local graceSeconds = tonumber(stream.graceSeconds) or 30
      stream.deadline = math.max(tonumber(stream.deadline) or 0, os.clock() + graceSeconds)
      return true
    end
  end

  while stream.nextIndex <= availableSamples and fedChunks < maxChunks do
    if fedChunks > 0 and stream.queuedUntil and stream.queuedUntil >= targetQueuedUntil then
      break
    end

    local last = math.min(availableSamples, stream.nextIndex + stream.chunkSamples - 1)
    stream.lastAttemptAt = os.clock()
    local ok, accepted, queuedSamples, playbackRate = securityAudio.playPcmRange(stream.speaker, stream.pcm, stream.nextIndex, last, stream.volume, {
      clampSamples = stream.clampSamples,
      sampleRate = stream.sampleRate,
      aukitPrepared = stream.aukitPrepared == true,
    })
    if not ok then
      state.alarm.audioStreams[speakerName] = nil
      return false
    end
    if accepted == false then
      local graceSeconds = tonumber(stream.graceSeconds) or 30
      if stream.queuedUntil then
        stream.deadline = math.max(tonumber(stream.deadline) or 0, stream.queuedUntil + graceSeconds)
      else
        stream.deadline = math.max(tonumber(stream.deadline) or 0, os.clock() + graceSeconds)
      end
      return true
    end

    local now = os.clock()
    local sampleRate = math.max(1, tonumber(playbackRate or stream.sampleRate) or 48000)
    local base = math.max(tonumber(stream.queuedUntil) or now, now)
    stream.queuedUntil = base + ((queuedSamples or 0) / sampleRate)
    stream.acceptedSamples = (tonumber(stream.acceptedSamples) or 0) + (queuedSamples or 0)
    stream.startedPlaybackAt = stream.startedPlaybackAt or now
    stream.nextIndex = last + 1
    stream.lastQueuedAt = now
    stream.deadline = stream.queuedUntil + (tonumber(stream.graceSeconds) or 30)
    state.alarm.audioPlayingUntil = math.max(tonumber(state.alarm.audioPlayingUntil) or 0, stream.queuedUntil)
    fedChunks = fedChunks + 1
    availableSamples = type(stream.pcm) == "table" and #stream.pcm or availableSamples
  end

  if stream.nextIndex > (type(stream.pcm) == "table" and #stream.pcm or 0) then
    if not alarmStreamSourceFinished(stream) then
      local graceSeconds = tonumber(stream.graceSeconds) or 30
      stream.deadline = math.max(tonumber(stream.deadline) or 0, os.clock() + graceSeconds)
      return true
    end
    stream.queueComplete = true
    stream.deadline = math.max(tonumber(stream.deadline) or 0, (tonumber(stream.queuedUntil) or os.clock()) + (tonumber(stream.graceSeconds) or 30))
    if state.alarm.pendingAudioStreams and state.alarm.pendingAudioStreams[speakerName] then
      local queuedUntil = tonumber(stream.queuedUntil) or os.clock()
      state.alarm.audioStreams[speakerName] = nil
      return promotePendingAlarmStream(speakerName, queuedUntil)
    end
  end
  return true
end

function feedAlarmAudioStreams()
  local names = {}
  for name in pairs(state.alarm.audioStreams or {}) do
    table.insert(names, name)
  end
  for _, name in ipairs(names) do
    alarmFeedSpeakerStream(name)
  end
end

function handleAlarmSpeakerAudioEmpty(speakerName)
  if type(speakerName) ~= "string" then
    return false
  end
  return alarmFeedSpeakerStream(speakerName)
end

function startAlarmAudioStream(profile, speakerName, speaker, pcm, volume, options)
  options = options or {}
  if not (securityAudio.canPlayAudio(speaker) and type(pcm) == "table" and #pcm > 0) then
    return false
  end

  speakerName = tostring(speakerName or "")
  local audioConfig = alarmAudioConfig(profile)
  local sampleRate = tonumber(options.sampleRate or audioConfig.sampleRate) or 48000
  if sampleRate <= 0 then
    sampleRate = 48000
  end
  if options.aukitPrepared ~= true and not options.source then
    local preparedPcm, _, preparedRate = securityAudio.preparePlaybackPcm(pcm, {
      sampleRate = sampleRate,
    })
    if type(preparedPcm) == "table" and #preparedPcm > 0 then
      pcm = preparedPcm
      sampleRate = tonumber(preparedRate) or sampleRate
      options.aukitPrepared = true
    end
  end
  local chunkSamples = alarmPlaybackChunkSize(profile)
  local duration = #pcm / sampleRate
  local graceSeconds = tonumber(audioConfig.streamGraceSeconds) or 30

  if speakerName == "" then
    local last = math.min(#pcm, chunkSamples)
    local ok, accepted, queuedSamples, playbackRate = securityAudio.playPcmRange(speaker, pcm, 1, last, volume, {
      sampleRate = sampleRate,
      aukitPrepared = options.aukitPrepared == true,
    })
    if ok and accepted ~= false then
      state.alarm.audioPlayingUntil = math.max(tonumber(state.alarm.audioPlayingUntil) or 0, os.clock() + ((queuedSamples or last) / math.max(1, tonumber(playbackRate or sampleRate) or 48000)))
    end
    return ok and accepted ~= false
  end

  state.alarm.audioStreams = state.alarm.audioStreams or {}
  state.alarm.pendingAudioStreams = state.alarm.pendingAudioStreams or {}
  local stream = {
    name = speakerName,
    speaker = speaker,
    pcm = pcm,
    volume = volume,
    nextIndex = 1,
    chunkSamples = chunkSamples,
    sampleRate = sampleRate,
    generation = state.alarm.audioGeneration or 0,
    deadline = os.clock() + duration + graceSeconds,
    graceSeconds = graceSeconds,
    tailSeconds = tonumber(audioConfig.tailSeconds) or 0.5,
    maxChunksPerFeed = tonumber(audioConfig.maxChunksPerFeed) or 4,
    prebufferSeconds = tonumber(audioConfig.prebufferSeconds) or 2.5,
    refillSeconds = tonumber(audioConfig.refillSeconds) or 0.75,
    syncToleranceSeconds = tonumber(options.syncToleranceSeconds or audioConfig.syncToleranceSeconds) or 0.08,
    syncSkipLate = options.syncSkipLate ~= nil and (options.syncSkipLate and true or false) or audioConfig.syncSkipLate ~= false,
    startAtMillis = options.queueAfterCurrent and nil or options.startAtMillis,
    clampSamples = false,
    source = options.source,
    sourceFinished = options.sourceFinished ~= false,
    expectedSamples = tonumber(options.expectedSamples),
    minStartSamples = tonumber(options.minStartSamples),
    aukitPrepared = options.aukitPrepared == true,
  }

  local existing = state.alarm.audioStreams[speakerName]
  if existing and options.replaceExisting == false then
    state.alarm.pendingAudioStreams[speakerName] = stream
    queueAudioStreamWork()
    alarmFeedSpeakerStream(speakerName)
    return true
  end

  state.alarm.audioStreams[speakerName] = stream
  queueAudioStreamWork()

  local queued = alarmFeedSpeakerStream(speakerName)
  if not stream.startAtMillis and not stream.queueComplete and (tonumber(stream.acceptedSamples) or 0) <= 0 then
    state.alarm.audioStreams[speakerName] = nil
    return false
  end
  return queued or state.alarm.audioStreams[speakerName] ~= nil
end

function playAlarmBuffer(profile, speaker, pcm, volume, speakerName, options)
  return startAlarmAudioStream(profile, speakerName, speaker, pcm, volume, options)
end

function playAlarmAudioSound(profile, sound, speaker, speakerName)
  local buffer = buildAlarmSoundBuffer(profile, sound)
  if not buffer then
    return false
  end

  local dsp = profile.dsp or {}
  local volume = type(sound) == "table" and sound.volume or nil
  return playAlarmBuffer(profile, speaker, buffer, tonumber(volume) or tonumber(profile.volume) or tonumber(dsp.volume) or 1, speakerName)
end

function announcementAudioConfig()
  local announcements = config.announcements or {}
  local audio = type(announcements.audio) == "table" and announcements.audio or {}
  return {
    sampleRate = audio.sampleRate or announcements.sampleRate or 48000,
    chunkSamples = audio.chunkSamples or announcements.chunkSamples or audio.playbackSamples or announcements.playbackSamples or 24000,
    volume = announcements.volume or audio.volume or 1,
    streamGraceSeconds = audio.streamGraceSeconds or announcements.streamGraceSeconds or 30,
    watchdogSeconds = audio.watchdogSeconds or announcements.watchdogSeconds or 0.1,
    idleWatchdogSeconds = audio.idleWatchdogSeconds or announcements.idleWatchdogSeconds or 1,
    tailSeconds = audio.tailSeconds or announcements.tailSeconds or 0.5,
    maxChunksPerFeed = audio.maxChunksPerFeed or announcements.maxChunksPerFeed or 8,
    prebufferSeconds = audio.prebufferSeconds or announcements.prebufferSeconds or 2.5,
    refillSeconds = audio.refillSeconds or announcements.refillSeconds or 0.75,
    syncLeadSeconds = audio.syncLeadSeconds or announcements.syncLeadSeconds or 1.5,
    syncToleranceSeconds = audio.syncToleranceSeconds or announcements.syncToleranceSeconds or 0.08,
    syncSkipLate = audio.syncSkipLate ~= false and announcements.syncSkipLate ~= false,
  }
end

function scheduledAnnouncementStartMillis(announcement)
  return notificationScheduledStartMillis(announcement)
end

function trimPcmStart(pcm, sampleOffset)
  sampleOffset = math.floor(tonumber(sampleOffset) or 0)
  if sampleOffset <= 0 then
    return pcm
  end
  if type(pcm) ~= "table" or sampleOffset >= #pcm then
    return nil
  end

  local trimmed = {}
  for index = sampleOffset + 1, #pcm do
    trimmed[#trimmed + 1] = pcm[index]
  end
  return trimmed
end

function alignAnnouncementPcmToSchedule(pcm, startAt, audioConfig)
  startAt = tonumber(startAt)
  if not startAt then
    return pcm
  end

  local delaySeconds = alarmDelayUntilMillis(startAt)
  if delaySeconds > 0 then
    return pcm
  end

  local toleranceSeconds = tonumber(audioConfig and audioConfig.syncToleranceSeconds) or 0.08
  local lateSeconds = (nowMillis() - startAt) / 1000
  if lateSeconds <= math.max(0, toleranceSeconds) then
    return pcm
  end
  if audioConfig and audioConfig.syncSkipLate == false then
    return pcm
  end

  local sampleRate = tonumber(audioConfig and audioConfig.sampleRate) or 48000
  if sampleRate <= 0 then
    sampleRate = 48000
  end
  return trimPcmStart(pcm, math.floor((lateSeconds * sampleRate) + 0.5))
end

function alignAlarmPcmToSchedule(profile, pcm)
  local startAt = tonumber(state.alarm and state.alarm.soundStartAt)
  if not startAt then
    return pcm
  end

  local delaySeconds = alarmDelayUntilMillis(startAt)
  if delaySeconds > 0 then
    sleep(delaySeconds)
    return pcm
  end

  local audioConfig = alarmAudioConfig(profile)
  if audioConfig.syncSkipLate == false then
    return pcm
  end

  local lateSeconds = (nowMillis() - startAt) / 1000
  local toleranceSeconds = tonumber(audioConfig.syncToleranceSeconds) or 0.08
  if lateSeconds <= math.max(0, toleranceSeconds) then
    return pcm
  end

  local sampleRate = tonumber(audioConfig.sampleRate) or 48000
  if sampleRate <= 0 then
    sampleRate = 48000
  end
  local durationSeconds = type(pcm) == "table" and #pcm / sampleRate or 0
  if durationSeconds <= 0 then
    return pcm
  end

  local loopSeconds = durationSeconds + alarmLoopGap(profile)
  if loopSeconds <= 0 then
    return pcm
  end
  local phaseSeconds = lateSeconds % loopSeconds
  if phaseSeconds >= durationSeconds then
    sleep(math.max(0, loopSeconds - phaseSeconds))
    return pcm
  end
  local sampleOffset = math.floor((phaseSeconds * sampleRate) + 0.5)
  if type(pcm) == "table" and sampleOffset >= #pcm then
    sleep(math.max(0, durationSeconds - phaseSeconds))
    return pcm
  end
  return trimPcmStart(pcm, sampleOffset)
end

function announcementPlaybackChunkSize()
  local audioConfig = announcementAudioConfig()
  local chunkSamples = tonumber(audioConfig.chunkSamples) or 128000
  if chunkSamples <= 0 then
    chunkSamples = 128000
  end
  chunkSamples = math.floor(chunkSamples)
  if chunkSamples < 1024 then
    return 1024
  end
  if chunkSamples > 128000 then
    return 128000
  end
  return chunkSamples
end

function clearAnnouncementAudioStreams(stopSpeakers)
  if stopSpeakers and type(state.announcements.audioStreams) == "table" then
    for _, stream in pairs(state.announcements.audioStreams) do
      if stream.speaker and stream.speaker.stop then
        pcall(stream.speaker.stop)
      end
    end
  end
  state.announcements.audioStreams = {}
  state.announcements.audioPlayingUntil = 0
  state.announcements.audioGeneration = (state.announcements.audioGeneration or 0) + 1
end

function pruneAnnouncementAudioStreams()
  local now = os.clock()
  for name, stream in pairs(state.announcements.audioStreams or {}) do
    local queuedUntil = tonumber(stream.queuedUntil)
    local tailSeconds = tonumber(stream.tailSeconds) or 0.5
    local queueFinished = stream.queueComplete and queuedUntil and now >= queuedUntil + tailSeconds
    local expired = stream.deadline and now > stream.deadline
    if stream.generation ~= state.announcements.audioGeneration or queueFinished or expired then
      state.announcements.audioStreams[name] = nil
    end
  end
end

function announcementAudioBusy()
  pruneAnnouncementAudioStreams()
  if (tonumber(state.announcements.audioPlayingUntil) or 0) > os.clock() then
    return true
  end
  for _ in pairs(state.announcements.audioStreams or {}) do
    return true
  end
  return false
end

function announcementFeedSpeakerStream(speakerName)
  local stream = state.announcements.audioStreams and state.announcements.audioStreams[speakerName]
  if not stream then
    return false
  end
  if state.alarm.active and not stream.allowDuringAlarm then
    clearAnnouncementAudioStreams(true)
    return false
  end
  if stream.generation ~= state.announcements.audioGeneration then
    state.announcements.audioStreams[speakerName] = nil
    return false
  end
  if not securityAudio.canPlayAudio(stream.speaker) then
    state.announcements.audioStreams[speakerName] = nil
    return false
  end

  local startAtMillis = tonumber(stream.startAtMillis)
  if startAtMillis and nowMillis() < startAtMillis then
    stream.deadline = math.max(tonumber(stream.deadline) or 0, os.clock() + alarmDelayUntilMillis(startAtMillis) + (tonumber(stream.graceSeconds) or 30))
    return true
  end

  if startAtMillis and not stream.started then
    local lateSeconds = (nowMillis() - startAtMillis) / 1000
    local toleranceSeconds = tonumber(stream.syncToleranceSeconds) or 0.08
    if lateSeconds > math.max(0, toleranceSeconds) and stream.syncSkipLate ~= false then
      local sampleRate = math.max(1, tonumber(stream.sampleRate) or 48000)
      local trimmed = trimPcmStart(stream.pcm, math.floor((lateSeconds * sampleRate) + 0.5))
      if not (type(trimmed) == "table" and #trimmed > 0) then
        state.announcements.audioStreams[speakerName] = nil
        return false
      end
      stream.pcm = trimmed
      stream.nextIndex = 1
    end
    stream.startAtMillis = nil
  end

  if stream.queueComplete then
    local queuedUntil = tonumber(stream.queuedUntil) or os.clock()
    if os.clock() >= queuedUntil + (tonumber(stream.tailSeconds) or 0.5) then
      state.announcements.audioStreams[speakerName] = nil
      return false
    end
    return true
  end

  local fedChunks = 0
  local maxChunks = math.max(1, tonumber(stream.maxChunksPerFeed) or 2)
  local targetQueuedUntil = os.clock() + streamPrebufferSeconds(stream)
  while stream.nextIndex <= #stream.pcm and fedChunks < maxChunks do
    if fedChunks > 0 and stream.queuedUntil and stream.queuedUntil >= targetQueuedUntil then
      break
    end

    local last = math.min(#stream.pcm, stream.nextIndex + stream.chunkSamples - 1)
    stream.lastAttemptAt = os.clock()
    local ok, accepted, queuedSamples, playbackRate = securityAudio.playPcmRange(stream.speaker, stream.pcm, stream.nextIndex, last, stream.volume, {
      clampSamples = stream.clampSamples,
      sampleRate = stream.sampleRate,
      aukitPrepared = stream.aukitPrepared == true,
    })
    if not ok then
      state.announcements.audioStreams[speakerName] = nil
      return false
    end
    if accepted == false then
      local graceSeconds = tonumber(stream.graceSeconds) or 30
      if stream.queuedUntil then
        stream.deadline = math.max(tonumber(stream.deadline) or 0, stream.queuedUntil + graceSeconds)
      else
        stream.deadline = math.max(tonumber(stream.deadline) or 0, os.clock() + graceSeconds)
      end
      return true
    end

    local now = os.clock()
    local sampleRate = math.max(1, tonumber(playbackRate or stream.sampleRate) or 48000)
    local base = math.max(tonumber(stream.queuedUntil) or now, now)
    stream.queuedUntil = base + ((queuedSamples or 0) / sampleRate)
    stream.acceptedSamples = (tonumber(stream.acceptedSamples) or 0) + (queuedSamples or 0)
    stream.started = true
    stream.nextIndex = last + 1
    stream.lastQueuedAt = now
    stream.deadline = stream.queuedUntil + (tonumber(stream.graceSeconds) or 30)
    state.announcements.audioPlayingUntil = math.max(tonumber(state.announcements.audioPlayingUntil) or 0, stream.queuedUntil)
    fedChunks = fedChunks + 1
  end

  if stream.nextIndex > #stream.pcm then
    stream.queueComplete = true
    stream.deadline = math.max(tonumber(stream.deadline) or 0, (tonumber(stream.queuedUntil) or os.clock()) + (tonumber(stream.graceSeconds) or 30))
  end
  return true
end

function feedAnnouncementAudioStreams()
  local names = {}
  for name in pairs(state.announcements.audioStreams or {}) do
    table.insert(names, name)
  end
  for _, name in ipairs(names) do
    announcementFeedSpeakerStream(name)
  end
end

function nextAudioStreamFeedDelay()
  local now = os.clock()
  local nextDelay = nil

  local function consider(streams)
    for _, stream in pairs(streams or {}) do
      if not stream.queueComplete then
        local delay = 0.1
        local startAtMillis = tonumber(stream.startAtMillis)
        if startAtMillis and nowMillis() < startAtMillis then
          delay = alarmDelayUntilMillis(startAtMillis)
        elseif stream.queuedUntil then
          delay = (tonumber(stream.queuedUntil) - now) - streamRefillSeconds(stream)
        else
          delay = 0.1
        end
        if delay < 0.05 then
          delay = 0.05
        end
        if not nextDelay or delay < nextDelay then
          nextDelay = delay
        end
      end
    end
  end

  consider(state.alarm.audioStreams)
  consider(state.announcements.audioStreams)
  if nextDelay and nextDelay > 1 then
    nextDelay = 1
  end
  return nextDelay
end

function audioWatchdogDelaySeconds(audioConfig)
  audioConfig = audioConfig or announcementAudioConfig()
  local alarmBusy = alarmAudioBusy()
  local announcementBusy = announcementAudioBusy()
  local active = state.alarm.active or alarmBusy or announcementBusy
  local streamDelay = nextAudioStreamFeedDelay()
  if streamDelay then
    return streamDelay
  end
  if state.announcements.queue and #state.announcements.queue > 0 then
    return 0.1
  end
  local seconds = active and tonumber(audioConfig.watchdogSeconds) or tonumber(audioConfig.idleWatchdogSeconds)
  seconds = seconds or (active and 0.1 or 1)
  if active then
    if seconds < 0.05 then
      seconds = 0.05
    elseif seconds > 1 then
      seconds = 1
    end
  else
    if seconds < 0.25 then
      seconds = 0.25
    elseif seconds > 5 then
      seconds = 5
    end
  end
  return seconds
end

function handleAnnouncementSpeakerAudioEmpty(speakerName)
  if type(speakerName) ~= "string" then
    return false
  end
  return announcementFeedSpeakerStream(speakerName)
end

function startAnnouncementAudioStream(speakerName, speaker, pcm, volume, options)
  options = options or {}
  if ((state.alarm.active or alarmAudioBusy()) and not options.allowDuringAlarm) or ((not options.allowExisting) and announcementAudioBusy()) then
    return false
  end
  if not (securityAudio.canPlayAudio(speaker) and type(pcm) == "table" and #pcm > 0) then
    return false
  end

  local audioConfig = announcementAudioConfig()
  local sampleRate = tonumber(audioConfig.sampleRate) or 48000
  if sampleRate <= 0 then
    sampleRate = 48000
  end
  if options.aukitPrepared ~= true then
    local preparedPcm, _, preparedRate = securityAudio.preparePlaybackPcm(pcm, {
      sampleRate = sampleRate,
    })
    if type(preparedPcm) == "table" and #preparedPcm > 0 then
      pcm = preparedPcm
      sampleRate = tonumber(preparedRate) or sampleRate
      options.aukitPrepared = true
    end
  end
  local duration = #pcm / sampleRate
  state.announcements.audioStreams = state.announcements.audioStreams or {}
  state.announcements.audioStreams[speakerName] = {
    speaker = speaker,
    pcm = pcm,
    volume = volume,
    nextIndex = 1,
    chunkSamples = announcementPlaybackChunkSize(),
    sampleRate = sampleRate,
    generation = options.generation or state.announcements.audioGeneration or 0,
    deadline = os.clock() + duration + (tonumber(audioConfig.streamGraceSeconds) or 30),
    graceSeconds = tonumber(audioConfig.streamGraceSeconds) or 30,
    tailSeconds = tonumber(audioConfig.tailSeconds) or 0.5,
    maxChunksPerFeed = tonumber(audioConfig.maxChunksPerFeed) or 8,
    prebufferSeconds = tonumber(audioConfig.prebufferSeconds) or 2.5,
    refillSeconds = tonumber(audioConfig.refillSeconds) or 0.75,
    syncToleranceSeconds = tonumber(audioConfig.syncToleranceSeconds) or 0.08,
    syncSkipLate = audioConfig.syncSkipLate ~= false,
    startAtMillis = options.startAtMillis,
    clampSamples = false,
    allowDuringAlarm = options.allowDuringAlarm and true or false,
    aukitPrepared = options.aukitPrepared == true,
  }

  local queued = announcementFeedSpeakerStream(speakerName)
  return queued or state.announcements.audioStreams[speakerName] ~= nil
end

function announcementFallbackSounds(announcement)
  local announcements = config.announcements or {}
  local kind = tostring((announcement and (announcement.kind or announcement.type)) or "")
  if (kind == "alarm" or kind == "emergency" or kind == "lockdown") and type(announcements.alarmFallbackSounds) == "table" then
    return announcements.alarmFallbackSounds
  end
  return announcements.fallbackSounds or {
    { name = "minecraft:block.note_block.chime", volume = 1.4, pitch = 0.9 },
    { name = "minecraft:block.note_block.bell", volume = 1.0, pitch = 1.25 },
  }
end

function announcementIsAlarmLike(announcement)
  local kind = announcementKindValue(announcement)
  return kind == "alarm" or kind == "emergency" or kind == "lockdown"
end

function announcementQueueLimit()
  local announcements = config and config.announcements or {}
  local limit = tonumber(announcements.queueLimit or announcements.maxQueue or announcements.maxQueued)
  if not limit or limit < 1 then
    return 12
  end
  return math.floor(limit)
end

function queueFacilityAnnouncement(announcement)
  if type(announcement) ~= "table" then
    return false
  end
  local announcements = config and config.announcements or {}
  if announcements.queue == false or announcements.queueEnabled == false then
    return false
  end

  state.announcements.queue = state.announcements.queue or {}
  local queued = shallowCopy(announcement)
  queued.queuedAtMillis = queued.queuedAtMillis or nowMillis()
  table.insert(state.announcements.queue, queued)

  local limit = announcementQueueLimit()
  while #state.announcements.queue > limit do
    table.remove(state.announcements.queue, 1)
  end
  return true
end

function announcementCanStartNow(announcement)
  local announcements = config and config.announcements or {}
  if announcements.enabled == false or announcements.sound == false then
    return false
  end
  local allowDuringAlarm = announcementCanPlayDuringAlarm(announcement) and announcements.alarmAnnouncements ~= false
  if alarmAnnouncementSuppressionActive() and not allowDuringAlarm then
    return false
  end
  return true
end

function processAnnouncementQueue()
  state.announcements.queue = state.announcements.queue or {}
  if #state.announcements.queue == 0 or announcementAudioBusy() then
    return false
  end

  local index = 1
  while index <= #state.announcements.queue do
    local queued = state.announcements.queue[index]
    if announcementCanStartNow(queued) then
      table.remove(state.announcements.queue, index)
      clearNotificationScheduledStart(queued)
      if playFacilityAnnouncement(queued, { fromQueue = true }) then
        return true
      end
    else
      index = index + 1
    end
  end

  return false
end

function playFacilityAnnouncement(announcement, options)
  options = options or {}
  local announcements = config.announcements or {}
  if announcements.enabled == false or announcements.sound == false then
    return false
  end
  local allowDuringAlarm = announcementCanPlayDuringAlarm(announcement) and announcements.alarmAnnouncements ~= false
  if alarmAnnouncementSuppressionActive() and not allowDuringAlarm then
    if not options.fromQueue then
      if type(announcement) == "table" then
        announcement.serverPreparedAudio = preparedAudioBroadcastEnabled()
      end
      return queueFacilityAnnouncement(announcement)
    end
    return false
  end
  if announcementAudioBusy() then
    if allowDuringAlarm then
      clearAnnouncementAudioStreams(true)
    elseif not options.fromQueue then
      if type(announcement) == "table" then
        announcement.serverPreparedAudio = preparedAudioBroadcastEnabled()
      end
      return queueFacilityAnnouncement(announcement)
    else
      return false
    end
  end

  local pcm = facilityAnnouncements.buildAnnouncementBuffer(announcement, announcements)
  if not (type(pcm) == "table" and #pcm > 0) then
    return false
  end
  local audioConfig = announcementAudioConfig()
  local startAtMillis = scheduledAnnouncementStartMillis(announcement)
  if preparedAudioBroadcastEnabled() then
    startAtMillis = preparedAudioStartMillis(startAtMillis)
    setNotificationScheduledStart(announcement, startAtMillis)
  end
  pcm = alignAnnouncementPcmToSchedule(pcm, startAtMillis, audioConfig)
  if not (type(pcm) == "table" and #pcm > 0) then
    return false
  end
  if alarmAnnouncementSuppressionActive() and not allowDuringAlarm then
    return false
  end
  clearAnnouncementAudioStreams()
  local volume = tonumber(announcements.volume) or 1
  local played = false
  local generation = state.announcements.audioGeneration or 0
  local remoteBroadcasted, remoteStartAt = broadcastPreparedAudio("announcement", pcm, {
    volume = volume,
    sampleRate = audioConfig.sampleRate,
    startAtMillis = startAtMillis,
    allowDuringAlarm = allowDuringAlarm,
    clearExisting = true,
  })
  if type(announcement) == "table" then
    announcement.serverPreparedAudio = remoteBroadcasted and true or false
  end
  startAtMillis = remoteStartAt or startAtMillis
  if remoteStartAt and preparedAudioBroadcastEnabled() then
    local sampleRate = math.max(1, tonumber(audioConfig.sampleRate) or 48000)
    local duration = #pcm / sampleRate
    state.announcements.audioPlayingUntil = math.max(tonumber(state.announcements.audioPlayingUntil) or 0, os.clock() + alarmDelayUntilMillis(remoteStartAt) + duration)
  end
  if type(pcm) == "table" and #pcm > 0 then
    for _, entry in ipairs(findSpeakerEntries()) do
      if startAnnouncementAudioStream(entry.name, entry.speaker, pcm, volume, { allowExisting = true, allowDuringAlarm = allowDuringAlarm, generation = generation, startAtMillis = startAtMillis }) then
        played = true
      end
    end
  end

  if not played then
    for _, speaker in ipairs(findSpeakers()) do
      if speaker.playSound then
        for _, sound in ipairs(announcementFallbackSounds(announcement)) do
          pcall(speaker.playSound, sound.name, sound.volume or 1, sound.pitch or 1)
        end
      end
    end
  end
  return played or remoteBroadcasted
end

function playDspAlarm(profile, speaker)
  if not securityAudio.canPlayAudio(speaker) then
    return false
  end

  local buffer = buildDspAlarmBuffer(profile)
  if not buffer or #buffer == 0 then
    return false
  end

  local dsp = profile.dsp or {}
  local ok, accepted = securityAudio.playPcmRange(speaker, buffer, 1, #buffer, tonumber(dsp.volume) or 1, {
    sampleRate = tonumber(dsp.sampleRate) or tonumber(profile.sampleRate) or 48000,
  })
  return ok and accepted ~= false
end

function playMinecraftAlarmSound(speaker, sound)
  if type(sound) == "string" then
    if alarmIsWavPath(sound) then
      return false
    end
    if speaker.playSound then
      local ok = pcall(speaker.playSound, sound, 2, 1)
      return ok
    end
    return false
  end

  if type(sound) ~= "table" then
    return false
  end
  if sound.name and speaker.playSound then
    local ok = pcall(speaker.playSound, sound.name, sound.volume or 2, sound.pitch or 1)
    return ok
  end
  if sound.note and speaker.playNote then
    local ok = pcall(speaker.playNote, sound.note, sound.volume or 2, sound.pitch or 1)
    return ok
  end
  return false
end

function alarmSoundValue(sound, key, fallback)
  if type(sound) == "table" and sound[key] ~= nil then
    return sound[key]
  end
  return fallback
end

function playAlarmPulse()
  if alarmWaitingForStart() then
    return false
  end

  local profile = alarmProfile(state.alarm.profile)
  if announcementAudioBusy() then
    clearAnnouncementAudioStreams(true)
  end

  local preloadMode = alarmAudioBusy()
  if preloadMode and not alarmCanPreloadNextPulse(profile) then
    return false
  end

  local sounds = profile.sounds or {}
  local soundIndex = state.alarm.soundIndex
  local sound = sounds[soundIndex] or sounds[1]
  if not sounds[soundIndex] and sounds[1] then
    soundIndex = 1
  end
  state.alarm.soundIndex = state.alarm.soundIndex + 1
  if #sounds > 0 and state.alarm.soundIndex > #sounds then
    state.alarm.soundIndex = 1
  end

  local audioBuffer = preparedAlarmSoundBuffer(profile, sound, soundIndex)
  local usePreparedAudio = preparedAudioBroadcastEnabled()
  if audioBuffer and not usePreparedAudio and not preloadMode then
    audioBuffer = alignAlarmPcmToSchedule(profile, audioBuffer)
  end
  local dsp = profile.dsp or {}
  local audioVolume = type(sound) == "table" and sound.volume or nil
  audioVolume = tonumber(audioVolume) or tonumber(profile.volume) or tonumber(dsp.volume) or 1
  local streamStartAt = usePreparedAudio and (not preloadMode) and (nowMillis() + preparedAudioLeadMillis()) or nil
  local localStartAt = nil
  local played = false

  if audioBuffer and usePreparedAudio and not preloadMode then
    streamStartAt = preparedAudioStartMillis(streamStartAt)
  end

  for _, entry in ipairs(findSpeakerEntries()) do
    local speaker = entry.speaker
    local speakerPlayed = false
    if audioBuffer then
      speakerPlayed = playAlarmBuffer(profile, speaker, audioBuffer, audioVolume, entry.name, {
        startAtMillis = localStartAt,
        replaceExisting = not preloadMode,
        queueAfterCurrent = preloadMode,
        syncSkipLate = false,
      })
      played = speakerPlayed or played
    end
    if not speakerPlayed then
      speakerPlayed = playDspAlarm(profile, speaker)
      played = speakerPlayed or played
    end
    if not speakerPlayed then
      speakerPlayed = playMinecraftAlarmSound(speaker, sound)
      played = speakerPlayed or played
    end
    if (not speakerPlayed) and speaker.playNote then
      pcall(speaker.playNote, "pling", alarmSoundValue(sound, "volume", 2), alarmSoundValue(sound, "pitch", 1))
    end
  end

  local remoteBroadcasted = false
  if audioBuffer then
    local broadcastStartAt
    remoteBroadcasted, broadcastStartAt = broadcastPreparedAudio("alarm", audioBuffer, {
      profile = state.alarm.profile,
      volume = audioVolume,
      sampleRate = alarmAudioConfig(profile).sampleRate,
      startAtMillis = streamStartAt,
      clearExisting = not preloadMode,
      queueAfterCurrent = preloadMode,
    })
    if usePreparedAudio then
      local sampleRate = math.max(1, tonumber(alarmAudioConfig(profile).sampleRate) or 48000)
      local duration = #audioBuffer / sampleRate
      if preloadMode then
        local base = math.max(tonumber(state.alarm.audioPlayingUntil) or os.clock(), os.clock())
        state.alarm.audioPlayingUntil = math.max(tonumber(state.alarm.audioPlayingUntil) or 0, base + alarmLoopGap(profile) + duration)
      elseif broadcastStartAt then
        state.alarm.audioPlayingUntil = math.max(tonumber(state.alarm.audioPlayingUntil) or 0, os.clock() + alarmDelayUntilMillis(broadcastStartAt) + duration)
      end
    end
  end
  return played or remoteBroadcasted
end

function alarmNextPulseDelay()
  local profile = alarmProfile(state.alarm.profile)
  if alarmWaitingForStart() then
    return math.max(0.05, alarmDelayUntilMillis(state.alarm.soundStartAt))
  end
  if alarmAudioBusy() then
    if not alarmHasPendingAudioStream() then
      local remaining = (tonumber(state.alarm.audioPlayingUntil) or os.clock()) - os.clock()
      local preloadDelay = remaining - alarmPreloadSeconds(profile)
      if preloadDelay > 0 then
        return math.max(0.05, preloadDelay)
      end
    end
    return 0.1
  end
  if announcementAudioBusy() then
    return 0.2
  end
  return tonumber(profile.repeatSeconds) or 1.5
end

function scheduleAlarmPulse()
  if state.alarm.active then
    scheduleTimer(alarmNextPulseDelay(), { type = "alarm_pulse", generation = state.alarm.audioGeneration })
  end
end

function applyAlarmSourceOptions(options)
  options = options or {}
  state.alarm.sourceKey = options.sourceKey
  state.alarm.sourceAutoReset = options.autoReset == true
  state.alarm.sourceAutoResetAfter = nil
  state.alarm.sourceAutoResetSeconds = tonumber(options.autoResetSeconds)
end

function raiseAlarm(reason, doorId, actor, profileName, options)
  options = options or {}
  profileName = profileName or "security"
  if state.alarm.active then
    if profileName == "emergency" and state.alarm.profile ~= "emergency" then
      setAlarmOutputs(false)
      clearAlarmAudioStreams(true)
      clearAnnouncementAudioStreams(true)
      state.alarm.reason = tostring(reason or "emergency")
      state.alarm.door = doorId
      state.alarm.actor = actor
      state.alarm.profile = "emergency"
      state.alarm.sinceMillis = nowMillis()
      state.alarm.soundStartAt = state.alarm.sinceMillis + alarmSyncLeadMillis(alarmProfile("emergency"))
      state.alarm.soundIndex = 1
      applyAlarmSourceOptions(options)
      local profile = alarmProfile("emergency")
      pcall(prepareAlarmSoundCache, "emergency")
      broadcastAlarmState()
      setAlarmOutputs(true)
      pcall(playAlarmPulse)
      scheduleAlarmPulse()
      sendChat((profile.label or "EMERGENCY") .. ": " .. tostring(state.alarm.reason or ""), "emergency")
      broadcastEventNotification("emergency", profile.label or "Emergency Alarm", state.alarm.reason, "critical", {
        alarm = shallowCopy(state.alarm),
      })
      audit("ALARM_ESCALATED", {
        reason = state.alarm.reason,
        door = doorId,
        actor = actor,
        profile = "emergency",
      })
      markDirty()
      return
    end

    if state.alarm.sourceKey ~= options.sourceKey then
      clearAlarmAutoResetSource()
    elseif options.autoReset == true then
      applyAlarmSourceOptions(options)
    end

    audit("ALARM_UPDATE", {
      reason = reason,
      door = doorId,
      actor = actor,
      profile = profileName,
    })
    broadcastAlarmState()
    broadcastEventNotification("alarm", "Alarm Update", tostring(reason or "alarm update"), "warning", {
      profile = profileName,
      door = doorId,
      actor = actor,
    })
    return
  end

  state.alarm.active = true
  state.alarm.reason = tostring(reason or "alarm")
  state.alarm.door = doorId
  state.alarm.actor = actor
  state.alarm.profile = profileName
  state.alarm.since = os.clock()
  state.alarm.sinceMillis = nowMillis()
  state.alarm.soundStartAt = state.alarm.sinceMillis + alarmSyncLeadMillis(alarmProfile(profileName))
  state.alarm.soundIndex = 1
  applyAlarmSourceOptions(options)
  clearAlarmAudioStreams(true)
  clearAlarmPreparedAudioCache()
  clearAnnouncementAudioStreams(true)

  local profile = alarmProfile(profileName)
  pcall(prepareAlarmSoundCache, profileName)
  broadcastAlarmState()
  setAlarmOutputs(true)
  pcall(playAlarmPulse)
  scheduleAlarmPulse()
  sendChat((profile.label or "ALARM") .. ": " .. tostring(state.alarm.reason or ""), profileName)
  broadcastEventNotification(profileName == "emergency" and "emergency" or "alarm", profile.label or "Alarm", state.alarm.reason, profileName == "emergency" and "critical" or "warning", {
    alarm = shallowCopy(state.alarm),
  })
  audit("ALARM_RAISED", {
    reason = state.alarm.reason,
    door = doorId,
    actor = actor,
    profile = profileName,
  })
  markDirty()
end

function resetAlarm(actor)
  local resetActor = tostring(actor or "console")
  local previousReason = tostring(state.alarm.reason or "alarm")
  local previousAlarm = {
    active = state.alarm.active,
    reason = previousReason,
    door = state.alarm.door,
    actor = state.alarm.actor,
    profile = state.alarm.profile,
    sinceMillis = state.alarm.sinceMillis,
    soundStartAt = state.alarm.soundStartAt,
    sourceKey = state.alarm.sourceKey,
    sourceAutoReset = state.alarm.sourceAutoReset,
  }
  setAlarmOutputs(false)
  state.alarm.active = false
  state.alarm.reason = nil
  state.alarm.door = nil
  state.alarm.actor = nil
  state.alarm.profile = nil
  state.alarm.since = nil
  state.alarm.sinceMillis = nil
  state.alarm.soundStartAt = nil
  clearAlarmAutoResetSource()
  clearAlarmAudioStreams(true)
  clearAlarmPreparedAudioCache()
  audit("ALARM_RESET", resetActor)
  broadcastAlarmState()
  broadcastEventNotification("alarm_reset", "Alarm Reset", "Alarm cleared by " .. resetActor, "info", {
    actor = resetActor,
    alarm = previousAlarm,
    profile = previousAlarm.profile,
    reason = previousReason,
    door = previousAlarm.door,
  })
  markDirty()
end

function unlockDoor(doorId, actor, seconds, reason)
  local door = config.doors[doorId]
  if not door then
    return false, "unknown door"
  end

  if state.lockdown and reason ~= "admin" and reason ~= "request_exit" then
    return false, "lockdown"
  end

  seconds = tonumber(seconds) or door.openSeconds or config.defaultOpenSeconds or 4

  local ok, err = setDoorOpen(doorId, true)
  local doorState = getDoorState(doorId)
  doorState.locked = false
  doorState.openUntil = os.clock() + seconds
  doorState.authorizedUntil = os.clock() + seconds + (door.forcedGraceSeconds or config.forcedGraceSeconds or 2)
  doorState.lastActor = actor or "unknown"

  if doorState.lockTimer then
    state.timers[doorState.lockTimer] = nil
  end
  doorState.lockTimer = scheduleTimer(seconds, { type = "door_lock", door = doorId })

  audit("ACCESS_GRANTED", {
    door = doorId,
    actor = actor,
    reason = reason or "credential",
    seconds = seconds,
    ok = ok,
    error = err,
  })
  markDirty()
  return ok, err
end

function expectedValue(endpoint, defaultValue)
  if type(endpoint) == "table" and endpoint.activeWhen ~= nil then
    return endpoint.activeWhen and true or false
  end
  return defaultValue
end

function denyAccess(doorId, actor, source, reason)
  local door = config.doors[doorId]
  local key = tostring(doorId) .. "|" .. tostring(actor or source or "?")
  local now = os.clock()
  local entry = state.denied[key]

  if not entry or now > entry.expires then
    entry = { count = 0, expires = now + 20 }
    state.denied[key] = entry
  end
  entry.count = entry.count + 1

  audit("ACCESS_DENIED", {
    door = doorId,
    actor = actor,
    source = source,
    reason = reason or "not_authorized",
    count = entry.count,
  })

  local limit = 999999
  if door and door.alarmOnDenied then
    limit = door.deniedBeforeAlarm or config.alarm.deniedBeforeAlarm or 1
  end

  if entry.count >= limit then
    raiseAlarm("denied access at " .. tostring(doorId), doorId, actor)
    entry.count = 0
  end
  markDirty()
end

function recordAllowsDoor(record, doorId)
  if record == true then
    return true
  end

  if type(record) == "string" or type(record) == "number" then
    return listContains(record, doorId)
  end

  if type(record) ~= "table" then
    return false
  end

  if record.disabled then
    return false
  end

  if record.allowAll then
    return true
  end

  return listContains(record.doors or record.door or record.access, doorId)
end

function credentialRecord(credential)
  if type(config.credentials) == "table" and config.credentials[credential] ~= nil then
    return config.credentials[credential]
  end

  if type(config.badges) == "table" and config.badges[credential] ~= nil then
    return config.badges[credential]
  end

  return nil
end

function authorizedCredential(doorId, kind, candidates, meta)
  local door = config.doors[doorId]
  if not door then
    return false, nil
  end

  if state.lockdown then
    return false, nil
  end

  for _, credential in ipairs(candidates) do
    if listContains(door.badges or door.credentials, credential) then
      return true, credential
    end

    local record = credentialRecord(credential)
    if recordAllowsDoor(record, doorId) then
      return true, credential
    end
  end

  local employeeRecordForCredential, employeeCredential = employeeForCredential(candidates)
  if employeeRecordForCredential and recordAllowsDoor(employeeRecordForCredential, doorId) then
    return true, employeeCredential
  end

  if kind == "player" then
    local playerName = meta and meta.player or candidates[1]
    if listContainsIgnoreCase(door.players, playerName) then
      return true, "player:" .. tostring(playerName)
    end

    if type(config.players) == "table" then
      local playerRecord = config.players[playerName] or config.players[string.lower(tostring(playerName))]
      if recordAllowsDoor(playerRecord, doorId) then
        return true, "player:" .. tostring(playerName)
      end
    end
  end

  return false, candidates[1]
end

function authorizedPin(doorId, pin)
  local door = config.doors[doorId]
  if not door or state.lockdown then
    return false
  end

  return listContains(door.pins, tostring(pin))
end

function authorizedAdminPin(pin)
  return listContains(config.adminPins, tostring(pin))
end

function doorIdsForSource(source)
  local out = {}

  for _, doorId in ipairs(tableKeys(config.doors)) do
    local door = config.doors[doorId]
    if listContains(door.readers, source) then
      table.insert(out, doorId)
    end
  end

  if #out > 0 then
    return out
  end

  local mapped = config.readers and (config.readers[source] or config.readers["*"])
  if type(mapped) == "string" or type(mapped) == "number" then
    table.insert(out, tostring(mapped))
  elseif type(mapped) == "table" then
    for _, doorId in ipairs(mapped) do
      table.insert(out, tostring(doorId))
    end
  end

  if #out == 0 then
    local doors = tableKeys(config.doors)
    if #doors == 1 then
      table.insert(out, doors[1])
    end
  end

  return out
end

function shouldAcceptBadge(key, fingerprint)
  local now = os.clock()
  local cooldown = config.badgeCooldownSeconds or 3
  local last = state.lastBadge[key]
  if last and last.fingerprint == fingerprint and now - last.time < cooldown then
    return false
  end

  state.lastBadge[key] = {
    fingerprint = fingerprint,
    time = now,
  }
  return true
end

function badgeRawData(value)
  local text = tostring(value or "")
  local prefix, rest = string.match(text, "^(%a[%w_%-]*):(.+)$")
  if prefix == "badge" or prefix == "nfc" or prefix == "rfid" then
    return rest, prefix
  end
  return text, nil
end

function badgeAliases(kind, value)
  local raw, embeddedKind = badgeRawData(value)
  kind = embeddedKind or kind
  local candidates = {}
  if raw == "" then
    return candidates, { id = raw, name = raw, kind = kind }
  end
  if kind and kind ~= "" then
    appendUnique(candidates, tostring(kind) .. ":" .. raw)
  end
  appendUnique(candidates, "badge:" .. raw)
  appendUnique(candidates, raw)
  return candidates, {
    id = raw,
    name = raw,
    kind = kind,
  }
end

function handleCredentials(source, kind, candidates, meta, cooldownKey)
  if type(candidates) ~= "table" or #candidates == 0 then
    return
  end

  local fingerprint = table.concat(candidates, "|")
  local badgeKey = cooldownKey or (tostring(source) .. "|" .. fingerprint)
  if not shouldAcceptBadge(badgeKey, fingerprint) then
    return
  end

  local actor = candidates[1]
  if meta then
    actor = meta.name or meta.player or meta.label or meta.id or actor
  end

  local doors = doorIdsForSource(source)
  if #doors == 0 then
    audit("CREDENTIAL_IGNORED", {
      source = source,
      kind = kind,
      actor = actor,
      reason = "no_reader_mapping",
    })
    return
  end

  local granted = false
  local firstDoor = nil
  for _, doorId in ipairs(doors) do
    if config.doors[doorId] then
      firstDoor = firstDoor or doorId
      local ok, credential = authorizedCredential(doorId, kind, candidates, meta)
      if ok then
        unlockDoor(doorId, actor, nil, credential)
        granted = true
      end
    end
  end

  if not granted and firstDoor then
    denyAccess(firstDoor, actor, source, "credential_rejected")
  end
end

function diskCandidates(name)
  local okPresent, present = pcall(disk.isPresent, name)
  if not okPresent or not present then
    return {}, nil
  end

  local candidates = {}
  local meta = {}

  local okId, id = pcall(disk.getID, name)
  if okId and id ~= nil then
    meta.id = tostring(id)
    appendUnique(candidates, "disk:" .. tostring(id))
    appendUnique(candidates, tostring(id))
  end

  local okLabel, label = pcall(disk.getLabel, name)
  if okLabel and label ~= nil and tostring(label) ~= "" then
    meta.label = tostring(label)
    appendUnique(candidates, "label:" .. tostring(label))
    appendUnique(candidates, tostring(label))
  end

  if #candidates > 0 then
    meta.name = meta.label or meta.id
  end

  return candidates, meta
end

function isDrive(name)
  if hasPeripheralType(name, "drive") then
    return true
  end

  local methods = methodMap(name)
  return methods.isDiskPresent == true
end

function driveNames()
  local out = {}
  local seen = {}

  for _, name in ipairs(peripheralNames()) do
    if isDrive(name) then
      table.insert(out, name)
      seen[name] = true
    end
  end

  for _, side in ipairs(sides) do
    if not seen[side] then
      local ok, present = pcall(peripheral.isPresent, side)
      if ok and present and isDrive(side) then
        table.insert(out, side)
        seen[side] = true
      end
    end
  end

  return out
end

function pollDiskDrives()
  for _, name in ipairs(driveNames()) do
    local candidates, meta = diskCandidates(name)
    if #candidates > 0 then
      handleCredentials(name, "disk", candidates, meta, "disk:" .. name)
    else
      state.lastBadge["disk:" .. name] = nil
    end
  end
end

local nfcWriteMethods = {
  "writeNFC",
  "writeNfc",
  "writeNfcData",
  "writeNFCData",
  "writeData",
  "writeCard",
  "writeBadge",
  "write",
  "setData",
  "encode",
}

function badgeWriterNames()
  local out = {}
  if not peripheral then
    return out
  end

  for _, name in ipairs(peripheralNames()) do
    local methods = methodMap(name)
    local looksLikeNfc = hasPeripheralType(name, "nfc_reader") or hasPeripheralType(name, "nfc_writer") or hasPeripheralType(name, "nfc")
    for _, method in ipairs(nfcWriteMethods) do
      if methods[method] then
        table.insert(out, name)
        looksLikeNfc = false
        break
      end
    end
    if looksLikeNfc then
      table.insert(out, name)
    end
  end

  table.sort(out)
  return out
end

function writeNfcBadgeData(data, preferredPeripheral)
  local raw = badgeRawData(data)
  if raw == "" then
    return false, "empty badge data"
  end

  local names = {}
  if preferredPeripheral and tostring(preferredPeripheral) ~= "" then
    table.insert(names, tostring(preferredPeripheral))
  else
    names = badgeWriterNames()
  end

  if #names == 0 then
    return false, "no NFC writer peripheral found"
  end

  for _, name in ipairs(names) do
    local device = peripheral.wrap(name)
    local methods = methodMap(name)
    if device then
      for _, method in ipairs(nfcWriteMethods) do
        if methods[method] and device[method] then
          local ok, result = pcall(device[method], raw)
          if ok and result ~= false then
            audit("BADGE_WRITE", { peripheral = name, method = method, data = raw })
            return true, name, method
          end
        end
      end
    end
  end

  return false, "NFC writer did not accept the data"
end

local genericBadgeMethods = {
  "getBadge",
  "readBadge",
  "scanBadge",
  "getLastBadge",
  "getCard",
  "readCard",
  "scanCard",
  "getCardData",
  "readCardData",
  "getLastCard",
  "getRFID",
  "readRFID",
  "scanRFID",
  "getRfid",
  "readRfid",
  "scanRfid",
  "getNFC",
  "readNFC",
  "scanNFC",
  "getNfc",
  "readNfc",
  "scanNfc",
  "getNfcData",
  "readNfcData",
  "getTag",
  "readTag",
  "scanTag",
  "getLastTag",
  "getUID",
  "readUID",
  "getUid",
  "readUid",
  "getData",
  "readData",
  "read",
  "scan",
}

local genericCredentialMethods = {
  getData = true,
  readData = true,
  read = true,
  scan = true,
}

function textContainsAny(text, words)
  text = string.lower(tostring(text or ""))
  for _, word in ipairs(words) do
    if string.find(text, tostring(word), 1, true) then
      return true
    end
  end
  return false
end

function credentialReaderHintText(name)
  local parts = { tostring(name or "") }
  if peripheral and peripheral.getType then
    for _, typeName in ipairs({ peripheral.getType(name) }) do
      if typeName then
        table.insert(parts, tostring(typeName))
      end
    end
  end
  return table.concat(parts, " ")
end

function likelyCredentialReaderName(name)
  return textContainsAny(credentialReaderHintText(name), { "nfc", "rfid", "badge", "card", "reader", "scanner" })
end

function methodLooksCredentialSpecific(method)
  return textContainsAny(method, { "badge", "card", "rfid", "nfc", "tag", "uid" })
end

function shouldUseCredentialMethod(name, method)
  if methodLooksCredentialSpecific(method) then
    return true
  end
  if genericCredentialMethods[tostring(method)] then
    return likelyCredentialReaderName(name)
  end
  return false
end

function hasCredentialReaderMethod(name, methodSet)
  if hasPeripheralType(name, "rfid_scanner") then
    return true
  end

  for _, method in ipairs(genericBadgeMethods) do
    if methodSet[method] and shouldUseCredentialMethod(name, method) then
      return true
    end
  end

  return false
end

function readerKindFor(name, method, value)
  local hint = credentialReaderHintText(name) .. " " .. tostring(method or "")
  if type(value) == "table" then
    for key in pairs(value) do
      hint = hint .. " " .. tostring(key)
    end
  end

  if textContainsAny(hint, { "rfid" }) then
    return "rfid"
  end
  if textContainsAny(hint, { "nfc", "card", "tag", "uid" }) then
    return "nfc"
  end
  return "badge"
end

function credentialKindForKey(defaultKind, key)
  local lower = string.lower(tostring(key or ""))
  if lower == "rfid" then
    return "rfid"
  end
  if lower == "nfc" or lower == "card" or lower == "tag" or lower == "uid" then
    return "nfc"
  end
  return defaultKind or "badge"
end

function appendCredentialAliases(candidates, meta, kind, value, key)
  local keyText = key and tostring(key) or nil
  local keyLower = keyText and string.lower(keyText) or nil
  if keyLower == "label" or keyLower == "name" or keyLower == "owner" then
    meta[keyText] = tostring(value)
    appendUnique(candidates, keyText .. ":" .. tostring(value))
    appendUnique(candidates, tostring(value))
    return
  end

  local aliases, aliasMeta = badgeAliases(kind or "badge", value)
  for _, candidate in ipairs(aliases) do
    appendUnique(candidates, candidate)
  end
  if keyText then
    meta[keyText] = tostring(value)
    appendUnique(candidates, keyText .. ":" .. tostring(value))
  end
  meta.id = meta.id or aliasMeta.id
  meta.kind = meta.kind or aliasMeta.kind
end

function candidatesFromValue(value, kind)
  kind = kind or "badge"
  local candidates = {}
  local meta = {}

  if type(value) == "string" or type(value) == "number" then
    candidates, meta = badgeAliases(kind, value)
    return candidates, meta
  end

  if type(value) ~= "table" then
    return candidates, meta
  end

  local keys = {
    "id",
    "uuid",
    "serial",
    "code",
    "badge",
    "card",
    "nfc",
    "rfid",
    "uid",
    "tag",
    "data",
    "value",
    "label",
    "name",
    "owner",
  }

  for _, key in ipairs(keys) do
    local item = value[key]
    if type(item) == "string" or type(item) == "number" then
      appendCredentialAliases(candidates, meta, credentialKindForKey(kind, key), item, key)
    end
  end

  if #candidates == 0 then
    for _, item in ipairs(value) do
      local nestedCandidates, nestedMeta = candidatesFromValue(item, kind)
      if #nestedCandidates > 0 then
        return nestedCandidates, nestedMeta
      end
    end
  end

  meta.name = meta.name or meta.label or meta.owner or meta.id or meta.uuid or meta.serial or candidates[1]
  meta.kind = meta.kind or kind
  return candidates, meta
end

function rfidBadgeCandidates(badge)
  if type(badge) == "table" and badge.data ~= nil then
    local candidates, meta = badgeAliases("rfid", badge.data)
    meta.distance = badge.distance
    return candidates, meta
  end

  if type(badge) == "string" or type(badge) == "number" then
    return badgeAliases("rfid", badge)
  end

  return {}, {}
end

function scanRfidScannerCredentials()
  if not peripheral then
    return nil
  end

  for _, name in ipairs(peripheralNames()) do
    if hasPeripheralType(name, "rfid_scanner") then
      local device = peripheral.wrap(name)
      if device and device.scan then
        local ok, badges = pcall(device.scan)
        if ok and type(badges) == "table" then
          for _, badge in ipairs(badges) do
            local candidates, meta = rfidBadgeCandidates(badge)
            if #candidates > 0 then
              meta.source = name
              return {
                source = name,
                kind = "rfid",
                candidates = candidates,
                meta = meta,
                cooldown = "rfid:" .. name .. ":" .. tostring(meta.id or candidates[1]),
              }
            end
          end
        end
      end
    end
  end

  return nil
end

function scanGenericBadgeCredentials()
  if not peripheral then
    return nil
  end

  for _, name in ipairs(peripheralNames()) do
    if not isDrive(name) then
      local methods = methodMap(name)
      for _, method in ipairs(genericBadgeMethods) do
        if methods[method] and shouldUseCredentialMethod(name, method) then
          local device = peripheral.wrap(name)
          if device and device[method] then
            local ok, value = pcall(device[method])
            if ok and value ~= nil and value ~= false then
              local kind = readerKindFor(name, method, value)
              local candidates, meta = candidatesFromValue(value, kind)
              if #candidates > 0 then
                meta.source = name
                meta.method = method
                return {
                  source = name,
                  kind = kind,
                  candidates = candidates,
                  meta = meta,
                  cooldown = kind .. ":" .. name .. ":" .. tostring(meta.id or candidates[1]),
                }
              end
            end
          end
          break
        end
      end
    end
  end

  return nil
end

function pollGenericBadgeReaders()
  for _, name in ipairs(peripheralNames()) do
    if not isDrive(name) then
      local methods = methodMap(name)
      for _, method in ipairs(genericBadgeMethods) do
        if methods[method] and shouldUseCredentialMethod(name, method) then
          local device = peripheral.wrap(name)
          if device and device[method] then
            local ok, value = pcall(device[method])
            if ok and value ~= nil and value ~= false then
              local kind = readerKindFor(name, method, value)
              local candidates, meta = candidatesFromValue(value, kind)
              if #candidates > 0 then
                meta.method = method
                handleCredentials(name, kind, candidates, meta, kind .. ":" .. name)
              end
            end
          end
          break
        end
      end
    end
  end
end

function pollRfidScanners()
  for _, name in ipairs(peripheralNames()) do
    if hasPeripheralType(name, "rfid_scanner") then
      local device = peripheral.wrap(name)
      if device and device.scan then
        local ok, badges = pcall(device.scan)
        if ok and type(badges) == "table" then
          for _, badge in ipairs(badges) do
            local candidates, meta = rfidBadgeCandidates(badge)
            if #candidates > 0 then
              handleCredentials(name, "rfid", candidates, meta, "rfid:" .. name .. ":" .. tostring(meta.id or candidates[1]))
            end
          end
        end
      end
    end
  end
end

function isPlayerDetector(name)
  local methods = methodMap(name)
  return methods.getPlayersInRange or methods.getPlayers or methods.getOnlinePlayers or methods.getPlayerNames
end

function playerListFromDetector(name)
  local device = peripheral.wrap(name)
  if not device then
    return {}
  end

  local methods = methodMap(name)
  local ok
  local value

  if methods.getPlayersInRange then
    ok, value = pcall(device.getPlayersInRange, config.playerDetectionRange or 8)
  elseif methods.getPlayers then
    ok, value = pcall(device.getPlayers)
  elseif methods.getOnlinePlayers then
    ok, value = pcall(device.getOnlinePlayers)
  elseif methods.getPlayerNames then
    ok, value = pcall(device.getPlayerNames)
  end

  if not ok or type(value) ~= "table" then
    return {}
  end

  local players = {}
  for _, item in pairs(value) do
    if type(item) == "string" then
      appendUnique(players, item)
    elseif type(item) == "table" then
      appendUnique(players, item.name or item.username or item.player)
    end
  end

  return players
end

function pollPlayerDetectors()
  for _, name in ipairs(peripheralNames()) do
    if isPlayerDetector(name) then
      for _, playerName in ipairs(playerListFromDetector(name)) do
        local candidates = {
          "player:" .. tostring(playerName),
          tostring(playerName),
        }
        handleCredentials(name, "player", candidates, { player = playerName, name = playerName }, "player:" .. name .. ":" .. tostring(playerName))
      end
    end
  end
end

function checkDoorSensors()
  local now = os.clock()

  for _, doorId in ipairs(tableKeys(config.doors)) do
    local door = config.doors[doorId]
    local doorState = getDoorState(doorId)

    if door.contact then
      local active, raw = readEndpoint(endpointWithController(door.contact, door.controller or door.computerId))
      if raw ~= nil then
        local isOpen = active == expectedValue(door.contact, door.contact.openWhen ~= false)
        if isOpen and doorState.locked and now > (doorState.authorizedUntil or 0) then
          raiseAlarm("forced door " .. tostring(doorId), doorId, doorState.lastActor)
        end
      end
    end

    if door.requestExit then
      local key = "exit:" .. tostring(doorId)
      local active, raw = readEndpoint(endpointWithController(door.requestExit, door.controller or door.computerId))
      if raw ~= nil then
        local requested = active == expectedValue(door.requestExit, true)
        if requested and not state.sensors[key] then
          if (not state.lockdown) or door.allowExitDuringLockdown then
            unlockDoor(doorId, "request_exit", door.exitOpenSeconds or door.openSeconds, "request_exit")
          end
        end
        state.sensors[key] = requested
      end
    end
  end
end

function checkEmergencyButtons()
  for index, button in ipairs(config.emergencyButtons or {}) do
    local input = button.input or button
    local active, raw = readEndpoint(input)
    if raw ~= nil then
      local pressed = active == expectedValue(input, button.activeWhen ~= false)
      local key = "emergency:" .. tostring(button.id or button.name or index)

      if pressed and not state.sensors[key] then
        if button.outputs then
          setOutputList(button.outputs, true)
        end
        raiseAlarm(tostring(button.reason or ("emergency button " .. tostring(button.name or index))), nil, button.actor or "emergency_button", button.profile or "emergency")
        audit("EMERGENCY_BUTTON", {
          button = button.name or index,
          profile = button.profile or "emergency",
        })
      elseif (not pressed) and state.sensors[key] and button.outputs then
        setOutputList(button.outputs, false)
      end

      state.sensors[key] = pressed
    end
  end
end

function callPeripheralValue(sensor, methodName)
  local peripheralName = sensor.peripheral or sensor.name
  if not peripheralName or not methodName then
    return false, nil, "missing peripheral or method"
  end

  local device = peripheral.wrap(peripheralName)
  if not device or not device[methodName] then
    return false, nil, "missing method " .. tostring(methodName)
  end

  local argsList = sensor.args or {}
  if type(argsList) ~= "table" then
    argsList = { argsList }
  end

  local ok, value = pcall(device[methodName], unpackArgs(argsList))
  if not ok then
    return false, nil, value
  end

  if type(value) == "table" and sensor.field then
    value = value[sensor.field]
  end

  return true, value
end

function numberOrNil(value)
  if type(value) == "number" then
    return value
  end
  if type(value) == "string" then
    return tonumber(value)
  end
  return nil
end

function compareSensorValue(value, sensor)
  if sensor.alarmWhen ~= nil then
    return value == sensor.alarmWhen
  end

  if sensor.equals ~= nil and value == sensor.equals then
    return true
  end

  if sensor.notEquals ~= nil and value ~= sensor.notEquals then
    return true
  end

  local numberValue = numberOrNil(value)
  if numberValue == nil then
    return value and true or false
  end

  if sensor.min ~= nil and numberValue < sensor.min then
    return true
  end
  if sensor.max ~= nil and numberValue > sensor.max then
    return true
  end
  if sensor.alarmBelow ~= nil and numberValue < sensor.alarmBelow then
    return true
  end
  if sensor.alarmAbove ~= nil and numberValue > sensor.alarmAbove then
    return true
  end

  return false
end

function readCreateStressSensor(sensor)
  local peripheralName = sensor.peripheral or sensor.name
  if not peripheralName then
    return nil, "missing peripheral"
  end

  local device = peripheral.wrap(peripheralName)
  if not device then
    return nil, "missing peripheral " .. tostring(peripheralName)
  end

  local stress = 0
  local capacity = 0
  local overstressed = false

  if device.getStress and device.getStressCapacity then
    local okStress, stressValue = pcall(device.getStress)
    local okCapacity, capacityValue = pcall(device.getStressCapacity)
    if not okStress or not okCapacity then
      return nil, "stressometer read failed"
    end
    stress = tonumber(stressValue) or 0
    capacity = tonumber(capacityValue) or 0
  elseif device.getStressImpact and device.getStressContribution then
    local okStress, stressValue = pcall(device.getStressImpact)
    local okCapacity, capacityValue = pcall(device.getStressContribution)
    if not okStress or not okCapacity then
      return nil, "kinetic peripheral read failed"
    end
    stress = tonumber(stressValue) or 0
    capacity = tonumber(capacityValue) or 0
  else
    return nil, "not a Create stress peripheral"
  end

  if device.isOverstressed then
    local ok, value = pcall(device.isOverstressed)
    overstressed = ok and value and true or false
  end

  local load = nil
  if capacity > 0 then
    load = stress / capacity
  end

  local maxLoad = sensor.maxLoad or sensor.maxLoadPercent
  if maxLoad ~= nil and maxLoad > 1 then
    maxLoad = maxLoad / 100
  end

  local triggered = overstressed
  if maxLoad ~= nil and load ~= nil and load >= maxLoad then
    triggered = true
  end
  if sensor.minCapacity ~= nil and capacity < sensor.minCapacity then
    triggered = true
  end
  if sensor.minStress ~= nil and stress < sensor.minStress then
    triggered = true
  end
  if sensor.maxStress ~= nil and stress > sensor.maxStress then
    triggered = true
  end
  if capacity <= 0 and sensor.alarmOnZeroCapacity ~= false then
    triggered = true
  end

  return triggered, {
    stress = stress,
    capacity = capacity,
    load = load,
    overstressed = overstressed,
  }
end

function readSpeedSensor(sensor)
  local method = sensor.method or "getSpeed"
  local ok, value, err = callPeripheralValue(sensor, method)
  if not ok then
    return nil, err
  end
  return compareSensorValue(value, sensor), { value = value, method = method }
end

function entityComparableNames(value)
  local text = string.lower(tostring(value or ""))
  text = string.gsub(text, "^%s+", "")
  text = string.gsub(text, "%s+$", "")
  if text == "" then
    return {}
  end

  local out = { text }
  local stripped = string.gsub(text, "^minecraft:", "")
  if stripped ~= text then
    table.insert(out, stripped)
  end
  local suffix = string.match(text, "([^:%./]+)$")
  if suffix and suffix ~= text and suffix ~= stripped then
    table.insert(out, suffix)
  end
  return out
end

function addEntityTarget(targets, value)
  for _, name in ipairs(entityComparableNames(value)) do
    targets[name] = true
  end
end

function entityTargetSet(sensor)
  local configured = sensor.entities or sensor.entityTypes or sensor.targets or sensor.mobs or sensor.entity or sensor.target or sensor.mob
  if configured == nil and config and config.facility then
    local hostile = config.facility.hostileEntityDetection or config.facility.hostileEntities
    if type(hostile) == "table" then
      configured = hostile.entities or hostile.entityTypes or hostile.targets or hostile.mobs
    end
  end
  if configured == nil then
    configured = { "minecraft:warden", "minecraft:wither" }
  end

  local targets = {}
  if type(configured) == "table" then
    for key, value in pairs(configured) do
      if type(key) == "string" and value == true then
        addEntityTarget(targets, key)
      elseif type(value) == "string" or type(value) == "number" then
        addEntityTarget(targets, value)
      end
    end
  else
    addEntityTarget(targets, configured)
  end
  return targets
end

function entityHasIdentity(value)
  if type(value) ~= "table" then
    return false
  end
  return value.id ~= nil
    or value.type ~= nil
    or value.name ~= nil
    or value.displayName ~= nil
    or value.entity ~= nil
    or value.entityName ~= nil
    or value.registryName ~= nil
    or value.translationKey ~= nil
    or value.mob ~= nil
    or value.key ~= nil
end

function collectEntityValues(value, out)
  if value == nil then
    return
  end
  if type(value) ~= "table" then
    table.insert(out, value)
    return
  end

  if type(value.entities) == "table" then
    collectEntityValues(value.entities, out)
    return
  end
  if type(value.mobs) == "table" then
    collectEntityValues(value.mobs, out)
    return
  end
  if type(value.results) == "table" then
    collectEntityValues(value.results, out)
    return
  end
  if entityHasIdentity(value) then
    table.insert(out, value)
    return
  end

  for _, item in pairs(value) do
    collectEntityValues(item, out)
  end
end

function entityTextValues(entity)
  local out = {}
  local function add(value)
    if value ~= nil and type(value) ~= "table" then
      table.insert(out, tostring(value))
    end
  end

  if type(entity) == "table" then
    add(entity.id)
    add(entity.type)
    add(entity.name)
    add(entity.displayName)
    add(entity.entity)
    add(entity.entityName)
    add(entity.registryName)
    add(entity.translationKey)
    add(entity.mob)
    add(entity.key)
    if type(entity.entity) == "table" then
      for _, value in ipairs(entityTextValues(entity.entity)) do
        table.insert(out, value)
      end
    end
  else
    add(entity)
  end
  return out
end

function entityMatchesTargets(entity, targets)
  for _, text in ipairs(entityTextValues(entity)) do
    for _, name in ipairs(entityComparableNames(text)) do
      if targets[name] then
        return true, name
      end
    end
  end
  return false, nil
end

function entityDetectorMethodCandidates(sensor, methods)
  local radius = sensor.radius or sensor.range or sensor.distance
  local configuredArgs = sensor.args
  if type(configuredArgs) ~= "table" then
    configuredArgs = configuredArgs ~= nil and { configuredArgs } or nil
  end
  if sensor.method then
    return {
      { name = tostring(sensor.method), args = configuredArgs or (radius and { radius } or {}) },
    }
  end

  local candidates = {
    { name = "getEntitiesInRange", args = radius and { radius } or {} },
    { name = "getNearbyEntities", args = radius and { radius } or {} },
    { name = "scanEntities", args = radius and { radius } or {} },
    { name = "getEntities", args = radius and { radius } or {} },
    { name = "getEntities", args = {} },
    { name = "getMobsInRange", args = radius and { radius } or {} },
    { name = "getMobs", args = radius and { radius } or {} },
    { name = "getMobs", args = {} },
    { name = "getLivingEntitiesInRange", args = radius and { radius } or {} },
    { name = "getLivingEntities", args = radius and { radius } or {} },
    { name = "getLivingEntities", args = {} },
    { name = "sense", args = radius and { radius } or {} },
    { name = "sense", args = {} },
  }

  local out = {}
  for _, candidate in ipairs(candidates) do
    if methods[candidate.name] then
      table.insert(out, candidate)
    end
  end
  return out
end

function entityDetectorPeripheralNames(sensor)
  local configured = sensor.peripherals or sensor.detectors or sensor.detector or sensor.peripheral
  local out = {}
  if type(configured) == "table" then
    for _, name in ipairs(configured) do
      table.insert(out, tostring(name))
    end
  elseif configured ~= nil and tostring(configured) ~= "" then
    table.insert(out, tostring(configured))
  elseif sensor.autoDiscover ~= false then
    for _, name in ipairs(peripheralNames()) do
      local methods = methodMap(name)
      if #entityDetectorMethodCandidates(sensor, methods) > 0 then
        table.insert(out, name)
      end
    end
  end
  return out
end

function entityLabel(entity)
  local texts = entityTextValues(entity)
  return texts[1] or "entity"
end

function readEntitySensor(sensor)
  if not peripheral then
    return nil, "peripheral API unavailable"
  end

  local targets = entityTargetSet(sensor)
  local detectors = entityDetectorPeripheralNames(sensor)
  if #detectors == 0 then
    return nil, "no entity detector peripheral"
  end

  local detail = {
    count = 0,
    matches = {},
    detectors = {},
  }

  local lastError = nil
  for _, peripheralName in ipairs(detectors) do
    local device = peripheral.wrap(peripheralName)
    if device then
      local methods = methodMap(peripheralName)
      local candidates = entityDetectorMethodCandidates(sensor, methods)
      for _, candidate in ipairs(candidates) do
        local ok, result = pcall(device[candidate.name], unpackArgs(candidate.args or {}))
        if ok then
          local entities = {}
          collectEntityValues(result, entities)
          table.insert(detail.detectors, {
            peripheral = peripheralName,
            method = candidate.name,
            count = #entities,
          })
          for _, entity in ipairs(entities) do
            local matched, target = entityMatchesTargets(entity, targets)
            if matched then
              detail.count = detail.count + 1
              table.insert(detail.matches, {
                target = target,
                label = entityLabel(entity),
                peripheral = peripheralName,
                method = candidate.name,
              })
            end
          end
          break
        else
          lastError = result
        end
      end
    else
      lastError = "missing peripheral " .. tostring(peripheralName)
    end
  end

  if #detail.detectors == 0 and lastError then
    return nil, lastError
  end
  return detail.count > 0, detail
end

function readFacilitySensor(sensor)
  local sensorType = sensor.type or sensor.kind

  if sensorType == "create_stress" or sensorType == "create_power" or sensorType == "stressometer" then
    return readCreateStressSensor(sensor)
  end

  if sensorType == "create_speed" or sensorType == "speedometer" then
    return readSpeedSensor(sensor)
  end

  if sensorType == "entity" or sensorType == "entity_detector" or sensorType == "mob" or sensorType == "mob_detector" or sensorType == "hostile_entity" then
    return readEntitySensor(sensor)
  end

  if sensorType == "peripheral" or sensorType == "generic" or sensor.method then
    local ok, value, err = callPeripheralValue(sensor, sensor.method)
    if not ok then
      return nil, err
    end
    return compareSensorValue(value, sensor), { value = value, method = sensor.method }
  end

  local input = sensor.input or sensor
  local active, raw = readEndpoint(input)
  if raw == nil then
    return nil, "missing input"
  end

  local alarmWhen = true
  if sensor.alarmWhen ~= nil then
    alarmWhen = sensor.alarmWhen and true or false
  end

  return active == alarmWhen, { active = active, raw = raw }
end

function sensorProfile(sensor)
  return sensor.profile or sensor.alarmProfile or sensor.severity or "facility_fault"
end

function sensorReason(sensor, detail)
  if sensor.reason then
    return sensor.reason
  end

  local name = sensor.label or sensor.name or sensor.peripheral or "sensor"
  if detail and type(detail.matches) == "table" and detail.matches[1] then
    return tostring(name) .. " detected " .. tostring(detail.matches[1].label or detail.matches[1].target or "hostile entity")
  end
  if detail and detail.load then
    return tostring(name) .. " load " .. tostring(math.floor(detail.load * 100)) .. "%"
  end
  if detail and detail.value ~= nil then
    return tostring(name) .. " value " .. tostring(detail.value)
  end
  return "facility fault: " .. tostring(name)
end

function configuredFacilitySensors()
  local out = {}

  for _, sensor in ipairs(config.sensors or {}) do
    table.insert(out, sensor)
  end

  for _, sensor in ipairs(config.facilitySensors or {}) do
    table.insert(out, sensor)
  end

  for _, sensor in ipairs(config.generators or {}) do
    local copy = shallowCopy(sensor)
    copy.type = copy.type or "create_stress"
    copy.profile = copy.profile or "power_fault"
    table.insert(out, copy)
  end

  local facility = config.facility or {}
  local hostile = facility.hostileEntityDetection or facility.hostileEntities
  if hostile ~= false then
    hostile = type(hostile) == "table" and hostile or {}
    if hostile.enabled ~= false then
      local copy = shallowCopy(hostile)
      copy.id = copy.id or "hostile_entities"
      copy.name = copy.name or "Hostile Entity Detector"
      copy.type = copy.type or "entity"
      if copy.entities == nil and #hostile > 0 then
        copy.entities = shallowCopy(hostile)
      end
      copy.entities = copy.entities or copy.entityTypes or copy.targets or { "minecraft:warden", "minecraft:wither" }
      copy.profile = copy.profile or "emergency"
      copy.actor = copy.actor or "entity_detector"
      copy.autoResetAlarm = copy.autoResetAlarm ~= false
      table.insert(out, copy)
    end
  end

  for _, sensor in ipairs(facility.entityDetectors or facility.entitySensors or {}) do
    local copy = shallowCopy(sensor)
    copy.type = copy.type or "entity"
    copy.profile = copy.profile or "emergency"
    copy.actor = copy.actor or "entity_detector"
    if copy.autoResetAlarm == nil then
      copy.autoResetAlarm = true
    end
    table.insert(out, copy)
  end

  return out
end

function facilitySensorUsesCreateStress(sensor)
  if type(sensor) ~= "table" then
    return false
  end

  local sensorType = sensor.type or sensor.kind
  return sensorType == "create_stress" or sensorType == "create_power" or sensorType == "stressometer"
end

function facilitySensorUsesRedstoneInput(sensor)
  if type(sensor) ~= "table" then
    return true
  end

  local sensorType = sensor.type or sensor.kind
  if facilitySensorUsesCreateStress(sensor)
      or sensorType == "create_speed"
      or sensorType == "speedometer"
      or sensorType == "entity"
      or sensorType == "entity_detector"
      or sensorType == "mob"
      or sensorType == "mob_detector"
      or sensorType == "hostile_entity" then
    return false
  end
  if sensorType == "peripheral" or sensorType == "generic" or sensor.method then
    return false
  end

  return sensor.input ~= nil
    or sensor.side ~= nil
    or sensor.peripheral ~= nil
    or sensor.relay ~= nil
    or sensor.redstoneRelay ~= nil
    or sensor.integrator ~= nil
    or sensor.device ~= nil
end

function sensorAutoResetEnabled(sensor)
  return sensor and (sensor.autoResetAlarm == true or sensor.autoReset == true)
end

function sensorAutoResetDelaySeconds(sensor)
  local facility = config and config.facility or {}
  local seconds = sensor and (sensor.autoResetSeconds or sensor.autoResetDelaySeconds or sensor.clearDelaySeconds)
  seconds = tonumber(seconds or facility.entityAutoResetSeconds or facility.hostileEntityAutoResetSeconds or 5)
  if seconds < 0 then
    return 0
  elseif seconds > 300 then
    return 300
  end
  return seconds
end

function clearAlarmAutoResetSource()
  state.alarm.sourceKey = nil
  state.alarm.sourceAutoReset = false
  state.alarm.sourceAutoResetAfter = nil
  state.alarm.sourceAutoResetSeconds = nil
end

function alarmOptionsFromSensor(sensor, key)
  return {
    sourceKey = key,
    autoReset = sensorAutoResetEnabled(sensor),
    autoResetSeconds = sensorAutoResetDelaySeconds(sensor),
  }
end

function cancelSensorAlarmAutoReset(key)
  if state.alarm.active and state.alarm.sourceKey == key then
    state.alarm.sourceAutoResetAfter = nil
  end
end

function scheduleSensorAlarmAutoReset(sensor, key)
  if not (state.alarm.active and state.alarm.sourceAutoReset and state.alarm.sourceKey == key) then
    return
  end
  state.alarm.sourceAutoResetAfter = os.clock() + sensorAutoResetDelaySeconds(sensor)
end

function maybeAutoResetSensorAlarm()
  if not (state.alarm.active and state.alarm.sourceAutoReset and state.alarm.sourceAutoResetAfter) then
    return
  end
  if os.clock() < tonumber(state.alarm.sourceAutoResetAfter) then
    return
  end

  local key = state.alarm.sourceKey
  if key and state.sensors and state.sensors[key] then
    state.alarm.sourceAutoResetAfter = nil
    return
  end
  resetAlarm("auto:" .. tostring(key or "sensor"))
end

function checkConfiguredFacilitySensors(filterFn)
  if config.facility and config.facility.enabled == false then
    return
  end

  for index, sensor in ipairs(configuredFacilitySensors()) do
    if not filterFn or filterFn(sensor, index) then
      local key = "sensor:" .. tostring(sensor.id or sensor.name or sensor.peripheral or index)
      local triggered, detail = readFacilitySensor(sensor)

      if triggered ~= nil then
        state.sensorDetails[key] = detail

        if triggered and sensor.outputs then
          setOutputList(sensor.outputs, true)
        elseif not triggered and sensor.outputs then
          setOutputList(sensor.outputs, false)
        end

        if triggered and not state.sensors[key] then
          raiseAlarm(sensorReason(sensor, detail), nil, sensor.actor or "facility_sensor", sensorProfile(sensor), alarmOptionsFromSensor(sensor, key))
          audit("SENSOR_FAULT", {
            sensor = sensor.name or sensor.peripheral or index,
            profile = sensorProfile(sensor),
            detail = detail,
          })
          cancelSensorAlarmAutoReset(key)
        elseif not triggered and state.sensors[key] then
          audit("SENSOR_CLEAR", {
            sensor = sensor.name or sensor.peripheral or index,
            detail = detail,
          })
          scheduleSensorAlarmAutoReset(sensor, key)
        end

        state.sensors[key] = triggered
      end
    end
  end
end

function checkAutoCreateStressSensors()
  if not (config.facility and config.facility.autoDiscoverCreateStress) then
    return
  end

  for _, name in ipairs(peripheralNames()) do
    local methods = methodMap(name)
    local looksLikeStressometer = methods.getStress and methods.getStressCapacity
    local looksLikeAvionicsKinetic = methods.getNetworkId and methods.getStressImpact and methods.getStressContribution

    if looksLikeStressometer or looksLikeAvionicsKinetic then
      local sensor = {
        name = name,
        peripheral = name,
        type = "create_stress",
        maxLoad = config.facility.autoStressMaxLoad or 0.9,
        profile = config.facility.autoStressProfile or "power_fault",
      }
      local key = "auto_stress:" .. tostring(name)
      local triggered, detail = readCreateStressSensor(sensor)
      if triggered ~= nil then
        state.sensorDetails[key] = detail
        if triggered and not state.sensors[key] then
          raiseAlarm(sensorReason(sensor, detail), nil, "create_stress", sensor.profile, alarmOptionsFromSensor(sensor, key))
          audit("SENSOR_FAULT", { sensor = name, profile = sensor.profile, detail = detail })
          cancelSensorAlarmAutoReset(key)
        elseif not triggered and state.sensors[key] then
          audit("SENSOR_CLEAR", { sensor = name, detail = detail })
          scheduleSensorAlarmAutoReset(sensor, key)
        end
        state.sensors[key] = triggered
      end
    end
  end
end

function checkGlobalSensors()
  checkConfiguredFacilitySensors()
  checkAutoCreateStressSensors()
  maybeAutoResetSensorAlarm()
end

function checkRedstoneFacilitySensors()
  checkConfiguredFacilitySensors(facilitySensorUsesRedstoneInput)
end

function checkStressSensors()
  checkConfiguredFacilitySensors(facilitySensorUsesCreateStress)
  checkAutoCreateStressSensors()
end

function pollCredentials()
  pollDiskDrives()
  pollRfidScanners()
  pollGenericBadgeReaders()
  pollPlayerDetectors()
end

function pollDoorInputs()
  checkDoorSensors()
  checkEmergencyButtons()
end

function pollFacilitySensors()
  checkGlobalSensors()
end

function pollInputs()
  pollCredentials()
  pollDoorInputs()
  pollFacilitySensors()
end

function openRednet()
  if not (config.rednet and config.rednet.enabled) or not rednet then
    return
  end

  for _, name in ipairs(peripheralNames()) do
    if hasPeripheralType(name, "modem") then
      local okOpen = true
      if rednet.isOpen then
        local ok, isOpen = pcall(rednet.isOpen, name)
        okOpen = ok and isOpen
      else
        okOpen = false
      end

      if not okOpen then
        pcall(rednet.open, name)
      end
    end
  end
end

function rednetProtocol()
  return (config.rednet and config.rednet.protocol) or PROTOCOL
end

function unwrapRednetMessage(message)
  return secureRednet.unwrap(message, config and config.rednet or {})
end

function sendRednet(target, message)
  if not rednet then
    return false, "rednet unavailable"
  end
  stampOutboundRednetMessage(message)
  return secureRednet.send(rednet, target, message, config and config.rednet or {}, rednetProtocol())
end

function broadcastRednet(message)
  if not rednet then
    return false, "rednet unavailable"
  end
  stampOutboundRednetMessage(message)
  return secureRednet.broadcast(rednet, message, config and config.rednet or {}, rednetProtocol())
end

function receiveRednet(timeout)
  local ok, sender, message = pcall(rednet.receive, rednetProtocol(), timeout)
  if not ok then
    return false, nil, nil, sender
  end

  if sender == nil then
    return true, nil, nil, nil
  end

  local decoded, err = unwrapRednetMessage(message)
  if decoded == nil then
    return true, sender, nil, err
  end
  return true, sender, decoded, nil
end

function peripheralSummary()
  local out = {}
  if not peripheral then
    return out
  end

  for _, name in ipairs(peripheralNames()) do
    local types = { peripheral.getType(name) }
    local methods = {}
    local methodSet = methodMap(name)
    for method in pairs(methodSet) do
      table.insert(methods, method)
    end
    table.sort(methods)
    table.insert(out, {
      name = name,
      types = types,
      methods = methods,
      reader = hasCredentialReaderMethod(name, methodSet),
    })
  end

  table.sort(out, function(a, b)
    return tostring(a.name) < tostring(b.name)
  end)
  return out
end

function kioskControllerOptions()
  local kiosk = config and config.kiosk or {}
  if type(kiosk.controller) == "table" then
    return kiosk.controller
  end
  if kiosk.controller == true or kiosk.controllerMode == true then
    return {
      enabled = true,
      permanent = true,
      credentialForwarding = true,
    }
  end
  return {}
end

function kioskControllerEnabled()
  local options = kioskControllerOptions()
  return options.enabled == true
end

function kioskControllerCredentialForwarding()
  local options = kioskControllerOptions()
  return kioskControllerEnabled() and options.credentialForwarding ~= false
end

function controllerModeActive()
  local mode = string.lower(tostring(config and config.mode or ""))
  return mode == "controller" or mode == "door" or mode == "door_controller"
end

function controllerPollSeconds()
  local options = kioskControllerOptions()
  if not controllerModeActive() and not kioskControllerEnabled() then
    return normalizedSeconds(options.idlePollSeconds or config.controllerIdlePollSeconds, 5, 0.5)
  end
  return normalizedSeconds(options.pollSeconds or config.controllerPollSeconds, 0.5, 0.1)
end

function kioskControllerId()
  return tostring(localComputerId() or "")
end

function controllerSenderAllowed(sender)
  local serverId = config and config.rednet and config.rednet.serverId
  if not serverId and state and state.kiosk then
    serverId = state.kiosk.serverId
  end
  return serverId == nil or tostring(sender) == tostring(serverId)
end

function handleControllerMessage(sender, message)
  if type(message) ~= "table" or not message.op then
    return
  end
  if message.op == "network_reboot" then
    handleNetworkRebootMessage(sender, message)
    return
  end
  if message.op == "audio_stream" then
    handlePreparedAudioMessage(message, sender)
    return
  end

  local reply = {
    ok = false,
    requestId = message.requestId,
    controllerId = localComputerId(),
  }

  if not controllerSenderAllowed(sender) then
    reply.error = "denied"
  elseif message.op == "controller_endpoint" then
    local endpoint = stripEndpointController(message.endpoint)
    if message.action == "write" then
      local ok, err = setEndpoint(endpoint, message.active and true or false)
      reply.ok = ok
      reply.error = err
    elseif message.action == "read" then
      local active, raw, err = readEndpoint(endpoint)
      reply.ok = raw ~= nil
      reply.active = active and true or false
      reply.raw = raw
      reply.error = err
    else
      reply.error = "unknown endpoint action"
    end
  elseif message.op == "controller_scan" or message.op == "controller_ping" then
    reply.ok = true
    reply.peripherals = peripheralSummary()
  else
    reply.error = "unknown controller op"
  end

  pcall(sendRednet, sender, reply)
end

function broadcastControllerHello()
  if not (config and config.rednet and config.rednet.enabled and rednet) then
    return
  end

  local payload = {
    op = "controller_hello",
    controllerId = localComputerId(),
    label = os.getComputerLabel and os.getComputerLabel() or nil,
    peripherals = peripheralSummary(),
  }
  local serverId = config.rednet and config.rednet.serverId
  if serverId then
    pcall(sendRednet, serverId, payload)
  else
    pcall(broadcastRednet, payload)
  end
end

function controllerCredentialSource(source)
  return "controller:" .. tostring(localComputerId() or "?") .. ":" .. tostring(source or "reader")
end

function sendControllerCredential(scanned)
  if type(scanned) ~= "table" or type(scanned.candidates) ~= "table" or #scanned.candidates == 0 then
    return
  end
  if not (config and config.rednet and config.rednet.enabled and rednet) then
    return
  end

  local fingerprint = table.concat(scanned.candidates, "|")
  local localSource = tostring(scanned.source or "reader")
  local source = controllerCredentialSource(localSource)
  if not shouldAcceptBadge(source, fingerprint) then
    return
  end

  local payload = {
    op = "controller_credential",
    controllerId = localComputerId(),
    localSource = localSource,
    source = source,
    kind = scanned.kind or "badge",
    candidates = scanned.candidates,
    meta = scanned.meta,
  }
  local serverId = config.rednet and config.rednet.serverId
  if serverId then
    pcall(sendRednet, serverId, payload)
  else
    pcall(broadcastRednet, payload)
  end
end

function controllerPollLocalCredentials()
  local scanned = scanRfidScannerCredentials() or scanGenericBadgeCredentials()
  if scanned then
    sendControllerCredential(scanned)
  end
end

function accountsPath()
  return (config.employees and config.employees.accountsFile) or ACCOUNTS_FILE
end

function socialPath()
  return (config.employees and config.employees.socialFile) or SOCIAL_FILE
end

function ensureEmployeeTables()
  state.accounts.users = state.accounts.users or {}
  state.accounts.notes = state.accounts.notes or {}
  state.social.feed = state.social.feed or {}
  state.social.messages = state.social.messages or {}
end

function saveAccounts()
  ensureEmployeeTables()
  saveDataFile(accountsPath(), {
    users = state.accounts.users,
    notes = state.accounts.notes,
  })
end

function saveSocial()
  ensureEmployeeTables()
  saveDataFile(socialPath(), state.social)
end

function loadEmployeeData()
  local accounts = loadDataFile(accountsPath(), { users = {}, notes = {} })
  local social = loadDataFile(socialPath(), { feed = {}, messages = {} })
  state.accounts = accounts
  state.social = social
  ensureEmployeeTables()

  local changed = false
  for username, record in pairs((config.employees and config.employees.initialAccounts) or {}) do
    local key = normalizeUsername(username)
    if key ~= "" and state.accounts.users[key] == nil then
      state.accounts.users[key] = {
        username = key,
        displayName = record.displayName or username,
        pin = tostring(record.pin or ""),
        role = record.role or "employee",
        clearance = record.clearance,
        credentials = shallowCopy(record.credentials or record.badges or record.cards),
        disabled = record.disabled or false,
        createdAt = timestamp(),
      }
      changed = true
    end
  end

  if changed then
    saveAccounts()
  end
end

function publicBrandPayload()
  local brand = displayBranding()
  return {
    facilityName = brand.facilityName,
    shortName = brand.shortName,
    kioskTitle = brand.kioskTitle,
    motto = brand.motto,
    primaryColor = brand.primaryColor,
    accentColor = brand.accentColor,
    textColor = brand.textColor,
    allowSelfRegistration = config.employees and config.employees.allowSelfRegistration or false,
    permissions = {
      quitKiosk = config.employees and config.employees.permissions and config.employees.permissions.quitKiosk or 5,
      setupFacility = config.employees and config.employees.permissions and config.employees.permissions.setupFacility or 5,
      issueBadges = config.employees and config.employees.permissions and config.employees.permissions.issueBadges or 5,
    },
  }
end

function serverComputerId()
  return os.getComputerID and os.getComputerID() or nil
end

function publicKioskConfig()
  local rednetConfig = shallowCopy(config.rednet or {})
  rednetConfig.serverId = serverComputerId()

  local out = {
    mode = "kiosk",
    siteName = config.siteName,
    facilityName = config.facilityName,
    branding = publicBrandPayload(),
    rednet = rednetConfig,
    kiosk = shallowCopy(config.kiosk or {}),
    notifications = shallowCopy(config.notifications or {}),
  }

  if not config.configSync or config.configSync.includeMonitors ~= false then
    out.monitors = shallowCopy(config.kioskMonitors or config.monitors or {})
  end
  if not config.configSync or config.configSync.includeAnnouncements ~= false then
    out.announcements = shallowCopy(config.announcements or {})
  end
  if not config.configSync or config.configSync.includeAlarm ~= false then
    out.alarm = shallowCopy(config.alarm or {})
  end

  return out
end

function employeeRecord(username)
  ensureEmployeeTables()
  return state.accounts.users[normalizeUsername(username)]
end

function publicEmployee(record)
  if not record then
    return nil
  end
  return {
    username = record.username,
    displayName = record.displayName or record.username,
    role = record.role or "employee",
    clearance = employeeClearance and employeeClearance(record) or record.clearance,
  }
end

function employeeCredentialList(record)
  local out = {}
  if type(record) ~= "table" then
    return out
  end

  local fields = { "credentials", "badges", "cards", "rfids", "nfc" }
  for _, field in ipairs(fields) do
    local value = record[field]
    if type(value) == "table" then
      for _, item in ipairs(value) do
        appendUnique(out, item)
      end
    elseif value ~= nil then
      appendUnique(out, value)
    end
  end
  return out
end

function recordHasCredential(record, candidates)
  local owned = employeeCredentialList(record)
  for _, candidate in ipairs(candidates or {}) do
    if listContains(owned, candidate) then
      return candidate
    end
  end
  return nil
end

function employeeForCredential(candidates)
  ensureEmployeeTables()

  for _, candidate in ipairs(candidates or {}) do
    local mapped = credentialRecord(candidate)
    if type(mapped) == "table" then
      local username = mapped.username or mapped.user or mapped.employee
      local record = username and employeeRecord(username)
      if record and not record.disabled then
        return record, candidate
      end
    end
  end

  for _, username in ipairs(tableKeys(state.accounts.users)) do
    local record = state.accounts.users[username]
    if record and not record.disabled then
      local matched = recordHasCredential(record, candidates)
      if matched then
        return record, matched
      end
    end
  end

  return nil, nil
end

function verifyEmployee(username, pin)
  local record = employeeRecord(username)
  if not record or record.disabled then
    return false, nil
  end
  return tostring(record.pin or "") == tostring(pin or ""), record
end

function verifyEmployeeCredential(candidates)
  local record, credential = employeeForCredential(candidates)
  return record ~= nil, record, credential
end

function issueEmployeeBadge(username, data, actor, doorAccess)
  local record = employeeRecord(username)
  if not record then
    return false, "unknown employee"
  end

  local raw = badgeRawData(data)
  if raw == "" then
    raw = makeId("badge")
  end

  local candidates = badgeAliases("badge", raw)
  record.credentials = record.credentials or {}
  for _, candidate in ipairs(candidates) do
    appendUnique(record.credentials, candidate)
  end

  if doorAccess and doorAccess ~= "" then
    config.credentials = config.credentials or {}
    local doors = {}
    if doorAccess == "*" then
      doors = { "*" }
    else
      for item in string.gmatch(tostring(doorAccess), "([^,]+)") do
        item = string.gsub(item, "^%s+", "")
        item = string.gsub(item, "%s+$", "")
        if item ~= "" then
          table.insert(doors, item)
        end
      end
    end
    if #doors > 0 then
      config.credentials["badge:" .. raw] = {
        username = record.username,
        name = record.displayName or record.username,
        doors = doors,
      }
    end
  end

  saveAccounts()
  saveConfig()
  audit("BADGE_ISSUE", {
    actor = actor or "system",
    user = record.username,
    data = raw,
    doorAccess = doorAccess,
  })
  return true, raw
end

function createSession(username, sender)
  local record = employeeRecord(username)
  if not record then
    return nil
  end

  local token = makeId("session")
  state.sessions[token] = {
    username = record.username,
    sender = sender,
    expires = os.clock() + ((config.employees and config.employees.sessionSeconds) or 1800),
  }
  return token
end

function touchSessionSender(token, sender)
  local session = state.sessions[tostring(token or "")]
  if session and sender then
    session.sender = sender
  end
end

function sessionRecord(token)
  local session = state.sessions[tostring(token or "")]
  if not session then
    return nil
  end

  if os.clock() > session.expires then
    state.sessions[tostring(token)] = nil
    return nil
  end

  session.expires = os.clock() + ((config.employees and config.employees.sessionSeconds) or 1800)
  return employeeRecord(session.username)
end

function employeeClearance(record)
  if not record then
    return 0
  end

  local direct = tonumber(record.clearance)
  if direct then
    return direct
  end

  return tonumber(config.employees and config.employees.defaultClearance) or 1
end

function permissionLevel(permission)
  local permissions = config.employees and config.employees.permissions or {}
  return tonumber(permissions[permission]) or 999
end

function employeeCan(record, permission)
  return employeeClearance(record) >= permissionLevel(permission)
end

function employeeIsAdmin(record)
  return employeeCan(record, "manageEmployees")
end

function registerEmployee(username, pin, displayName)
  if not (config.employees and config.employees.allowSelfRegistration) then
    return false, "registration disabled"
  end

  local key = normalizeUsername(username)
  if key == "" then
    return false, "invalid username"
  end
  if string.len(tostring(pin or "")) < 4 then
    return false, "pin too short"
  end
  if state.accounts.users[key] then
    return false, "account exists"
  end

  state.accounts.users[key] = {
    username = key,
    displayName = displayName and tostring(displayName) ~= "" and tostring(displayName) or key,
    pin = tostring(pin),
    role = (config.employees and config.employees.defaultRole) or "employee",
    clearance = config.employees and config.employees.defaultClearance or 1,
    createdAt = timestamp(),
  }
  saveAccounts()
  audit("EMPLOYEE_REGISTER", key)
  return true
end

function notesFor(username)
  ensureEmployeeTables()
  local key = normalizeUsername(username)
  state.accounts.notes[key] = state.accounts.notes[key] or {}
  return state.accounts.notes[key]
end

function findEmployeeNote(record, noteId)
  local notes = notesFor(record.username)
  noteId = tostring(noteId or "")
  if noteId == "" then
    return nil, nil
  end

  for index, note in ipairs(notes) do
    if tostring(note.id) == noteId then
      return note, index
    end
  end

  return nil, nil
end

function socialMailbox(username)
  ensureEmployeeTables()
  local key = normalizeUsername(username)
  state.social.messages[key] = state.social.messages[key] or {}
  return state.social.messages[key]
end

function capEmployeeText(text, maxLength)
  text = tostring(text or "")
  maxLength = tonumber(maxLength) or 512
  if string.len(text) > maxLength then
    text = string.sub(text, 1, maxLength)
  end
  return text
end

function addEmployeeNote(record, title, body, noteId)
  local notes = notesFor(record.username)
  local maxLength = (config.employees and config.employees.maxNoteLength) or 4096
  local id = tostring(noteId or "")

  if id ~= "" then
    local note, index = findEmployeeNote(record, id)
    if not note then
      return false, nil, "note not found"
    end

    note.title = capEmployeeText(title, 80)
    note.body = capEmployeeText(body, maxLength)
    note.updatedAt = timestamp()
    if index and index > 1 then
      table.remove(notes, index)
      table.insert(notes, 1, note)
    end
    saveAccounts()
    return true, id
  end

  id = makeId("note")
  table.insert(notes, 1, {
    id = id,
    title = capEmployeeText(title, 80),
    body = capEmployeeText(body, maxLength),
    createdAt = timestamp(),
    updatedAt = timestamp(),
  })

  saveAccounts()
  return true, id
end

function deleteEmployeeNote(record, noteId)
  local notes = notesFor(record.username)
  for index, note in ipairs(notes) do
    if note.id == noteId then
      table.remove(notes, index)
      saveAccounts()
      return true
    end
  end
  return false
end

function addFeedPost(record, text)
  local maxLength = (config.employees and config.employees.maxPostLength) or 512
  local post = {
    id = makeId("post"),
    author = record.username,
    displayName = record.displayName or record.username,
    text = capEmployeeText(text, maxLength),
    createdAt = timestamp(),
  }
  table.insert(state.social.feed, 1, post)

  local maxItems = (config.employees and config.employees.maxFeedItems) or 100
  while #state.social.feed > maxItems do
    table.remove(state.social.feed)
  end

  saveSocial()
  audit("SOCIAL_POST", { author = record.username, id = post.id })
  broadcastEventNotification("social", "Facility Feed", tostring(post.displayName or post.author) .. ": " .. truncate(post.text or "", 80), "info", {
    postId = post.id,
    author = post.author,
  })
  return post
end

function sendDirectMessage(record, toUser, text)
  local target = employeeRecord(toUser)
  if not target then
    return false, "unknown recipient"
  end

  local maxLength = (config.employees and config.employees.maxMessageLength) or 512
  local message = {
    id = makeId("msg"),
    from = record.username,
    fromName = record.displayName or record.username,
    to = target.username,
    text = capEmployeeText(text, maxLength),
    createdAt = timestamp(),
  }

  table.insert(socialMailbox(target.username), 1, message)
  table.insert(socialMailbox(record.username), 1, shallowCopy(message))
  saveSocial()
  audit("SOCIAL_DM", { from = record.username, to = target.username, id = message.id })
  broadcastKioskNotification(makeNotification("dm", "Direct Message", tostring(message.fromName or message.from) .. ": " .. truncate(message.text or "", 80), "info", {
    messageId = message.id,
    from = message.from,
    to = message.to,
  }), target.username)
  return true
end

function employeeList()
  local out = {}
  for _, username in ipairs(tableKeys(state.accounts.users)) do
    local record = state.accounts.users[username]
    if record and not record.disabled then
      table.insert(out, publicEmployee(record))
    end
  end
  return out
end

function requireEmployeePermission(token, permission)
  local record = sessionRecord(token)
  if not record then
    return nil, "session expired"
  end
  if not employeeCan(record, permission) then
    return nil, "clearance denied"
  end
  return record
end

function statusSnapshot()
  local doors = {}
  for _, doorId in ipairs(tableKeys(config.doors)) do
    local door = config.doors[doorId]
    local doorState = getDoorState(doorId)
    doors[doorId] = {
      label = door.label or doorId,
      locked = doorState.locked,
      openUntil = doorState.openUntil,
      lastActor = doorState.lastActor,
    }
  end

  local sensors = {}
  for key, detail in pairs(state.sensorDetails or {}) do
    local item
    if type(detail) == "table" then
      item = shallowCopy(detail)
    else
      item = { value = detail }
    end
    item.fault = state.sensors and state.sensors[key] and true or false
    sensors[key] = item
  end

  for key, active in pairs(state.sensors or {}) do
    if sensors[key] == nil and (string.find(tostring(key), "sensor:", 1, true) == 1 or string.find(tostring(key), "auto_stress:", 1, true) == 1 or string.find(tostring(key), "emergency:", 1, true) == 1) then
      sensors[key] = {
        active = active and true or false,
        fault = active and true or false,
      }
    end
  end

  return {
    site = config.siteName,
    facilityName = (displayBranding()).facilityName,
    branding = publicBrandPayload(),
    serverTimeMillis = nowMillis(),
    alarm = {
      active = state.alarm.active,
      reason = state.alarm.reason,
      door = state.alarm.door,
      actor = state.alarm.actor,
      profile = state.alarm.profile,
      sinceMillis = state.alarm.sinceMillis,
      soundStartAt = state.alarm.soundStartAt,
      sourceKey = state.alarm.sourceKey,
      sourceAutoReset = state.alarm.sourceAutoReset,
    },
    lockdown = state.lockdown,
    doors = doors,
    sensors = sensors,
    employees = state.accounts and state.accounts.users and #tableKeys(state.accounts.users) or 0,
    sessions = #tableKeys(state.sessions or {}),
  }
end

function cleanConfigId(value, fallback)
  local text = string.lower(tostring(value or fallback or "item"))
  text = string.gsub(text, "%s+", "_")
  text = string.gsub(text, "[^%w_%-]", "")
  if text == "" then
    text = tostring(fallback or "item")
  end
  return text
end

function setupClearanceLevel()
  return tonumber(config.setup and config.setup.clearance) or permissionLevel("setupFacility")
end

function employeeCanSetup(record)
  return employeeClearance(record) >= setupClearanceLevel()
end

function requireSetupPermission(token)
  local record = sessionRecord(token)
  if not record then
    return nil, "session expired"
  end
  if config.setup and config.setup.enabled == false then
    return nil, "setup disabled"
  end
  if not employeeCanSetup(record) then
    audit("SETUP_DENIED", { user = record.username, clearance = employeeClearance(record) })
    return nil, "clearance denied"
  end
  return record
end

function setupBool(value, defaultValue)
  if value == nil or value == "" then
    return defaultValue
  end
  local text = string.lower(tostring(value))
  return text == "y" or text == "yes" or text == "true" or text == "1" or value == true
end

function setupList(value)
  if type(value) == "table" then
    return shallowCopy(value)
  end
  local out = {}
  for item in string.gmatch(tostring(value or ""), "([^,]+)") do
    item = string.gsub(item, "^%s+", "")
    item = string.gsub(item, "%s+$", "")
    if item ~= "" then
      table.insert(out, item)
    end
  end
  return out
end

function setupEndpointFromValue(value, defaultSide, controller)
  if type(value) == "table" then
    local endpoint = shallowCopy(value)
    if endpoint.side == nil or endpoint.side == "" then
      endpoint.side = defaultSide
    end
    if controller and controller ~= "" and controller ~= "server" and controller ~= "local" and endpointController(endpoint) == nil then
      endpoint.controller = controller
    end
    return endpoint
  end

  local endpoint = { side = tostring(value or defaultSide or "back") }
  if controller and controller ~= "" and controller ~= "server" and controller ~= "local" then
    endpoint.controller = controller
  end
  return endpoint
end

function setupSummary()
  local doors = {}
  for _, doorId in ipairs(tableKeys(config.doors)) do
    local door = config.doors[doorId]
    table.insert(doors, {
      id = doorId,
      label = door.label or doorId,
      controller = door.controller or door.computerId or "server",
      output = door.output or door.outputs,
      contact = door.contact,
      requestExit = door.requestExit,
    })
  end

  return {
    computerId = localComputerId(),
    setupClearance = setupClearanceLevel(),
    peripherals = peripheralSummary(),
    doors = doors,
    readers = shallowCopy(config.readers or {}),
    sensors = shallowCopy(config.sensors or {}),
    emergencyButtons = shallowCopy(config.emergencyButtons or {}),
    generators = shallowCopy(config.generators or {}),
  }
end

function setupScanController(controller)
  if controller == nil or controller == "" or controller == "server" or controller == "local" or tostring(controller) == tostring(localComputerId() or "") then
    return true, { controllerId = localComputerId(), peripherals = peripheralSummary() }
  end

  local ok, err, reply = remoteControllerRequest(controller, { op = "controller_scan" })
  if ok and reply then
    return true, reply
  end
  return false, err or "scan failed"
end

function methodSetFromList(methods)
  local out = {}
  if type(methods) == "table" then
    for _, method in ipairs(methods) do
      out[tostring(method)] = true
    end
  end
  return out
end

function peripheralItemHintText(item)
  local parts = { tostring(item and item.name or "") }
  if type(item) == "table" and type(item.types) == "table" then
    for _, typeName in ipairs(item.types) do
      table.insert(parts, tostring(typeName))
    end
  elseif type(item) == "table" and item.types then
    table.insert(parts, tostring(item.types))
  end
  if type(item) == "table" and type(item.methods) == "table" then
    for _, method in ipairs(item.methods) do
      table.insert(parts, tostring(method))
    end
  end
  return table.concat(parts, " ")
end

function peripheralItemLooksCredentialReader(item)
  if type(item) ~= "table" then
    return false
  end
  if item.reader == true then
    return true
  end

  local hint = peripheralItemHintText(item)
  if textContainsAny(hint, { "nfc", "rfid", "badge", "card" }) then
    return true
  end

  local methodSet = methodSetFromList(item.methods)
  for _, method in ipairs(genericBadgeMethods) do
    if methodSet[method] then
      if methodLooksCredentialSpecific(method) then
        return true
      end
      if genericCredentialMethods[method] and textContainsAny(hint, { "reader", "scanner" }) then
        return true
      end
    end
  end
  return false
end

function readerSourceForController(controller, peripheralName)
  local controllerText = tostring(controller or "")
  if controllerText == "" or controllerText == "server" or controllerText == "local" then
    return tostring(peripheralName or "")
  end
  return "controller:" .. controllerText .. ":" .. tostring(peripheralName or "")
end

function readerSourcesFromSummary(items, controller)
  local out = {}
  local seen = {}
  if type(items) ~= "table" then
    return out
  end

  for _, item in ipairs(items) do
    if item and item.name and peripheralItemLooksCredentialReader(item) then
      local source = readerSourceForController(controller, item.name)
      if source ~= "" and not seen[source] then
        seen[source] = true
        table.insert(out, {
          name = item.name,
          source = source,
          types = item.types,
        })
      end
    end
  end
  return out
end

function normalizeReaderSourceInput(value)
  local text = tostring(value or "")
  local lower = string.lower(text)
  if lower == "none" or lower == "skip" or lower == "-" then
    return ""
  end
  return text
end

function printReaderSourceHints(items, controller)
  local readers = readerSourcesFromSummary(items, controller)
  if #readers == 0 then
    print("No likely NFC/RFID/card readers reported.")
    if controller and controller ~= "" and controller ~= "server" and controller ~= "local" then
      print("Manual format: controller:" .. tostring(controller) .. ":<peripheral>")
    else
      print("Manual format: <server peripheral>, for example nfc_reader_0")
    end
    return nil
  end

  print("Reader sources to map:")
  for _, reader in ipairs(readers) do
    local types = type(reader.types) == "table" and table.concat(reader.types, ",") or tostring(reader.types or "?")
    print("  " .. truncate(reader.source, 48) .. " [" .. truncate(types, 18) .. "]")
  end
  return readers[1].source
end

function setupReaderSourceHints(controller)
  print("Scanning for NFC/RFID/card readers...")
  local ok, scan = setupScanController(controller)
  local sourceController = controller
  if sourceController == nil or sourceController == "" or sourceController == "server" or sourceController == "local" or tostring(sourceController) == tostring(localComputerId() or "") then
    sourceController = "server"
  end
  if ok then
    return printReaderSourceHints(scan.peripherals or {}, sourceController), scan
  end
  print("Reader scan failed: " .. tostring(scan))
  return nil, nil
end

function saveSetupChange(actor, action, detail)
  saveConfig()
  audit("SETUP_CHANGE", {
    actor = actor,
    action = action,
    detail = detail,
  })
  markDirty()
end

function applySetupDoor(message, actor)
  config.doors = config.doors or {}
  config.readers = config.readers or {}

  local doorId = cleanConfigId(message.id or message.doorId or message.name, "door")
  local existing = config.doors[doorId] or {}
  local controller = tostring(message.controller or message.controllerId or existing.controller or config.setup.defaultDoorController or "server")
  local output = setupEndpointFromValue(message.output or message.endpoint or message.outputSide, config.setup.defaultDoorSide or "front", controller)

  local door = shallowCopy(existing)
  door.label = tostring(message.label or message.name or existing.label or doorId)
  door.controller = controller
  door.output = output
  door.outputs = nil
  door.activeOpen = setupBool(message.activeOpen, existing.activeOpen ~= false)
  door.openSeconds = tonumber(message.openSeconds) or tonumber(existing.openSeconds) or tonumber(config.defaultOpenSeconds) or 4
  door.alarmOnDenied = setupBool(message.alarmOnDenied, existing.alarmOnDenied ~= false)
  door.badges = existing.badges or {}
  door.players = existing.players or {}
  door.pins = existing.pins or {}

  if message.contact or message.contactSide then
    door.contact = setupEndpointFromValue(message.contact or message.contactSide, config.setup.defaultContactSide or "back", controller)
    if message.contactOpenWhen ~= nil then
      door.contact.openWhen = setupBool(message.contactOpenWhen, true)
    end
  end
  if message.requestExit or message.exitSide then
    door.requestExit = setupEndpointFromValue(message.requestExit or message.exitSide, config.setup.defaultExitSide or "right", controller)
    if message.exitActiveWhen ~= nil then
      door.requestExit.activeWhen = setupBool(message.exitActiveWhen, true)
    end
  end

  config.doors[doorId] = door
  if message.reader and tostring(message.reader) ~= "" then
    config.readers[tostring(message.reader)] = doorId
  end

  getDoorState(doorId)
  saveSetupChange(actor, "door", { door = doorId, controller = controller })
  return true, "door saved", { door = doorId }
end

function applySetupSensor(message, actor)
  config.sensors = config.sensors or {}

  local sensorType = tostring(message.sensorType or message.type or "redstone")
  local sensor = {
    id = cleanConfigId(message.id or message.name, "sensor"),
    name = tostring(message.name or message.label or "Facility Sensor"),
    profile = tostring(message.profile or "facility_fault"),
  }

  if sensorType == "create_stress" or sensorType == "create_power" or sensorType == "stressometer" then
    sensor.type = "create_stress"
    sensor.peripheral = tostring(message.peripheral or message.name or "")
    sensor.maxLoad = tonumber(message.maxLoad) or 0.9
    sensor.profile = tostring(message.profile or "power_fault")
  elseif sensorType == "entity" or sensorType == "entity_detector" or sensorType == "mob" or sensorType == "hostile_entity" then
    sensor.type = "entity"
    sensor.peripheral = tostring(message.peripheral or "")
    if sensor.peripheral == "" then
      sensor.peripheral = nil
      sensor.autoDiscover = true
    end
    sensor.method = message.method ~= "" and message.method or nil
    sensor.radius = tonumber(message.radius or message.range) or 64
    sensor.entities = setupList(message.entities or message.targets or "minecraft:warden,minecraft:wither")
    sensor.profile = tostring(message.profile or "emergency")
    sensor.actor = "entity_detector"
    sensor.autoResetAlarm = setupBool(message.autoResetAlarm or message.autoReset, true)
    sensor.autoResetSeconds = tonumber(message.autoResetSeconds) or 8
  elseif sensorType == "peripheral" or sensorType == "generic" then
    sensor.type = "peripheral"
    sensor.peripheral = tostring(message.peripheral or "")
    sensor.method = tostring(message.method or "")
    sensor.field = message.field ~= "" and message.field or nil
    sensor.min = tonumber(message.min)
    sensor.max = tonumber(message.max)
    sensor.alarmWhen = message.alarmWhen
  else
    sensor.type = "redstone"
    sensor.input = setupEndpointFromValue(message.input or message.side, tostring(message.side or "left"), message.controller or message.controllerId)
    sensor.alarmWhen = setupBool(message.alarmWhen, true)
  end

  table.insert(config.sensors, sensor)
  saveSetupChange(actor, "sensor", { sensor = sensor.name, type = sensor.type })
  return true, "sensor saved", { sensor = sensor }
end

function applySetupEmergencyButton(message, actor)
  config.emergencyButtons = config.emergencyButtons or {}
  local button = {
    id = cleanConfigId(message.id or message.name, "emergency"),
    name = tostring(message.name or "Emergency Button"),
    input = setupEndpointFromValue(message.input or message.side, tostring(message.side or "top"), message.controller or message.controllerId),
    activeWhen = setupBool(message.activeWhen, true),
    profile = tostring(message.profile or "emergency"),
    reason = tostring(message.reason or "emergency button"),
  }
  table.insert(config.emergencyButtons, button)
  saveSetupChange(actor, "emergency_button", { button = button.name })
  return true, "emergency button saved", { button = button }
end

function applySetupReader(message, actor)
  local source = tostring(message.source or message.reader or "")
  local doorId = tostring(message.door or message.doorId or "")
  if source == "" or doorId == "" or not (config.doors and config.doors[doorId]) then
    return false, "reader source and existing door id required"
  end

  config.readers = config.readers or {}
  config.readers[source] = doorId
  saveSetupChange(actor, "reader", { source = source, door = doorId })
  return true, "reader mapped", { source = source, door = doorId }
end

function removeReaderDoorValue(mapped, doorId)
  if type(mapped) == "table" then
    local out = {}
    local changed = false
    for _, item in ipairs(mapped) do
      if tostring(item) == tostring(doorId) then
        changed = true
      else
        table.insert(out, item)
      end
    end
    if #out == 0 then
      return nil, changed
    end
    return out, changed
  end

  if tostring(mapped) == tostring(doorId) then
    return nil, true
  end
  return mapped, false
end

function removeReaderMappingsForDoor(doorId)
  local removed = {}
  config.readers = config.readers or {}
  for source, mapped in pairs(config.readers) do
    local nextValue, changed = removeReaderDoorValue(mapped, doorId)
    if changed then
      removed[#removed + 1] = source
      config.readers[source] = nextValue
    end
  end
  return removed
end

function setupListItemMatches(item, selector)
  selector = tostring(selector or "")
  if selector == "" or type(item) ~= "table" then
    return false
  end

  local cleanSelector = cleanConfigId(selector, selector)
  local keys = { "id", "name", "label", "peripheral", "source", "localSource" }
  for _, key in ipairs(keys) do
    local value = item[key]
    if value ~= nil and (tostring(value) == selector or cleanConfigId(value, value) == cleanSelector) then
      return true
    end
  end
  return false
end

function removeSetupListItem(list, selector)
  if type(list) ~= "table" then
    return nil, nil
  end

  local index = tonumber(selector)
  if index and list[index] then
    return table.remove(list, index), index
  end

  for itemIndex, item in ipairs(list) do
    if setupListItemMatches(item, selector) then
      return table.remove(list, itemIndex), itemIndex
    end
  end
  return nil, nil
end

function applyRemoveSetupDoor(message, actor)
  local doorId = tostring(message.door or message.doorId or message.id or "")
  if doorId == "" or not (config.doors and config.doors[doorId]) then
    return false, "unknown door"
  end

  pcall(lockDoor, doorId, "setup_remove", true)
  config.doors[doorId] = nil
  state.doors[doorId] = nil
  local removedReaders = {}
  if message.keepReaders ~= true then
    removedReaders = removeReaderMappingsForDoor(doorId)
  end
  saveSetupChange(actor, "remove_door", { door = doorId, removedReaders = removedReaders })
  return true, "door removed", { door = doorId, removedReaders = removedReaders }
end

function applyRemoveSetupSensor(message, actor)
  config.sensors = config.sensors or {}
  local removed, index = removeSetupListItem(config.sensors, message.selector or message.sensor or message.id or message.index or message.name)
  if not removed then
    return false, "sensor not found"
  end
  saveSetupChange(actor, "remove_sensor", { index = index, sensor = removed.name or removed.id or removed.peripheral })
  return true, "sensor removed", { sensor = removed, index = index }
end

function applyRemoveSetupEmergency(message, actor)
  config.emergencyButtons = config.emergencyButtons or {}
  local removed, index = removeSetupListItem(config.emergencyButtons, message.selector or message.button or message.id or message.index or message.name)
  if not removed then
    return false, "emergency button not found"
  end
  saveSetupChange(actor, "remove_emergency_button", { index = index, button = removed.name or removed.id })
  return true, "emergency button removed", { button = removed, index = index }
end

function applyRemoveSetupGenerator(message, actor)
  config.generators = config.generators or {}
  local removed, index = removeSetupListItem(config.generators, message.selector or message.generator or message.id or message.index or message.name)
  if not removed then
    return false, "generator not found"
  end
  saveSetupChange(actor, "remove_generator", { index = index, generator = removed.name or removed.id or removed.peripheral })
  return true, "generator removed", { generator = removed, index = index }
end

function applyRemoveSetupReader(message, actor)
  local source = tostring(message.source or message.reader or message.selector or "")
  if source == "" or not (config.readers and config.readers[source] ~= nil) then
    return false, "reader mapping not found"
  end

  local old = config.readers[source]
  config.readers[source] = nil
  saveSetupChange(actor, "remove_reader", { source = source, previous = old })
  return true, "reader mapping removed", { source = source }
end

function applySetupIssueBadge(message, actor)
  local ok, result = issueEmployeeBadge(message.username or message.user, message.data or message.badge or message.credential, actor, message.doorAccess)
  if not ok then
    return false, result
  end
  return true, "badge issued", { data = result, credential = "badge:" .. tostring(result) }
end

function handleSetupAction(message, actor)
  local action = tostring(message.action or "summary")
  if action == "summary" then
    return true, "summary", { summary = setupSummary() }
  elseif action == "scan" then
    local ok, result = setupScanController(message.controller or message.controllerId)
    return ok, ok and "scan complete" or result, ok and { scan = result } or nil
  elseif action == "add_door" or action == "door" then
    return applySetupDoor(message, actor)
  elseif action == "add_sensor" or action == "sensor" then
    return applySetupSensor(message, actor)
  elseif action == "add_emergency" or action == "emergency_button" then
    return applySetupEmergencyButton(message, actor)
  elseif action == "map_reader" or action == "reader" then
    return applySetupReader(message, actor)
  elseif action == "issue_badge" or action == "badge" then
    return applySetupIssueBadge(message, actor)
  elseif action == "remove_door" then
    return applyRemoveSetupDoor(message, actor)
  elseif action == "remove_sensor" then
    return applyRemoveSetupSensor(message, actor)
  elseif action == "remove_emergency" or action == "remove_emergency_button" then
    return applyRemoveSetupEmergency(message, actor)
  elseif action == "remove_generator" then
    return applyRemoveSetupGenerator(message, actor)
  elseif action == "remove_reader" then
    return applyRemoveSetupReader(message, actor)
  end
  return false, "unknown setup action"
end

function handleStatusMessage(reply)
  reply.ok = true
  reply.status = statusSnapshot()
end

function handleKioskHelloMessage(reply)
  reply.ok = true
  reply.serverId = os.getComputerID and os.getComputerID() or nil
  reply.branding = publicBrandPayload()
  reply.status = statusSnapshot()
end

function handleKioskLoginMessage(sender, message, reply)
  local ok, record = verifyEmployee(message.username, message.pin)
  if ok then
    reply.ok = true
    reply.token = createSession(record.username, sender)
    reply.user = publicEmployee(record)
    reply.branding = publicBrandPayload()
    audit("EMPLOYEE_LOGIN", { user = record.username, sender = sender })
  else
    reply.error = "invalid login"
    audit("EMPLOYEE_LOGIN_DENIED", { user = message.username, sender = sender })
  end
end

function handleKioskBadgeLoginMessage(sender, message, reply)
  local candidates = message.candidates
  if type(candidates) ~= "table" or #candidates == 0 then
    if message.data or message.badge or message.credential then
      candidates = badgeAliases(message.kind or "badge", message.data or message.badge or message.credential)
    end
  end

  local ok, record, credential = verifyEmployeeCredential(candidates or {})
  if ok then
    reply.ok = true
    reply.token = createSession(record.username, sender)
    reply.user = publicEmployee(record)
    reply.branding = publicBrandPayload()
    reply.credential = credential
    audit("EMPLOYEE_BADGE_LOGIN", { user = record.username, sender = sender, credential = credential })
  else
    reply.error = "badge not assigned"
    audit("EMPLOYEE_BADGE_LOGIN_DENIED", { sender = sender, candidates = candidates })
  end
end

function handleKioskRegisterMessage(message, reply)
  local ok, err = registerEmployee(message.username, message.pin, message.displayName)
  reply.ok = ok
  reply.error = err
  reply.branding = publicBrandPayload()
end

function handleKioskLogoutMessage(message, reply)
  if message.token then
    state.sessions[tostring(message.token)] = nil
  end
  reply.ok = true
end

function handleKioskNotesMessage(message, reply)
  local record = sessionRecord(message.token)
  if record then
    reply.ok = true
    reply.notes = notesFor(record.username)
  else
    reply.error = "session expired"
  end
end

function handleKioskSaveNoteMessage(message, reply)
  local record = sessionRecord(message.token)
  if record then
    local ok, id, err = addEmployeeNote(record, message.title or "Untitled", message.body or "", message.id)
    reply.ok = ok
    reply.id = id
    reply.error = err
  else
    reply.error = "session expired"
  end
end

function handleKioskDeleteNoteMessage(message, reply)
  local record = sessionRecord(message.token)
  if record then
    reply.ok = deleteEmployeeNote(record, tostring(message.id or ""))
    if not reply.ok then
      reply.error = "note not found"
    end
  else
    reply.error = "session expired"
  end
end

function handleKioskFeedMessage(message, reply)
  local record = sessionRecord(message.token)
  if record then
    reply.ok = true
    reply.feed = state.social.feed
  else
    reply.error = "session expired"
  end
end

function handleKioskPostMessage(message, reply)
  local record, err = requireEmployeePermission(message.token, "postFeed")
  if record then
    reply.ok = true
    reply.post = addFeedPost(record, message.text or "")
  else
    reply.error = err
  end
end

function handleKioskInboxMessage(message, reply)
  local record = sessionRecord(message.token)
  if record then
    reply.ok = true
    reply.messages = socialMailbox(record.username)
  else
    reply.error = "session expired"
  end
end

function handleKioskSendMessage(message, reply)
  local record, err = requireEmployeePermission(message.token, "sendMessage")
  if record then
    local ok, sendErr = sendDirectMessage(record, message.to, message.text or "")
    reply.ok = ok
    reply.error = sendErr
  else
    reply.error = err
  end
end

function handleKioskPeopleMessage(message, reply)
  local record = sessionRecord(message.token)
  if record then
    reply.ok = true
    reply.people = employeeList()
  else
    reply.error = "session expired"
  end
end

function handleKioskStatusMessage(message, reply)
  local record, err = requireEmployeePermission(message.token, "viewStatus")
  if record then
    reply.ok = true
    reply.status = statusSnapshot()
  else
    reply.error = err
  end
end

function handleKioskLogsMessage(message, reply)
  local record, err = requireEmployeePermission(message.token, "viewLogs")
  if record then
    reply.ok = true
    reply.logs = readFacilityLogsFor(record, message.limit)
    reply.clearance = employeeClearance(record)
  else
    reply.error = err
  end
end

function handleKioskConfigMessage(reply)
  if config.configSync and config.configSync.enabled == false then
    reply.error = "config sync disabled"
    return
  end
  if config.configSync and config.configSync.allowKioskPull == false then
    reply.error = "config sync denied"
    return
  end

  reply.ok = true
  reply.config = publicKioskConfig()
  reply.configVersion = tostring(config.configVersion or config.updatedAt or nowMillis())
end

function handleKioskSetupMessage(message, reply)
  if config.setup and config.setup.kiosk == false then
    reply.error = "kiosk setup disabled"
    return
  end

  local action = tostring(message.action or "summary")
  local record, err
  if action == "issue_badge" or action == "badge" then
    record, err = requireEmployeePermission(message.token, "issueBadges")
  else
    record, err = requireSetupPermission(message.token)
  end
  if not record then
    reply.error = err
    return
  end

  local ok, result, extra = handleSetupAction(message, record.username)
  reply.ok = ok
  if ok then
    reply.message = result
  else
    reply.error = result
  end
  if type(extra) == "table" then
    for key, value in pairs(extra) do
      reply[key] = value
    end
  end
end

function kioskSecurityPermission(action)
  if action == "emergency" then
    return "triggerEmergency"
  elseif action == "reset_alarm" then
    return "resetAlarm"
  elseif action == "lockdown" or action == "unlockdown" then
    return "lockdown"
  elseif action == "unlock_door" or action == "lock_door" then
    return "operateDoors"
  elseif action == "personnel_request" then
    return "sendMessage"
  elseif action == "quit_kiosk" then
    return "quitKiosk"
  elseif action == "setup" then
    return "setupFacility"
  end
  return "triggerAlarm"
end

function handleKioskDoorAction(action, record, message, reply)
  local doorId = tostring(message.door or "")
  if not config.doors[doorId] then
    reply.error = "unknown door"
  elseif action == "unlock_door" then
    local ok, doorErr = unlockDoor(doorId, record.username, message.seconds, "employee")
    reply.ok = ok
    reply.error = doorErr
  else
    local ok, doorErr = lockDoor(doorId, "employee")
    reply.ok = ok
    reply.error = doorErr
  end
end

function handleKioskSecurityActionMessage(sender, message, reply)
  local action = tostring(message.action or "")
  local record, err = requireEmployeePermission(message.token, kioskSecurityPermission(action))
  if not record then
    reply.error = err
  elseif action == "emergency" then
    raiseAlarm(tostring(message.reason or "employee emergency"), nil, record.username, "emergency")
    reply.ok = true
  elseif action == "alarm" then
    raiseAlarm(tostring(message.reason or "employee alarm"), nil, record.username, message.profile or "security")
    reply.ok = true
  elseif action == "personnel_request" then
    local requester = record.displayName or record.username
    local personnel = tostring(message.personnel or message.person or message.name or "available personnel")
    if personnel == "" then
      personnel = "available personnel"
    end
    local area = tostring(message.area or message.location or "")
    if area == "" and message.door then
      area = doorAnnouncementFields(message.door).area
    end
    if area == "" then
      area = "unspecified area"
    end
    local personnelFields = personnelRequestFields(message, personnel)
    local reasonFields = personnelReasonFields(message)
    audit("PERSONNEL_REQUEST", {
      actor = record.username,
      requester = requester,
      personnel = personnel,
      personnelRole = personnelFields.personnelRole,
      personnelTitle = personnelFields.personnelTitle,
      personnelReason = reasonFields.personnelReasonLabel,
      area = area,
      door = message.door,
    })
    broadcastEventNotification("personnel_request", "Personnel Request", tostring(personnel) .. " requested in " .. tostring(area) .. " for " .. tostring(reasonFields.personnelReasonLabel), "info", {
      actor = record.username,
      requester = requester,
      personnel = personnel,
      personnelKey = announcementKey(personnel),
      personnelRole = personnelFields.personnelRole,
      personnelRoleKey = personnelFields.personnelRoleKey,
      personnelTitle = personnelFields.personnelTitle,
      personnelTitleKey = personnelFields.personnelTitleKey,
      personnelVoiceLine = personnelFields.personnelVoiceLine,
      personnelNameVoiceLine = personVoiceLineId(personnel),
      personnelUsername = personnelFields.personnelUsername,
      personnelReason = reasonFields.personnelReason,
      personnelReasonKey = reasonFields.personnelReasonKey,
      personnelReasonLabel = reasonFields.personnelReasonLabel,
      personnelReasonVoiceLine = reasonFields.personnelReasonVoiceLine,
      area = area,
      areaKey = announcementKey(area),
      areaVoiceLine = placeVoiceLineId(area),
      door = message.door,
    })
    reply.ok = true
  elseif action == "reset_alarm" then
    resetAlarm(record.username)
    reply.ok = true
  elseif action == "lockdown" then
    state.lockdown = true
    for _, doorId in ipairs(tableKeys(config.doors)) do
      lockDoor(doorId, "employee_lockdown", true)
    end
    audit("LOCKDOWN", { actor = record.username, source = "kiosk" })
    markDirty()
    broadcastAlarmState()
    broadcastLockdownNotification(true, record.username, "kiosk")
    reply.ok = true
  elseif action == "unlockdown" then
    state.lockdown = false
    audit("LOCKDOWN_CLEAR", { actor = record.username, source = "kiosk" })
    markDirty()
    broadcastAlarmState()
    broadcastLockdownNotification(false, record.username, "kiosk")
    reply.ok = true
  elseif action == "unlock_door" or action == "lock_door" then
    handleKioskDoorAction(action, record, message, reply)
  elseif action == "quit_kiosk" then
    audit("KIOSK_QUIT", { actor = record.username, sender = sender })
    reply.ok = true
  else
    reply.error = "unknown security action"
  end
end

function handleFacilityFaultMessage(sender, message, reply)
  local requiredKey = config.facility and config.facility.remoteSensorKey
  if requiredKey and tostring(message.key or "") ~= tostring(requiredKey) then
    reply.error = "denied"
  else
    local profile = message.profile or message.alarmProfile or "facility_fault"
    raiseAlarm(tostring(message.reason or "remote facility fault"), nil, "remote:" .. tostring(sender), profile)
    audit("REMOTE_SENSOR_FAULT", {
      sender = sender,
      profile = profile,
      sensor = message.sensor,
      detail = message.detail,
    })
    reply.ok = true
  end
end

function handleControllerCredentialMessage(sender, message, reply)
  local source = tostring(message.source or ("controller:" .. tostring(sender) .. ":" .. tostring(message.localSource or "reader")))
  local candidates = message.candidates
  if type(candidates) ~= "table" or #candidates == 0 then
    candidates = badgeAliases(message.kind or "badge", message.data or message.badge or message.credential or "")
  end
  if #candidates == 0 then
    reply.error = "missing credential"
    return
  end

  handleCredentials(source, message.kind or "badge", candidates, message.meta or {
    name = source,
    source = source,
  }, "controller:" .. tostring(sender) .. ":" .. table.concat(candidates, "|"))
  reply.ok = true
end

function handleUnlockCredentialMessage(sender, message, doorId, reply)
  local credential = tostring(message.credential or message.badge)
  local candidates = { credential }
  if not string.find(credential, ":", 1, true) then
    appendUnique(candidates, "badge:" .. credential)
  end

  local actor = "rednet:" .. tostring(sender)
  local allowed = authorizedCredential(doorId, "badge", candidates, { name = actor })
  if allowed then
    local ok, err = unlockDoor(doorId, actor, message.seconds, "rednet_credential")
    reply.ok = ok
    reply.error = err
  else
    denyAccess(doorId, actor, "rednet", "credential_rejected")
    reply.error = "denied"
  end
end

function handleUnlockMessage(sender, message, reply)
  local doorId = tostring(message.door or "")
  local actor = "rednet:" .. tostring(sender)
  if not config.doors[doorId] then
    reply.error = "unknown door"
  elseif message.pin and authorizedPin(doorId, message.pin) then
    local ok, err = unlockDoor(doorId, actor, message.seconds, "rednet_pin")
    reply.ok = ok
    reply.error = err
  elseif message.credential or message.badge then
    handleUnlockCredentialMessage(sender, message, doorId, reply)
  else
    reply.error = "missing pin or credential"
  end
end

function handleResetAlarmMessage(sender, message, reply)
  if authorizedAdminPin(message.adminPin) then
    resetAlarm("rednet:" .. tostring(sender))
    reply.ok = true
  else
    reply.error = "denied"
  end
end

function networkRebootMessage(reason)
  return {
    op = "network_reboot",
    reason = reason or "server command",
    rebootAtMillis = nowMillis() + 750,
  }
end

function broadcastNetworkReboot(reason)
  if not (config and config.rednet and config.rednet.enabled and rednet) then
    return false, "rednet unavailable"
  end

  openRednet()
  local message = networkRebootMessage(reason)
  local sentAny = false
  local lastErr = nil
  for _ = 1, 3 do
    local ok, result = pcall(broadcastRednet, message)
    if ok and result ~= false then
      sentAny = true
    else
      lastErr = result or "broadcast failed"
    end
    sleep(0.1)
  end
  if not sentAny then
    return false, lastErr or "broadcast failed"
  end
  audit("NETWORK_REBOOT", reason or "console")
  return true
end

function rebootServerAfterNetworkBroadcast(reason)
  local ok, err = broadcastNetworkReboot(reason)
  if not ok then
    return false, err
  end
  sleep(0.8)
  os.reboot()
  return true
end

function handleNetworkRebootMessage(sender, message)
  if type(message) ~= "table" or not serverSenderAllowed(sender) then
    return false
  end

  updateKioskClockOffset(message, sender)
  local rebootAt = serverMillisToLocalMillis(message.rebootAtMillis) or (nowMillis() + 250)
  local delay = math.max(0, (rebootAt - nowMillis()) / 1000)
  if delay > 0 then
    sleep(math.min(delay, 3))
  end
  os.reboot()
  return true
end

function handleRednetOperation(sender, message, reply)
  local op = message.op
  if op == "status" then
    handleStatusMessage(reply)
  elseif op == "kiosk_hello" then
    handleKioskHelloMessage(reply)
  elseif op == "kiosk_login" then
    handleKioskLoginMessage(sender, message, reply)
  elseif op == "kiosk_badge_login" then
    handleKioskBadgeLoginMessage(sender, message, reply)
  elseif op == "kiosk_register" then
    handleKioskRegisterMessage(message, reply)
  elseif op == "kiosk_logout" then
    handleKioskLogoutMessage(message, reply)
  elseif op == "kiosk_notes" then
    handleKioskNotesMessage(message, reply)
  elseif op == "kiosk_save_note" then
    handleKioskSaveNoteMessage(message, reply)
  elseif op == "kiosk_delete_note" then
    handleKioskDeleteNoteMessage(message, reply)
  elseif op == "kiosk_feed" then
    handleKioskFeedMessage(message, reply)
  elseif op == "kiosk_post" then
    handleKioskPostMessage(message, reply)
  elseif op == "kiosk_inbox" then
    handleKioskInboxMessage(message, reply)
  elseif op == "kiosk_send" then
    handleKioskSendMessage(message, reply)
  elseif op == "kiosk_people" then
    handleKioskPeopleMessage(message, reply)
  elseif op == "kiosk_status" then
    handleKioskStatusMessage(message, reply)
  elseif op == "kiosk_logs" then
    handleKioskLogsMessage(message, reply)
  elseif op == "kiosk_config" or op == "config_sync" then
    handleKioskConfigMessage(reply)
  elseif op == "kiosk_setup" then
    handleKioskSetupMessage(message, reply)
  elseif op == "kiosk_security_action" then
    handleKioskSecurityActionMessage(sender, message, reply)
  elseif op == "controller_hello" then
    reply.ok = true
  elseif op == "controller_credential" then
    handleControllerCredentialMessage(sender, message, reply)
  elseif op == "facility_fault" then
    handleFacilityFaultMessage(sender, message, reply)
  elseif op == "unlock" then
    handleUnlockMessage(sender, message, reply)
  elseif op == "reset_alarm" then
    handleResetAlarmMessage(sender, message, reply)
  else
    reply.error = "unknown op"
  end
end

function handleRednet(sender, message, protocol)
  local wantedProtocol = rednetProtocol()
  if protocol ~= wantedProtocol then
    return
  end

  local decoded, decodeErr = unwrapRednetMessage(message)
  if decoded ~= nil then
    message = decoded
  elseif secureRednet.enabled(config.rednet) then
    audit("REDNET_DECRYPT_DENIED", { sender = sender, error = decodeErr })
    return
  end

  if type(message) == "string" then
    local ok, decoded = pcall(textutils.unserialize, message)
    if ok and type(decoded) == "table" then
      message = decoded
    else
      message = { op = message }
    end
  end

  if type(message) ~= "table" then
    return
  end

  if message.token then
    touchSessionSender(message.token, sender)
  end

  local reply = { ok = false }
  handleRednetOperation(sender, message, reply)
  reply.requestId = message.requestId
  pcall(sendRednet, sender, reply)
end

function monitorNames()
  local out = {}
  if not (config.monitors and config.monitors.enabled) then
    return out
  end

  local now = os.clock()
  local scanSeconds = tonumber(config.monitors.scanSeconds or config.monitors.peripheralScanSeconds) or 15
  if scanSeconds < 2 then
    scanSeconds = 2
  elseif scanSeconds > 120 then
    scanSeconds = 120
  end
  if type(state.monitorNames) == "table" and tonumber(state.monitorNamesAt) and now - state.monitorNamesAt < scanSeconds then
    return state.monitorNames
  end

  for _, name in ipairs(peripheralNames()) do
    if hasPeripheralType(name, "monitor") then
      table.insert(out, name)
    end
  end
  state.monitorNames = out
  state.monitorNamesAt = now
  return out
end

function invalidateMonitorCache()
  state.monitorNames = nil
  state.monitorNamesAt = nil
end

function monitorDeviceConfig(name)
  local monitors = config.monitors or {}
  local devices = monitors.devices or monitors.monitors or {}
  if type(devices) ~= "table" then
    devices = {}
  end
  local device = devices[name] or devices["*"] or {}
  if type(device) == "string" then
    return { view = device }
  end
  if type(device) ~= "table" then
    return {}
  end
  return device
end

function monitorTheme(theme)
  local themes = {
    blue = { bg = colors.blue, fg = colors.white, accent = colors.cyan, dim = colors.lightBlue },
    red = { bg = colors.red, fg = colors.white, accent = colors.yellow, dim = colors.orange },
    green = { bg = colors.green, fg = colors.black, accent = colors.lime, dim = colors.white },
    black = { bg = colors.black, fg = colors.white, accent = colors.cyan, dim = colors.lightGray },
    gray = { bg = colors.gray, fg = colors.white, accent = colors.lime, dim = colors.lightGray },
    purple = { bg = colors.purple, fg = colors.white, accent = colors.pink, dim = colors.magenta },
  }

  if type(theme) == "table" then
    return {
      bg = colorValue(theme.bg or theme.background, colors.black),
      fg = colorValue(theme.fg or theme.text, colors.white),
      accent = colorValue(theme.accent, colors.lime),
      dim = colorValue(theme.dim, colors.lightGray),
    }
  end

  return themes[tostring(theme or "black")] or themes.black
end

function monitorWrite(monitor, x, y, text, fg, bg, width)
  if y < 1 then
    return
  end

  local totalWidth, totalHeight = monitor.getSize()
  if y > totalHeight then
    return
  end

  local maxWidth = width
  if maxWidth == nil then
    maxWidth = totalWidth - x + 1
  end
  if maxWidth <= 0 then
    return
  end

  if bg then
    monitor.setBackgroundColor(bg)
  end
  if fg then
    monitor.setTextColor(fg)
  end
  monitor.setCursorPos(x, y)
  monitor.write(string.sub(tostring(text or ""), 1, maxWidth))
end

function monitorFill(monitor, y, bg, fg, text)
  local width, height = monitor.getSize()
  if y < 1 or y > height then
    return
  end
  monitor.setCursorPos(1, y)
  monitor.setBackgroundColor(bg or colors.black)
  monitor.setTextColor(fg or colors.white)
  monitor.write(string.rep(" ", width))
  if text then
    monitor.setCursorPos(1, y)
    monitor.write(string.sub(tostring(text), 1, width))
  end
end

function monitorCenter(monitor, y, text, fg, bg)
  local width = monitor.getSize()
  text = tostring(text or "")
  local x = math.max(1, math.floor((width - string.len(text)) / 2) + 1)
  monitorWrite(monitor, x, y, text, fg, bg, width - x + 1)
end

function monitorRule(monitor, y, fg)
  local width = monitor.getSize()
  monitorWrite(monitor, 1, y, string.rep("-", width), fg or colors.gray, colors.black, width)
end

function monitorBar(monitor, x, y, width, value, fg, bg)
  width = math.max(3, tonumber(width) or 3)
  value = tonumber(value) or 0
  if value < 0 then
    value = 0
  elseif value > 1 then
    value = 1
  end

  local inner = math.max(1, width - 2)
  local filled = math.floor(inner * value + 0.5)
  local text = "[" .. string.rep("#", filled) .. string.rep(".", inner - filled) .. "]"
  monitorWrite(monitor, x, y, text, fg or colors.lime, bg or colors.black, width)
end

function monitorWrap(text, width)
  local lines = {}
  width = math.max(1, tonumber(width) or 20)
  text = tostring(text or "")

  for rawLine in string.gmatch(text .. "\n", "([^\n]*)\n") do
    local line = rawLine
    while string.len(line) > width do
      local cut = width
      for index = width, 1, -1 do
        if string.sub(line, index, index) == " " then
          cut = index
          break
        end
      end
      table.insert(lines, string.sub(line, 1, cut))
      line = string.gsub(string.sub(line, cut + 1), "^%s+", "")
    end
    table.insert(lines, line)
  end

  return lines
end

function monitorStatusText()
  if state.alarm.active then
    local profile = alarmProfile(state.alarm.profile)
    return tostring(profile.label or "ALARM"), colors.yellow, colors.red
  end
  if state.lockdown then
    return "LOCKDOWN", colors.black, colors.orange
  end
  return "SECURE", colors.black, colors.lime
end

function kioskMonitorStatus()
  if config and tostring(config.mode or "") == "kiosk" and state.kiosk and type(state.kiosk.status) == "table" then
    return state.kiosk.status
  end
  return nil
end

function monitorDoorEntries()
  local status = kioskMonitorStatus()
  if status and type(status.doors) == "table" then
    return status.doors, true
  end
  return config.doors or {}, false
end

function monitorDoorLabel(doorId, door, remote)
  if type(door) == "table" then
    return door.label or door.name or doorId
  end
  return doorId
end

function monitorDoorLocked(doorId, door, remote)
  if remote then
    return door and door.locked and true or false
  end
  return getDoorState(doorId).locked
end

function monitorDoorLastActor(doorId, door, remote)
  if remote and type(door) == "table" then
    return door.lastActor
  end
  return getDoorState(doorId).lastActor
end

function monitorSensorEntries()
  local status = kioskMonitorStatus()
  if status and type(status.sensors) == "table" then
    return status.sensors, true
  end
  return state.sensorDetails or {}, false
end

function monitorSensorActive(key, detail, remote)
  if remote then
    if type(detail) == "table" then
      return detail.fault or detail.triggered or detail.alarm or false
    end
    return false
  end
  return state.sensors and state.sensors[key]
end

function monitorEmergencyEntries()
  local status = kioskMonitorStatus()
  if status and type(status.sensors) == "table" then
    local out = {}
    for key, detail in pairs(status.sensors) do
      if string.find(tostring(key), "emergency:", 1, true) == 1 then
        table.insert(out, {
          name = sensorDisplayName(key),
          active = monitorSensorActive(key, detail, true),
        })
      end
    end
    return out, true
  end

  local out = {}
  for index, button in ipairs(config.emergencyButtons or {}) do
    local key = "emergency:" .. tostring(button.id or button.name or index)
    table.insert(out, {
      name = tostring(button.name or index),
      active = state.sensors[key],
    })
  end
  return out, false
end

function drawMonitorHeader(monitor, title, deviceConfig)
  local width = monitor.getSize()
  local brand = displayBranding()
  local theme = monitorTheme(deviceConfig.theme or (config.monitors and config.monitors.theme) or "blue")
  local shortName = brand.shortName or "SEC"
  local facility = brand.facilityName or config.siteName or "Facility"

  monitorFill(monitor, 1, theme.bg, theme.fg, " " .. shortName .. " | " .. facility)
  monitorFill(monitor, 2, colors.black, theme.accent, " " .. tostring(title or "Status"))

  if config.monitors.alarmBanner ~= false and state.alarm.active then
    local profile = alarmProfile(state.alarm.profile)
    monitorFill(monitor, 3, colors.red, colors.yellow, " " .. tostring(profile.label or "ALARM") .. ": " .. tostring(state.alarm.reason or ""))
    return 5
  end

  local text, fg, bg = monitorStatusText()
  monitorFill(monitor, 3, bg, fg, " " .. text)
  return 5
end

function countDoorStates()
  local locked = 0
  local open = 0
  local total = 0
  local doors, remote = monitorDoorEntries()
  for _, doorId in ipairs(tableKeys(doors)) do
    total = total + 1
    if monitorDoorLocked(doorId, doors[doorId], remote) then
      locked = locked + 1
    else
      open = open + 1
    end
  end
  return locked, open, total
end

function sensorDisplayName(key)
  local name = tostring(key or "sensor")
  name = string.gsub(name, "^sensor:", "")
  name = string.gsub(name, "^auto_stress:", "")
  name = string.gsub(name, "^emergency:", "")
  return name
end

function countActiveFaults()
  local count = 0
  local sensors, remote = monitorSensorEntries()
  for key, detail in pairs(sensors or {}) do
    if monitorSensorActive(key, detail, remote) and (string.find(tostring(key), "sensor:", 1, true) == 1 or string.find(tostring(key), "auto_stress:", 1, true) == 1 or string.find(tostring(key), "emergency:", 1, true) == 1) then
      count = count + 1
    end
  end
  return count
end

function monitorDetailText(detail)
  if type(detail) ~= "table" then
    return tostring(detail or "")
  end
  if detail.load then
    return "load " .. tostring(math.floor(detail.load * 100 + 0.5)) .. "%"
  end
  if detail.stress or detail.capacity then
    return "stress " .. tostring(detail.stress or "?") .. "/" .. tostring(detail.capacity or "?")
  end
  if detail.value ~= nil then
    return "value " .. tostring(detail.value)
  end
  if detail.raw ~= nil then
    return "raw " .. tostring(detail.raw)
  end
  if detail.active ~= nil then
    return "active " .. tostring(detail.active)
  end
  return compact(detail)
end

function drawMonitorOverview(monitor, deviceConfig)
  local width, height = monitor.getSize()
  local y = drawMonitorHeader(monitor, "Facility Overview", deviceConfig)
  local locked, open, total = countDoorStates()
  local faults = countActiveFaults()
  local status = kioskMonitorStatus()
  local employees = status and status.employees or (state.accounts and state.accounts.users and #tableKeys(state.accounts.users) or 0)
  local sessions = status and status.sessions or #tableKeys(state.sessions or {})

  monitorWrite(monitor, 1, y, "Doors", colors.cyan, colors.black, width)
  monitorWrite(monitor, 1, y + 1, "Locked " .. tostring(locked) .. "/" .. tostring(total) .. "  Open " .. tostring(open), open > 0 and colors.yellow or colors.lime, colors.black, width)
  y = y + 3

  monitorWrite(monitor, 1, y, "Facility", colors.cyan, colors.black, width)
  monitorWrite(monitor, 1, y + 1, "Faults " .. tostring(faults) .. "  Employees " .. tostring(employees) .. "  Sessions " .. tostring(sessions), faults > 0 and colors.orange or colors.lightGray, colors.black, width)
  y = y + 3

  if state.alarm.active then
    local profile = alarmProfile(state.alarm.profile)
    monitorWrite(monitor, 1, y, "Active Alarm", colors.yellow, colors.black, width)
    monitorWrite(monitor, 1, y + 1, tostring(profile.label or "Alarm"), colors.yellow, colors.black, width)
    monitorWrite(monitor, 1, y + 2, truncate(state.alarm.reason or "", width), colors.white, colors.black, width)
    y = y + 4
  end

  monitorWrite(monitor, 1, y, "Recent Doors", colors.cyan, colors.black, width)
  y = y + 1
  local doors, remote = monitorDoorEntries()
  for _, doorId in ipairs(tableKeys(doors)) do
    if y > height then
      break
    end
    local door = doors[doorId]
    local lockedState = monitorDoorLocked(doorId, door, remote)
    local statusText = lockedState and "LOCKED" or "OPEN"
    monitorWrite(monitor, 1, y, truncate(monitorDoorLabel(doorId, door, remote) .. ": " .. statusText, width), lockedState and colors.lightGray or colors.lime, colors.black, width)
    y = y + 1
  end
end

function drawMonitorDoors(monitor, deviceConfig)
  local width, height = monitor.getSize()
  local y = drawMonitorHeader(monitor, "Door Matrix", deviceConfig)
  monitorWrite(monitor, 1, y, "Door", colors.cyan, colors.black, math.max(1, width - 12))
  monitorWrite(monitor, math.max(1, width - 8), y, "State", colors.cyan, colors.black, 9)
  y = y + 1
  monitorRule(monitor, y, colors.gray)
  y = y + 1

  local doors, remote = monitorDoorEntries()
  for _, doorId in ipairs(tableKeys(doors)) do
    if y > height then
      break
    end
    local door = doors[doorId]
    local lockedState = monitorDoorLocked(doorId, door, remote)
    local label = truncate(monitorDoorLabel(doorId, door, remote), math.max(8, width - 11))
    local status = lockedState and "LOCKED" or "OPEN"
    local fg = lockedState and colors.lightGray or colors.lime
    monitorWrite(monitor, 1, y, label, fg, colors.black, math.max(1, width - 11))
    monitorWrite(monitor, math.max(1, width - 8), y, status, fg, colors.black, 9)
    y = y + 1
    local lastActor = monitorDoorLastActor(doorId, door, remote)
    if lastActor and y <= height then
      monitorWrite(monitor, 3, y, truncate("by " .. tostring(lastActor), width - 2), colors.gray, colors.black, width - 2)
      y = y + 1
    end
  end
end

function drawMonitorFacility(monitor, deviceConfig)
  local width, height = monitor.getSize()
  local y = drawMonitorHeader(monitor, "Facility Systems", deviceConfig)
  monitorWrite(monitor, 1, y, "Sensors / Power", colors.cyan, colors.black, width)
  y = y + 1
  monitorRule(monitor, y, colors.gray)
  y = y + 1

  local sensors, remote = monitorSensorEntries()
  local keys = tableKeys(sensors or {})
  if #keys == 0 then
    monitorWrite(monitor, 1, y, "No facility sensor data yet.", colors.lightGray, colors.black, width)
    return
  end

  for _, key in ipairs(keys) do
    if y > height then
      break
    end
    local detail = sensors[key]
    local active = monitorSensorActive(key, detail, remote)
    local fg = active and colors.orange or colors.lime
    local name = truncate(sensorDisplayName(key), math.max(8, width - 9))
    monitorWrite(monitor, 1, y, name, fg, colors.black, math.max(1, width - 9))
    monitorWrite(monitor, math.max(1, width - 6), y, active and "FAULT" or "OK", fg, colors.black, 6)
    y = y + 1

    if y > height then
      break
    end
    monitorWrite(monitor, 3, y, truncate(monitorDetailText(detail), width - 2), colors.lightGray, colors.black, width - 2)
    if type(detail) == "table" and detail.load and width >= 18 then
      monitorBar(monitor, 3, y + 1, width - 4, detail.load, detail.load >= 0.9 and colors.red or colors.lime, colors.black)
      y = y + 2
    else
      y = y + 1
    end
  end
end

function drawMonitorSecurity(monitor, deviceConfig)
  local width, height = monitor.getSize()
  local y = drawMonitorHeader(monitor, "Security Control", deviceConfig)
  local profile = alarmProfile(state.alarm.profile)
  monitorWrite(monitor, 1, y, "Alarm", colors.cyan, colors.black, width)
  monitorWrite(monitor, 1, y + 1, state.alarm.active and tostring(profile.label or "ACTIVE") or "Clear", state.alarm.active and colors.yellow or colors.lime, colors.black, width)
  if state.alarm.reason and y + 2 <= height then
    monitorWrite(monitor, 1, y + 2, truncate(state.alarm.reason, width), colors.white, colors.black, width)
  end
  y = y + 4

  if y <= height then
    monitorWrite(monitor, 1, y, "Lockdown: " .. tostring(state.lockdown), state.lockdown and colors.orange or colors.lightGray, colors.black, width)
    y = y + 2
  end

  if y <= height then
    monitorWrite(monitor, 1, y, "Emergency Buttons", colors.cyan, colors.black, width)
    y = y + 1
    local emergencyEntries = monitorEmergencyEntries()
    for _, button in ipairs(emergencyEntries) do
      if y > height then
        break
      end
      local active = button.active
      monitorWrite(monitor, 1, y, truncate(tostring(button.name or "Emergency"), width - 8), active and colors.yellow or colors.lightGray, colors.black, width - 8)
      monitorWrite(monitor, math.max(1, width - 5), y, active and "PUSH" or "IDLE", active and colors.yellow or colors.lime, colors.black, 6)
      y = y + 1
    end
  end
end

function posterList(deviceConfig)
  local posters = deviceConfig.posters or (config.monitors and config.monitors.posters) or {}
  if type(posters) ~= "table" then
    return {}
  end
  return posters
end

function drawMonitorPoster(monitor, deviceConfig)
  local width, height = monitor.getSize()
  local posters = posterList(deviceConfig)
  if #posters == 0 then
    drawMonitorHeader(monitor, "Facility Posters", deviceConfig)
    monitorWrite(monitor, 1, 5, "No posters configured.", colors.lightGray, colors.black, width)
    return
  end

  local seconds = tonumber(deviceConfig.posterSeconds or (config.monitors and config.monitors.posterSeconds)) or 10
  local index = (math.floor(os.clock() / seconds) % #posters) + 1
  local poster = posters[index]
  local theme = monitorTheme(poster.theme or deviceConfig.theme or "blue")

  monitor.setBackgroundColor(theme.bg)
  monitor.setTextColor(theme.fg)
  monitor.clear()

  local y = 2
  if config.monitors.alarmBanner ~= false and state.alarm.active then
    local profile = alarmProfile(state.alarm.profile)
    monitorFill(monitor, 1, colors.red, colors.yellow, " " .. tostring(profile.label or "ALARM") .. ": " .. tostring(state.alarm.reason or ""))
    y = 3
  end

  monitorCenter(monitor, y, truncate(poster.title or "FACILITY NOTICE", width), theme.fg, theme.bg)
  y = y + 2
  if poster.subtitle then
    for _, line in ipairs(monitorWrap(poster.subtitle, width - 2)) do
      if y > height - 2 then
        break
      end
      monitorCenter(monitor, y, line, theme.accent, theme.bg)
      y = y + 1
    end
    y = y + 1
  end

  local body = poster.body or {}
  if type(body) == "string" then
    body = { body }
  end

  for _, item in ipairs(body) do
    for _, line in ipairs(monitorWrap(item, width - 4)) do
      if y > height - 2 then
        break
      end
      monitorCenter(monitor, y, line, theme.fg, theme.bg)
      y = y + 1
    end
    y = y + 1
    if y > height - 2 then
      break
    end
  end

  if poster.footer and height >= 3 then
    monitorFill(monitor, height, theme.bg, theme.dim, truncate(poster.footer, width))
  end
end

function monitorViewFor(name, deviceConfig)
  local view = tostring(deviceConfig.view or deviceConfig.mode or (config.monitors and config.monitors.defaultView) or "overview")
  if view == "cycle" or view == "rotate" or view == "slideshow" then
    local views = deviceConfig.views or (config.monitors and config.monitors.viewRotation) or { "overview", "facility", "doors", "security", "posters" }
    if type(views) ~= "table" or #views == 0 then
      return "overview"
    end

    local seconds = tonumber(deviceConfig.rotateSeconds or (config.monitors and config.monitors.rotateSeconds)) or 14
    local index = (math.floor(os.clock() / seconds) % #views) + 1
    return tostring(views[index])
  end
  return view
end

function monitorViewNeedsPeriodicRedraw(view)
  view = tostring(view or "")
  return view == "cycle"
    or view == "rotate"
    or view == "slideshow"
    or view == "posters"
    or view == "poster"
    or view == "propaganda"
end

function monitorsNeedPeriodicRedraw()
  local monitors = config.monitors or {}
  if monitors.alwaysRedraw then
    return true
  end
  if monitorViewNeedsPeriodicRedraw(monitors.defaultView) then
    return true
  end

  local devices = monitors.devices or monitors.monitors or {}
  if type(devices) == "table" then
    for _, device in pairs(devices) do
      local view = device
      if type(device) == "table" then
        view = device.view or device.mode
      end
      if monitorViewNeedsPeriodicRedraw(view) then
        return true
      end
    end
  end

  return false
end

function drawMonitor(name)
  local monitor = peripheral.wrap(name)
  if not monitor then
    return
  end

  local deviceConfig = monitorDeviceConfig(name)
  local textScale = deviceConfig.textScale or (config.monitors and config.monitors.textScale)
  if monitor.setTextScale and textScale then
    pcall(monitor.setTextScale, textScale)
  end

  monitor.setBackgroundColor(colors.black)
  monitor.setTextColor(colors.white)
  monitor.clear()

  local view = monitorViewFor(name, deviceConfig)
  if view == "facility" or view == "systems" or view == "power" then
    drawMonitorFacility(monitor, deviceConfig)
  elseif view == "doors" or view == "door" then
    drawMonitorDoors(monitor, deviceConfig)
  elseif view == "security" or view == "alarm" then
    drawMonitorSecurity(monitor, deviceConfig)
  elseif view == "posters" or view == "poster" or view == "propaganda" then
    drawMonitorPoster(monitor, deviceConfig)
  else
    drawMonitorOverview(monitor, deviceConfig)
  end
end

function drawMonitors(force)
  local monitors = config.monitors or {}
  if not force and not state.screenDirty and not monitors.alwaysRedraw then
    return
  end

  for _, name in ipairs(monitorNames()) do
    pcall(drawMonitor, name)
  end

  state.screenDirty = false
end

function printStatus()
  local brand = displayBranding()
  print("Facility: " .. tostring(brand.facilityName))
  if state.alarm.active then
    local profile = alarmProfile(state.alarm.profile)
    print("Alarm: ACTIVE - " .. tostring(profile.label) .. " - " .. tostring(state.alarm.reason))
  else
    print("Alarm: clear")
  end
  print("Lockdown: " .. tostring(state.lockdown))

  for _, doorId in ipairs(tableKeys(config.doors)) do
    local door = config.doors[doorId]
    local doorState = getDoorState(doorId)
    local status = doorState.locked and "LOCKED" or "OPEN"
    print(tostring(doorId) .. " (" .. tostring(door.label or doorId) .. "): " .. status)
  end
end

function splitWords(line)
  local words = {}
  for word in string.gmatch(line or "", "%S+") do
    table.insert(words, word)
  end
  return words
end

function joinWords(words, startIndex)
  local parts = {}
  for index = startIndex, #words do
    table.insert(parts, words[index])
  end
  return table.concat(parts, " ")
end

function requireAdmin()
  if os.clock() < state.consoleAdminUntil then
    return true
  end
  print("Admin login required. Use: login <pin>")
  return false
end

function wrapConsoleLine(line, width)
  local out = {}
  line = tostring(line or "")
  width = math.max(1, tonumber(width) or 51)

  if line == "" then
    return { "" }
  end

  while string.len(line) > width do
    table.insert(out, string.sub(line, 1, width))
    line = string.sub(line, width + 1)
  end
  table.insert(out, line)
  return out
end

function waitForHelpPage()
  write("-- more --")
  local _, key = os.pullEvent("key")
  local _, y = term.getCursorPos()
  term.setCursorPos(1, y)
  term.clearLine()
  return keys and key == keys.q
end

function printPaged(lines)
  local width, height = term.getSize()
  local pageLines = math.max(3, height - 3)
  local wrappedLines = {}
  for lineIndex, line in ipairs(lines) do
    local wrapped = wrapConsoleLine(line, width)
    for wrappedIndex, part in ipairs(wrapped) do
      table.insert(wrappedLines, part)
    end
  end

  if #wrappedLines <= pageLines then
    for _, line in ipairs(wrappedLines) do
      print(line)
    end
    return
  end

  local page = 1
  local pages = math.ceil(#wrappedLines / pageLines)
  while true do
    clearScreen()
    print("Page " .. tostring(page) .. "/" .. tostring(pages))
    print(string.rep("-", math.min(width, 28)))

    local first = ((page - 1) * pageLines) + 1
    local last = math.min(#wrappedLines, first + pageLines - 1)
    for index = first, last do
      print(wrappedLines[index])
    end

    print()
    local prompt = page < pages and "[Enter/N] next  [P] prev  [Q] quit: " or "[Enter/Q] close  [P] prev: "
    local choice
    if config and tostring(config.mode or "") == "kiosk" and kioskRead then
      choice = string.lower(kioskRead(prompt) or "")
    else
      write(prompt)
      choice = string.lower(read() or "")
    end

    if choice == "q" then
      return
    elseif choice == "p" and page > 1 then
      page = page - 1
    elseif page < pages then
      page = page + 1
    else
      return
    end
  end
end

function printHelp()
  printPaged({
    "Commands:",
    "  status",
    "  pin <door> <pin>",
    "  login <admin-pin>",
    "  unlock <door> [seconds]",
    "  lock <door>",
    "  alarm <reason>",
    "  emergency <reason>",
    "  announce <message>",
    "  setup",
    "  reset",
    "  lockdown",
    "  unlockdown",
    "  allow badge <door> <credential>",
    "  allow player <door> <player>",
    "  badge writers",
    "  badge write <data> [nfc-peripheral]",
    "  badge issue <user> [data] [nfc-peripheral] [doorAccess]",
    "  employee list",
    "  employee add <user> <pin> [display name]",
    "  employee role <user> <role>",
    "  employee clearance <user> <level>",
    "  employee disable <user>",
    "  employee enable <user>",
    "  save",
    "  reboot [network|clients|server]",
    "  quit",
    "",
    "Paged output uses Enter/N for next, P for previous, and Q to close.",
  })
end

function addDoorCredential(doorId, credential)
  local door = config.doors[doorId]
  if not door then
    print("Unknown door: " .. tostring(doorId))
    return
  end

  door.badges = door.badges or {}
  appendUnique(door.badges, credential)
  audit("CONFIG_ALLOW_BADGE", { door = doorId, credential = credential })
  print("Allowed " .. credential .. " on " .. doorId)
end

function addDoorPlayer(doorId, player)
  local door = config.doors[doorId]
  if not door then
    print("Unknown door: " .. tostring(doorId))
    return
  end

  door.players = door.players or {}
  appendUnique(door.players, player)
  audit("CONFIG_ALLOW_PLAYER", { door = doorId, player = player })
  print("Allowed player " .. player .. " on " .. doorId)
end

function handleEmployeeCommand(words)
  local subcommand = string.lower(words[2] or "")

  if subcommand == "list" then
    for _, person in ipairs(employeeList()) do
      print(person.username .. " - " .. tostring(person.displayName) .. " (" .. tostring(person.role) .. ", C" .. tostring(person.clearance or "?") .. ")")
    end
  elseif subcommand == "add" then
    local username = normalizeUsername(words[3])
    local pin = words[4]
    local displayName = joinWords(words, 5)
    if username == "" or not pin then
      print("Usage: employee add <user> <pin> [display name]")
      return
    end
    if state.accounts.users[username] then
      print("Account already exists")
      return
    end
    state.accounts.users[username] = {
      username = username,
      displayName = displayName ~= "" and displayName or username,
      pin = tostring(pin),
      role = "employee",
      clearance = config.employees and config.employees.defaultClearance or 1,
      createdAt = timestamp(),
    }
    saveAccounts()
    audit("EMPLOYEE_ADD", { user = username, actor = "console" })
    print("Added " .. username)
  elseif subcommand == "role" then
    local username = normalizeUsername(words[3])
    local role = words[4]
    local record = employeeRecord(username)
    if not record or not role then
      print("Usage: employee role <user> <role>")
      return
    end
    record.role = tostring(role)
    saveAccounts()
    audit("EMPLOYEE_ROLE", { user = username, role = role, actor = "console" })
    print("Updated " .. username)
  elseif subcommand == "clearance" then
    local username = normalizeUsername(words[3])
    local level = tonumber(words[4])
    local record = employeeRecord(username)
    if not record or not level then
      print("Usage: employee clearance <user> <level>")
      return
    end
    record.clearance = level
    saveAccounts()
    audit("EMPLOYEE_CLEARANCE", { user = username, clearance = level, actor = "console" })
    print("Updated " .. username .. " clearance to " .. tostring(level))
  elseif subcommand == "disable" or subcommand == "enable" then
    local username = normalizeUsername(words[3])
    local record = employeeRecord(username)
    if not record then
      print("Usage: employee " .. subcommand .. " <user>")
      return
    end
    record.disabled = subcommand == "disable"
    saveAccounts()
    audit("EMPLOYEE_" .. string.upper(subcommand), { user = username, actor = "console" })
    print((record.disabled and "Disabled " or "Enabled ") .. username)
  else
    print("Usage: employee list|add|role|clearance|disable|enable")
  end
end

function handleBadgeCommand(words)
  local subcommand = string.lower(words[2] or "")

  if subcommand == "writers" or subcommand == "list-writers" then
    local writers = badgeWriterNames()
    if #writers == 0 then
      print("No NFC writer peripherals found.")
    else
      for _, name in ipairs(writers) do
        print(name)
      end
    end
  elseif subcommand == "write" then
    local data = words[3]
    local writer = words[4]
    if not data then
      print("Usage: badge write <data> [nfc-peripheral]")
      return
    end
    local ok, nameOrErr, method = writeNfcBadgeData(data, writer)
    print(ok and ("Wrote badge with " .. tostring(nameOrErr) .. " via " .. tostring(method)) or ("Write failed: " .. tostring(nameOrErr)))
  elseif subcommand == "issue" then
    local username = words[3]
    local data = words[4] or makeId("badge")
    local writer = words[5]
    local doorAccess = words[6]
    if not username then
      print("Usage: badge issue <user> [data] [nfc-peripheral] [doorAccess]")
      return
    end
    local okWrite, writerResult, method = writeNfcBadgeData(data, writer)
    if not okWrite then
      print("Write failed: " .. tostring(writerResult))
      return
    end
    local okIssue, issueResult = issueEmployeeBadge(username, data, "console", doorAccess)
    print(okIssue and ("Issued " .. tostring(issueResult) .. " using " .. tostring(writerResult) .. " via " .. tostring(method)) or ("Issue failed: " .. tostring(issueResult)))
  else
    print("Usage: badge writers")
    print("   or: badge write <data> [nfc-peripheral]")
    print("   or: badge issue <user> [data] [nfc-peripheral] [doorAccess]")
  end
end

function promptLine(label, defaultValue)
  if defaultValue ~= nil and defaultValue ~= "" then
    write(label .. " [" .. tostring(defaultValue) .. "]: ")
  else
    write(label .. ": ")
  end
  local value = read()
  if value == nil or value == "" then
    return defaultValue
  end
  return value
end

function promptBool(label, defaultValue)
  local marker = defaultValue and "Y/n" or "y/N"
  local value = string.lower(tostring(promptLine(label .. " (" .. marker .. ")", "") or ""))
  if value == "" then
    return defaultValue and true or false
  end
  return value == "y" or value == "yes" or value == "true" or value == "1"
end

function promptNumber(label, defaultValue)
  local value = promptLine(label, defaultValue)
  return tonumber(value) or defaultValue
end

function promptEndpoint(label, defaultSide, controller, options)
  options = options or {}
  print(label)
  local side = promptLine("  Redstone side", defaultSide or "back")
  local peripheralName = promptLine("  Redstone relay/integrator/peripheral blank=computer side", "")
  local analog = promptBool("  Analog endpoint", false)
  local endpoint = {
    side = side or defaultSide or "back",
  }
  if peripheralName and peripheralName ~= "" then
    endpoint.peripheral = peripheralName
  end
  if analog then
    endpoint.analog = true
    endpoint.threshold = promptNumber("  Analog threshold", 1)
  end
  if options.output and promptBool("  Pulse/momentary output", false) then
    endpoint.pulseSeconds = promptNumber("  Pulse seconds", 0.1)
  end
  if controller and controller ~= "" and controller ~= "server" and controller ~= "local" then
    endpoint.controller = controller
  end
  return endpoint
end

function printPeripheralSummary(items)
  if type(items) ~= "table" or #items == 0 then
    print("No peripherals reported.")
    return
  end

  for _, item in ipairs(items) do
    local types = type(item.types) == "table" and table.concat(item.types, ",") or tostring(item.types or "?")
    print(tostring(item.name) .. " [" .. types .. "]")
    if type(item.methods) == "table" and #item.methods > 0 then
      print("  " .. truncate(table.concat(item.methods, ", "), 70))
    end
  end
end

function setupConsoleAddDoor()
  local controller = tostring(promptLine("Controller computer id blank/server=server", config.setup.defaultDoorController or "server") or "server")
  local payload = {
    action = "add_door",
    id = promptLine("Door id", nil),
    label = promptLine("Door label", nil),
    controller = controller,
    output = promptEndpoint("Door lock/output endpoint", config.setup.defaultDoorSide or "front", controller, { output = true }),
    activeOpen = promptBool("Output active opens door", true),
    openSeconds = promptNumber("Open seconds", config.defaultOpenSeconds or 4),
    alarmOnDenied = promptBool("Alarm after denied attempts", true),
  }
  if promptBool("Add forced-open contact sensor", false) then
    payload.contact = promptEndpoint("Contact input endpoint", config.setup.defaultContactSide or "back", controller)
    payload.contactOpenWhen = promptBool("Contact active means open", true)
  end
  if promptBool("Add request-to-exit button", false) then
    payload.requestExit = promptEndpoint("Exit button input endpoint", config.setup.defaultExitSide or "right", controller)
    payload.exitActiveWhen = promptBool("Exit input active when pressed", true)
  end
  local defaultReader = setupReaderSourceHints(controller)
  payload.reader = normalizeReaderSourceInput(promptLine("Reader source to map type none=skip", defaultReader or ""))

  local ok, message = handleSetupAction(payload, "console")
  print(ok and tostring(message) or ("Setup failed: " .. tostring(message)))
end

function setupConsoleAddSensor()
  print("Sensor type: 1 redstone  2 Create stress  3 generic peripheral  4 entity detector")
  local choice = promptLine("Type", "1")
  local payload = {
    action = "add_sensor",
    name = promptLine("Sensor name", "Facility Sensor"),
    profile = promptLine("Alarm profile", "facility_fault"),
  }
  if choice == "2" then
    payload.sensorType = "create_stress"
    payload.peripheral = promptLine("Stress peripheral name", "")
    payload.maxLoad = promptNumber("Max load 0.9 = 90%", 0.9)
    payload.profile = promptLine("Alarm profile", "power_fault")
  elseif choice == "3" then
    payload.sensorType = "peripheral"
    payload.peripheral = promptLine("Peripheral name", "")
    payload.method = promptLine("Method", "")
    payload.field = promptLine("Table field blank=whole value", "")
    payload.max = promptNumber("Alarm above blank=none", nil)
    payload.min = promptNumber("Alarm below blank=none", nil)
  elseif choice == "4" then
    payload.sensorType = "entity"
    payload.peripheral = promptLine("Entity detector peripheral blank=auto", "")
    payload.method = promptLine("Method blank=auto", "")
    payload.entities = promptLine("Entities comma-list", "minecraft:warden,minecraft:wither")
    payload.radius = promptNumber("Radius/range", 64)
    payload.profile = promptLine("Alarm profile", "emergency")
    payload.autoResetAlarm = promptBool("Auto-reset when clear", true)
    payload.autoResetSeconds = promptNumber("Auto-reset delay seconds", 8)
  else
    payload.sensorType = "redstone"
    payload.controller = promptLine("Controller id blank/server=server", "server")
    payload.input = promptEndpoint("Sensor input endpoint", "left", payload.controller)
    payload.alarmWhen = promptBool("Input active means fault", true)
  end

  local ok, message = handleSetupAction(payload, "console")
  print(ok and tostring(message) or ("Setup failed: " .. tostring(message)))
end

function setupConsoleAddEmergency()
  local controller = promptLine("Controller id blank/server=server", "server")
  local payload = {
    action = "add_emergency",
    name = promptLine("Button name", "Emergency Button"),
    controller = controller,
    input = promptEndpoint("Emergency input endpoint", "top", controller),
    activeWhen = promptBool("Input active means pressed", true),
    profile = promptLine("Alarm profile", "emergency"),
    reason = promptLine("Alarm reason", "emergency button"),
  }
  local ok, message = handleSetupAction(payload, "console")
  print(ok and tostring(message) or ("Setup failed: " .. tostring(message)))
end

function setupConsoleMapReader()
  local controller = promptLine("Controller id blank/server=server", "server")
  local defaultReader = setupReaderSourceHints(controller)
  local payload = {
    action = "map_reader",
    source = normalizeReaderSourceInput(promptLine("Reader source", defaultReader or "")),
    door = promptLine("Door id", ""),
  }
  local ok, message = handleSetupAction(payload, "console")
  print(ok and tostring(message) or ("Setup failed: " .. tostring(message)))
end

function setupConsoleIssueBadge()
  local username = promptLine("Employee username", "")
  local data = promptLine("Badge data blank=generate", "")
  if data == "" or data == nil then
    data = makeId("badge")
  end
  local writer = promptLine("NFC writer blank=auto", "")
  local doorAccess = promptLine("Door access blank=login only, *=all, comma=list", "")
  print("Place card on NFC writer.")
  local okWrite, writerResult, method = writeNfcBadgeData(data, writer)
  if not okWrite then
    print("Write failed: " .. tostring(writerResult))
    return
  end
  local ok, message, extra = handleSetupAction({
    action = "issue_badge",
    username = username,
    data = data,
    doorAccess = doorAccess,
  }, "console")
  print(ok and ("Issued " .. tostring(extra and extra.data or data) .. " using " .. tostring(writerResult) .. " via " .. tostring(method)) or ("Setup failed: " .. tostring(message)))
end

function printSetupRemovalSummary()
  local summary = setupSummary()
  print("Doors")
  for _, door in ipairs(summary.doors or {}) do
    print("  " .. tostring(door.id) .. " - " .. tostring(door.label) .. " [" .. tostring(door.controller) .. "]")
  end
  print("Sensors")
  for index, sensor in ipairs(summary.sensors or {}) do
    print("  " .. tostring(index) .. ". " .. tostring(sensor.name or sensor.id or sensor.peripheral or "sensor"))
  end
  print("Emergency buttons")
  for index, button in ipairs(summary.emergencyButtons or {}) do
    print("  " .. tostring(index) .. ". " .. tostring(button.name or button.id or "button"))
  end
  print("Generators")
  for index, generator in ipairs(summary.generators or {}) do
    print("  " .. tostring(index) .. ". " .. tostring(generator.name or generator.id or generator.peripheral or "generator"))
  end
  print("Readers")
  for source, door in pairs(summary.readers or {}) do
    print("  " .. tostring(source) .. " -> " .. tostring(door))
  end
end

function setupConsoleRemoveItem()
  while true do
    print()
    printSetupRemovalSummary()
    print()
    print("Remove")
    print("1. Door")
    print("2. Sensor")
    print("3. Emergency button")
    print("4. Generator")
    print("5. Reader mapping")
    print("B. Back")
    local choice = string.lower(tostring(promptLine("> ", "") or ""))
    local payload

    if choice == "1" then
      payload = {
        action = "remove_door",
        door = promptLine("Door id", ""),
        keepReaders = not promptBool("Also remove reader mappings for this door", true),
      }
    elseif choice == "2" then
      payload = { action = "remove_sensor", selector = promptLine("Sensor number/id/name", "") }
    elseif choice == "3" then
      payload = { action = "remove_emergency", selector = promptLine("Button number/id/name", "") }
    elseif choice == "4" then
      payload = { action = "remove_generator", selector = promptLine("Generator number/id/name", "") }
    elseif choice == "5" then
      payload = { action = "remove_reader", source = promptLine("Reader source", "") }
    elseif choice == "b" then
      return
    end

    if payload then
      local ok, message = handleSetupAction(payload, "console")
      print(ok and tostring(message) or ("Remove failed: " .. tostring(message)))
    end
  end
end

function setupWizard()
  while true do
    print()
    print("Facility Setup")
    print("1. Summary")
    print("2. Scan server peripherals")
    print("3. Scan door controller")
    print("4. Add/update door")
    print("5. Add facility sensor")
    print("6. Add emergency button")
    print("7. Map reader to door")
    print("8. Issue/write employee badge")
    print("9. Remove configured item")
    print("B. Back")
    local choice = string.lower(tostring(promptLine("> ", "") or ""))

    if choice == "1" then
      local summary = setupSummary()
      print("Server computer: " .. tostring(summary.computerId or "?"))
      print("Setup clearance: C" .. tostring(summary.setupClearance or "?"))
      print("Doors: " .. tostring(#(summary.doors or {})))
      for _, door in ipairs(summary.doors or {}) do
        print("  " .. tostring(door.id) .. " -> " .. tostring(door.label) .. " controller " .. tostring(door.controller))
      end
      print("Sensors: " .. tostring(#(summary.sensors or {})) .. ", emergency buttons: " .. tostring(#(summary.emergencyButtons or {})))
    elseif choice == "2" then
      local items = peripheralSummary()
      printPeripheralSummary(items)
      printReaderSourceHints(items, "server")
    elseif choice == "3" then
      local controller = promptLine("Controller computer id", "")
      local ok, scan = setupScanController(controller)
      if ok then
        local sourceController = controller
        if sourceController == nil or sourceController == "" or sourceController == "server" or sourceController == "local" or tostring(sourceController) == tostring(localComputerId() or "") then
          sourceController = "server"
        end
        print("Controller: " .. tostring(scan.controllerId or controller or "server"))
        printPeripheralSummary(scan.peripherals or {})
        printReaderSourceHints(scan.peripherals or {}, sourceController)
      else
        print("Scan failed: " .. tostring(scan))
      end
    elseif choice == "4" then
      setupConsoleAddDoor()
    elseif choice == "5" then
      setupConsoleAddSensor()
    elseif choice == "6" then
      setupConsoleAddEmergency()
    elseif choice == "7" then
      setupConsoleMapReader()
    elseif choice == "8" then
      setupConsoleIssueBadge()
    elseif choice == "9" then
      setupConsoleRemoveItem()
    elseif choice == "b" then
      return
    end
  end
end

function handleCommand(line)
  local words = splitWords(line)
  local command = words[1]
  if not command or command == "" then
    return
  end

  command = string.lower(command)

  if command == "help" or command == "?" then
    printHelp()
  elseif command == "status" then
    printStatus()
  elseif command == "pin" then
    local doorId = words[2]
    local pin = words[3]
    if not doorId or not pin then
      print("Usage: pin <door> <pin>")
    elseif authorizedPin(doorId, pin) then
      local ok, err = unlockDoor(doorId, "console-pin", nil, "pin")
      print(ok and "Access granted" or ("Failed: " .. tostring(err)))
    else
      denyAccess(doorId, "console-pin", "console", "pin_rejected")
      print("Access denied")
    end
  elseif command == "login" then
    local pin = words[2]
    if authorizedAdminPin(pin) then
      state.consoleAdminUntil = os.clock() + (config.adminSessionSeconds or 300)
      audit("ADMIN_LOGIN", "console")
      print("Admin session active")
    else
      audit("ADMIN_LOGIN_DENIED", "console")
      print("Denied")
    end
  elseif command == "unlock" then
    if requireAdmin() then
      local doorId = words[2]
      if not doorId then
        print("Usage: unlock <door> [seconds]")
      else
        local ok, err = unlockDoor(doorId, "console-admin", words[3], "admin")
        print(ok and "Unlocked" or ("Failed: " .. tostring(err)))
      end
    end
  elseif command == "lock" then
    if requireAdmin() then
      local doorId = words[2]
      if not doorId then
        print("Usage: lock <door>")
      else
        local ok, err = lockDoor(doorId, "console")
        print(ok and "Locked" or ("Failed: " .. tostring(err)))
      end
    end
  elseif command == "alarm" then
    if requireAdmin() then
      raiseAlarm(joinWords(words, 2) ~= "" and joinWords(words, 2) or "manual alarm", nil, "console")
      print("Alarm raised")
    end
  elseif command == "emergency" then
    if requireAdmin() then
      raiseAlarm(joinWords(words, 2) ~= "" and joinWords(words, 2) or "manual emergency", nil, "console", "emergency")
      print("Emergency alarm raised")
    end
  elseif command == "announce" then
    if requireAdmin() then
      local ok, err = broadcastAnnouncement(joinWords(words, 2), "console")
      print(ok and "Announcement sent" or ("Announcement failed: " .. tostring(err)))
    end
  elseif command == "setup" then
    if requireAdmin() then
      setupWizard()
    end
  elseif command == "reset" then
    if requireAdmin() then
      resetAlarm("console")
      print("Alarm reset")
    end
  elseif command == "lockdown" then
    if requireAdmin() then
      state.lockdown = true
      for _, doorId in ipairs(tableKeys(config.doors)) do
        lockDoor(doorId, "lockdown", true)
      end
      audit("LOCKDOWN", "console")
      markDirty()
      broadcastAlarmState()
      broadcastLockdownNotification(true, "console", "console")
      print("Lockdown enabled")
    end
  elseif command == "unlockdown" then
    if requireAdmin() then
      state.lockdown = false
      audit("LOCKDOWN_CLEAR", "console")
      markDirty()
      broadcastAlarmState()
      broadcastLockdownNotification(false, "console", "console")
      print("Lockdown cleared")
    end
  elseif command == "allow" then
    if requireAdmin() then
      local kind = words[2]
      local doorId = words[3]
      local value = joinWords(words, 4)
      if not kind or not doorId or value == "" then
        print("Usage: allow badge <door> <credential>")
        print("   or: allow player <door> <player>")
      elseif kind == "badge" then
        addDoorCredential(doorId, value)
      elseif kind == "player" then
        addDoorPlayer(doorId, value)
      else
        print("Unknown allow type: " .. tostring(kind))
      end
    end
  elseif command == "employee" then
    if requireAdmin() then
      handleEmployeeCommand(words)
    end
  elseif command == "badge" then
    if requireAdmin() then
      handleBadgeCommand(words)
    end
  elseif command == "save" then
    if requireAdmin() then
      saveConfig()
      print("Saved " .. CONFIG_FILE)
    end
  elseif command == "reboot" then
    if requireAdmin() then
      local target = string.lower(tostring(words[2] or "network"))
      if target == "network" or target == "all" or target == "everything" then
        print("Broadcasting reboot to network, then rebooting server...")
        local ok, err = rebootServerAfterNetworkBroadcast("console")
        if not ok then
          print("Network reboot failed: " .. tostring(err))
        end
      elseif target == "clients" or target == "kiosks" or target == "remotes" then
        local ok, err = broadcastNetworkReboot("console")
        print(ok and "Reboot broadcast sent" or ("Reboot broadcast failed: " .. tostring(err)))
      elseif target == "server" then
        audit("SERVER_REBOOT", "console")
        print("Rebooting server...")
        sleep(0.2)
        os.reboot()
      else
        print("Usage: reboot [network|clients|server]")
      end
    end
  elseif command == "quit" or command == "exit" then
    if requireAdmin() then
      state.running = false
      os.queueEvent("security_shutdown")
    end
  else
    print("Unknown command. Type help.")
  end
end

function consoleLoop()
  print((displayBranding()).facilityName .. " console. Type help.")
  while state.running do
    write("> ")
    local line = read()
    if line == nil then
      return
    end
    handleCommand(line)
  end
end

function clearScreen()
  term.setCursorPos(1, 1)
  term.clear()
end

function drawKioskHeader(brand, user)
  brand = state.kiosk.branding or brand or displayBranding()
  if term.isColor and term.isColor() then
    term.setBackgroundColor(colorValue(brand.primaryColor, colors.blue))
    term.setTextColor(colorValue(brand.textColor, colors.white))
  end

  clearScreen()
  print(brand.facilityName or "Facility")
  print(brand.kioskTitle or "Employee Kiosk")
  if brand.motto and brand.motto ~= "" then
    print(brand.motto)
  end
  if user then
    print("Signed in: " .. tostring(user.displayName or user.username))
  end
  if state.alarm.active then
    local profile = alarmProfile(state.alarm.profile)
    print("ALARM: " .. tostring(profile.label or "Alarm"))
    if state.alarm.reason then
      print(truncate(state.alarm.reason, 28))
    end
  elseif state.lockdown then
    print("LOCKDOWN ACTIVE")
  end
  for _, line in ipairs(kioskNotifications.lines(state.kiosk, 2)) do
    print("! " .. truncate(line, 26))
  end
  print(string.rep("-", 28))

  if term.isColor and term.isColor() then
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
  end
end

function kioskAutoLogoutSignal()
  return "__security_kiosk_auto_logout__"
end

function touchKioskActivity()
  state.kiosk.lastActivity = os.clock()
end

function kioskAutoLogoutSeconds()
  if state.kiosk and state.kiosk.user then
    return tonumber(config.kiosk and config.kiosk.autoLogoutSeconds) or 0
  end
  return 0
end

function kioskReadWithTimeout(label, mask, timeout)
  write(label or "")
  local text = ""
  local timer
  local function resetTimer()
    if timer and os.cancelTimer then
      pcall(os.cancelTimer, timer)
    end
    timer = timeout and timeout > 0 and os.startTimer(timeout) or nil
  end
  resetTimer()

  while true do
    local event = { os.pullEvent() }
    local name = event[1]

    if name == "timer" and event[2] == timer then
      error(kioskAutoLogoutSignal(), 0)
    elseif name == "char" then
      text = text .. tostring(event[2] or "")
      write(mask and tostring(mask) or tostring(event[2] or ""))
      touchKioskActivity()
      resetTimer()
    elseif name == "paste" then
      local pasted = tostring(event[2] or "")
      text = text .. pasted
      if mask then
        write(string.rep(tostring(mask), string.len(pasted)))
      else
        write(pasted)
      end
      touchKioskActivity()
      resetTimer()
    elseif name == "key" then
      local key = event[2]
      if key == keys.enter then
        print()
        touchKioskActivity()
        return text
      elseif key == keys.backspace and string.len(text) > 0 then
        text = string.sub(text, 1, -2)
        local x, y = term.getCursorPos()
        if x > 1 then
          term.setCursorPos(x - 1, y)
          write(" ")
          term.setCursorPos(x - 1, y)
        end
        touchKioskActivity()
        resetTimer()
      end
    end
  end
end

function kioskRead(label, mask)
  local timeout = kioskAutoLogoutSeconds()
  if timeout > 0 then
    return kioskReadWithTimeout(label, mask, timeout)
  end

  write(label)
  local value = mask and read(mask) or read()
  touchKioskActivity()
  return value
end

function pause()
  print()
  kioskRead("Press enter...")
end

function kioskNotificationTargetAllowed(notification, envelope)
  local target = envelope and envelope.target or notification.target or notification.to
  if not target or target == "" then
    return true
  end

  local user = state.kiosk.user
  return user and normalizeUsername(user.username) == normalizeUsername(target)
end

function kioskApplyNotification(notification, sender, envelope)
  if type(notification) ~= "table" or not kioskNotificationTargetAllowed(notification, envelope) then
    return
  end

  if sender then
    state.kiosk.serverId = sender
  end
  normalizeNotificationTimingFromServer(notification, envelope, sender)

  local item = kioskNotifications.push(state.kiosk, notification, config.notifications and config.notifications.maxItems)
  if item then
    local serverAudioOnly = kioskServerPreparedAudioOnly() and item.serverPreparedAudio == true
    if item.alarm and (item.kind == "alarm" or item.kind == "emergency") then
      kioskApplyAlarmMessage({
        alarm = item.alarm,
        serverTimeMillis = envelope and envelope.serverTimeMillis,
        sentAtMillis = envelope and envelope.sentAtMillis,
      }, sender)
      if notificationUsesAnnouncementAudio(item) and not serverAudioOnly then
        playFacilityAnnouncement(item)
      end
    elseif item.announcement == true or item.kind == "announcement" or item.kind == "alarm" or item.kind == "emergency" or item.kind == "lockdown" then
      if not serverAudioOnly then
        playFacilityAnnouncement(item)
      end
    else
      kioskNotifications.playSound(findSpeakers(), item, config)
    end
    markDirty()
  end
end

function kioskApplyAlarmMessage(message, sender)
  if type(message) ~= "table" then
    return
  end

  if sender then
    state.kiosk.serverId = sender
  end
  updateKioskClockOffset(message, sender)

  if message.branding then
    state.kiosk.branding = message.branding
  end
  if message.status then
    state.kiosk.status = message.status
  end

  local alarm = message.alarm or (message.status and message.status.alarm)
  if alarm then
    local wasActive = state.alarm.active
    local oldProfile = state.alarm.profile
    local oldStartAt = tonumber(state.alarm.soundStartAt)
    local newStartAt = serverMillisToLocalMillis(alarm.soundStartAt)
    local newSinceMillis = serverMillisToLocalMillis(alarm.sinceMillis)
    state.alarm.active = alarm.active and true or false
    state.alarm.reason = alarm.reason
    state.alarm.actor = alarm.actor
    state.alarm.door = alarm.door
    state.alarm.profile = alarm.profile
    state.alarm.sinceMillis = newSinceMillis or alarm.sinceMillis
    if state.alarm.active then
      state.alarm.soundStartAt = newStartAt or nowMillis()
    else
      state.alarm.soundStartAt = nil
    end
    if not state.alarm.active then
      clearAlarmAudioStreams(not announcementAudioBusy())
      state.kiosk.lastAlarmSound = 0
      state.alarm.soundIndex = 1
    elseif (not wasActive) or oldProfile ~= state.alarm.profile or oldStartAt ~= tonumber(state.alarm.soundStartAt) then
      if not kioskServerPreparedAudioOnly() or not alarmAudioBusy() then
        clearAlarmAudioStreams(not announcementAudioBusy())
      end
      state.kiosk.lastAlarmSound = 0
      state.alarm.soundIndex = 1
    end
  end

  if message.lockdown ~= nil then
    state.lockdown = message.lockdown and true or false
  elseif message.status and message.status.lockdown ~= nil then
    state.lockdown = message.status.lockdown and true or false
  end

  state.kiosk.lastSync = os.clock()
  markDirty()
end

function kioskQueueMessage(sender, message)
  table.insert(state.kiosk.inbox, {
    sender = sender,
    message = message,
  })
  while #state.kiosk.inbox > 50 do
    table.remove(state.kiosk.inbox, 1)
  end
end

function kioskTakeReply(serverId, requestId)
  for index, item in ipairs(state.kiosk.inbox) do
    local message = item.message
    if item.sender == serverId and type(message) == "table" and message.requestId == requestId then
      table.remove(state.kiosk.inbox, index)
      kioskApplyAlarmMessage(message, item.sender)
      return message
    end
  end
  return nil
end

function kioskRequest(serverId, op, payload, timeout)
  if not rednet then
    return { ok = false, error = "rednet unavailable" }
  end

  payload = payload or {}
  payload.op = op
  payload.requestId = payload.requestId or makeId("req")
  local okSend, sendErr = pcall(sendRednet, serverId, payload)
  if not okSend then
    return { ok = false, error = sendErr }
  end

  local deadline = os.clock() + (timeout or 5)
  if state.kiosk.netLoop then
    while os.clock() < deadline do
      local reply = kioskTakeReply(serverId, payload.requestId)
      if reply then
        return reply
      end
      sleep(0.05)
    end

    return { ok = false, error = "server timeout" }
  end

  while os.clock() < deadline do
    local remaining = math.max(0.1, deadline - os.clock())
    local okReceive, sender, message, receiveErr = receiveRednet(remaining)
    if not okReceive then
      return { ok = false, error = receiveErr }
    end
    if type(message) == "table" and message.op == "network_reboot" then
      handleNetworkRebootMessage(sender, message)
    elseif type(message) == "table" and message.op == "audio_stream" then
      handlePreparedAudioMessage(message, sender)
    elseif type(message) == "table" and message.op == "alarm_state" then
      kioskApplyAlarmMessage(message, sender)
    elseif type(message) == "table" and message.op == "notification" then
      kioskApplyNotification(message.notification, sender, message)
    elseif sender == serverId and type(message) == "table" and (message.requestId == payload.requestId or message.requestId == nil) then
      kioskApplyAlarmMessage(message, sender)
      return message
    end
  end

  return { ok = false, error = "server timeout" }
end

function discoverServer()
  if not rednet then
    return nil, displayBranding(), nil
  end

  openRednet()
  local configured = config.rednet and config.rednet.serverId
  if configured then
    local reply = kioskRequest(configured, "kiosk_hello", {}, config.rednet.discoverySeconds or 2)
    if reply.ok then
      return configured, reply.branding or displayBranding(), reply.status
    end
  end

  local requestId = makeId("discover")
  local okBroadcast = pcall(broadcastRednet, { op = "kiosk_hello", requestId = requestId })
  if not okBroadcast then
    return nil, displayBranding(), nil
  end
  local timeout = (config.rednet and config.rednet.discoverySeconds) or 2
  local deadline = os.clock() + timeout
  if state.kiosk.netLoop then
    while os.clock() < deadline do
      for index, item in ipairs(state.kiosk.inbox) do
        local message = item.message
        if type(message) == "table" and message.requestId == requestId and message.ok and message.branding then
          table.remove(state.kiosk.inbox, index)
          kioskApplyAlarmMessage(message, item.sender)
          return item.sender, message.branding, message.status
        end
      end
      sleep(0.05)
    end

    return nil, displayBranding(), nil
  end

  while os.clock() < deadline do
    local okReceive, sender, message = receiveRednet(math.max(0.1, deadline - os.clock()))
    if not okReceive then
      return nil, displayBranding(), nil
    end
    if type(message) == "table" and message.op == "network_reboot" then
      handleNetworkRebootMessage(sender, message)
    elseif type(message) == "table" and message.op == "audio_stream" then
      handlePreparedAudioMessage(message, sender)
    elseif type(message) == "table" and message.ok and message.branding then
      kioskApplyAlarmMessage(message, sender)
      return sender, message.branding, message.status
    end
  end

  return nil, displayBranding(), nil
end

function kioskNetworkLoop()
  openRednet()

  while state.kiosk.running do
    if not rednet then
      sleep(0.5)
    else
      local ok, sender, message = receiveRednet(0.5)
      if ok and type(message) == "table" then
        if message.op == "network_reboot" then
          handleNetworkRebootMessage(sender, message)
        elseif kioskControllerEnabled() and (message.op == "controller_endpoint" or message.op == "controller_scan" or message.op == "controller_ping") then
          handleControllerMessage(sender, message)
        elseif message.op == "audio_stream" then
          handlePreparedAudioMessage(message, sender)
        elseif message.op == "alarm_state" then
          kioskApplyAlarmMessage(message, sender)
        elseif message.op == "notification" then
          kioskApplyNotification(message.notification, sender, message)
        else
          kioskQueueMessage(sender, message)
          if message.alarm or message.status then
            kioskApplyAlarmMessage(message, sender)
          end
        end
      elseif not ok then
        sleep(0.5)
      end
    end
  end
end

function kioskHandleRawRednetMessage(sender, message, protocol)
  if protocol ~= rednetProtocol() then
    return
  end

  local decoded, decodeErr = unwrapRednetMessage(message)
  if decoded ~= nil then
    message = decoded
  elseif secureRednet.enabled(config.rednet) then
    return
  elseif decodeErr then
    return
  end

  if type(message) == "string" then
    local ok, value = pcall(textutils.unserialize, message)
    message = ok and value or { op = message }
  end

  if type(message) == "table" then
    if message.op == "network_reboot" then
      handleNetworkRebootMessage(sender, message)
    elseif kioskControllerEnabled() and (message.op == "controller_endpoint" or message.op == "controller_scan" or message.op == "controller_ping") then
      handleControllerMessage(sender, message)
    elseif message.op == "audio_stream" then
      handlePreparedAudioMessage(message, sender)
    elseif message.op == "alarm_state" then
      kioskApplyAlarmMessage(message, sender)
    elseif message.op == "notification" then
      kioskApplyNotification(message.notification, sender, message)
    else
      kioskQueueMessage(sender, message)
      if message.alarm or message.status then
        kioskApplyAlarmMessage(message, sender)
      end
    end
  end
end

function kioskAlarmSpeakerLoop()
  while state.kiosk.running do
    local sleepSeconds = 0.5
    if kioskServerPreparedAudioOnly() then
      if not state.alarm.active and ((tonumber(state.alarm.audioPlayingUntil) or 0) > 0 or next(state.alarm.audioStreams or {}) ~= nil) then
        clearAlarmAudioStreams(not announcementAudioBusy())
      end
    elseif state.alarm.active then
      local interval = tonumber(config.kiosk and config.kiosk.alarmSoundSeconds) or alarmProfile(state.alarm.profile).repeatSeconds or 1.5
      if alarmWaitingForStart() then
        state.kiosk.lastAlarmSound = 0
        sleepSeconds = math.max(0.01, math.min(0.05, alarmDelayUntilMillis(state.alarm.soundStartAt)))
      elseif alarmAudioBusy() then
        playAlarmPulse()
        sleepSeconds = math.max(0.05, math.min(0.25, alarmNextPulseDelay()))
      else
        local elapsed = os.clock() - (state.kiosk.lastAlarmSound or 0)
        if elapsed >= interval then
          playAlarmPulse()
          state.kiosk.lastAlarmSound = os.clock()
          sleepSeconds = math.min(0.25, math.max(0.05, interval))
        else
          sleepSeconds = math.max(0.05, math.min(0.25, interval - elapsed))
        end
      end
    else
      state.kiosk.lastAlarmSound = 0
      if (tonumber(state.alarm.audioPlayingUntil) or 0) > 0 or next(state.alarm.audioStreams or {}) ~= nil then
        clearAlarmAudioStreams(not announcementAudioBusy())
      end
    end
    sleep(sleepSeconds)
  end
end

function alarmAudioStreamLoop()
  local audioConfig = announcementAudioConfig()
  local watchdogSeconds = audioWatchdogDelaySeconds(audioConfig)
  local watchdogTimer = os.startTimer(watchdogSeconds)
  local function resetAudioWatchdog()
    if watchdogTimer and os.cancelTimer then
      pcall(os.cancelTimer, watchdogTimer)
    end
    audioConfig = announcementAudioConfig()
    watchdogSeconds = audioWatchdogDelaySeconds(audioConfig)
    watchdogTimer = os.startTimer(watchdogSeconds)
  end
  while state.running or state.kiosk.running do
    local event = { os.pullEventRaw() }
    if event[1] == "speaker_audio_empty" then
      processRemoteAudioStreams()
      if not handleAlarmSpeakerAudioEmpty(event[2]) then
        handleAnnouncementSpeakerAudioEmpty(event[2])
      end
      processAnnouncementQueue()
      resetAudioWatchdog()
    elseif event[1] == "security_audio_work" then
      processRemoteAudioStreams()
      feedAlarmAudioStreams()
      feedAnnouncementAudioStreams()
      processAnnouncementQueue()
      resetAudioWatchdog()
    elseif event[1] == "timer" and event[2] == watchdogTimer then
      processRemoteAudioStreams()
      feedAlarmAudioStreams()
      feedAnnouncementAudioStreams()
      processAnnouncementQueue()
      resetAudioWatchdog()
    end
  end
end

function kioskLocalControllerLoop()
  local options = kioskControllerOptions()
  local pollSeconds = controllerPollSeconds()
  local helloSeconds = tonumber(options.helloSeconds) or 30
  local pollTimer = os.startTimer(pollSeconds)
  local helloTimer = os.startTimer(1)

  while state.kiosk.running do
    local event = { os.pullEventRaw() }
    local name = event[1]

    if name == "timer" and event[2] == pollTimer then
      if kioskControllerCredentialForwarding() then
        controllerPollLocalCredentials()
      end
      options = kioskControllerOptions()
      pollSeconds = controllerPollSeconds()
      pollTimer = os.startTimer(pollSeconds)
    elseif name == "timer" and event[2] == helloTimer then
      if kioskControllerEnabled() then
        broadcastControllerHello()
      end
      options = kioskControllerOptions()
      helloSeconds = tonumber(options.helloSeconds) or 30
      helloTimer = os.startTimer(helloSeconds)
    elseif name == "nfc_data" and kioskControllerCredentialForwarding() then
      local source = event[2] or "nfc"
      local data = tostring(event[3] or "")
      if data ~= "" then
        local candidates, meta = badgeAliases("nfc", data)
        meta.source = source
        sendControllerCredential({
          source = source,
          kind = "nfc",
          candidates = candidates,
          meta = meta,
        })
      end
    elseif name == "peripheral" or name == "peripheral_detach" then
      invalidatePeripheralCache()
      if kioskControllerEnabled() then
        broadcastControllerHello()
      end
    end
  end
end

function kioskScanLocalBadge(timeout)
  timeout = tonumber(timeout) or tonumber(config.kiosk and config.kiosk.badgeScanSeconds) or 8
  local deadline = os.clock() + timeout
  local timer = os.startTimer(0.2)

  while os.clock() < deadline do
    local scanned = scanRfidScannerCredentials() or scanGenericBadgeCredentials()
    if scanned and scanned.candidates and #scanned.candidates > 0 then
      return scanned
    end

    local event = { os.pullEventRaw() }
    local name = event[1]
    if name == "timer" and event[2] == timer then
      timer = os.startTimer(0.2)
    elseif name == "nfc_data" then
      local source = event[2] or "nfc"
      local data = tostring(event[3] or "")
      if data ~= "" then
        local candidates, meta = badgeAliases("nfc", data)
        meta.source = source
        return {
          source = source,
          kind = "nfc",
          candidates = candidates,
          meta = meta,
          cooldown = "nfc:" .. tostring(source) .. ":" .. tostring(meta.id or data),
        }
      end
    elseif name == "rednet_message" then
      kioskHandleRawRednetMessage(event[2], event[3], event[4])
    elseif name == "terminate" then
      error("Terminated", 0)
    end
  end

  return nil
end

function kioskRefreshServerStatus()
  local serverId = state.kiosk.serverId or (config.rednet and config.rednet.serverId)
  if not serverId then
    return
  end

  local reply = kioskRequest(serverId, "status", {}, 1.5)
  if reply and reply.ok and reply.status then
    kioskApplyAlarmMessage(reply, serverId)
  end
end

function kioskMonitorLoop()
  drawMonitors(true)

  while state.kiosk.running do
    kioskRefreshServerStatus()
    drawMonitors(monitorsNeedPeriodicRedraw())
    sleep(monitorRefreshSeconds())
  end
end

function kioskLogin(serverId, brand)
  while true do
    drawKioskHeader(brand)
    print("1. Sign in")
    print("B. Scan badge")
    if brand.allowSelfRegistration then
      print("2. Create account")
    end
    print("R. Retry server")
    if config.kiosk and config.kiosk.locked == false then
      print("Q. Quit")
    end
    local choice = string.lower(kioskRead("> "))

    if choice == "1" then
      local username = kioskRead("Username: ")
      local pin = kioskRead("PIN: ", "*")
      local reply = kioskRequest(serverId, "kiosk_login", { username = username, pin = pin })
      if reply.ok then
        return reply.token, reply.user, reply.branding or brand
      end
      print("Denied: " .. tostring(reply.error))
      pause()
    elseif choice == "b" then
      print("Scan RFID/NFC badge now...")
      local scanned = kioskScanLocalBadge()
      if not scanned then
        print("No badge detected.")
        pause()
      else
        local reply = kioskRequest(serverId, "kiosk_badge_login", {
          kind = scanned.kind,
          source = scanned.source,
          candidates = scanned.candidates,
          meta = scanned.meta,
        })
        if reply.ok then
          return reply.token, reply.user, reply.branding or brand
        end
        print("Denied: " .. tostring(reply.error))
        pause()
      end
    elseif choice == "2" and brand.allowSelfRegistration then
      local username = kioskRead("New username: ")
      local displayName = kioskRead("Display name: ")
      local pin = kioskRead("New PIN: ", "*")
      local reply = kioskRequest(serverId, "kiosk_register", {
        username = username,
        displayName = displayName,
        pin = pin,
      })
      print(reply.ok and "Account created." or ("Failed: " .. tostring(reply.error)))
      pause()
    elseif choice == "r" then
      return nil, nil, brand, "retry"
    elseif choice == "q" and config.kiosk and config.kiosk.locked == false then
      return nil, nil, brand, "quit"
    end
  end
end

function printNotes(notes)
  if not notes or #notes == 0 then
    print("No notes.")
    return
  end

  for index, note in ipairs(notes) do
    local updated = note.updatedAt or note.createdAt or ""
    print(tostring(index) .. ". " .. truncate(note.title or "Untitled", 28))
    print("   " .. truncate(note.body or "", 42))
    print("   " .. tostring(updated))
  end
end

function noteBySelection(notes, selection)
  selection = tostring(selection or "")
  local index = tonumber(selection)
  if index and notes and notes[index] then
    return notes[index]
  end

  for _, note in ipairs(notes or {}) do
    if tostring(note.id) == selection then
      return note
    end
  end

  return nil
end

function readMultilineBody(existing)
  print("Body. End with a single '.' line.")
  if existing and existing ~= "" then
    print("Leave blank then '.' to keep the existing body.")
  end

  local lines = {}
  while true do
    local line = kioskRead("")
    if line == "." then
      break
    end
    table.insert(lines, line)
  end

  if existing and #lines == 0 then
    return existing
  end

  return table.concat(lines, "\n")
end

function viewKioskNote(brand, user, note)
  drawKioskHeader(brand, user)
  if not note then
    print("Note not found.")
    pause()
    return
  end

  local lines = {
    "Title: " .. tostring(note.title or "Untitled"),
    "Created: " .. tostring(note.createdAt or ""),
    "Updated: " .. tostring(note.updatedAt or ""),
    "ID: " .. tostring(note.id or ""),
    "",
  }

  for line in string.gmatch(tostring(note.body or "") .. "\n", "([^\n]*)\n") do
    table.insert(lines, line)
  end

  printPaged(lines)
  pause()
end

function kioskNotes(serverId, brand, token, user)
  while true do
    drawKioskHeader(brand, user)
    local reply = kioskRequest(serverId, "kiosk_notes", { token = token })
    if not reply.ok then
      print("Notes unavailable: " .. tostring(reply.error))
      pause()
      return false
    end

    printNotes(reply.notes)
    print()
    print("V. View note")
    print("A. Add note")
    print("E. Edit note")
    print("D. Delete note")
    print("B. Back")
    local choice = string.lower(kioskRead("> "))
    if choice == "v" then
      local selected = noteBySelection(reply.notes, kioskRead("Note number or id: "))
      viewKioskNote(brand, user, selected)
    elseif choice == "a" then
      local title = kioskRead("Title: ")
      local body = readMultilineBody()
      local saved = kioskRequest(serverId, "kiosk_save_note", {
        token = token,
        title = title,
        body = body,
      })
      print(saved.ok and ("Saved " .. tostring(saved.id)) or ("Failed: " .. tostring(saved.error)))
      pause()
    elseif choice == "e" then
      local selected = noteBySelection(reply.notes, kioskRead("Note number or id: "))
      if not selected then
        print("Note not found.")
        pause()
      else
        local title = kioskRead("Title [" .. tostring(selected.title or "Untitled") .. "]: ")
        if title == "" then
          title = selected.title or "Untitled"
        end
        local body = readMultilineBody(selected.body or "")
        local saved = kioskRequest(serverId, "kiosk_save_note", {
          token = token,
          id = selected.id,
          title = title,
          body = body,
        })
        print(saved.ok and ("Updated " .. tostring(saved.id)) or ("Failed: " .. tostring(saved.error)))
        pause()
      end
    elseif choice == "d" then
      local selected = noteBySelection(reply.notes, kioskRead("Note number or id: "))
      local deleted = selected and kioskRequest(serverId, "kiosk_delete_note", { token = token, id = selected.id }) or { ok = false, error = "note not found" }
      print(deleted.ok and "Deleted." or ("Failed: " .. tostring(deleted.error)))
      pause()
    elseif choice == "b" then
      return true
    end
  end
end

function kioskFeed(serverId, brand, token, user)
  drawKioskHeader(brand, user)
  local reply = kioskRequest(serverId, "kiosk_feed", { token = token })
  if not reply.ok then
    print("Feed unavailable: " .. tostring(reply.error))
    pause()
    return false
  end

  for index, post in ipairs(reply.feed or {}) do
    if index > 10 then
      break
    end
    print((post.displayName or post.author or "?") .. " - " .. tostring(post.createdAt or ""))
    print(truncate(post.text or "", 60))
    print()
  end

  print("P. Post")
  print("B. Back")
  local choice = string.lower(kioskRead("> "))
  if choice == "p" then
    local text = kioskRead("Post: ")
    local posted = kioskRequest(serverId, "kiosk_post", { token = token, text = text })
    print(posted.ok and "Posted." or ("Failed: " .. tostring(posted.error)))
    pause()
  end
  return true
end

function kioskMessages(serverId, brand, token, user)
  drawKioskHeader(brand, user)
  local reply = kioskRequest(serverId, "kiosk_inbox", { token = token })
  if not reply.ok then
    print("Messages unavailable: " .. tostring(reply.error))
    pause()
    return false
  end

  for index, message in ipairs(reply.messages or {}) do
    if index > 10 then
      break
    end
    print((message.fromName or message.from or "?") .. " -> " .. tostring(message.to or "?"))
    print(truncate(message.text or "", 60))
    print()
  end

  print("S. Send message")
  print("B. Back")
  local choice = string.lower(kioskRead("> "))
  if choice == "s" then
    local toUser = kioskRead("To username: ")
    local text = kioskRead("Message: ")
    local sent = kioskRequest(serverId, "kiosk_send", { token = token, to = toUser, text = text })
    print(sent.ok and "Sent." or ("Failed: " .. tostring(sent.error)))
    pause()
  end
  return true
end

function kioskPeople(serverId, brand, token, user)
  drawKioskHeader(brand, user)
  local reply = kioskRequest(serverId, "kiosk_people", { token = token })
  if not reply.ok then
    print("Directory unavailable: " .. tostring(reply.error))
    pause()
    return false
  end

  for _, person in ipairs(reply.people or {}) do
    print((person.displayName or person.username) .. " (" .. tostring(person.role or "employee") .. ")")
  end
  pause()
  return true
end

function kioskStatus(serverId, brand, token, user)
  drawKioskHeader(brand, user)
  local reply = kioskRequest(serverId, "kiosk_status", { token = token })
  if not reply.ok then
    print("Status unavailable: " .. tostring(reply.error))
    pause()
    return false
  end

  local status = reply.status or {}
  local alarm = status.alarm or {}
  print("Alarm: " .. (alarm.active and ("ACTIVE " .. tostring(alarm.reason)) or "clear"))
  print("Lockdown: " .. tostring(status.lockdown))
  print()
  for doorId, door in pairs(status.doors or {}) do
    print(tostring(door.label or doorId) .. ": " .. (door.locked and "locked" or "open"))
  end
  pause()
  return true
end

function kioskLogs(serverId, brand, token, user)
  drawKioskHeader(brand, user)
  local reply = kioskRequest(serverId, "kiosk_logs", { token = token, limit = 80 })
  if not reply.ok then
    print("Logs unavailable: " .. tostring(reply.error))
    pause()
    return false
  end

  local lines = {
    "Facility Logs",
    "Clearance: C" .. tostring(reply.clearance or user.clearance or "?"),
    "",
  }

  for _, line in ipairs(reply.logs or {}) do
    table.insert(lines, line)
  end

  if #(reply.logs or {}) == 0 then
    table.insert(lines, "No visible log entries.")
  end

  printPaged(lines)
  pause()
  return true
end

function kioskNotificationCenter(brand, user)
  drawKioskHeader(brand, user)
  local lines = kioskNotifications.lines(state.kiosk, config.notifications and config.notifications.maxItems or 12)
  if #lines == 0 then
    print("No notifications.")
  else
    print("Recent notifications")
    print()
    for _, line in ipairs(lines) do
      print(truncate(line, 60))
      print()
    end
  end
  pause()
  return true
end

function kioskSetupRequest(serverId, token, payload)
  payload = payload or {}
  payload.token = token
  return kioskRequest(serverId, "kiosk_setup", payload, 4)
end

function kioskDefaultController()
  if kioskControllerEnabled() then
    return kioskControllerId()
  end
  return "server"
end

function defaultLocalReaderPeripheral(defaultPeripheral)
  local readers = readerSourcesFromSummary(peripheralSummary(), "")
  if #readers > 0 then
    return readers[1].name
  end
  return defaultPeripheral or "nfc_reader_0"
end

function kioskReaderSourcePrompt(defaultPeripheral, controller, defaultSource)
  if defaultSource and defaultSource ~= "" then
    return normalizeReaderSourceInput(kioskPromptLine("Reader source type none=skip", defaultSource))
  end

  if kioskControllerEnabled() then
    print("Local reader source format:")
    print("  " .. controllerCredentialSource("<peripheral>"))
    local preferLocal = controller == nil or controller == "" or tostring(controller) == kioskControllerId()
    if kioskPromptBool("Use reader attached to this kiosk/controller", preferLocal) then
      local peripheralName = kioskPromptLine("  Local reader peripheral", defaultLocalReaderPeripheral(defaultPeripheral))
      return normalizeReaderSourceInput(controllerCredentialSource(peripheralName))
    end
  end

  print("Reader source examples:")
  print("  server: nfc_reader_0")
  print("  controller:23:nfc_reader_0")
  return normalizeReaderSourceInput(kioskPromptLine("Reader source type none=skip", ""))
end

function kioskSetupReaderHints(serverId, token, controller)
  print("Scanning for NFC/RFID/card readers...")
  local reply = kioskSetupRequest(serverId, token, { action = "scan", controller = controller })
  if reply.ok then
    return kioskPrintPeripheralSummary((reply.scan or {}).peripherals or {}, controller)
  end
  print("Reader scan failed: " .. tostring(reply.error))
  return nil
end

function saveKioskControllerSetting(enabled)
  config.kiosk = config.kiosk or {}
  config.kiosk.controller = config.kiosk.controller or {}
  config.kiosk.controller.enabled = enabled and true or false
  config.kiosk.controller.permanent = enabled and true or false
  if config.kiosk.controller.credentialForwarding == nil then
    config.kiosk.controller.credentialForwarding = true
  end
  if config.kiosk.controller.pollSeconds == nil then
    config.kiosk.controller.pollSeconds = 0.5
  end
  if config.kiosk.controller.idlePollSeconds == nil then
    config.kiosk.controller.idlePollSeconds = 5
  end
  if config.kiosk.controller.helloSeconds == nil then
    config.kiosk.controller.helloSeconds = 30
  end
  saveConfig()
  if enabled then
    broadcastControllerHello()
  end
end

function kioskLocationArea()
  local kiosk = config and config.kiosk or {}
  return firstTextValue(kiosk.area, kiosk.locationArea, kiosk.location, kiosk.zone) or ""
end

function saveKioskLocationArea(area)
  config.kiosk = config.kiosk or {}
  area = tostring(area or "")
  config.kiosk.area = area
  config.kiosk.locationArea = area
  saveConfig()
end

function kioskLocationSetup()
  clearScreen()
  print("Kiosk Location")
  print("Computer id: " .. tostring(localComputerId() or "?"))
  print("Current area: " .. tostring(kioskLocationArea() ~= "" and kioskLocationArea() or "unset"))
  print()
  local area = kioskPromptLine("Area/location", kioskLocationArea())
  saveKioskLocationArea(area or "")
  print("Saved area: " .. tostring((area and area ~= "") and area or "unset"))
  pause()
end

function kioskLocalControllerSetup()
  while true do
    clearScreen()
    print("Local Door Controller")
    print("Computer id: " .. tostring(localComputerId() or "?"))
    print("Enabled: " .. tostring(kioskControllerEnabled()))
    print("Reader source prefix:")
    print("controller:" .. tostring(localComputerId() or "?") .. ":<peripheral>")
    print()
    print("1. Enable permanently")
    print("2. Disable")
    print("3. Show local peripherals")
    print("B. Back")
    local choice = string.lower(kioskRead("> "))

    if choice == "1" then
      saveKioskControllerSetting(true)
      print("This kiosk is now a persistent door controller.")
      print("Use controller id " .. tostring(localComputerId() or "?") .. " when adding doors.")
      pause()
    elseif choice == "2" then
      saveKioskControllerSetting(false)
      print("Local controller mode disabled.")
      pause()
    elseif choice == "3" then
      local items = peripheralSummary()
      printPeripheralSummary(items)
      printReaderSourceHints(items, kioskControllerId())
      pause()
    elseif choice == "b" then
      return
    end
  end
end

function kioskPromptLine(label, defaultValue)
  local prompt = label .. (defaultValue ~= nil and defaultValue ~= "" and (" [" .. tostring(defaultValue) .. "]") or "") .. ": "
  local value = kioskRead(prompt)
  if value == nil or value == "" then
    return defaultValue
  end
  return value
end

function kioskPromptBool(label, defaultValue)
  local marker = defaultValue and "Y/n" or "y/N"
  local value = string.lower(tostring(kioskPromptLine(label .. " (" .. marker .. ")", "") or ""))
  if value == "" then
    return defaultValue and true or false
  end
  return value == "y" or value == "yes" or value == "true" or value == "1"
end

function kioskPromptNumber(label, defaultValue)
  local value = kioskPromptLine(label, defaultValue)
  return tonumber(value) or defaultValue
end

function kioskEndpointPrompt(label, defaultSide, controller, options)
  options = options or {}
  print(label)
  local side = kioskPromptLine("  Side", defaultSide or "back")
  local peripheralName = kioskPromptLine("  Redstone relay/peripheral blank=computer side", "")
  local analog = kioskPromptBool("  Analog", false)
  local endpoint = { side = side or defaultSide or "back" }
  if peripheralName and peripheralName ~= "" then
    endpoint.peripheral = peripheralName
  end
  if analog then
    endpoint.analog = true
    endpoint.threshold = kioskPromptNumber("  Threshold", 1)
  end
  if options.output and kioskPromptBool("  Pulse/momentary output", false) then
    endpoint.pulseSeconds = kioskPromptNumber("  Pulse seconds", 0.1)
  end
  if controller and controller ~= "" and controller ~= "server" and controller ~= "local" then
    endpoint.controller = controller
  end
  return endpoint
end

function kioskPrintSetupSummary(summary)
  print("Server computer: " .. tostring(summary.computerId or "?"))
  print("This kiosk id: " .. tostring(localComputerId() or "?"))
  print("This kiosk controller: " .. tostring(kioskControllerEnabled()))
  print("This kiosk area: " .. tostring(kioskLocationArea() ~= "" and kioskLocationArea() or "unset"))
  print("Setup clearance: C" .. tostring(summary.setupClearance or "?"))
  print("Doors")
  for _, door in ipairs(summary.doors or {}) do
    print("  " .. tostring(door.id) .. " - " .. tostring(door.label) .. " [" .. tostring(door.controller) .. "]")
  end
  print("Sensors: " .. tostring(#(summary.sensors or {})))
  print("Emergency buttons: " .. tostring(#(summary.emergencyButtons or {})))
end

function kioskPrintPeripheralSummary(items, controller)
  printPeripheralSummary(items)
  return printReaderSourceHints(items, controller or "server")
end

function kioskSetupAddDoor(serverId, token)
  local controller = kioskPromptLine("Controller id blank/server=server", kioskDefaultController())
  local payload = {
    action = "add_door",
    id = kioskPromptLine("Door id", nil),
    label = kioskPromptLine("Door label", nil),
    controller = controller,
    output = kioskEndpointPrompt("Output endpoint", "front", controller, { output = true }),
    activeOpen = kioskPromptBool("Output active opens door", true),
    openSeconds = kioskPromptNumber("Open seconds", config.defaultOpenSeconds or 4),
    alarmOnDenied = kioskPromptBool("Alarm on denied attempts", true),
  }
  if kioskPromptBool("Add forced-open contact", false) then
    payload.contact = kioskEndpointPrompt("Contact endpoint", "back", controller)
    payload.contactOpenWhen = kioskPromptBool("Contact active means open", true)
  end
  if kioskPromptBool("Add request-to-exit", false) then
    payload.requestExit = kioskEndpointPrompt("Exit button endpoint", "right", controller)
    payload.exitActiveWhen = kioskPromptBool("Exit active when pressed", true)
  end
  local defaultReader = kioskSetupReaderHints(serverId, token, controller)
  payload.reader = kioskReaderSourcePrompt("nfc_reader_0", controller, defaultReader)

  local reply = kioskSetupRequest(serverId, token, payload)
  print(reply.ok and tostring(reply.message or "Saved.") or ("Denied/failed: " .. tostring(reply.error)))
  pause()
end

function kioskSetupAddSensor(serverId, token)
  print("Sensor type: 1 redstone  2 Create stress  3 generic peripheral  4 entity detector")
  local choice = kioskPromptLine("Type", "1")
  local payload = {
    action = "add_sensor",
    name = kioskPromptLine("Sensor name", "Facility Sensor"),
    profile = kioskPromptLine("Alarm profile", "facility_fault"),
  }
  if choice == "2" then
    payload.sensorType = "create_stress"
    payload.peripheral = kioskPromptLine("Stress peripheral", "")
    payload.maxLoad = kioskPromptNumber("Max load", 0.9)
    payload.profile = kioskPromptLine("Alarm profile", "power_fault")
  elseif choice == "3" then
    payload.sensorType = "peripheral"
    payload.peripheral = kioskPromptLine("Peripheral", "")
    payload.method = kioskPromptLine("Method", "")
    payload.field = kioskPromptLine("Table field blank=whole value", "")
    payload.max = kioskPromptNumber("Alarm above blank=none", nil)
    payload.min = kioskPromptNumber("Alarm below blank=none", nil)
  elseif choice == "4" then
    payload.sensorType = "entity"
    payload.peripheral = kioskPromptLine("Entity detector blank=auto", "")
    payload.method = kioskPromptLine("Method blank=auto", "")
    payload.entities = kioskPromptLine("Entities comma-list", "minecraft:warden,minecraft:wither")
    payload.radius = kioskPromptNumber("Radius/range", 64)
    payload.profile = kioskPromptLine("Alarm profile", "emergency")
    payload.autoResetAlarm = kioskPromptBool("Auto-reset when clear", true)
    payload.autoResetSeconds = kioskPromptNumber("Auto-reset delay seconds", 8)
  else
    payload.sensorType = "redstone"
    payload.controller = kioskPromptLine("Controller id blank/server=server", kioskDefaultController())
    payload.input = kioskEndpointPrompt("Input endpoint", "left", payload.controller)
    payload.alarmWhen = kioskPromptBool("Active means fault", true)
  end

  local reply = kioskSetupRequest(serverId, token, payload)
  print(reply.ok and tostring(reply.message or "Saved.") or ("Denied/failed: " .. tostring(reply.error)))
  pause()
end

function kioskSetupAddEmergency(serverId, token)
  local controller = kioskPromptLine("Controller id blank/server=server", kioskDefaultController())
  local payload = {
    action = "add_emergency",
    name = kioskPromptLine("Button name", "Emergency Button"),
    controller = controller,
    input = kioskEndpointPrompt("Input endpoint", "top", controller),
    activeWhen = kioskPromptBool("Active means pressed", true),
    profile = kioskPromptLine("Alarm profile", "emergency"),
    reason = kioskPromptLine("Alarm reason", "emergency button"),
  }
  local reply = kioskSetupRequest(serverId, token, payload)
  print(reply.ok and tostring(reply.message or "Saved.") or ("Denied/failed: " .. tostring(reply.error)))
  pause()
end

function kioskSetupMapReader(serverId, token)
  local controller = kioskPromptLine("Controller id blank/server=server", kioskDefaultController())
  local defaultReader = kioskSetupReaderHints(serverId, token, controller)
  local reply = kioskSetupRequest(serverId, token, {
    action = "map_reader",
    source = kioskReaderSourcePrompt("nfc_reader_0", controller, defaultReader),
    door = kioskPromptLine("Door id", ""),
  })
  print(reply.ok and tostring(reply.message or "Saved.") or ("Denied/failed: " .. tostring(reply.error)))
  pause()
end

function kioskSetupIssueBadge(serverId, token)
  local username = kioskPromptLine("Employee username", "")
  local data = kioskPromptLine("Badge data blank=generate", "")
  if data == "" or data == nil then
    data = makeId("badge")
  end
  local writer = kioskPromptLine("NFC writer blank=auto", "")
  local doorAccess = kioskPromptLine("Door access blank=login only, *=all, comma=list", "")

  print("Place card on NFC writer.")
  local okWrite, writerResult, method = writeNfcBadgeData(data, writer)
  if not okWrite then
    print("Write failed: " .. tostring(writerResult))
    pause()
    return
  end

  local reply = kioskSetupRequest(serverId, token, {
    action = "issue_badge",
    username = username,
    data = data,
    doorAccess = doorAccess,
  })
  if reply.ok then
    print("Issued badge " .. tostring(reply.data or data))
    print("Writer: " .. tostring(writerResult) .. " via " .. tostring(method))
  else
    print("Server update failed: " .. tostring(reply.error))
  end
  pause()
end

function kioskPrintSetupRemovalSummary(summary)
  kioskPrintSetupSummary(summary)
  print("Readers")
  for source, door in pairs(summary.readers or {}) do
    print("  " .. tostring(source) .. " -> " .. tostring(door))
  end
  print("Sensors")
  for index, sensor in ipairs(summary.sensors or {}) do
    print("  " .. tostring(index) .. ". " .. tostring(sensor.name or sensor.id or sensor.peripheral or "sensor"))
  end
  print("Emergency buttons")
  for index, button in ipairs(summary.emergencyButtons or {}) do
    print("  " .. tostring(index) .. ". " .. tostring(button.name or button.id or "button"))
  end
  print("Generators")
  for index, generator in ipairs(summary.generators or {}) do
    print("  " .. tostring(index) .. ". " .. tostring(generator.name or generator.id or generator.peripheral or "generator"))
  end
end

function kioskSetupRemoveItem(serverId, token, brand, user)
  while true do
    drawKioskHeader(brand, user)
    local summaryReply = kioskSetupRequest(serverId, token, { action = "summary" })
    if summaryReply.ok then
      kioskPrintSetupRemovalSummary(summaryReply.summary or {})
    else
      print("Summary unavailable: " .. tostring(summaryReply.error))
    end
    print()
    print("Remove")
    print("1. Door")
    print("2. Sensor")
    print("3. Emergency button")
    print("4. Generator")
    print("5. Reader mapping")
    print("B. Back")

    local choice = string.lower(kioskRead("> "))
    local payload
    if choice == "1" then
      payload = {
        action = "remove_door",
        door = kioskPromptLine("Door id", ""),
        keepReaders = not kioskPromptBool("Also remove reader mappings for this door", true),
      }
    elseif choice == "2" then
      payload = { action = "remove_sensor", selector = kioskPromptLine("Sensor number/id/name", "") }
    elseif choice == "3" then
      payload = { action = "remove_emergency", selector = kioskPromptLine("Button number/id/name", "") }
    elseif choice == "4" then
      payload = { action = "remove_generator", selector = kioskPromptLine("Generator number/id/name", "") }
    elseif choice == "5" then
      payload = { action = "remove_reader", source = kioskPromptLine("Reader source", "") }
    elseif choice == "b" then
      return
    end

    if payload then
      local reply = kioskSetupRequest(serverId, token, payload)
      print(reply.ok and tostring(reply.message or "Removed.") or ("Remove failed: " .. tostring(reply.error)))
      pause()
    end
  end
end

function kioskSetupMenu(serverId, brand, token, user)
  while true do
    drawKioskHeader(brand, user)
    local issueClearance = brand.permissions and tonumber(brand.permissions.issueBadges) or 5
    local canIssueBadges = issueClearance == nil or (tonumber(user.clearance) or 0) >= issueClearance
    print("Facility Setup")
    print("1. Summary")
    print("2. Scan server peripherals")
    print("3. Scan door controller")
    print("4. Add/update door")
    print("5. Add facility sensor")
    print("6. Add emergency button")
    print("7. Map reader to door")
    if canIssueBadges then
      print("8. Issue/write employee badge")
    end
    print("9. This kiosk door-controller mode")
    print("A. This kiosk location area")
    print("0. Remove configured item")
    print("B. Back")

    local choice = string.lower(kioskRead("> "))
    if choice == "1" then
      local reply = kioskSetupRequest(serverId, token, { action = "summary" })
      if reply.ok then
        kioskPrintSetupSummary(reply.summary or {})
      else
        print("Unavailable: " .. tostring(reply.error))
      end
      pause()
    elseif choice == "2" then
      local reply = kioskSetupRequest(serverId, token, { action = "scan", controller = "server" })
      if reply.ok then
        kioskPrintPeripheralSummary((reply.scan or {}).peripherals or {}, "server")
      else
        print("Scan failed: " .. tostring(reply.error))
      end
      pause()
    elseif choice == "3" then
      local controller = kioskPromptLine("Controller computer id", "")
      local reply = kioskSetupRequest(serverId, token, { action = "scan", controller = controller })
      if reply.ok then
        print("Controller: " .. tostring((reply.scan or {}).controllerId or controller))
        kioskPrintPeripheralSummary((reply.scan or {}).peripherals or {}, controller)
      else
        print("Scan failed: " .. tostring(reply.error))
      end
      pause()
    elseif choice == "4" then
      kioskSetupAddDoor(serverId, token)
    elseif choice == "5" then
      kioskSetupAddSensor(serverId, token)
    elseif choice == "6" then
      kioskSetupAddEmergency(serverId, token)
    elseif choice == "7" then
      kioskSetupMapReader(serverId, token)
    elseif choice == "8" and canIssueBadges then
      kioskSetupIssueBadge(serverId, token)
    elseif choice == "9" then
      kioskLocalControllerSetup()
    elseif choice == "a" then
      kioskLocationSetup()
    elseif choice == "0" then
      kioskSetupRemoveItem(serverId, token, brand, user)
    elseif choice == "b" then
      return true
    end
  end
end

function requestKioskQuit(serverId, token)
  local reply = kioskRequest(serverId, "kiosk_security_action", {
    token = token,
    action = "quit_kiosk",
  })

  if not reply.ok then
    print("Denied/failed: " .. tostring(reply.error))
    pause()
    return false
  end

  local handle = fs.open(KIOSK_EXIT_FILE, "w")
  handle.writeLine("authorized " .. timestamp())
  handle.close()
  state.kiosk.running = false
  return true
end

function kioskPaRequest(serverId, brand, token, user)
  drawKioskHeader(brand, user)
  print("PA Request")
  print("Kiosk area: " .. tostring(kioskLocationArea() ~= "" and kioskLocationArea() or "unset"))
  print()

  local payload = {
    token = token,
    action = "personnel_request",
    personnel = kioskPromptLine("Personnel/name blank=available", ""),
    personnelRole = kioskPromptLine("Title/role blank=auto", ""),
    reason = kioskPromptLine("Reason blank=general", "general"),
    area = kioskPromptLine("Area", kioskLocationArea()),
  }

  local reply = kioskRequest(serverId, "kiosk_security_action", payload)
  print(reply.ok and "PA request sent." or ("Denied/failed: " .. tostring(reply.error)))
  pause()
  return true
end

function kioskSecurityActions(serverId, brand, token, user)
  while true do
    drawKioskHeader(brand, user)
    print("Clearance: C" .. tostring(user.clearance or "?"))
    print("1. Trigger emergency alarm")
    print("2. Trigger security alarm")
    print("3. Reset active alarm")
    print("4. Lockdown")
    print("5. Clear lockdown")
    print("6. Unlock door")
    print("7. Lock door")
    print("8. Request personnel")
    print("B. Back")

    local choice = string.lower(kioskRead("> "))
    local payload = { token = token }

    if choice == "1" then
      payload.action = "emergency"
      payload.reason = kioskRead("Reason: ")
    elseif choice == "2" then
      payload.action = "alarm"
      payload.profile = "security"
      payload.reason = kioskRead("Reason: ")
    elseif choice == "3" then
      payload.action = "reset_alarm"
    elseif choice == "4" then
      payload.action = "lockdown"
    elseif choice == "5" then
      payload.action = "unlockdown"
    elseif choice == "6" then
      payload.action = "unlock_door"
      payload.door = kioskRead("Door id: ")
      payload.seconds = tonumber(kioskRead("Seconds blank=default: "))
    elseif choice == "7" then
      payload.action = "lock_door"
      payload.door = kioskRead("Door id: ")
    elseif choice == "8" then
      kioskPaRequest(serverId, brand, token, user)
      payload = nil
    elseif choice == "b" then
      return true
    else
      payload = nil
    end

    if payload then
      local reply = kioskRequest(serverId, "kiosk_security_action", payload)
      print(reply.ok and "Done." or ("Denied/failed: " .. tostring(reply.error)))
      pause()
    end
  end
end

function kioskMenu(serverId, brand, token, user)
  while true do
    drawKioskHeader(brand, user)
    brand = state.kiosk.branding or brand or {}
    local quitClearance = brand.permissions and tonumber(brand.permissions.quitKiosk) or tonumber(config.kiosk and config.kiosk.quitClearance) or 5
    local canQuitKiosk = quitClearance == nil or (tonumber(user.clearance) or 0) >= quitClearance
    local setupClearance = brand.permissions and tonumber(brand.permissions.setupFacility) or 5
    local canSetup = setupClearance == nil or (tonumber(user.clearance) or 0) >= setupClearance
    print("1. Personal notes")
    print("2. Facility feed")
    print("3. Messages")
    print("4. Employee directory")
    print("5. Facility status")
    print("6. Security actions")
    print("7. Facility logs")
    print("8. Notifications")
    print("P. PA request")
    if canSetup then
      print("9. Facility setup")
    end
    if canQuitKiosk then
      print("Q. Quit kiosk")
    end
    print("L. Log out")
    local choice = string.lower(kioskRead("> "))

    if choice == "1" then
      if not kioskNotes(serverId, brand, token, user) then
        return "logout"
      end
    elseif choice == "2" then
      if not kioskFeed(serverId, brand, token, user) then
        return "logout"
      end
    elseif choice == "3" then
      if not kioskMessages(serverId, brand, token, user) then
        return "logout"
      end
    elseif choice == "4" then
      if not kioskPeople(serverId, brand, token, user) then
        return "logout"
      end
    elseif choice == "5" then
      if not kioskStatus(serverId, brand, token, user) then
        return "logout"
      end
    elseif choice == "6" then
      if not kioskSecurityActions(serverId, brand, token, user) then
        return "logout"
      end
    elseif choice == "7" then
      if not kioskLogs(serverId, brand, token, user) then
        return "logout"
      end
    elseif choice == "8" then
      kioskNotificationCenter(brand, user)
    elseif choice == "p" then
      if not kioskPaRequest(serverId, brand, token, user) then
        return "logout"
      end
    elseif choice == "9" and canSetup then
      if not kioskSetupMenu(serverId, brand, token, user) then
        return "logout"
      end
    elseif choice == "q" and canQuitKiosk then
      if requestKioskQuit(serverId, token) then
        return "quit"
      end
    elseif choice == "l" then
      kioskRequest(serverId, "kiosk_logout", { token = token }, 2)
      return "logout"
    end
  end
end

function kioskUiLoop()
  while true do
    local serverId, brand = discoverServer()
    if not serverId then
      drawKioskHeader(brand)
      print("No security server found.")
      print("Attach/open a modem or set rednet.serverId.")
      pause()
    else
      local token, user, nextBrand, action = kioskLogin(serverId, brand)
      brand = nextBrand or brand
      if action == "quit" and config.kiosk and config.kiosk.locked == false then
        return
      elseif action ~= "retry" and token and user then
        state.kiosk.token = token
        state.kiosk.user = user
        touchKioskActivity()
        local okMenu, menuResult = pcall(kioskMenu, serverId, brand, token, user)
        if not okMenu then
          if menuResult == kioskAutoLogoutSignal() then
            kioskRequest(serverId, "kiosk_logout", { token = token }, 2)
            menuResult = "logout"
          else
            error(menuResult)
          end
        end
        state.kiosk.token = nil
        state.kiosk.user = nil
        state.kiosk.loggedOutSince = os.clock()
        if menuResult == "quit" then
          return
        end
      else
        state.kiosk.token = nil
        state.kiosk.user = nil
        state.kiosk.loggedOutSince = os.clock()
      end
    end
  end
end

function kioskMaintenanceLoop()
  state.kiosk.loggedOutSince = state.kiosk.loggedOutSince or os.clock()
  while state.kiosk.running do
    local rebootSeconds = tonumber(config.kiosk and config.kiosk.autoRebootLoggedOutSeconds) or 0
    if rebootSeconds > 0 and not state.kiosk.user then
      state.kiosk.loggedOutSince = state.kiosk.loggedOutSince or os.clock()
      if os.clock() - state.kiosk.loggedOutSince >= rebootSeconds then
        os.reboot()
      end
    elseif state.kiosk.user then
      state.kiosk.loggedOutSince = nil
    end

    sleep(5)
  end
end

function kioskMain()
  config = loadConfig("kiosk")
  config.mode = "kiosk"
  math.randomseed(nowMillis() % 2147483647)
  if fs.exists(KIOSK_EXIT_FILE) then
    fs.delete(KIOSK_EXIT_FILE)
  end
  local originalPullEvent = os.pullEvent
  if not (config.kiosk and config.kiosk.locked == false) then
    os.pullEvent = os.pullEventRaw
  end
  state.kiosk.running = true
  state.kiosk.netLoop = true
  state.kiosk.loggedOutSince = os.clock()
  touchKioskActivity()
  openRednet()
  drawMonitors(true)

  local ok, err = pcall(function()
    parallel.waitForAny(kioskUiLoop, kioskNetworkLoop, kioskAlarmSpeakerLoop, alarmAudioStreamLoop, kioskMonitorLoop, kioskMaintenanceLoop, kioskLocalControllerLoop)
  end)

  state.kiosk.running = false
  state.kiosk.token = nil
  state.kiosk.user = nil
  os.pullEvent = originalPullEvent
  if not ok then
    error(err)
  end
end

function controllerMain()
  config = loadConfig("controller")
  config.mode = "controller"
  math.randomseed(nowMillis() % 2147483647)
  openRednet()
  clearScreen()
  print("Security door controller")
  print("Computer id: " .. tostring(localComputerId() or "?"))
  print("Server id: " .. tostring(config.rednet and config.rednet.serverId or "broadcast"))
  print("Waiting for server endpoint requests.")
  broadcastControllerHello()
  local helloTimer = os.startTimer(30)
  local scanTimer = os.startTimer(controllerPollSeconds())

  local function controllerLoop()
    while true do
      local event = { os.pullEventRaw() }
      local name = event[1]
      if name == "terminate" then
        return
      elseif name == "timer" and event[2] == helloTimer then
        broadcastControllerHello()
        helloTimer = os.startTimer(30)
      elseif name == "timer" and event[2] == scanTimer then
        controllerPollLocalCredentials()
        scanTimer = os.startTimer(controllerPollSeconds())
      elseif name == "peripheral" or name == "peripheral_detach" then
        invalidatePeripheralCache()
        openRednet()
        broadcastControllerHello()
      elseif name == "nfc_data" then
        local source = event[2] or "nfc"
        local data = tostring(event[3] or "")
        if data ~= "" then
          local candidates, meta = badgeAliases("nfc", data)
          meta.source = source
          sendControllerCredential({
            source = source,
            kind = "nfc",
            candidates = candidates,
            meta = meta,
          })
        end
      elseif name == "rednet_message" then
        local sender = event[2]
        local message = event[3]
        local protocol = event[4]
        if protocol == rednetProtocol() then
          local decoded, decodeErr = unwrapRednetMessage(message)
          if decoded ~= nil then
            message = decoded
          elseif secureRednet.enabled(config.rednet) then
            message = nil
          elseif decodeErr then
            message = nil
          end
          if type(message) == "string" then
            local ok, value = pcall(textutils.unserialize, message)
            message = ok and value or { op = message }
          end
          handleControllerMessage(sender, message)
        end
      end
    end
  end

  parallel.waitForAny(controllerLoop, alarmAudioStreamLoop)
end

function initializeDoors()
  for _, doorId in ipairs(tableKeys(config.doors)) do
    getDoorState(doorId)
    lockDoor(doorId, "startup", true)
  end
end

function shutdownHardware()
  if config.lockDoorsOnExit ~= false then
    for _, doorId in ipairs(tableKeys(config.doors)) do
      lockDoor(doorId, "shutdown", true)
    end
  end

  if config.clearAlarmOnExit then
    setAlarmOutputs(false)
    clearAlarmAudioStreams(true)
  end
end

function eventLoop()
  scheduleTimer(credentialPollSeconds(), { type = "credential_poll" })
  scheduleTimer(inputPollSeconds(), { type = "input_poll" })
  scheduleTimer(sensorPollSeconds(), { type = "sensor_poll" })
  scheduleTimer(monitorRefreshSeconds(), { type = "monitor" })
  scheduleTimer(alarmBroadcastSeconds(), { type = "alarm_broadcast" })
  scheduleAnnouncementTimer()

  while state.running do
    local event = { os.pullEventRaw() }
    local name = event[1]

    if name == "terminate" then
      audit("STOP", "terminate")
      state.running = false
      return
    elseif name == "security_shutdown" then
      return
    elseif name == "timer" then
      local id = event[2]
      local payload = state.timers[id]
      state.timers[id] = nil
      clearTimerKey(payload, id)

      if payload then
        if payload.type == "credential_poll" then
          pollCredentials()
          scheduleTimer(credentialPollSeconds(), { type = "credential_poll" })
        elseif payload.type == "input_poll" then
          pollDoorInputs()
          scheduleTimer(inputPollSeconds(), { type = "input_poll" })
        elseif payload.type == "sensor_poll" then
          pollFacilitySensors()
          scheduleTimer(sensorPollSeconds(), { type = "sensor_poll" })
        elseif payload.type == "poll" then
          pollInputs()
          scheduleTimer(normalizedSeconds(config.pollSeconds, 1, 0.1), { type = "poll" })
        elseif payload.type == "monitor" then
          drawMonitors(monitorsNeedPeriodicRedraw())
          scheduleTimer(monitorRefreshSeconds(), { type = "monitor" })
        elseif payload.type == "alarm_broadcast" then
          broadcastAlarmState()
          scheduleTimer(alarmBroadcastSeconds(), { type = "alarm_broadcast" })
        elseif payload.type == "redstone_update" then
          pollDoorInputs()
          checkRedstoneFacilitySensors()
        elseif payload.type == "stress_update" then
          checkStressSensors()
        elseif payload.type == "announcement" then
          local text, voiceLine = nextConfiguredAnnouncement()
          if text then
            broadcastAnnouncement(text, "auto", voiceLine)
          end
          scheduleAnnouncementTimer()
        elseif payload.type == "alarm_pulse" then
          if state.alarm.active and (payload.generation == nil or payload.generation == state.alarm.audioGeneration) then
            playAlarmPulse()
            scheduleAlarmPulse()
          end
        elseif payload.type == "door_lock" then
          local doorState = getDoorState(payload.door)
          if doorState.lockTimer == id then
            lockDoor(payload.door, "timer")
          end
        end
      end
    elseif name == "disk" then
      local drive = event[2]
      local candidates, meta = diskCandidates(drive)
      if #candidates > 0 then
        handleCredentials(drive, "disk", candidates, meta, "disk:" .. tostring(drive))
      end
    elseif name == "disk_eject" then
      state.lastBadge["disk:" .. tostring(event[2])] = nil
    elseif name == "nfc_data" then
      local source = event[2] or "nfc"
      local data = tostring(event[3] or "")
      if data ~= "" then
        handleCredentials(source, "nfc", {
          "nfc:" .. data,
          "badge:" .. data,
          data,
        }, {
          name = data,
          id = data,
        }, "nfc:" .. tostring(source) .. ":" .. data)
      end
    elseif name == "playerClick" then
      local username = event[2]
      local source = event[3] or "playerDetector"
      if username then
        handleCredentials(source, "player", {
          "player:" .. tostring(username),
          tostring(username),
        }, {
          player = username,
          name = username,
        }, "playerClick:" .. tostring(source) .. ":" .. tostring(username))
      end
    elseif name == "overstressed" then
      raiseAlarm("Create kinetic network overstressed", nil, "create", "power_fault")
    elseif name == "stress_change" then
      scheduleKeyedTimer("stress_update", stressDebounceSeconds(), { type = "stress_update" })
    elseif name == "redstone" then
      scheduleKeyedTimer("redstone_update", redstoneDebounceSeconds(), { type = "redstone_update" })
    elseif name == "peripheral" or name == "peripheral_detach" then
      invalidatePeripheralCache()
      openRednet()
      markDirty()
    elseif name == "rednet_message" then
      handleRednet(event[2], event[3], event[4])
    end
  end
end

function main()
  local requestedMode = args[1] and string.lower(tostring(args[1])) or nil
  if requestedMode == "kiosk" then
    kioskMain()
    return
  end
  if requestedMode == "controller" or requestedMode == "door" or requestedMode == "door_controller" then
    controllerMain()
    return
  end

  config = loadConfig(requestedMode)
  if requestedMode and requestedMode ~= "" then
    config.mode = requestedMode
  end

  math.randomseed(nowMillis() % 2147483647)

  local configMode = string.lower(tostring(config.mode or "server"))
  if configMode == "kiosk" then
    kioskMain()
    return
  end
  if configMode == "controller" or configMode == "door" or configMode == "door_controller" then
    controllerMain()
    return
  end

  if config.employees and config.employees.enabled ~= false then
    loadEmployeeData()
  end

  openRednet()
  initializeDoors()
  drawMonitors(true)
  audit("START", {
    site = config.siteName,
    doors = tableKeys(config.doors),
  })

  local ok, err = pcall(function()
    parallel.waitForAny(eventLoop, consoleLoop, alarmAudioStreamLoop)
  end)

  shutdownHardware()

  if not ok then
    audit("ERROR", tostring(err))
    error(err)
  end

  audit("STOP", "normal")
end

return {
  run = function(...)
    args = { ... }
    return main()
  end,
}
