-- CC: Tweaked security system for doors, badges, alarms, sensors, and rednet.
-- Put this file on a computer as "startup.lua" or run it with:
--   security_system
--
-- The first run creates security_config.lua if it does not exist.

local CONFIG_FILE = "security_config.lua"
local LOG_FILE = "security_audit.log"
local ACCOUNTS_FILE = "security_accounts.lua"
local SOCIAL_FILE = "security_social.lua"
local PROTOCOL = "cc_security_v1"
local args = { ... }

local sides = { "top", "bottom", "left", "right", "front", "back" }
local unpackArgs = table.unpack or unpack

local defaultConfig = {
  mode = "server",
  siteName = "Base Security",
  facilityName = "Base Security",
  branding = {
    facilityName = "Base Security",
    shortName = "SEC",
    kioskTitle = "Employee Kiosk",
    motto = "Authorized staff only",
    primaryColor = "blue",
    accentColor = "lime",
    textColor = "white",
  },
  logFile = LOG_FILE,
  lockDoorsOnExit = true,
  clearAlarmOnExit = false,
  defaultOpenSeconds = 4,
  forcedGraceSeconds = 2,
  badgeCooldownSeconds = 3,
  pollSeconds = 1,

  adminPins = { "0000" },
  adminSessionSeconds = 300,

  rednet = {
    enabled = true,
    protocol = PROTOCOL,
    serverId = nil,
    discoverySeconds = 2,
  },

  employees = {
    enabled = true,
    allowSelfRegistration = false,
    accountsFile = ACCOUNTS_FILE,
    socialFile = SOCIAL_FILE,
    maxNoteLength = 4096,
    maxPostLength = 512,
    maxMessageLength = 512,
    maxFeedItems = 100,
    sessionSeconds = 1800,
    initialAccounts = {
      -- admin = { pin = "2468", displayName = "Facility Admin", role = "admin" },
    },
  },

  monitors = {
    enabled = true,
    textScale = 0.5,
  },

  alarm = {
    repeatSeconds = 1.5,
    deniedBeforeAlarm = 3,
    chat = true,
    sounds = {
      { name = "minecraft:block.note_block.pling", volume = 3, pitch = 0.6 },
      { name = "minecraft:block.note_block.bell", volume = 3, pitch = 1.8 },
    },
    outputs = {
      -- { side = "top" },
      -- { peripheral = "redstoneIntegrator_0", side = "back" },
    },
    profiles = {
      security = {
        label = "Security Alarm",
      },
      power_fault = {
        label = "Power Fault",
        sounds = {
          { name = "minecraft:block.note_block.bass", volume = 3, pitch = 0.7 },
          { name = "minecraft:block.note_block.pling", volume = 3, pitch = 1.2 },
        },
      },
      facility_fault = {
        label = "Facility Fault",
        sounds = {
          { name = "minecraft:block.note_block.bit", volume = 3, pitch = 0.8 },
          { name = "minecraft:block.note_block.bit", volume = 3, pitch = 1.6 },
        },
      },
    },
  },

  facility = {
    enabled = true,
    autoDiscoverCreateStress = false,
    autoStressMaxLoad = 0.9,
    autoStressProfile = "power_fault",
  },

  -- Source name to door id. Use "*" as a fallback for any reader.
  -- Disk drives, badge readers, player detectors, and remote reader peripherals
  -- are all treated as sources.
  readers = {
    ["*"] = "main",
  },

  -- Global credentials. The key is the credential string:
  --   disk:12345
  --   label:Guard Badge
  --   nfc:card-data
  --   rfid:badge-data
  --   player:Steve
  --   badge:custom-token
  credentials = {
    -- ["label:Guard Badge"] = { name = "Guard Badge", doors = { "main" } },
    -- ["player:Steve"] = { name = "Steve", doors = { "*" } },
  },

  doors = {
    main = {
      label = "Main Door",
      output = { side = "front" },
      activeOpen = true,
      openSeconds = 4,
      alarmOnDenied = true,
      badges = {
        -- "label:Guard Badge",
        -- "disk:12345",
      },
      players = {
        -- "Steve",
      },
      pins = {
        -- "1234",
      },

      -- Optional forced-open contact.
      -- contact = { side = "back", openWhen = true },

      -- Optional request-to-exit button.
      -- requestExit = { side = "right", activeWhen = true },
    },
  },

  sensors = {
    -- { name = "Vault Tripwire", input = { side = "left" }, alarmWhen = true },
    -- {
    --   name = "Main Stress Network",
    --   type = "create_stress",
    --   peripheral = "stressometer_0",
    --   maxLoad = 0.9,
    --   profile = "power_fault",
    -- },
  },

  generators = {
    -- Alias for facility power sensors. Create stressometers and Create: Avionics
    -- kinetic peripherals can be monitored here.
  },
}

