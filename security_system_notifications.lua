-- Kiosk notification queues and sounds for the CC: Tweaked security system.

local M = {}

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

function M.playSound(speakers, notification, config)
  local notifications = config and config.notifications or {}
  if notifications.enabled == false or notifications.sound == false then
    return
  end

  local kind = tostring(notification.kind or notification.type or "default")
  local sounds = soundConfig(config, kind)
  if type(sounds) ~= "table" then
    return
  end

  for _, speaker in ipairs(speakers or {}) do
    for _, sound in ipairs(sounds) do
      if speaker.playSound then
        pcall(speaker.playSound, sound.name or "minecraft:block.note_block.pling", sound.volume or 1, sound.pitch or 1)
      elseif speaker.playNote then
        pcall(speaker.playNote, sound.note or "pling", sound.volume or 1, sound.pitch or 1)
      end
      if sleep and sound.delay then
        sleep(sound.delay)
      end
    end
  end
end

return M
