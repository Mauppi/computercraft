-- Kiosk notification queues and sounds for the CC: Tweaked security system.

local M = {}

local okAnnouncementAudio, announcementAudio = pcall(require, "security_system_announcements")
if not okAnnouncementAudio then
  announcementAudio = nil
end

local defaultWavKinds = {
  dm = true,
  social = true,
  message = true,
  feed = true,
}

local blockedWavKinds = {
  alarm = true,
  alarm_reset = true,
  announcement = true,
  emergency = true,
  lockdown = true,
  lockdown_clear = true,
}

local function copyNotification(notification)
  local out = {}
  for key, value in pairs(notification or {}) do
    out[key] = value
  end
  return out
end

local function notificationId(notification)
  return tostring(notification.id or "") .. ":" .. tostring(notification.kind or notification.type or "") .. ":" .. tostring(notification.createdAt or "")
end

function M.ensure(state, maxItems)
  state.notifications = state.notifications or {}
  state.notificationSeen = state.notificationSeen or {}
  state.maxNotifications = tonumber(maxItems) or state.maxNotifications or 12
  return state
end

function M.push(state, notification, maxItems)
  if type(notification) ~= "table" then
    return nil
  end

  M.ensure(state, maxItems)
  local id = notificationId(notification)
  if id ~= "::" and state.notificationSeen[id] then
    return nil
  end

  local item = copyNotification(notification)
  if not item.createdAt then
    item.createdAt = tostring(os.clock())
  end
  if not item.id then
    item.id = tostring(item.kind or "note") .. "_" .. tostring(item.createdAt)
  end

  state.notificationSeen[notificationId(item)] = true
  table.insert(state.notifications, 1, item)
  while #state.notifications > state.maxNotifications do
    table.remove(state.notifications)
  end
  return item
end

function M.latest(state)
  M.ensure(state)
  return state.notifications[1]
end