local config
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

local function shallowCopy(value)
  if type(value) ~= "table" then
    return value
  end

  local copy = {}
  for k, v in pairs(value) do
    copy[k] = shallowCopy(v)
  end
  return copy
end

local function listContains(list, value)
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

local function listContainsIgnoreCase(list, value)
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

local function appendUnique(list, value)
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

local function tableKeys(map)
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

local function compact(value)
  if type(value) == "table" then
    local ok, encoded = pcall(textutils.serialize, value)
    if ok then
      return encoded
    end
  end
  return tostring(value)
end

local function timestamp()
  if os.date then
    return os.date("%Y-%m-%d %H:%M:%S")
  end
  return tostring(os.time())
end

local function audit(action, detail)
  local path = LOG_FILE
  if config and config.logFile then
    path = config.logFile
  end

  local ok, handle = pcall(fs.open, path, "a")
  if ok and handle then
    handle.writeLine(timestamp() .. " " .. action .. " " .. compact(detail or ""))
    handle.close()
  end
end

local function writeDefaultConfig()
  local handle = fs.open(CONFIG_FILE, "w")
  handle.writeLine("-- Generated by security_system.lua. Edit this file for your base.")
  handle.writeLine("return " .. textutils.serialize(defaultConfig))
  handle.close()
end

local function applyDefaults(userConfig)
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

  merged.rednet = merged.rednet or shallowCopy(defaultConfig.rednet)
  for key, value in pairs(defaultConfig.rednet) do
    if merged.rednet[key] == nil then
      merged.rednet[key] = shallowCopy(value)
    end
  end

  merged.employees = merged.employees or shallowCopy(defaultConfig.employees)
  for key, value in pairs(defaultConfig.employees) do
    if merged.employees[key] == nil then
      merged.employees[key] = shallowCopy(value)
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
  merged.generators = merged.generators or {}
  merged.facilityName = merged.facilityName or merged.siteName or merged.branding.facilityName
  if merged.branding.facilityName == defaultConfig.branding.facilityName and merged.facilityName ~= defaultConfig.facilityName then
    merged.branding.facilityName = merged.facilityName
  else
    merged.branding.facilityName = merged.branding.facilityName or merged.facilityName
  end

  return merged
end

local function loadConfig()
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

local function saveConfig()
  local handle = fs.open(CONFIG_FILE, "w")
  handle.writeLine("-- Saved by security_system.lua. Comments from the example file are not preserved.")
  handle.writeLine("return " .. textutils.serialize(config))
  handle.close()
  audit("CONFIG_SAVE", "saved")
end

local function loadDataFile(path, defaultValue)
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

local function saveDataFile(path, value)
  local handle = fs.open(path, "w")
  handle.writeLine("-- Saved by security_system.lua.")
  handle.writeLine("return " .. textutils.serialize(value or {}))
  handle.close()
end

local function nowMillis()
  if os.epoch then
    local ok, value = pcall(os.epoch, "utc")
    if ok and value then
      return value
    end
  end
  return math.floor(os.clock() * 1000)
end

local function makeId(prefix)
  return tostring(prefix or "id") .. "_" .. tostring(nowMillis()) .. "_" .. tostring(math.random(100000, 999999))
end

local function normalizeUsername(username)
  local text = tostring(username or "")
  text = string.gsub(text, "^%s+", "")
  text = string.gsub(text, "%s+$", "")
  return string.lower(text)
end

local function displayBranding()
  local branding = config and config.branding or {}
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

local function colorValue(name, fallback)
  if type(name) == "number" then
    return name
  end

  if type(name) == "string" and colors and colors[name] then
    return colors[name]
  end

  return fallback or colors.white
end

local function truncate(text, limit)
  text = tostring(text or "")
  limit = tonumber(limit) or 80
  if string.len(text) <= limit then
    return text
  end
  return string.sub(text, 1, math.max(0, limit - 3)) .. "..."
end

local function getTypes(name)
  local types = { peripheral.getType(name) }
  local map = {}
  for _, item in ipairs(types) do
    if item then
      map[tostring(item)] = true
    end
  end
  return map
end

local function hasPeripheralType(name, wanted)
  local types = getTypes(name)
  return types[wanted] == true
