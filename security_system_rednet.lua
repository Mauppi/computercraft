-- Rednet message wrapping for the CC: Tweaked facility security system.
-- This is shared-key encryption intended for in-game Rednet traffic.

local M = {}

local HEX = "0123456789abcdef"
local HEX_BYTES = {}
local HEX_VALUES = {}

for value = 0, 255 do
  local hi = math.floor(value / 16) + 1
  local lo = (value % 16) + 1
  HEX_BYTES[value] = string.sub(HEX, hi, hi) .. string.sub(HEX, lo, lo)
end

for index = 1, #HEX do
  HEX_VALUES[string.sub(HEX, index, index)] = index - 1
end

local function hash32(text)
  local hash = 2166136261
  text = tostring(text or "")
  for index = 1, #text do
    hash = (hash + string.byte(text, index)) % 4294967296
    hash = (hash * 16777619) % 4294967296
  end
  return hash
end

local function toHexByte(value)
  return HEX_BYTES[value % 256]
end

local function fromHexByte(hex, pos)
  local hi = HEX_VALUES[string.sub(hex, pos, pos)]
  local lo = HEX_VALUES[string.sub(hex, pos + 1, pos + 1)]
  if hi == nil or lo == nil then
    return nil
  end
  return hi * 16 + lo
end

local function nonce()
  local epoch = os.epoch and os.epoch("utc") or math.floor(os.clock() * 100000)
  return tostring(epoch) .. ":" .. tostring(math.random(100000, 999999)) .. ":" .. tostring(os.getComputerID and os.getComputerID() or 0)
end

local function settings(rednetConfig)
  rednetConfig = rednetConfig or {}
  local encryption = rednetConfig.encryption or {}
  local key = tostring(encryption.key or encryption.sharedKey or rednetConfig.key or "")
  local enabled = encryption.enabled == true or (encryption.enabled == nil and key ~= "")
  return {
    enabled = enabled and key ~= "",
    key = key,
    allowPlaintext = encryption.allowPlaintext == true,
  }
end

local function encryptText(text, key, useNonce)
  local out = {}
  local keyLen = #key
  local nonceLen = #useNonce
  local seed = nil
  for index = 1, #text do
    if (index - 1) % 32 == 0 then
      seed = hash32(tostring(key) .. ":" .. tostring(useNonce) .. ":" .. tostring(math.floor((index - 1) / 32)))
    end
    local keyValue = (seed + (string.byte(key, ((index - 1) % keyLen) + 1) or 0) * 131 + (string.byte(useNonce, ((index - 1) % nonceLen) + 1) or 0) * 17 + index * 29) % 256
    local value = (string.byte(text, index) + keyValue) % 256
    out[index] = toHexByte(value)
  end
  return table.concat(out)
end

local function decryptText(hex, key, useNonce)
  if #hex % 2 ~= 0 then
    return nil
  end

  local out = {}
  local outIndex = 1
  local keyLen = #key
  local nonceLen = #useNonce
  local seed = nil
  for index = 1, #hex, 2 do
    local value = fromHexByte(hex, index)
    if value == nil then
      return nil
    end
    if (outIndex - 1) % 32 == 0 then
      seed = hash32(tostring(key) .. ":" .. tostring(useNonce) .. ":" .. tostring(math.floor((outIndex - 1) / 32)))
    end
    local keyValue = (seed + (string.byte(key, ((outIndex - 1) % keyLen) + 1) or 0) * 131 + (string.byte(useNonce, ((outIndex - 1) % nonceLen) + 1) or 0) * 17 + outIndex * 29) % 256
    local plain = (value - keyValue) % 256
    out[outIndex] = string.char(plain)
    outIndex = outIndex + 1
  end
  return table.concat(out)
end

function M.enabled(rednetConfig)
  return settings(rednetConfig).enabled
end

function M.wrap(message, rednetConfig)
  local opts = settings(rednetConfig)
  if not opts.enabled then
    return message
  end

  local plain = textutils.serialize(message)
  local useNonce = nonce()
  return {
    __securitySystem = "enc1",
    nonce = useNonce,
    payload = encryptText(plain, opts.key, useNonce),
    checksum = hash32(plain .. ":" .. opts.key .. ":" .. useNonce),
  }
end

function M.unwrap(message, rednetConfig)
  local opts = settings(rednetConfig)
  if type(message) == "table" and message.__securitySystem == "enc1" then
    if not opts.enabled then
      return nil, "encrypted message received but encryption is disabled"
    end

    local plain = decryptText(tostring(message.payload or ""), opts.key, tostring(message.nonce or ""))
    if not plain then
      return nil, "encrypted message payload is invalid"
    end

    if tonumber(message.checksum) ~= hash32(plain .. ":" .. opts.key .. ":" .. tostring(message.nonce or "")) then
      return nil, "encrypted message checksum failed"
    end

    local ok, decoded = pcall(textutils.unserialize, plain)
    if ok then
      return decoded
    end
    return nil, "encrypted message could not be decoded"
  end

  if opts.enabled and not opts.allowPlaintext then
    return nil, "plaintext rednet message rejected"
  end

  return message
end

function M.send(rednetApi, target, message, rednetConfig, protocol)
  return rednetApi.send(target, M.wrap(message, rednetConfig), protocol)
end

function M.broadcast(rednetApi, message, rednetConfig, protocol)
  return rednetApi.broadcast(M.wrap(message, rednetConfig), protocol)
end

return M
