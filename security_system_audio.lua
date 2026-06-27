-- AUKit-backed audio helpers for the CC: Tweaked security system.

local M = {}

local DEFAULT_SAMPLE_RATE = 48000
local unpackArgs = table.unpack or unpack

local okAukit, aukit = pcall(require, "aukit")
if not okAukit then
  aukit = nil
end

local aukitPlaybackCache = setmetatable({}, { __mode = "k" })

local function cooperativeYield()
  if sleep then
    sleep(0)
  end
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

function M.readFile(path)
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

local function targetRate(config)
  local rate = tonumber(config and config.sampleRate) or DEFAULT_SAMPLE_RATE
  if rate <= 0 then
    return DEFAULT_SAMPLE_RATE
  end
  return math.floor(rate)
end

function M.sampleRate(config)
  return targetRate(config)
end

function M.usingAukit()
  return aukit ~= nil
end

local function clampSample(value)
  value = math.floor(tonumber(value) or 0)
  if value > 127 then
    return 127
  end
  if value < -128 then
    return -128
  end
  return value
end

M.clampSample = clampSample

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
    out[index] = clampSample((samples[left] or 0) + (((samples[right] or samples[left] or 0) - (samples[left] or 0)) * fraction))
    if index % 8192 == 0 then
      cooperativeYield()
    end
  end
  return out
end

local function loadWavWithAukit(data, config)
  if not (aukit and aukit.wav) then
    return nil, "aukit unavailable"
  end

  local rate = targetRate(config)
  local ok, audio = pcall(aukit.wav, data)
  if not ok or not audio then
    return nil, audio or "aukit wav decode failed"
  end

  local okPcm, samples = pcall(function()
    local prepared = audio
    if prepared.sampleRate ~= rate and prepared.resample then
      prepared = prepared:resample(rate)
    end
    if prepared.mono then
      prepared = prepared:mono()
    end
    return prepared:pcm(8, "signed", true)
  end)
  if not okPcm or type(samples) ~= "table" or #samples == 0 then
    return nil, samples or "aukit pcm conversion failed"
  end

  for index = 1, #samples do
    samples[index] = clampSample(samples[index])
    if index % 8192 == 0 then
      cooperativeYield()
    end
  end
  return samples
end