end

local function methodMap(name)
  local ok, methods = pcall(peripheral.getMethods, name)
  local out = {}
  if ok and type(methods) == "table" then
    for _, method in ipairs(methods) do
      out[method] = true
    end
  end
  return out
end

local function endpointList(value)
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

local function normalizeEndpoint(endpoint)
  if type(endpoint) == "string" then
    return { side = endpoint }
  end
  return endpoint
end

local function setEndpoint(endpoint, active)
  endpoint = normalizeEndpoint(endpoint)
  if type(endpoint) ~= "table" then
    return false, "invalid endpoint"
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

local function readEndpoint(endpoint)
  endpoint = normalizeEndpoint(endpoint)
  if type(endpoint) ~= "table" then
    return false, nil
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

local function setOutputList(outputs, active)
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

local function getDoorState(doorId)
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

local function setDoorOpen(doorId, open)
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

  return setOutputList(outputs, active)
end

local function scheduleTimer(seconds, payload)
  local id = os.startTimer(seconds)
  state.timers[id] = payload
  return id
end

local function markDirty()
  state.screenDirty = true
end

local function lockDoor(doorId, reason, quiet)
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

local function findSpeakers()
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

local function findChatBox()
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

local function alarmProfile(profileName)
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
    outputs = profile.outputs or profile.output or alarm.outputs or alarm.output,
  }
end

local function sendChat(message, profileName)
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

local function setAlarmOutputs(active)
  local profile = alarmProfile(state.alarm.profile)
  setOutputList(profile.outputs, active)
end

local function playAlarmPulse()
  local profile = alarmProfile(state.alarm.profile)
  local sounds = profile.sounds or {}
  if #sounds == 0 then
    return
  end

  local sound = sounds[state.alarm.soundIndex] or sounds[1]
  state.alarm.soundIndex = state.alarm.soundIndex + 1
  if state.alarm.soundIndex > #sounds then
    state.alarm.soundIndex = 1
  end

  for _, speaker in ipairs(findSpeakers()) do
    if speaker.playSound then
      pcall(speaker.playSound, sound.name, sound.volume or 2, sound.pitch or 1)
    elseif speaker.playNote then
      pcall(speaker.playNote, "pling", sound.volume or 2, sound.pitch or 1)
    end
  end
end

local function scheduleAlarmPulse()
  if state.alarm.active then
    scheduleTimer(alarmProfile(state.alarm.profile).repeatSeconds, { type = "alarm_pulse" })
  end
end

