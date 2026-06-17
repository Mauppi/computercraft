-- CC: Tweaked security system for doors, badges, alarms, sensors, and rednet.
-- Loaded by security_system.lua. Run security_system.lua directly with:
--   security_system
--
-- The first run creates security_config.lua if it does not exist.

local CONFIG_FILE = "security_config.lua"
local LOG_FILE = "security_audit.log"
local ACCOUNTS_FILE = "security_accounts.lua"
local SOCIAL_FILE = "security_social.lua"
local KIOSK_EXIT_FILE = ".security_kiosk_exit"
local PROTOCOL = "cc_security_v1"
local args = {}

local secureRednet = require("security_system_rednet")
local kioskNotifications = require("security_system_notifications")
local facilityAnnouncements = require("security_system_announcements")

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
  },
  announcements = {
    index = 0,
  },
  sensorDetails = {},
  alarm = {
    active = false,
    reason = nil,
    actor = nil,
    door = nil,
    profile = nil,
    since = nil,
    soundIndex = 1,
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

function writeDefaultConfig()
  local handle = fs.open(CONFIG_FILE, "w")
  handle.writeLine("-- Generated by security_system.lua. Edit this file for your base.")
  handle.writeLine("return " .. textutils.serialize(defaultConfig))
  handle.close()
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

  merged.employees = merged.employees or shallowCopy(defaultConfig.employees)
  for key, value in pairs(defaultConfig.employees) do
    if merged.employees[key] == nil then
      merged.employees[key] = shallowCopy(value)
    end
  end
  merged.employees.clearanceLevels = merged.employees.clearanceLevels or shallowCopy(defaultConfig.employees.clearanceLevels)
  for key, value in pairs(defaultConfig.employees.clearanceLevels) do
    if merged.employees.clearanceLevels[key] == nil then
      merged.employees.clearanceLevels[key] = value
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

function loadConfig()
  if not fs.exists(CONFIG_FILE) then
    writeDefaultConfig()
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

function getTypes(name)
  local types = { peripheral.getType(name) }
  local map = {}
  for _, item in ipairs(types) do
    if item then
      map[tostring(item)] = true
    end
  end
  return map
end

function hasPeripheralType(name, wanted)
  local types = getTypes(name)
  return types[wanted] == true
end

function methodMap(name)
  local ok, methods = pcall(peripheral.getMethods, name)
  local out = {}
  if ok and type(methods) == "table" then
    for _, method in ipairs(methods) do
      out[method] = true
    end
  end
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

  local side = endpoint.side or "back"
  local level = endpoint.level or endpoint.analogLevel or 15

  if endpoint.peripheral then
    local device = peripheral.wrap(endpoint.peripheral)
    if not device then
      return false, "missing peripheral " .. tostring(endpoint.peripheral)
    end

    if endpoint.analog or endpoint.level or endpoint.analogLevel then
      if device.setAnalogOutput then
        local ok, err = pcall(device.setAnalogOutput, side, value and level or 0)
        return ok, err
      end
    end

    if device.setOutput then
      local ok, err = pcall(device.setOutput, side, value)
      return ok, err
    end

    if device.setAnalogOutput then
      local ok, err = pcall(device.setAnalogOutput, side, value and level or 0)
      return ok, err
    end

    return false, "peripheral cannot output redstone"
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

  local side = endpoint.side or "back"
  local threshold = endpoint.threshold or 1
  local active
  local raw

  if endpoint.peripheral then
    local device = peripheral.wrap(endpoint.peripheral)
    if not device then
      return false, nil
    end

    if endpoint.analog or endpoint.threshold then
      if device.getAnalogInput then
        local ok, value = pcall(device.getAnalogInput, side)
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

function scheduleTimer(seconds, payload)
  local id = os.startTimer(seconds)
  state.timers[id] = payload
  return id
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

function findSpeakers()
  local out = {}
  for _, name in ipairs(peripheral.getNames()) do
    if hasPeripheralType(name, "speaker") then
      local device = peripheral.wrap(name)
      if device then
        table.insert(out, device)
      end
    end
  end
  return out
end

function findChatBox()
  for _, name in ipairs(peripheral.getNames()) do
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
      },
    },
    alarm = {
      active = state.alarm.active,
      reason = state.alarm.reason,
      door = state.alarm.door,
      actor = state.alarm.actor,
      profile = state.alarm.profile,
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
  return notification
end

function sendNotificationPayload(target, notification, targetUser)
  local payload = {
    op = "notification",
    notification = notification,
    target = targetUser,
  }
  return pcall(sendRednet, target, payload)
end

function broadcastKioskNotification(notification, targetUser)
  local options = notificationConfig()
  if options.enabled == false or not (config and config.rednet and config.rednet.enabled and rednet) then
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
  })
