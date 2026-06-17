-- Minimal config for an employee kiosk computer.
-- Copy to security_config.lua on kiosk computers, or run:
--   security_system kiosk

return {
  mode = "kiosk",

  rednet = {
    enabled = true,
    protocol = "cc_security_v1",

    -- Optional but recommended once you know the main server computer id.
    -- Leave nil to discover by broadcast.
    serverId = nil,
    discoverySeconds = 3,
    encryption = {
      -- Must match the main server when enabled.
      enabled = false,
      key = "change-this-facility-key",
      allowPlaintext = false,
    },
  },

  kiosk = {
    locked = true,
    syncSeconds = 2,
    alarmSoundSeconds = 1.5,
    quitClearance = 5,
  },

  notifications = {
    enabled = true,
    maxItems = 12,
    sound = true,
  },

  branding = {
    facilityName = "North Ridge Facility",
    shortName = "NRF",
    kioskTitle = "Employee Kiosk",
    motto = "Connect to the facility server to continue.",
    primaryColor = "blue",
    accentColor = "lime",
    textColor = "white",
  },

  monitors = {
    enabled = true,
    textScale = 0.5,
    refreshSeconds = 2,
    rotateSeconds = 12,
    posterSeconds = 10,
    defaultView = "cycle",

    -- Use monitor peripheral names from `peripheral.getNames()`.
    -- `cycle` works well on kiosks because it shows server status when linked
    -- and facility posters even before login.
    devices = {
      -- monitor_0 = { view = "cycle", views = { "overview", "security", "posters" }, theme = "blue" },
      -- ["*"] = { view = "posters", textScale = 1, theme = "red" },
    },
  },
}