local function raiseAlarm(reason, doorId, actor, profileName)
  profileName = profileName or "security"
  if state.alarm.active then
    audit("ALARM_UPDATE", {
      reason = reason,
      door = doorId,
      actor = actor,
      profile = profileName,
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
  audit("ALARM_RAISED", {
    reason = state.alarm.reason,
    door = doorId,
    actor = actor,
    profile = profileName,
  })
  markDirty()
end

local function resetAlarm(actor)
  setAlarmOutputs(false)
  state.alarm.active = false
  state.alarm.reason = nil
  state.alarm.door = nil
  state.alarm.actor = nil
  state.alarm.profile = nil
  state.alarm.since = nil
  audit("ALARM_RESET", actor or "console")
  markDirty()
end

local function unlockDoor(doorId, actor, seconds, reason)
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

local function expectedValue(endpoint, defaultValue)
  if type(endpoint) == "table" and endpoint.activeWhen ~= nil then
    return endpoint.activeWhen and true or false
  end
  return defaultValue
end

local function denyAccess(doorId, actor, source, reason)
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

local function recordAllowsDoor(record, doorId)
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

local function credentialRecord(credential)
  if type(config.credentials) == "table" and config.credentials[credential] ~= nil then
    return config.credentials[credential]
  end

  if type(config.badges) == "table" and config.badges[credential] ~= nil then
    return config.badges[credential]
  end

  return nil
end

local function authorizedCredential(doorId, kind, candidates, meta)
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

local function authorizedPin(doorId, pin)
  local door = config.doors[doorId]
  if not door or state.lockdown then
    return false
  end

  return listContains(door.pins, tostring(pin))
end

local function authorizedAdminPin(pin)
  return listContains(config.adminPins, tostring(pin))
end

local function doorIdsForSource(source)
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

local function shouldAcceptBadge(key, fingerprint)
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

local function handleCredentials(source, kind, candidates, meta, cooldownKey)
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

local function diskCandidates(name)
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

local function isDrive(name)
  if hasPeripheralType(name, "drive") then
    return true
  end

  local methods = methodMap(name)
  return methods.isDiskPresent == true
end

local function driveNames()
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

local function pollDiskDrives()
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

local function candidatesFromValue(value)
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

local function pollGenericBadgeReaders()
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

local function pollRfidScanners()
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

local function isPlayerDetector(name)
  local methods = methodMap(name)
  return methods.getPlayersInRange or methods.getPlayers or methods.getOnlinePlayers or methods.getPlayerNames
end

local function playerListFromDetector(name)
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

local function pollPlayerDetectors()
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

local function checkDoorSensors()
  local now = os.clock()

  for _, doorId in ipairs(tableKeys(config.doors)) do
    local door = config.doors[doorId]
    local doorState = getDoorState(doorId)

    if door.contact then
      local active, raw = readEndpoint(door.contact)
      if raw ~= nil then
        local isOpen = active == expectedValue(door.contact, door.contact.openWhen ~= false)
        if isOpen and doorState.locked and now > (doorState.authorizedUntil or 0) then
          raiseAlarm("forced door " .. tostring(doorId), doorId, doorState.lastActor)
        end
      end
    end

    if door.requestExit then
      local key = "exit:" .. tostring(doorId)
      local active, raw = readEndpoint(door.requestExit)
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

local function callPeripheralValue(sensor, methodName)
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

local function numberOrNil(value)
  if type(value) == "number" then
    return value
  end
  if type(value) == "string" then
    return tonumber(value)
  end
  return nil
end

local function compareSensorValue(value, sensor)
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

local function readCreateStressSensor(sensor)
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

local function readSpeedSensor(sensor)
  local method = sensor.method or "getSpeed"
  local ok, value, err = callPeripheralValue(sensor, method)
  if not ok then
    return nil, err
  end
  return compareSensorValue(value, sensor), { value = value, method = method }
end

local function readFacilitySensor(sensor)
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

local function sensorProfile(sensor)
  return sensor.profile or sensor.alarmProfile or sensor.severity or "facility_fault"
end

local function sensorReason(sensor, detail)
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

local function configuredFacilitySensors()
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

local function checkConfiguredFacilitySensors()
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

local function checkAutoCreateStressSensors()
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

local function checkGlobalSensors()
  checkConfiguredFacilitySensors()
  checkAutoCreateStressSensors()
end

local function pollInputs()
  pollDiskDrives()
  pollRfidScanners()
  pollGenericBadgeReaders()
  pollPlayerDetectors()
  checkDoorSensors()
  checkGlobalSensors()
end

local function openRednet()
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

local function accountsPath()
  return (config.employees and config.employees.accountsFile) or ACCOUNTS_FILE
end

local function socialPath()
  return (config.employees and config.employees.socialFile) or SOCIAL_FILE
end

local function ensureEmployeeTables()
  state.accounts.users = state.accounts.users or {}
  state.accounts.notes = state.accounts.notes or {}
  state.social.feed = state.social.feed or {}
  state.social.messages = state.social.messages or {}
end

local function saveAccounts()
  ensureEmployeeTables()
  saveDataFile(accountsPath(), {
    users = state.accounts.users,
    notes = state.accounts.notes,
  })
end

local function saveSocial()
  ensureEmployeeTables()
  saveDataFile(socialPath(), state.social)
end

local function loadEmployeeData()
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

local function publicBrandPayload()
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
  }
end

local function employeeRecord(username)
  ensureEmployeeTables()
  return state.accounts.users[normalizeUsername(username)]
end

local function publicEmployee(record)
  if not record then
    return nil
  end
  return {
    username = record.username,
    displayName = record.displayName or record.username,
    role = record.role or "employee",
  }
end

local function verifyEmployee(username, pin)
  local record = employeeRecord(username)
  if not record or record.disabled then
    return false, nil
  end
  return tostring(record.pin or "") == tostring(pin or ""), record
end

local function createSession(username)
  local record = employeeRecord(username)
  if not record then
    return nil
  end

  local token = makeId("session")
  state.sessions[token] = {
    username = record.username,
    expires = os.clock() + ((config.employees and config.employees.sessionSeconds) or 1800),
  }
  return token
end

local function sessionRecord(token)
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

local function employeeIsAdmin(record)
  return record and (record.role == "admin" or record.role == "security" or record.role == "manager")
end

local function registerEmployee(username, pin, displayName)
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
    createdAt = timestamp(),
  }
  saveAccounts()
  audit("EMPLOYEE_REGISTER", key)
  return true