end

function broadcastEventNotification(kind, title, text, severity, extra)
  broadcastKioskNotification(makeNotification(kind, title, text, severity, extra))
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
  local lines = config.announcements and config.announcements.lines or {}
  if type(lines) ~= "table" or #lines == 0 then
    return nil
  end

  state.announcements.index = (state.announcements.index or 0) + 1
  if state.announcements.index > #lines then
    state.announcements.index = 1
  end

  local line = lines[state.announcements.index]
  if type(line) == "table" then
    return line.text or line.message or line.title, line.voiceLine or line.id
  end
  return tostring(line), nil
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

function playDspAlarm(profile, speaker)
  if not (speaker and speaker.playAudio) then
    return false
  end

  local buffer = buildDspAlarmBuffer(profile)
  if not buffer or #buffer == 0 then
    return false
  end

  local dsp = profile.dsp or {}
  local ok, accepted = pcall(speaker.playAudio, buffer, tonumber(dsp.volume) or 1)
  return ok and accepted ~= false
end

function playAlarmPulse()
  local profile = alarmProfile(state.alarm.profile)
  local sounds = profile.sounds or {}
  local sound = sounds[state.alarm.soundIndex] or sounds[1]
  state.alarm.soundIndex = state.alarm.soundIndex + 1
  if #sounds > 0 and state.alarm.soundIndex > #sounds then
    state.alarm.soundIndex = 1
  end

  for _, speaker in ipairs(findSpeakers()) do
    local played = playDspAlarm(profile, speaker)
    if (not played) and sound and speaker.playSound then
      pcall(speaker.playSound, sound.name, sound.volume or 2, sound.pitch or 1)
    elseif (not played) and speaker.playNote then
      pcall(speaker.playNote, "pling", sound and sound.volume or 2, sound and sound.pitch or 1)
    end
  end
end

function scheduleAlarmPulse()
  if state.alarm.active then
    scheduleTimer(alarmProfile(state.alarm.profile).repeatSeconds, { type = "alarm_pulse" })
  end
end

function raiseAlarm(reason, doorId, actor, profileName)
  profileName = profileName or "security"
  if state.alarm.active then
    if profileName == "emergency" and state.alarm.profile ~= "emergency" then
      setAlarmOutputs(false)
      state.alarm.reason = reason or "emergency"
      state.alarm.door = doorId
      state.alarm.actor = actor
      state.alarm.profile = "emergency"
      state.alarm.soundIndex = 1
      setAlarmOutputs(true)
      playAlarmPulse()
      local profile = alarmProfile("emergency")
      sendChat((profile.label or "EMERGENCY") .. ": " .. state.alarm.reason, "emergency")
      broadcastAlarmState()
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
  state.alarm.reason = reason or "alarm"
  state.alarm.door = doorId
  state.alarm.actor = actor
  state.alarm.profile = profileName
  state.alarm.since = os.clock()
  state.alarm.soundIndex = 1

  setAlarmOutputs(true)
  playAlarmPulse()
  scheduleAlarmPulse()
  local profile = alarmProfile(profileName)
  sendChat((profile.label or "ALARM") .. ": " .. state.alarm.reason, profileName)
  broadcastAlarmState()
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
  setAlarmOutputs(false)
  state.alarm.active = false
  state.alarm.reason = nil
  state.alarm.door = nil
  state.alarm.actor = nil
  state.alarm.profile = nil
  state.alarm.since = nil
  audit("ALARM_RESET", actor or "console")
  broadcastAlarmState()
  broadcastEventNotification("alarm_reset", "Alarm Reset", "Alarm cleared by " .. tostring(actor or "console"), "info")
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

  for _, name in ipairs(peripheral.getNames()) do
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

