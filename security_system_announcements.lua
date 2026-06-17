-- Facility announcement audio for the CC: Tweaked security system.

local M = {}

local DEFAULT_SAMPLE_RATE = 48000

local function combinePath(base, path)
  base = string.gsub(tostring(base or ""), "\\", "/")
  path = string.gsub(tostring(path or ""), "\\", "/")
  while string.sub(path, 1, 1) == "/" do
    path = string.sub(path, 2)
  end
  if base == "" then
    return path
  end
  if path == "" then
    return base
  end
  if fs and fs.combine then
    return fs.combine(base, path)
  end
  return base .. "/" .. path
end

local function assetPath(path)
  local root = (_G and (_G.SECURITY_SYSTEM_ASSET_ROOT or _G.SECURITY_SYSTEM_INSTALL_ROOT)) or ""
  root = tostring(root or "")
  if root == "" then
    return nil
  end
  return combinePath(root, path)
end

local function targetRate(config)
  return tonumber(config and config.sampleRate) or DEFAULT_SAMPLE_RATE
end

local function clamp(value)
  value = math.floor(tonumber(value) or 0)
  if value > 127 then
    return 127
  end
  if value < -128 then
    return -128
  end
  return value
end

local function appendSamples(buffer, samples)
  if type(samples) ~= "table" then
    return
  end
  for index = 1, #samples do
    buffer[#buffer + 1] = clamp(samples[index])
  end
end

local function readFileAt(path)
  path = tostring(path or "")
  if path == "" then
    return nil, "empty path"
  end

  if fs and fs.open then
    if fs.exists and not fs.exists(path) then
      return nil, "missing file"
    end
    local ok, handle = pcall(fs.open, path, "rb")
    if (not ok) or not handle then
      ok, handle = pcall(fs.open, path, "r")
    end
    if ok and handle then
      local readOk, data = pcall(handle.readAll)
      pcall(handle.close)
      if readOk and data then
        return data
      end
      return nil, "read failed"
    end
  end

  if io and io.open then
    local handle = io.open(path, "rb")
    if handle then
      local data = handle:read("*a")
      handle:close()
      return data
    end
  end

  return nil, "file unavailable"
end

local function readFile(path)
  local data, err = readFileAt(path)
  if data then
    return data
  end

  local fallback = assetPath(path)
  if fallback and fallback ~= path then
    local fallbackData, fallbackErr = readFileAt(fallback)
    if fallbackData then
      return fallbackData
    end
    return nil, fallbackErr or err
  end

  return nil, err
end

local function u16le(data, pos)
  local a, b = string.byte(data, pos, pos + 1)
  return (a or 0) + ((b or 0) * 256)
end

local function u32le(data, pos)
  local a, b, c, d = string.byte(data, pos, pos + 3)
  return (a or 0) + ((b or 0) * 256) + ((c or 0) * 65536) + ((d or 0) * 16777216)
end

local function s16le(data, pos)
  local value = u16le(data, pos)
  if value >= 32768 then
    value = value - 65536
  end
  return value
end

local function resample(samples, fromRate, toRate)
  fromRate = tonumber(fromRate) or toRate
  toRate = tonumber(toRate) or DEFAULT_SAMPLE_RATE
  if fromRate == toRate or #samples == 0 then
    return samples
  end

  local out = {}
  local outCount = math.max(1, math.floor((#samples * toRate / fromRate) + 0.5))
  for index = 1, outCount do
    local source = math.floor(((index - 1) * fromRate) / toRate) + 1
    if source > #samples then
      source = #samples
    end
    out[index] = samples[source]
  end
  return out
end

function M.loadWav(path, config)
  local data, err = readFile(path)
  if not data then
    return nil, err
  end
  if string.sub(data, 1, 4) ~= "RIFF" or string.sub(data, 9, 12) ~= "WAVE" then
    return nil, "not a wav file"
  end

  local fmt = nil
  local dataStart = nil
  local dataSize = nil
  local pos = 13
  while pos + 7 <= #data do
    local chunkId = string.sub(data, pos, pos + 3)
    local chunkSize = u32le(data, pos + 4)
    local chunkStart = pos + 8
    if chunkId == "fmt " and chunkSize >= 16 then
      fmt = {
        audioFormat = u16le(data, chunkStart),
        channels = u16le(data, chunkStart + 2),
        sampleRate = u32le(data, chunkStart + 4),
        blockAlign = u16le(data, chunkStart + 12),
        bits = u16le(data, chunkStart + 14),
      }
    elseif chunkId == "data" then
      dataStart = chunkStart
      dataSize = chunkSize
    end

    pos = chunkStart + chunkSize
    if chunkSize % 2 == 1 then
      pos = pos + 1
    end
  end

  if not fmt or not dataStart or not dataSize then
    return nil, "wav missing fmt or data chunk"
  end
  if fmt.audioFormat ~= 1 then
    return nil, "only PCM wav is supported"
  end
  if fmt.channels < 1 or (fmt.bits ~= 8 and fmt.bits ~= 16) then
    return nil, "unsupported wav format"
  end

  local bytesPerSample = fmt.bits / 8
  local frameSize = fmt.blockAlign
  if frameSize <= 0 then
    frameSize = fmt.channels * bytesPerSample
  end

  local samples = {}
  local last = math.min(#data + 1, dataStart + dataSize)
  for frame = dataStart, last - frameSize, frameSize do
    local total = 0
    for channel = 0, fmt.channels - 1 do
      local samplePos = frame + (channel * bytesPerSample)
      if fmt.bits == 8 then
        total = total + ((string.byte(data, samplePos) or 128) - 128)
      else
        total = total + math.floor(s16le(data, samplePos) / 256)
      end
    end
    samples[#samples + 1] = clamp(total / fmt.channels)
  end

  return resample(samples, fmt.sampleRate, targetRate(config))
end

local function charFrequency(char)
  local byte = string.byte(string.lower(tostring(char or " ")), 1) or 32
  if byte == 32 then
    return nil
  end
  return 145 + ((byte * 17) % 210)
end

local function appendTone(buffer, freq, duration, config, style)
  local rate = targetRate(config)
  local samples = math.max(1, math.floor(rate * duration))
  if not freq or tonumber(freq) == 0 then
    for _ = 1, samples do
      buffer[#buffer + 1] = 0
    end
    return
  end

  freq = tonumber(freq) or 220
  for index = 1, samples do
    local progress = index / samples
    local seconds = index / rate
    local envelope = 1
    if progress < 0.12 then
      envelope = progress / 0.12
    elseif progress > 0.86 then
      envelope = (1 - progress) / 0.14
    end

    local wave
    if style == "alarm" then
      wave = math.sin(seconds * math.pi * 2 * freq)
        + (math.sin(seconds * math.pi * 2 * (freq * 0.5)) * 0.52)
        + (math.sin(seconds * math.pi * 2 * (freq + 17)) * 0.24)
    elseif style == "jingle" then
      wave = math.sin(seconds * math.pi * 2 * freq) + (math.sin(seconds * math.pi * 4 * freq) * 0.18)
    else
      local phase = seconds * math.pi * 2 * freq
      wave = math.sin(phase) + (math.sin(phase * 2.03) * 0.35) + (math.sin(phase * 0.51) * 0.28)
      wave = wave + (math.sin(progress * math.pi * 22) * 0.18)
    end

    local gain = tonumber(config and config.gain) or (style == "alarm" and 66 or 54)
    buffer[#buffer + 1] = clamp(wave * gain * envelope)
  end
end

function M.buildVoiceBuffer(text, config)
  config = config or {}
  local buffer = {}
  text = string.sub(tostring(text or ""), 1, tonumber(config.maxCharacters) or 96)

  for index = 1, #text do
    local char = string.sub(text, index, index)
    local freq = charFrequency(char)
    local duration = freq and (tonumber(config.characterSeconds) or 0.055) or (tonumber(config.spaceSeconds) or 0.075)
    appendTone(buffer, freq, duration, config, "voice")
  end

  return buffer
end

local function defaultJingle(alarmLike)
  if alarmLike then
    return {
      { freq = 92, seconds = 0.17 },
      { silence = 0.035 },
      { freq = 74, seconds = 0.20 },
      { freq = 118, seconds = 0.16 },
      { silence = 0.045 },
      { freq = 63, seconds = 0.24 },
    }
  end
  return {
    { freq = 523, seconds = 0.09 },
    { freq = 659, seconds = 0.09 },
    { freq = 784, seconds = 0.12 },
    { silence = 0.045 },
  }
end

local function appendTones(buffer, tones, config, style)
  for _, tone in ipairs(tones or {}) do
    if type(tone) == "number" then
      appendTone(buffer, tone, 0.1, config, style)
    elseif type(tone) == "table" then
      local freq = tone.freq or tone.frequency or tone[1]
      local duration = tone.seconds or tone.duration or tone[2] or tone.silence or 0.1
      if tone.silence then
        freq = nil
      end
      appendTone(buffer, freq, tonumber(duration) or 0.1, config, style)
    end
  end
end

local samplesFromSpec

local function appendSpec(buffer, spec, config, alarmLike)
  local samples = samplesFromSpec(spec, config, alarmLike)
  appendSamples(buffer, samples)
end

samplesFromSpec = function(spec, config, alarmLike)
  if type(spec) == "string" then
    return M.loadWav(spec, config)
  end
  if type(spec) ~= "table" then
    return nil
  end

  if type(spec.pcm) == "table" then
    return spec.pcm
  end

  local wav = spec.wav or spec.file or spec.path
  if wav then
    local samples = M.loadWav(wav, config)
    if samples then
      return samples
    end
  end

  local parts = spec.files or spec.parts or spec.segments
  if type(parts) == "table" then
    local buffer = {}
    for _, part in ipairs(parts) do
      appendSpec(buffer, part, config, alarmLike)
    end
    return buffer
  end

  if type(spec.tones) == "table" then
    local buffer = {}
    appendTones(buffer, spec.tones, config, alarmLike and "alarm" or "jingle")
    return buffer
  end

  return nil
end

local function isAlarmLike(announcement)
  local kind = tostring((announcement and (announcement.kind or announcement.type)) or "")
  return kind == "alarm" or kind == "emergency" or kind == "lockdown"
end

local function configuredVoice(announcement, config, alarmLike)
  if type(announcement) == "table" then
    local direct = samplesFromSpec(announcement, config, alarmLike)
    if direct then
      return direct
    end
  end

  local lines = config.voiceLines or {}
  local id = announcement and announcement.voiceLine
  if id and lines[id] ~= nil then
    return samplesFromSpec(lines[id], config, alarmLike)
  end

  local kind = announcement and (announcement.kind or announcement.type)
  if kind and lines[kind] ~= nil then
    return samplesFromSpec(lines[kind], config, alarmLike)
  end

  return nil
end

local function configuredJingle(config, alarmLike)
  local jingles = config.jingles or {}
  local spec = alarmLike and (jingles.alarm or jingles.emergency or config.alarmJingle) or (jingles.announcement or config.jingle)
  local samples = samplesFromSpec(spec, config, alarmLike)
  if samples and #samples > 0 then
    return samples
  end

  local buffer = {}
  local generated = type(spec) == "table" and spec.tones or nil
  appendTones(buffer, generated or defaultJingle(alarmLike), config, alarmLike and "alarm" or "jingle")
  return buffer
end

function M.buildJingle(alarmLike, config)
  return configuredJingle(config or {}, alarmLike)
end

function M.buildAnnouncementBuffer(announcement, config)
  config = config or {}
  local alarmLike = isAlarmLike(announcement)
  local buffer = {}
  if config.jingle ~= false then
    appendSamples(buffer, configuredJingle(config, alarmLike))
  end

  local voice = configuredVoice(announcement, config, alarmLike)
  if voice then
    appendSamples(buffer, voice)
  elseif config.voice ~= false then
    local text = (announcement and (announcement.text or announcement.message or announcement.title)) or ""
    appendSamples(buffer, M.buildVoiceBuffer(text, config.voiceConfig or config))
  end

  return buffer
end

local function playBuffer(speaker, pcm, volume, config)
  if not (speaker and speaker.playAudio and type(pcm) == "table" and #pcm > 0) then
    return false
  end

  local maxSamples = tonumber(config and config.maxSamples) or 128000
  if maxSamples <= 0 or #pcm <= maxSamples then
    local ok, accepted = pcall(speaker.playAudio, pcm, volume)
    return ok and accepted ~= false
  end

  local chunk = {}
  for index = 1, maxSamples do
    chunk[index] = pcm[index]
  end
  local ok, accepted = pcall(speaker.playAudio, chunk, volume)
  return ok and accepted ~= false
end

local function fallbackSounds(config, alarmLike)
  if alarmLike and type(config.alarmFallbackSounds) == "table" then
    return config.alarmFallbackSounds
  end
  return config.fallbackSounds or {
    { name = "minecraft:block.note_block.chime", volume = 1.4, pitch = 0.9 },
    { name = "minecraft:block.note_block.bell", volume = 1.0, pitch = 1.25 },
  }
end

function M.play(speakers, announcement, config)
  config = config or {}
  if config.enabled == false or config.sound == false then
    return
  end

  local alarmLike = isAlarmLike(announcement)
  local pcm = M.buildAnnouncementBuffer(announcement, config)
  for _, speaker in ipairs(speakers or {}) do
    local played = playBuffer(speaker, pcm, tonumber(config.volume) or 1, config)
    if not played and speaker.playSound then
      for _, sound in ipairs(fallbackSounds(config, alarmLike)) do
        pcall(speaker.playSound, sound.name, sound.volume or 1, sound.pitch or 1)
      end
    end
  end
end

return M