end

local function notesFor(username)
  ensureEmployeeTables()
  local key = normalizeUsername(username)
  state.accounts.notes[key] = state.accounts.notes[key] or {}
  return state.accounts.notes[key]
end

local function socialMailbox(username)
  ensureEmployeeTables()
  local key = normalizeUsername(username)
  state.social.messages[key] = state.social.messages[key] or {}
  return state.social.messages[key]
end

local function capEmployeeText(text, maxLength)
  text = tostring(text or "")
  maxLength = tonumber(maxLength) or 512
  if string.len(text) > maxLength then
    text = string.sub(text, 1, maxLength)
  end
  return text
end

local function addEmployeeNote(record, title, body, noteId)
  local notes = notesFor(record.username)
  local maxLength = (config.employees and config.employees.maxNoteLength) or 4096
  local id = tostring(noteId or makeId("note"))
  local found = false

  for _, note in ipairs(notes) do
    if note.id == id then
      note.title = capEmployeeText(title, 80)
      note.body = capEmployeeText(body, maxLength)
      note.updatedAt = timestamp()
      found = true
      break
    end
  end

  if not found then
    table.insert(notes, {
      id = id,
      title = capEmployeeText(title, 80),
      body = capEmployeeText(body, maxLength),
      createdAt = timestamp(),
      updatedAt = timestamp(),
    })
  end

  saveAccounts()
  return id
end

local function deleteEmployeeNote(record, noteId)
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

local function addFeedPost(record, text)
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
  return post
end

local function sendDirectMessage(record, toUser, text)
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
  return true
end

local function employeeList()
  local out = {}
  for _, username in ipairs(tableKeys(state.accounts.users)) do
    local record = state.accounts.users[username]
    if record and not record.disabled then
      table.insert(out, publicEmployee(record))
    end
  end
  return out
end

local function statusSnapshot()
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
    sensors = state.sensorDetails,
  }
end

local function handleRednet(sender, message, protocol)
  local wantedProtocol = config.rednet.protocol or PROTOCOL
  if protocol ~= wantedProtocol then
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

  local reply = { ok = false }

  if message.op == "status" then
    reply.ok = true
    reply.status = statusSnapshot()
  elseif message.op == "kiosk_hello" then
    reply.ok = true
    reply.serverId = os.getComputerID and os.getComputerID() or nil
    reply.branding = publicBrandPayload()
    reply.status = statusSnapshot()
  elseif message.op == "kiosk_login" then
    local ok, record = verifyEmployee(message.username, message.pin)
    if ok then
      reply.ok = true
      reply.token = createSession(record.username)
      reply.user = publicEmployee(record)
      reply.branding = publicBrandPayload()
      audit("EMPLOYEE_LOGIN", { user = record.username, sender = sender })
    else
      reply.error = "invalid login"
      audit("EMPLOYEE_LOGIN_DENIED", { user = message.username, sender = sender })
    end
  elseif message.op == "kiosk_register" then
    local ok, err = registerEmployee(message.username, message.pin, message.displayName)
    reply.ok = ok
    reply.error = err
    reply.branding = publicBrandPayload()
  elseif message.op == "kiosk_logout" then
    if message.token then
      state.sessions[tostring(message.token)] = nil
    end
    reply.ok = true
  elseif message.op == "kiosk_notes" then
    local record = sessionRecord(message.token)
    if record then
      reply.ok = true
      reply.notes = notesFor(record.username)
    else
      reply.error = "session expired"
    end
  elseif message.op == "kiosk_save_note" then
    local record = sessionRecord(message.token)
    if record then
      reply.ok = true
      reply.id = addEmployeeNote(record, message.title or "Untitled", message.body or "", message.id)
    else
      reply.error = "session expired"
    end
  elseif message.op == "kiosk_delete_note" then
    local record = sessionRecord(message.token)
    if record then
      reply.ok = deleteEmployeeNote(record, tostring(message.id or ""))
      if not reply.ok then
        reply.error = "note not found"
      end
    else
      reply.error = "session expired"
    end
  elseif message.op == "kiosk_feed" then
    local record = sessionRecord(message.token)
    if record then
      reply.ok = true
      reply.feed = state.social.feed
    else
      reply.error = "session expired"
    end
  elseif message.op == "kiosk_post" then
    local record = sessionRecord(message.token)
    if record then
      reply.ok = true
      reply.post = addFeedPost(record, message.text or "")
    else
      reply.error = "session expired"
    end
  elseif message.op == "kiosk_inbox" then
    local record = sessionRecord(message.token)
    if record then
      reply.ok = true
      reply.messages = socialMailbox(record.username)
    else
      reply.error = "session expired"
    end
  elseif message.op == "kiosk_send" then
    local record = sessionRecord(message.token)
    if record then
      local ok, err = sendDirectMessage(record, message.to, message.text or "")
      reply.ok = ok
      reply.error = err
    else
      reply.error = "session expired"
    end
  elseif message.op == "kiosk_people" then
    local record = sessionRecord(message.token)
    if record then
      reply.ok = true
      reply.people = employeeList()
    else
      reply.error = "session expired"
    end
  elseif message.op == "kiosk_status" then
    local record = sessionRecord(message.token)
    if record then
      reply.ok = true
      reply.status = statusSnapshot()
    else
      reply.error = "session expired"
    end
  elseif message.op == "facility_fault" then
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
  elseif message.op == "unlock" then
    local doorId = tostring(message.door or "")
    if not config.doors[doorId] then
      reply.error = "unknown door"
    elseif message.pin and authorizedPin(doorId, message.pin) then
      local ok, err = unlockDoor(doorId, "rednet:" .. tostring(sender), message.seconds, "rednet_pin")
      reply.ok = ok
      reply.error = err
    elseif message.credential or message.badge then
      local credential = tostring(message.credential or message.badge)
      local candidates = { credential }
      if not string.find(credential, ":", 1, true) then
        appendUnique(candidates, "badge:" .. credential)
      end

      local allowed = authorizedCredential(doorId, "badge", candidates, { name = "rednet:" .. tostring(sender) })
      if allowed then
        local ok, err = unlockDoor(doorId, "rednet:" .. tostring(sender), message.seconds, "rednet_credential")
        reply.ok = ok
        reply.error = err
      else
        denyAccess(doorId, "rednet:" .. tostring(sender), "rednet", "credential_rejected")
        reply.error = "denied"
      end
    else
      reply.error = "missing pin or credential"
    end
  elseif message.op == "reset_alarm" then
    if authorizedAdminPin(message.adminPin) then
      resetAlarm("rednet:" .. tostring(sender))
      reply.ok = true
    else
      reply.error = "denied"
    end
  else
    reply.error = "unknown op"
  end

  pcall(rednet.send, sender, reply, wantedProtocol)