function M.lines(state, limit)
  M.ensure(state)
  local out = {}
  limit = tonumber(limit) or 3
  for index, item in ipairs(state.notifications) do
    if index > limit then
      break
    end
    local title = tostring(item.title or item.kind or "Notice")
    local text = tostring(item.text or "")
    if text ~= "" then
      out[#out + 1] = title .. ": " .. text
    else
      out[#out + 1] = title
    end
  end
  return out
end

local function soundConfig(config, kind)
  local notifications = config and config.notifications or {}
  local sounds = notifications.sounds or {}
  return sounds[kind] or sounds.default or {
    { name = "minecraft:block.note_block.pling", volume = 1.2, pitch = 1.4 },
  }
end

local function isWavPath(path)
  return string.sub(string.lower(tostring(path or "")), -4) == ".wav"
end

local function soundList(sounds)
  if type(sounds) == "string" then
    return { sounds }
  end
  if type(sounds) ~= "table" then
    return {}
  end
  if #sounds > 0 then
    return sounds
  end
  return { sounds }
end

local function wavKindAllowed(notifications, kind)
  kind = tostring(kind or "default")
  if blockedWavKinds[kind] then
    return false
  end

  local allowed = notifications and notifications.wavKinds
  if type(allowed) == "table" then
    if allowed[kind] ~= nil then
      return allowed[kind] == true
    end
    for _, value in ipairs(allowed) do
      if tostring(value) == kind then
        return true
      end
    end
    return false
  end

  return defaultWavKinds[kind] == true
end

local function appendSamples(buffer, samples)
  if type(samples) ~= "table" then
    return
  end
  for index = 1, #samples do
    buffer[#buffer + 1] = samples[index]
  end
end

local function loadWav(path, audioConfig)
  if not (announcementAudio and announcementAudio.loadWav) then
    return nil
  end
  local ok, samples = pcall(announcementAudio.loadWav, path, audioConfig)
  if ok and type(samples) == "table" and #samples > 0 then
    return samples
  end
  return nil
end

local function wavPath(sound)
  if type(sound) == "string" then
    return isWavPath(sound) and sound or nil
  end
  if type(sound) ~= "table" then
    return nil
  end
  return sound.wav or sound.file or sound.path
end

local function notificationPcm(sound, audioConfig)
  if type(sound) ~= "table" then
    local path = wavPath(sound)
    return path and loadWav(path, audioConfig) or nil
  end

  if type(sound.pcm) == "table" then
    return sound.pcm
  end

  local buffer = {}
  if type(sound.files) == "table" then
    for _, path in ipairs(sound.files) do
      appendSamples(buffer, loadWav(path, audioConfig))
    end
  else
    appendSamples(buffer, loadWav(wavPath(sound), audioConfig))
  end

  if #buffer > 0 then
    return buffer
  end
  return nil
end

local function playPcm(speaker, pcm, volume, audioConfig)
  if not (speaker and speaker.playAudio and type(pcm) == "table" and #pcm > 0) then
    return false
  end

  local maxSamples = tonumber(audioConfig and audioConfig.maxSamples) or 128000
  if maxSamples <= 0 or #pcm <= maxSamples then
    local ok, accepted = pcall(speaker.playAudio, pcm, volume)
    return ok and accepted ~= false
  end

  local chunkSamples = tonumber(audioConfig and (audioConfig.chunkSamples or audioConfig.playbackSamples)) or maxSamples
  if chunkSamples <= 0 then
    chunkSamples = maxSamples
  end
  chunkSamples = math.floor(chunkSamples)
  if chunkSamples < 1024 then
    chunkSamples = 1024
  elseif chunkSamples > 128000 then
    chunkSamples = 128000
  end

  local sampleRate = tonumber(audioConfig and audioConfig.sampleRate) or 48000
  if sampleRate <= 0 then
    sampleRate = 48000
  end
  local tailSeconds = tonumber(audioConfig and audioConfig.tailSeconds) or 0.25
  local graceSeconds = tonumber(audioConfig and audioConfig.streamGraceSeconds) or 10
  local deadline = os.clock() + (#pcm / sampleRate) + graceSeconds
  local nextIndex = 1
  local queuedUntil = nil
  local started = false

  local function waitForSpeaker(seconds)
    seconds = tonumber(seconds) or 0.25
    if os and os.startTimer and (os.pullEventRaw or os.pullEvent) then
      local pull = os.pullEventRaw or os.pullEvent
      local timer = os.startTimer(seconds)
      while true do
        local event = { pull() }
        if event[1] == "speaker_audio_empty" or (event[1] == "timer" and event[2] == timer) then
          return
        end
      end
    elseif sleep then
      sleep(seconds)
    end
  end

  while nextIndex <= #pcm and os.clock() <= deadline do
    local last = math.min(#pcm, nextIndex + chunkSamples - 1)
    local chunk = {}
    local outIndex = 1
    for index = nextIndex, last do
      chunk[outIndex] = pcm[index]
      outIndex = outIndex + 1
    end

    local ok, accepted = pcall(speaker.playAudio, chunk, volume)
    if not ok then
      return started
    end
    if accepted == false then
      local waitSeconds = 0.25
      if queuedUntil then
        waitSeconds = (queuedUntil - os.clock()) - 0.25
        if waitSeconds < 0.05 then
          waitSeconds = 0.05
        elseif waitSeconds > 1 then
          waitSeconds = 1
        end
      end
      waitForSpeaker(waitSeconds)
    else
      local now = os.clock()
      local queuedSamples = last - nextIndex + 1
      queuedUntil = math.max(queuedUntil or now, now) + (queuedSamples / sampleRate)
      nextIndex = last + 1
      started = true
    end
  end

  if started and queuedUntil then
    while os.clock() < queuedUntil + tailSeconds and os.clock() <= deadline do
      waitForSpeaker(math.min(1, math.max(0.05, queuedUntil + tailSeconds - os.clock())))
    end
  end

  return started
end

local function playNotificationWav(speaker, sounds, notifications)
  if not (speaker and speaker.playAudio) then
    return false
  end

  local audioConfig = (notifications and notifications.audio) or notifications or {}
  for _, sound in ipairs(soundList(sounds)) do
    local pcm = notificationPcm(sound, audioConfig)
    if pcm then
      local volume = type(sound) == "table" and sound.volume or nil
      if playPcm(speaker, pcm, tonumber(volume) or tonumber(notifications and notifications.wavVolume) or tonumber(notifications and notifications.volume) or 1, audioConfig) then
        return true
      end
    end
  end
  return false
end

local function playMinecraftSound(speaker, sound)
  if type(sound) == "string" then
    if isWavPath(sound) then
      return
    end
    if speaker.playSound then
      pcall(speaker.playSound, sound, 1, 1)
    end
    return
  end

  if type(sound) ~= "table" then
    return
  end
  if speaker.playSound then
    pcall(speaker.playSound, sound.name or "minecraft:block.note_block.pling", sound.volume or 1, sound.pitch or 1)
  elseif speaker.playNote then
    pcall(speaker.playNote, sound.note or "pling", sound.volume or 1, sound.pitch or 1)
  end
end

function M.playSound(speakers, notification, config)
  notification = notification or {}
  local notifications = config and config.notifications or {}
  if notifications.enabled == false or notifications.sound == false then
    return
  end

  local kind = tostring(notification.kind or notification.type or "default")
  local sounds = soundConfig(config, kind)
  if type(sounds) ~= "table" and type(sounds) ~= "string" then
    return
  end

  for _, speaker in ipairs(speakers or {}) do
    local playedWav = wavKindAllowed(notifications, kind) and playNotificationWav(speaker, sounds, notifications)
    if not playedWav then
      for _, sound in ipairs(soundList(sounds)) do
        playMinecraftSound(speaker, sound)
        if sleep and type(sound) == "table" and sound.delay then
          sleep(sound.delay)
        end
      end
    else
      for _, sound in ipairs(soundList(sounds)) do
        if sleep and type(sound) == "table" and sound.delay then
          sleep(sound.delay)
        end
      end
    end
  end
end

function M.wavKindAllowed(config, kind)
  return wavKindAllowed((config and config.notifications) or config or {}, kind)
end

return M
