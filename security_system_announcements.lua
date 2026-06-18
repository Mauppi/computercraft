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

local function appendSamples(buffer, samples, gain)
  if type(samples) ~= "table" then
    return
  end
  gain = tonumber(gain) or 1
  for index = 1, #samples do
    buffer[#buffer + 1] = clamp(samples[index] * gain)
  end
end

local function mixSamplesAt(buffer, samples, startIndex, gain)
  if type(samples) ~= "table" then
    return
  end

  startIndex = math.max(1, math.floor(tonumber(startIndex) or 1))
  gain = tonumber(gain) or 1
  for index = #buffer + 1, startIndex - 1 do
    buffer[index] = 0
  end
  for index = 1, #samples do
    local target = startIndex + index - 1
    buffer[target] = clamp((buffer[target] or 0) + (samples[index] * gain))
  end
end

local function secondsToSamples(seconds, config)
  return math.floor((tonumber(seconds) or 0) * targetRate(config) + 0.5)
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
    local source = ((index - 1) * fromRate / toRate) + 1
    local left = math.floor(source)
    local right = left + 1
    if left < 1 then
      left = 1
    end
    if right > #samples then
      right = #samples
    end
    local fraction = source - left
    out[index] = clamp((samples[left] or 0) + (((samples[right] or samples[left] or 0) - (samples[left] or 0)) * fraction))
  end
  return out
end

local function scaledSamples(samples, gain)
  if type(samples) ~= "table" then
    return nil
  end
  gain = tonumber(gain) or 1
  if gain == 1 then
    return samples
  end
  local out = {}
  for index = 1, #samples do
    out[index] = clamp(samples[index] * gain)
  end
  return out
end

local function hasSamples(samples)
  return type(samples) == "table" and #samples > 0
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

samplesFromSpec = function(spec, config, alarmLike)
  if type(spec) == "string" then
    local samples = M.loadWav(spec, config)
    if hasSamples(samples) then
      return samples
    end
    return nil
  end
  if type(spec) ~= "table" then
    return nil
  end

  local variations = spec.variations or spec.variants or spec.choices
  if type(variations) == "table" and #variations > 0 then
    return samplesFromSpec(variations[math.random(1, #variations)], config, alarmLike)
  end

  if type(spec.pcm) == "table" or type(spec.samples) == "table" then
    local samples = spec.pcm or spec.samples
    if spec.sampleRate then
      samples = resample(samples, spec.sampleRate, targetRate(config))
    end
    samples = scaledSamples(samples, spec.gain or spec.volume)
    if hasSamples(samples) then
      return samples
    end
    return nil
  end

  local wav = spec.wav or spec.file or spec.path
  if wav then
    local samples = M.loadWav(wav, config)
    if hasSamples(samples) then
      return scaledSamples(samples, spec.gain or spec.volume)
    end
  end

  local layers = spec.mix or spec.layers or spec.overlay or spec.overlays
  if type(layers) == "table" then
    local buffer = {}
    local cursor = 1
    local defaultOverlap = secondsToSamples(spec.overlapSeconds or spec.overlap, config)
    for index, layer in ipairs(layers) do
      local layerSpec = layer
      local layerGain = nil
      if type(layer) == "table" and (layer.sound or layer.spec or layer.source) then
        layerSpec = layer.sound or layer.spec or layer.source
        layerGain = layer.gain or layer.volume
      end

      local samples = samplesFromSpec(layerSpec, config, alarmLike)
      if hasSamples(samples) then
        local startIndex = nil
        if type(layer) == "table" then
          startIndex = layer.offsetSamples or layer.startSamples
          if not startIndex then
            local seconds = layer.offsetSeconds or layer.startSeconds or layer.atSeconds or layer.offset or layer.startAt
            if seconds ~= nil then
              startIndex = secondsToSamples(seconds, config) + 1
            end
          end
        end
        if not startIndex then
          if index == 1 then
            startIndex = 1
          else
            startIndex = math.max(1, cursor - defaultOverlap)
          end
        end

        mixSamplesAt(buffer, samples, startIndex, layerGain)
        cursor = math.max(cursor, startIndex + #samples)
      end
    end
    if #buffer > 0 then
      return buffer
    end
  end

  local parts = spec.files or spec.parts or spec.segments
  if type(parts) == "table" then
    local buffer = {}
    local overlap = secondsToSamples(spec.overlapSeconds or spec.overlap, config)
    for _, part in ipairs(parts) do
      local samples = samplesFromSpec(part, config, alarmLike)
      if hasSamples(samples) then
        if overlap > 0 and #buffer > 0 then
          mixSamplesAt(buffer, samples, math.max(1, #buffer - overlap + 1))
        else
          appendSamples(buffer, samples)
        end
      end
    end
    if #buffer > 0 then
      return buffer
    end
    return nil
  end

  if type(spec.tones) == "table" then
    local buffer = {}
    appendTones(buffer, spec.tones, config, alarmLike and "alarm" or "jingle")
    if #buffer > 0 then
      return buffer
    end
    return nil
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
    if hasSamples(direct) then
      return direct
    end
  end

  local lines = config.voiceLines or {}
  local sequence = announcement and (announcement.voiceLines or announcement.voiceLineParts or announcement.voiceSequence)
  if type(sequence) == "table" then
    local buffer = {}
    for _, part in ipairs(sequence) do
      local samples = nil
      if type(part) == "string" or type(part) == "number" then
        local id = tostring(part or "")
        if id ~= "" then
          if lines[id] ~= nil or lines[tostring(id)] ~= nil then
            samples = samplesFromSpec(lines[id] or lines[tostring(id)], config, alarmLike)
          else
            samples = samplesFromSpec(id, config, alarmLike)
          end
        end
      elseif type(part) == "table" then
        local id = part.voiceLine or part.voice or part.id
        if id and tostring(id) ~= "" and (lines[id] ~= nil or lines[tostring(id)] ~= nil) then
          samples = samplesFromSpec(lines[id] or lines[tostring(id)], config, alarmLike)
        else
          samples = samplesFromSpec(part, config, alarmLike)
        end
      end

      if hasSamples(samples) then
        appendSamples(buffer, samples)
      end
    end
    if hasSamples(buffer) then
      return buffer
    end
  end

  local id = announcement and announcement.voiceLine
  if id and (lines[id] ~= nil or lines[tostring(id)] ~= nil) then
    local samples = samplesFromSpec(lines[id] or lines[tostring(id)], config, alarmLike)
    if hasSamples(samples) then
      return samples
    end
    return nil
  end

  local kind = announcement and (announcement.kind or announcement.type)
  if kind and (lines[kind] ~= nil or lines[tostring(kind)] ~= nil) then
    local samples = samplesFromSpec(lines[kind] or lines[tostring(kind)], config, alarmLike)
    if hasSamples(samples) then
      return samples
    end
    return nil
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

  local voice = configuredVoice(announcement, config, alarmLike)
  if not voice and config.requireVoiceLine then
    return buffer
  end

  local body = voice
  if not hasSamples(body) and config.syntheticVoice == true then
    local text = (announcement and (announcement.text or announcement.message or announcement.title)) or ""
    body = M.buildVoiceBuffer(text, config.voiceConfig or config)
  end
  if not hasSamples(body) then
    return buffer
  end

  if config.jingle ~= false then
    appendSamples(buffer, configuredJingle(config, alarmLike))
  end

  appendSamples(buffer, body)

  return buffer
end

local function playbackChunkSamples(config)
  local audio = type(config and config.audio) == "table" and config.audio or {}
  local samples = tonumber(audio.chunkSamples or audio.playbackSamples or config.chunkSamples or config.playbackSamples) or 24000
  if samples <= 0 then
    samples = 24000
  end
  samples = math.floor(samples)
  if samples < 1024 then
    return 1024
  end
  if samples > 128000 then
    return 128000
  end
  return samples
end

local function streamDone(stream)
  if stream.done then
    return true
  end
  if stream.queueComplete then
    local queuedUntil = tonumber(stream.queuedUntil) or os.clock()
    local tailSeconds = tonumber(stream.tailSeconds) or 0.5
    if os.clock() >= queuedUntil + tailSeconds then
      stream.done = true
      return true
    end
  end
  return false
end

local function feedStream(stream)
  if streamDone(stream) then
    return false
  end
  if stream.queueComplete then
    return true
  end

  local acceptedAny = false
  local fedChunks = 0
  local maxChunks = math.max(1, tonumber(stream.maxChunksPerFeed) or 2)
  while stream.nextIndex <= #stream.pcm and fedChunks < maxChunks do
    local chunk = {}
    local last = math.min(#stream.pcm, stream.nextIndex + stream.chunkSamples - 1)
    for index = stream.nextIndex, last do
      chunk[#chunk + 1] = clamp(stream.pcm[index])
    end

    local ok, accepted = pcall(stream.speaker.playAudio, chunk, stream.volume)
    if not ok then
      stream.done = true
      stream.failed = true
      return acceptedAny
    end
    if accepted == false then
      return acceptedAny
    end

    local now = os.clock()
    local queuedSamples = last - stream.nextIndex + 1
    local sampleRate = math.max(1, tonumber(stream.sampleRate) or DEFAULT_SAMPLE_RATE)
    local base = math.max(tonumber(stream.queuedUntil) or now, now)
    stream.queuedUntil = base + (queuedSamples / sampleRate)
    stream.started = true
    acceptedAny = true
    stream.nextIndex = last + 1
    fedChunks = fedChunks + 1
  end

  if stream.nextIndex > #stream.pcm then
    stream.queueComplete = true
  end
  return acceptedAny
end

local function streamsDone(streams)
  for _, stream in ipairs(streams) do
    if not streamDone(stream) then
      return false
    end
  end
  return true
end

local function startedCount(streams)
  local count = 0
  for _, stream in ipairs(streams) do
    if stream.started then
      count = count + 1
    end
  end
  return count
end

local function waitForSpeakerReady(seconds)
  seconds = tonumber(seconds) or 0.05
  local pull = os and (os.pullEventRaw or os.pullEvent)
  if os and os.startTimer and pull then
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

local function playPcmOnSpeakers(speakers, pcm, volume, config)
  if not (type(pcm) == "table" and #pcm > 0) then
    return 0
  end

  local chunkSamples = playbackChunkSamples(config or {})
  local sampleRate = targetRate(config or {})
  local graceSeconds = tonumber(config and config.streamGraceSeconds) or 30
  local tailSeconds = tonumber(config and config.tailSeconds) or 0.5
  local maxChunksPerFeed = tonumber(config and config.maxChunksPerFeed) or 2
  local deadline = os.clock() + (#pcm / math.max(1, sampleRate)) + graceSeconds
  local streams = {}
  for _, speaker in ipairs(speakers or {}) do
    if speaker and speaker.playAudio then
      streams[#streams + 1] = {
        speaker = speaker,
        pcm = pcm,
        volume = volume,
        nextIndex = 1,
        chunkSamples = chunkSamples,
        sampleRate = sampleRate,
        tailSeconds = tailSeconds,
        maxChunksPerFeed = maxChunksPerFeed,
      }
    end
  end

  if #streams == 0 then
    return 0
  end

  while not streamsDone(streams) do
    for _, stream in ipairs(streams) do
      feedStream(stream)
    end

    if streamsDone(streams) then
      break
    end
    if os.clock() > deadline then
      break
    end
    waitForSpeakerReady(0.05)
  end

  return startedCount(streams)
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
  local played = playPcmOnSpeakers(speakers, pcm, tonumber(config.volume) or 1, config)
  if played == 0 then
    for _, speaker in ipairs(speakers or {}) do
      if speaker.playSound then
        for _, sound in ipairs(fallbackSounds(config, alarmLike)) do
          pcall(speaker.playSound, sound.name, sound.volume or 1, sound.pitch or 1)
        end
      end
    end
  end
end

function M.playBuffer(speakers, pcm, volume, config)
  return playPcmOnSpeakers(speakers, pcm, volume, config)
end

return M