local genericBadgeMethods = {
  "getBadge",
  "readBadge",
  "scanBadge",
  "getCard",
  "readCard",
  "getCardData",
  "getRFID",
  "readRFID",
  "getLastBadge",
}

function candidatesFromValue(value)
  local candidates = {}
  local meta = {}

  if type(value) == "string" or type(value) == "number" then
    meta.id = tostring(value)
    meta.name = tostring(value)
    appendUnique(candidates, "badge:" .. tostring(value))
    appendUnique(candidates, tostring(value))
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
    "label",
    "name",
    "owner",
  }

  for _, key in ipairs(keys) do
    local item = value[key]
    if type(item) == "string" or type(item) == "number" then
      meta[key] = tostring(item)
      appendUnique(candidates, key .. ":" .. tostring(item))
      appendUnique(candidates, tostring(item))
      if key == "id" or key == "uuid" or key == "serial" or key == "code" or key == "badge" then
        appendUnique(candidates, "badge:" .. tostring(item))
      end
    end
  end

  meta.name = meta.name or meta.label or meta.owner or meta.id or meta.uuid or meta.serial or candidates[1]
  return candidates, meta
end

function pollGenericBadgeReaders()
  for _, name in ipairs(peripheral.getNames()) do
    if not isDrive(name) then
      local methods = methodMap(name)
      for _, method in ipairs(genericBadgeMethods) do
        if methods[method] then
          local device = peripheral.wrap(name)
          if device and device[method] then
            local ok, value = pcall(device[method])
            if ok and value ~= nil and value ~= false then
              local candidates, meta = candidatesFromValue(value)
              if #candidates > 0 then
                handleCredentials(name, "badge", candidates, meta, "badge:" .. name)
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
  for _, name in ipairs(peripheral.getNames()) do
    if hasPeripheralType(name, "rfid_scanner") then
      local device = peripheral.wrap(name)
      if device and device.scan then
        local ok, badges = pcall(device.scan)
        if ok and type(badges) == "table" then
          for _, badge in ipairs(badges) do
            if type(badge) == "table" and badge.data ~= nil then
              local data = tostring(badge.data)
              local candidates = {
                "rfid:" .. data,
                "badge:" .. data,
                data,
              }
              handleCredentials(name, "rfid", candidates, {
                name = data,
                id = data,
                distance = badge.distance,
              }, "rfid:" .. name .. ":" .. data)
            elseif type(badge) == "string" or type(badge) == "number" then
              local data = tostring(badge)
              local candidates = {
                "rfid:" .. data,
                "badge:" .. data,
                data,
              }
              handleCredentials(name, "rfid", candidates, {
                name = data,
                id = data,
              }, "rfid:" .. name .. ":" .. data)
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
  for _, name in ipairs(peripheral.getNames()) do
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

function readFacilitySensor(sensor)
  local sensorType = sensor.type or sensor.kind

  if sensorType == "create_stress" or sensorType == "create_power" or sensorType == "stressometer" then
    return readCreateStressSensor(sensor)
  end

  if sensorType == "create_speed" or sensorType == "speedometer" then
    return readSpeedSensor(sensor)
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

  return out
end

function checkConfiguredFacilitySensors()
  if config.facility and config.facility.enabled == false then
    return
  end

  for index, sensor in ipairs(configuredFacilitySensors()) do
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
        raiseAlarm(sensorReason(sensor, detail), nil, sensor.actor or "facility_sensor", sensorProfile(sensor))
        audit("SENSOR_FAULT", {
          sensor = sensor.name or sensor.peripheral or index,
          profile = sensorProfile(sensor),
          detail = detail,
        })
      elseif not triggered and state.sensors[key] then
        audit("SENSOR_CLEAR", {
          sensor = sensor.name or sensor.peripheral or index,
          detail = detail,
        })
      end

      state.sensors[key] = triggered
    end
  end
end