end

local function monitorNames()
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

local function drawMonitor(name)
  local monitor = peripheral.wrap(name)
  if not monitor then
    return
  end

  if monitor.setTextScale and config.monitors.textScale then
    pcall(monitor.setTextScale, config.monitors.textScale)
  end

  local width, height = monitor.getSize()
  local bg = state.alarm.active and colors.red or colors.black
  local fg = colors.white
  monitor.setBackgroundColor(bg)
  monitor.setTextColor(fg)
  monitor.clear()

  local brand = displayBranding()
  monitor.setCursorPos(1, 1)
  monitor.write(string.sub(brand.facilityName or config.siteName or "Security", 1, width))

  monitor.setCursorPos(1, 2)
  if state.alarm.active then
    monitor.setTextColor(colors.yellow)
    local profile = alarmProfile(state.alarm.profile)
    monitor.write(string.sub((profile.label or "ALARM") .. " " .. tostring(state.alarm.reason or ""), 1, width))
  elseif state.lockdown then
    monitor.setTextColor(colors.orange)
    monitor.write("LOCKDOWN")
  else
    monitor.setTextColor(colors.lime)
    monitor.write("SECURE")
  end

  local y = 4
  for _, doorId in ipairs(tableKeys(config.doors)) do
    if y > height then
      break
    end

    local door = config.doors[doorId]
    local doorState = getDoorState(doorId)
    local label = door.label or doorId
    local status = doorState.locked and "LOCKED" or "OPEN"
    monitor.setCursorPos(1, y)
    monitor.setTextColor(doorState.locked and colors.lightGray or colors.lime)
    monitor.write(string.sub(label .. ": " .. status, 1, width))
    y = y + 1
  end
end

local function drawMonitors(force)
  if not force and not state.screenDirty then
    return
  end

  for _, name in ipairs(monitorNames()) do
    pcall(drawMonitor, name)
  end

  state.screenDirty = false
end

local function printStatus()
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

local function splitWords(line)
  local words = {}
  for word in string.gmatch(line or "", "%S+") do
    table.insert(words, word)
  end
  return words
end