local function loadPcmWavFallback(data, config)
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
    return nil, "only PCM wav is supported without aukit"
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
  local outIndex = 1
  local last = math.min(#data + 1, dataStart + dataSize)
  if fmt.channels == 1 and fmt.bits == 8 then
    for frame = dataStart, last - frameSize, frameSize do
      samples[outIndex] = (string.byte(data, frame) or 128) - 128
      outIndex = outIndex + 1
      if outIndex % 8192 == 0 then
        cooperativeYield()
      end
    end
  elseif fmt.channels == 1 and fmt.bits == 16 then
    for frame = dataStart, last - frameSize, frameSize do
      samples[outIndex] = math.floor(s16le(data, frame) / 256)
      outIndex = outIndex + 1
      if outIndex % 8192 == 0 then
        cooperativeYield()
      end
    end
  else
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
      samples[outIndex] = clampSample(total / fmt.channels)
      outIndex = outIndex + 1
      if outIndex % 8192 == 0 then
        cooperativeYield()
      end
    end
  end

  return resample(samples, fmt.sampleRate, targetRate(config))
end

function M.loadWav(path, config)
  local data, err = M.readFile(path)
  if not data then
    return nil, err
  end

  local samples, loadErr = loadWavWithAukit(data, config)
  if samples then
    return samples
  end

  local fallback, fallbackErr = loadPcmWavFallback(data, config)
  if fallback then
    return fallback
  end
  return nil, loadErr or fallbackErr
end

function M.pcmChunk(pcm, firstIndex, lastIndex, clampSamples)
  local chunk = {}
  local outIndex = 1
  firstIndex = math.max(1, math.floor(tonumber(firstIndex) or 1))
  lastIndex = math.floor(tonumber(lastIndex) or firstIndex)
  if type(pcm) ~= "table" or lastIndex < firstIndex then
    return chunk
  end

  if clampSamples then
    for index = firstIndex, lastIndex do
      chunk[outIndex] = clampSample(pcm[index])
      outIndex = outIndex + 1
    end
  else
    for index = firstIndex, lastIndex do
      chunk[outIndex] = pcm[index]
      outIndex = outIndex + 1
    end
  end
  return chunk
end

function M.aukitChunk(pcm, firstIndex, lastIndex, clampSamples)
  return { M.pcmChunk(pcm, firstIndex, lastIndex, clampSamples) }
end

function M.canPlayAudio(speaker)
  return type(speaker) == "table" and type(speaker.playAudio) == "function"
end

local function playbackRate(options)
  local rate = tonumber(options and options.sampleRate) or DEFAULT_SAMPLE_RATE
  if rate <= 0 then
    return DEFAULT_SAMPLE_RATE
  end
  return math.floor(rate)
end

function M.preparePlaybackPcm(pcm, options)
  options = options or {}
  if not (type(pcm) == "table" and #pcm > 0) then
    return nil, "empty pcm"
  end
  if options.aukitPrepared == true then
    return pcm, nil, playbackRate(options)
  end
  if not (aukit and aukit.pcm) then
    return nil, "aukit unavailable"
  end

  local sourceRate = playbackRate(options)
  local clampSamples = options.clampSamples == true
  local bySource = aukitPlaybackCache[pcm]
  if not bySource then
    bySource = {}
    aukitPlaybackCache[pcm] = bySource
  end

  local key = tostring(#pcm) .. ":" .. tostring(sourceRate) .. ":" .. tostring(clampSamples)
  local cached = bySource[key]
  if cached then
    return cached.samples, nil, cached.rate
  end

  local raw = clampSamples and M.pcmChunk(pcm, 1, #pcm, true) or pcm
  if #raw == 0 then
    return raw, nil, DEFAULT_SAMPLE_RATE
  end

  local okAudio, audio = pcall(aukit.pcm, raw, 8, "signed", 1, sourceRate, true, false)
  if not okAudio or not audio then
    return nil, audio or "aukit pcm conversion failed"
  end

  local rate = sourceRate
  if rate ~= DEFAULT_SAMPLE_RATE and audio.resample then
    local okResample, resampled = pcall(audio.resample, audio, DEFAULT_SAMPLE_RATE)
    if okResample and resampled then
      audio = resampled
      rate = DEFAULT_SAMPLE_RATE
    end
  end

  local okSamples, samples = pcall(audio.pcm, audio, 8, "signed", true)
  if not okSamples or type(samples) ~= "table" or #samples == 0 then
    return nil, samples or "aukit pcm export failed"
  end

  for index = 1, #samples do
    samples[index] = clampSample(samples[index])
    if index % 8192 == 0 then
      cooperativeYield()
    end
  end

  bySource[key] = {
    samples = samples,
    rate = rate,
  }
  return samples, nil, rate
end

function M.aukitPcmRange(pcm, firstIndex, lastIndex, options)
  options = options or {}
  firstIndex = math.max(1, math.floor(tonumber(firstIndex) or 1))
  lastIndex = math.floor(tonumber(lastIndex) or firstIndex)
  if lastIndex < firstIndex then
    return {}, nil, playbackRate(options)
  end

  local prepared, err, rate = M.preparePlaybackPcm(pcm, options)
  if not prepared then
    return nil, err
  end
  return M.pcmChunk(prepared, firstIndex, lastIndex, false), nil, rate
end

function M.playPcmRange(speaker, pcm, firstIndex, lastIndex, volume, options)
  if not (M.canPlayAudio(speaker) and type(pcm) == "table" and #pcm > 0) then
    return false, false, 0
  end

  options = options or {}
  local chunk, _, rate = M.aukitPcmRange(pcm, firstIndex, lastIndex, options)
  if not chunk then
    chunk = M.pcmChunk(pcm, firstIndex, lastIndex, options.clampSamples == true)
    rate = playbackRate(options)
  end
  if #chunk == 0 then
    return true, false, 0, rate
  end

  local ok, accepted = pcall(speaker.playAudio, chunk, volume)
  return ok, accepted, #chunk, rate
end

function M.playAukitChunk(speaker, chunk, volume)
  if not M.canPlayAudio(speaker) then
    return false, false, 0
  end
  local samples = nil
  if type(chunk) == "table" then
    samples = type(chunk[1]) == "table" and chunk[1] or chunk
  end
  if type(samples) ~= "table" or #samples == 0 then
    return false, false, 0
  end
  local ok, accepted = pcall(speaker.playAudio, samples, volume)
  return ok, accepted, #samples
end

function M.packPcmSamples(pcm, firstIndex, lastIndex)
  local out = {}
  local block = {}
  local blockIndex = 1
  local processed = 0
  for index = firstIndex, lastIndex do
    block[blockIndex] = (clampSample(pcm[index]) + 128) % 256
    processed = processed + 1
    if blockIndex >= 256 then
      out[#out + 1] = string.char(unpackArgs(block, 1, blockIndex))
      blockIndex = 1
    else
      blockIndex = blockIndex + 1
    end
    if processed % 4096 == 0 then
      cooperativeYield()
    end
  end
  if blockIndex > 1 then
    out[#out + 1] = string.char(unpackArgs(block, 1, blockIndex - 1))
  end
  return table.concat(out)
end

function M.appendPackedPcmSamples(buffer, packed, allowYield)
  if type(buffer) ~= "table" or type(packed) ~= "string" then
    return
  end
  local offset = #buffer
  local blocks = 0
  for index = 1, #packed, 256 do
    local last = math.min(#packed, index + 255)
    local bytes = { string.byte(packed, index, last) }
    for byteIndex = 1, #bytes do
      buffer[offset + byteIndex] = (bytes[byteIndex] or 128) - 128
    end
    offset = offset + #bytes
    blocks = blocks + 1
    if allowYield and blocks % 8 == 0 then
      cooperativeYield()
    end
  end
end

function M.appendPcmSampleTable(buffer, samples, allowYield)
  if type(buffer) ~= "table" or type(samples) ~= "table" then
    return
  end
  local offset = #buffer
  for index = 1, #samples do
    buffer[offset + index] = clampSample(samples[index])
    if allowYield and index % 4096 == 0 then
      cooperativeYield()
    end
  end
end

local function playbackChunkSamples(config)
  local audio = type(config and config.audio) == "table" and config.audio or {}
  local samples = tonumber(audio.chunkSamples or audio.playbackSamples or config and config.chunkSamples or config and config.playbackSamples) or 24000
  if samples <= 0 then
    samples = 24000
  end
  samples = math.floor(samples)
  if samples < 1024 then
    return 1024
  end
  if samples > 48000 then
    return 48000
  end
  return samples
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

local function streamPrebufferSeconds(stream)
  local seconds = tonumber(stream and stream.prebufferSeconds) or 2.5
  if seconds < 0.25 then
    return 0.25
  end
  if seconds > 8 then
    return 8
  end
  return seconds
end

local function streamRefillSeconds(stream)
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
  local targetQueuedUntil = os.clock() + streamPrebufferSeconds(stream)
  while stream.nextIndex <= #stream.pcm and fedChunks < maxChunks do
    if fedChunks > 0 and stream.queuedUntil and stream.queuedUntil >= targetQueuedUntil then
      break
    end

    local last = math.min(#stream.pcm, stream.nextIndex + stream.chunkSamples - 1)
    local ok, accepted, queuedSamples, rate = M.playPcmRange(stream.speaker, stream.pcm, stream.nextIndex, last, stream.volume, {
      clampSamples = stream.clampSamples,
      sampleRate = stream.sampleRate,
      aukitPrepared = stream.aukitPrepared == true,
    })
    if not ok then
      stream.done = true
      stream.failed = true
      return acceptedAny
    end
    if accepted == false then
      return acceptedAny
    end

    local now = os.clock()
    local sampleRate = math.max(1, tonumber(rate or stream.sampleRate) or DEFAULT_SAMPLE_RATE)
    local base = math.max(tonumber(stream.queuedUntil) or now, now)
    stream.queuedUntil = base + ((queuedSamples or 0) / sampleRate)
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

local function nextStreamWaitSeconds(streams)
  local now = os.clock()
  local delay
  for _, stream in ipairs(streams or {}) do
    if not streamDone(stream) and not stream.queueComplete then
      local streamDelay = 0.1
      if stream.queuedUntil then
        streamDelay = (tonumber(stream.queuedUntil) - now) - streamRefillSeconds(stream)
      end
      if streamDelay < 0.05 then
        streamDelay = 0.05
      end
      if not delay or streamDelay < delay then
        delay = streamDelay
      end
    end
  end
  if not delay then
    delay = 0.25
  elseif delay > 1 then
    delay = 1
  end
  return delay
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

function M.playPcmOnSpeakers(speakers, pcm, volume, config)
  if not (type(pcm) == "table" and #pcm > 0) then
    return 0
  end

  local chunkSamples = playbackChunkSamples(config or {})
  local sampleRate = targetRate(config or {})
  local aukitPrepared = false
  local preparedPcm, _, preparedRate = M.preparePlaybackPcm(pcm, {
    sampleRate = sampleRate,
  })
  if type(preparedPcm) == "table" and #preparedPcm > 0 then
    pcm = preparedPcm
    sampleRate = tonumber(preparedRate) or sampleRate
    aukitPrepared = true
  end
  local graceSeconds = tonumber(config and config.streamGraceSeconds) or 30
  local tailSeconds = tonumber(config and config.tailSeconds) or 0.5
  local maxChunksPerFeed = tonumber(config and config.maxChunksPerFeed) or 2
  local prebufferSeconds = tonumber(config and config.prebufferSeconds) or 2.5
  local refillSeconds = tonumber(config and config.refillSeconds) or 0.75
  local clampSamples = config and config.clampPlaybackSamples == true
  local deadline = os.clock() + (#pcm / math.max(1, sampleRate)) + graceSeconds
  local streams = {}
  for _, speaker in ipairs(speakers or {}) do
    if M.canPlayAudio(speaker) then
      streams[#streams + 1] = {
        speaker = speaker,
        pcm = pcm,
        volume = volume,
        nextIndex = 1,
        chunkSamples = chunkSamples,
        sampleRate = sampleRate,
        tailSeconds = tailSeconds,
        maxChunksPerFeed = maxChunksPerFeed,
        prebufferSeconds = prebufferSeconds,
        refillSeconds = refillSeconds,
        clampSamples = clampSamples,
        aukitPrepared = aukitPrepared,
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
    waitForSpeakerReady(nextStreamWaitSeconds(streams))
  end

  return startedCount(streams)
end

function M.playPcm(speaker, pcm, volume, config)
  return M.playPcmOnSpeakers({ speaker }, pcm, volume, config) > 0
end

return M