function checkAutoCreateStressSensors()
  if not (config.facility and config.facility.autoDiscoverCreateStress) then
    return
  end

  for _, name in ipairs(peripheral.getNames()) do
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
          raiseAlarm(sensorReason(sensor, detail), nil, "create_stress", sensor.profile)
          audit("SENSOR_FAULT", { sensor = name, profile = sensor.profile, detail = detail })
        elseif not triggered and state.sensors[key] then
          audit("SENSOR_CLEAR", { sensor = name, detail = detail })
        end
        state.sensors[key] = triggered
      end
    end
  end
end

function checkGlobalSensors()
  checkConfiguredFacilitySensors()
  checkAutoCreateStressSensors()
end

function pollInputs()
  pollDiskDrives()
  pollRfidScanners()
  pollGenericBadgeReaders()
  pollPlayerDetectors()
  checkDoorSensors()
  checkEmergencyButtons()
  checkGlobalSensors()
end

function openRednet()
  if not (config.rednet and config.rednet.enabled) or not rednet then
    return
  end

  for _, name in ipairs(peripheral.getNames()) do
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
  return secureRednet.send(rednet, target, message, config and config.rednet or {}, rednetProtocol())
end

function broadcastRednet(message)
  if not rednet then
    return false, "rednet unavailable"
  end
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

  for _, name in ipairs(peripheral.getNames()) do
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
    })
  end

  table.sort(out, function(a, b)
    return tostring(a.name) < tostring(b.name)
  end)
  return out
end

function controllerSenderAllowed(sender)
  local serverId = config and config.rednet and config.rednet.serverId
  return serverId == nil or tostring(sender) == tostring(serverId)
end

function handleControllerMessage(sender, message)
  if type(message) ~= "table" or not message.op then
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