local function joinWords(words, startIndex)
  local parts = {}
  for index = startIndex, #words do
    table.insert(parts, words[index])
  end
  return table.concat(parts, " ")
end

local function requireAdmin()
  if os.clock() < state.consoleAdminUntil then
    return true
  end
  print("Admin login required. Use: login <pin>")
  return false
end

local function wrapConsoleLine(line, width)
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

local function waitForHelpPage()
  write("-- more --")
  local _, key = os.pullEvent("key")
  local _, y = term.getCursorPos()
  term.setCursorPos(1, y)
  term.clearLine()
  return keys and key == keys.q
end

local function printPaged(lines)
  local width, height = term.getSize()
  local pageLines = math.max(3, height - 3)
  local printed = 0

  for lineIndex, line in ipairs(lines) do
    local wrapped = wrapConsoleLine(line, width)
    for wrappedIndex, part in ipairs(wrapped) do
      print(part)
      printed = printed + 1

      local hasMore = lineIndex < #lines or wrappedIndex < #wrapped
      if hasMore and printed >= pageLines then
        if waitForHelpPage() then
          return
        end
        printed = 0
      end
    end
  end
end

local function printHelp()
  printPaged({
    "Commands:",
    "  status",
    "  pin <door> <pin>",
    "  login <admin-pin>",
    "  unlock <door> [seconds]",
    "  lock <door>",
    "  alarm <reason>",
    "  reset",
    "  lockdown",
    "  unlockdown",
    "  allow badge <door> <credential>",
    "  allow player <door> <player>",
    "  employee list",
    "  employee add <user> <pin> [display name]",
    "  employee role <user> <role>",
    "  employee disable <user>",
    "  employee enable <user>",
    "  save",
    "  quit",
    "",
    "Press any key at -- more --, or Q to stop help.",
  })
end

local function addDoorCredential(doorId, credential)
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

local function addDoorPlayer(doorId, player)
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

local function handleEmployeeCommand(words)
  local subcommand = string.lower(words[2] or "")

  if subcommand == "list" then
    for _, person in ipairs(employeeList()) do
      print(person.username .. " - " .. tostring(person.displayName) .. " (" .. tostring(person.role) .. ")")
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
    print("Usage: employee list|add|role|disable|enable")
  end
end

local function handleCommand(line)
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
      print("Lockdown enabled")
    end
  elseif command == "unlockdown" then
    if requireAdmin() then
      state.lockdown = false
      audit("LOCKDOWN_CLEAR", "console")
      markDirty()
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

local function consoleLoop()
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

local function clearScreen()
  term.setCursorPos(1, 1)
  term.clear()
end

local function drawKioskHeader(brand, user)
  brand = brand or displayBranding()
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
  print(string.rep("-", 28))

  if term.isColor and term.isColor() then
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
  end
end

local function kioskRead(label, mask)
  write(label)
  if mask then
    return read(mask)
  end
  return read()
end

local function pause()
  print()
  write("Press enter...")
  read()
end

local function kioskRequest(serverId, op, payload, timeout)
  if not rednet then
    return { ok = false, error = "rednet unavailable" }
  end

  payload = payload or {}
  payload.op = op
  local protocol = (config.rednet and config.rednet.protocol) or PROTOCOL
  local okSend, sendErr = pcall(rednet.send, serverId, payload, protocol)
  if not okSend then
    return { ok = false, error = sendErr }
  end

  local deadline = os.clock() + (timeout or 5)
  while os.clock() < deadline do
    local remaining = math.max(0.1, deadline - os.clock())
    local okReceive, sender, message = pcall(rednet.receive, protocol, remaining)
    if not okReceive then
      return { ok = false, error = sender }
    end
    if sender == serverId and type(message) == "table" then
      return message
    end
  end

  return { ok = false, error = "server timeout" }
end

local function discoverServer()
  if not rednet then
    return nil, displayBranding(), nil
  end

  openRednet()
  local protocol = (config.rednet and config.rednet.protocol) or PROTOCOL
  local configured = config.rednet and config.rednet.serverId
  if configured then
    local reply = kioskRequest(configured, "kiosk_hello", {}, config.rednet.discoverySeconds or 2)
    if reply.ok then
      return configured, reply.branding or displayBranding(), reply.status
    end
  end

  local okBroadcast = pcall(rednet.broadcast, { op = "kiosk_hello" }, protocol)
  if not okBroadcast then
    return nil, displayBranding(), nil
  end
  local timeout = (config.rednet and config.rednet.discoverySeconds) or 2
  local deadline = os.clock() + timeout
  while os.clock() < deadline do
    local okReceive, sender, message = pcall(rednet.receive, protocol, math.max(0.1, deadline - os.clock()))
    if not okReceive then
      return nil, displayBranding(), nil
    end
    if type(message) == "table" and message.ok and message.branding then
      return sender, message.branding, message.status
    end
  end

  return nil, displayBranding(), nil