function verifyEmployee(username, pin)
  local record = employeeRecord(username)
  if not record or record.disabled then
    return false, nil
  end
  return tostring(record.pin or "") == tostring(pin or ""), record
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

  local levels = config.employees and config.employees.clearanceLevels or {}
  return tonumber(levels[record.role or "employee"]) or tonumber(config.employees and config.employees.defaultClearance) or 1
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
    alarm = {
      active = state.alarm.active,
      reason = state.alarm.reason,
      door = state.alarm.door,
      actor = state.alarm.actor,
      profile = state.alarm.profile,
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

  local record, err = requireSetupPermission(message.token)
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

function handleRednetOperation(sender, message, reply)
  local op = message.op
  if op == "status" then
    handleStatusMessage(reply)
  elseif op == "kiosk_hello" then
    handleKioskHelloMessage(reply)
  elseif op == "kiosk_login" then
    handleKioskLoginMessage(sender, message, reply)
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

  for _, name in ipairs(peripheral.getNames()) do
    if hasPeripheralType(name, "monitor") then
      table.insert(out, name)
    end
  end
  return out
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
    "  employee list",
    "  employee add <user> <pin> [display name]",
    "  employee role <user> <role>",
    "  employee clearance <user> <level>",
    "  employee disable <user>",
    "  employee enable <user>",
    "  save",
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

function promptEndpoint(label, defaultSide, controller)
  print(label)
  local side = promptLine("  Redstone side", defaultSide or "back")
  local peripheralName = promptLine("  Redstone integrator/peripheral blank=computer side", "")
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
    output = promptEndpoint("Door lock/output endpoint", config.setup.defaultDoorSide or "front", controller),
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
  payload.reader = promptLine("Reader source to map blank=skip", "")

  local ok, message = handleSetupAction(payload, "console")
  print(ok and tostring(message) or ("Setup failed: " .. tostring(message)))
end

function setupConsoleAddSensor()
  print("Sensor type: 1 redstone  2 Create stress  3 generic peripheral")
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
  local payload = {
    action = "map_reader",
    source = promptLine("Reader source/peripheral name", ""),
    door = promptLine("Door id", ""),
  }
  local ok, message = handleSetupAction(payload, "console")
  print(ok and tostring(message) or ("Setup failed: " .. tostring(message)))
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
      printPeripheralSummary(peripheralSummary())
    elseif choice == "3" then
      local controller = promptLine("Controller computer id", "")
      local ok, scan = setupScanController(controller)
      if ok then
        print("Controller: " .. tostring(scan.controllerId or controller or "server"))
        printPeripheralSummary(scan.peripherals or {})
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
  elseif command == "save" then
    if requireAdmin() then
      saveConfig()
      print("Saved " .. CONFIG_FILE)
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

  local item = kioskNotifications.push(state.kiosk, notification, config.notifications and config.notifications.maxItems)
  if item then
    if item.kind == "announcement" or item.kind == "alarm" or item.kind == "emergency" or item.kind == "lockdown" then
      facilityAnnouncements.play(findSpeakers(), item, config.announcements or {})
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

  if message.branding then
    state.kiosk.branding = message.branding
  end
  if message.status then
    state.kiosk.status = message.status
  end

  local alarm = message.alarm or (message.status and message.status.alarm)
  if alarm then
    state.alarm.active = alarm.active and true or false
    state.alarm.reason = alarm.reason
    state.alarm.actor = alarm.actor
    state.alarm.door = alarm.door
    state.alarm.profile = alarm.profile
    if not state.alarm.active then
      state.alarm.soundIndex = 1
    end
  end

  if message.lockdown ~= nil then
    state.lockdown = message.lockdown and true or false
  elseif message.status and message.status.lockdown ~= nil then
    state.lockdown = message.status.lockdown and true or false
  end

  if sender then
    state.kiosk.serverId = sender
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
    if type(message) == "table" and message.op == "alarm_state" then
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
    if type(message) == "table" and message.ok and message.branding then
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
        if message.op == "alarm_state" then
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

function kioskAlarmSpeakerLoop()
  while state.kiosk.running do
    if state.alarm.active then
      local interval = tonumber(config.kiosk and config.kiosk.alarmSoundSeconds) or alarmProfile(state.alarm.profile).repeatSeconds or 1.5
      if os.clock() - (state.kiosk.lastAlarmSound or 0) >= interval then
        playAlarmPulse()
        state.kiosk.lastAlarmSound = os.clock()
      end
    else
      state.kiosk.lastAlarmSound = 0
    end
    sleep(0.1)
  end
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
    drawMonitors(true)
    sleep(tonumber(config.monitors and config.monitors.refreshSeconds) or 2)
  end
end

function kioskLogin(serverId, brand)
  while true do
    drawKioskHeader(brand)
    print("1. Sign in")
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

function kioskEndpointPrompt(label, defaultSide, controller)
  print(label)
  local side = kioskPromptLine("  Side", defaultSide or "back")
  local peripheralName = kioskPromptLine("  Peripheral blank=computer side", "")
  local analog = kioskPromptBool("  Analog", false)
  local endpoint = { side = side or defaultSide or "back" }
  if peripheralName and peripheralName ~= "" then
    endpoint.peripheral = peripheralName
  end
  if analog then
    endpoint.analog = true
    endpoint.threshold = kioskPromptNumber("  Threshold", 1)
  end
  if controller and controller ~= "" and controller ~= "server" and controller ~= "local" then
    endpoint.controller = controller
  end
  return endpoint
end

function kioskPrintSetupSummary(summary)
  print("Server computer: " .. tostring(summary.computerId or "?"))
  print("Setup clearance: C" .. tostring(summary.setupClearance or "?"))
  print("Doors")
  for _, door in ipairs(summary.doors or {}) do
    print("  " .. tostring(door.id) .. " - " .. tostring(door.label) .. " [" .. tostring(door.controller) .. "]")
  end
  print("Sensors: " .. tostring(#(summary.sensors or {})))
  print("Emergency buttons: " .. tostring(#(summary.emergencyButtons or {})))
end

function kioskPrintPeripheralSummary(items)
  printPeripheralSummary(items)
end

function kioskSetupAddDoor(serverId, token)
  local controller = kioskPromptLine("Controller id blank/server=server", "server")
  local payload = {
    action = "add_door",
    id = kioskPromptLine("Door id", nil),
    label = kioskPromptLine("Door label", nil),
    controller = controller,
    output = kioskEndpointPrompt("Output endpoint", "front", controller),
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
  payload.reader = kioskPromptLine("Reader source blank=skip", "")

  local reply = kioskSetupRequest(serverId, token, payload)
  print(reply.ok and tostring(reply.message or "Saved.") or ("Denied/failed: " .. tostring(reply.error)))
  pause()
end

function kioskSetupAddSensor(serverId, token)
  print("Sensor type: 1 redstone  2 Create stress  3 generic peripheral")
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
  else
    payload.sensorType = "redstone"
    payload.controller = kioskPromptLine("Controller id blank/server=server", "server")
    payload.input = kioskEndpointPrompt("Input endpoint", "left", payload.controller)
    payload.alarmWhen = kioskPromptBool("Active means fault", true)
  end

  local reply = kioskSetupRequest(serverId, token, payload)
  print(reply.ok and tostring(reply.message or "Saved.") or ("Denied/failed: " .. tostring(reply.error)))
  pause()
end

function kioskSetupAddEmergency(serverId, token)
  local controller = kioskPromptLine("Controller id blank/server=server", "server")
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
  local reply = kioskSetupRequest(serverId, token, {
    action = "map_reader",
    source = kioskPromptLine("Reader source", ""),
    door = kioskPromptLine("Door id", ""),
  })
  print(reply.ok and tostring(reply.message or "Saved.") or ("Denied/failed: " .. tostring(reply.error)))
  pause()
end

function kioskSetupMenu(serverId, brand, token, user)
  while true do
    drawKioskHeader(brand, user)
    print("Facility Setup")
    print("1. Summary")
    print("2. Scan server peripherals")
    print("3. Scan door controller")
    print("4. Add/update door")
    print("5. Add facility sensor")
    print("6. Add emergency button")
    print("7. Map reader to door")
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
        kioskPrintPeripheralSummary((reply.scan or {}).peripherals or {})
      else
        print("Scan failed: " .. tostring(reply.error))
      end
      pause()
    elseif choice == "3" then
      local controller = kioskPromptLine("Controller computer id", "")
      local reply = kioskSetupRequest(serverId, token, { action = "scan", controller = controller })
      if reply.ok then
        print("Controller: " .. tostring((reply.scan or {}).controllerId or controller))
        kioskPrintPeripheralSummary((reply.scan or {}).peripherals or {})
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
  config = loadConfig()
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
    parallel.waitForAny(kioskUiLoop, kioskNetworkLoop, kioskAlarmSpeakerLoop, kioskMonitorLoop, kioskMaintenanceLoop)
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
  config = loadConfig()
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

  while true do
    local event = { os.pullEventRaw() }
    local name = event[1]
    if name == "terminate" then
      return
    elseif name == "timer" and event[2] == helloTimer then
      broadcastControllerHello()
      helloTimer = os.startTimer(30)
    elseif name == "peripheral" or name == "peripheral_detach" then
      openRednet()
      broadcastControllerHello()
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
  end
end

function eventLoop()
  scheduleTimer(config.pollSeconds or 1, { type = "poll" })
  scheduleTimer((config.monitors and config.monitors.refreshSeconds) or 2, { type = "monitor" })
  scheduleTimer(tonumber(config.kiosk and config.kiosk.syncSeconds) or 2, { type = "alarm_broadcast" })
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

      if payload then
        if payload.type == "poll" then
          pollInputs()
          scheduleTimer(config.pollSeconds or 1, { type = "poll" })
        elseif payload.type == "monitor" then
          drawMonitors(true)
          scheduleTimer((config.monitors and config.monitors.refreshSeconds) or 2, { type = "monitor" })
        elseif payload.type == "alarm_broadcast" then
          broadcastAlarmState()
          scheduleTimer(tonumber(config.kiosk and config.kiosk.syncSeconds) or 2, { type = "alarm_broadcast" })
        elseif payload.type == "announcement" then
          local text, voiceLine = nextConfiguredAnnouncement()
          if text then
            broadcastAnnouncement(text, "auto", voiceLine)
          end
          scheduleAnnouncementTimer()
        elseif payload.type == "alarm_pulse" then
          if state.alarm.active then
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
      checkGlobalSensors()
    elseif name == "redstone" then
      checkDoorSensors()
      checkEmergencyButtons()
      checkGlobalSensors()
    elseif name == "peripheral" or name == "peripheral_detach" then
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

  config = loadConfig()
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
    parallel.waitForAny(eventLoop, consoleLoop)
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