end

local function kioskLogin(serverId, brand)
  while true do
    drawKioskHeader(brand)
    print("1. Sign in")
    if brand.allowSelfRegistration then
      print("2. Create account")
    end
    print("R. Retry server")
    print("Q. Quit")
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
    elseif choice == "q" then
      return nil, nil, brand, "quit"
    end
  end
end

local function printNotes(notes)
  if not notes or #notes == 0 then
    print("No notes.")
    return
  end

  for index, note in ipairs(notes) do
    print(tostring(index) .. ". " .. truncate(note.title or "Untitled", 24) .. " [" .. tostring(note.id) .. "]")
    print("   " .. truncate(note.body or "", 44))
  end
end

local function kioskNotes(serverId, brand, token, user)
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
    print("A. Add/update note")
    print("D. Delete note")
    print("B. Back")
    local choice = string.lower(kioskRead("> "))
    if choice == "a" then
      local id = kioskRead("Existing note id, or blank: ")
      if id == "" then
        id = nil
      end
      local title = kioskRead("Title: ")
      print("Body. End with a single '.' line.")
      local lines = {}
      while true do
        local line = read()
        if line == "." then
          break
        end
        table.insert(lines, line)
      end
      local saved = kioskRequest(serverId, "kiosk_save_note", {
        token = token,
        id = id,
        title = title,
        body = table.concat(lines, "\n"),
      })
      print(saved.ok and ("Saved " .. tostring(saved.id)) or ("Failed: " .. tostring(saved.error)))
      pause()
    elseif choice == "d" then
      local id = kioskRead("Note id: ")
      local deleted = kioskRequest(serverId, "kiosk_delete_note", { token = token, id = id })
      print(deleted.ok and "Deleted." or ("Failed: " .. tostring(deleted.error)))
      pause()
    elseif choice == "b" then
      return true
    end
  end
end

local function kioskFeed(serverId, brand, token, user)
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

local function kioskMessages(serverId, brand, token, user)
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

local function kioskPeople(serverId, brand, token, user)
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

local function kioskStatus(serverId, brand, token, user)
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

local function kioskMenu(serverId, brand, token, user)
  while true do
    drawKioskHeader(brand, user)
    print("1. Personal notes")
    print("2. Facility feed")
    print("3. Messages")
    print("4. Employee directory")
    print("5. Facility status")
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
    elseif choice == "l" then
      kioskRequest(serverId, "kiosk_logout", { token = token }, 2)
      return "logout"
    end
  end
end

local function kioskMain()
  config = loadConfig()
  config.mode = "kiosk"

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
      if action == "quit" then
        return
      elseif action ~= "retry" and token and user then
        kioskMenu(serverId, brand, token, user)
      end
    end
  end
end

local function initializeDoors()
  for _, doorId in ipairs(tableKeys(config.doors)) do
    getDoorState(doorId)
    lockDoor(doorId, "startup", true)
  end
end

local function shutdownHardware()
  if config.lockDoorsOnExit ~= false then
    for _, doorId in ipairs(tableKeys(config.doors)) do
      lockDoor(doorId, "shutdown", true)
    end
  end

  if config.clearAlarmOnExit then
    setAlarmOutputs(false)
  end
end

local function eventLoop()
  scheduleTimer(config.pollSeconds or 1, { type = "poll" })
  scheduleTimer(1, { type = "monitor" })

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
          drawMonitors(false)
          scheduleTimer(1, { type = "monitor" })
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
    elseif name == "peripheral" or name == "peripheral_detach" then
      openRednet()
      markDirty()
    elseif name == "rednet_message" then
      handleRednet(event[2], event[3], event[4])
    end
  end
end

local function main()
  local requestedMode = args[1] and string.lower(tostring(args[1])) or nil
  if requestedMode == "kiosk" then
    kioskMain()
    return
  end

  config = loadConfig()
  if requestedMode and requestedMode ~= "" then
    config.mode = requestedMode
  end

  math.randomseed(nowMillis() % 2147483647)

  if string.lower(tostring(config.mode or "server")) == "kiosk" then
    kioskMain()
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

main()
