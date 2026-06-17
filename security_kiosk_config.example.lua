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
    autoLogoutSeconds = 600,
    autoRebootLoggedOutSeconds = 1800,
  },

  notifications = {
    enabled = true,
    maxItems = 12,
    sound = true,
  },

  announcements = {
    enabled = true,
    sound = true,
    voice = true,
    volume = 1,
    sampleRate = 48000,
    maxSamples = 128000,
    syncAssets = true,
    assetsRequired = false,
    -- assetBaseUrl = "https://raw.githubusercontent.com/Mauppi/computercraft/master/",
    voiceLines = {
      -- badge_notice = { wav = "announcements/badge_notice.wav" },
      -- lockdown = { files = { "announcements/lockdown_1.wav", "announcements/lockdown_2.wav" } },
    },
    jingles = {
      announcement = {
        -- wav = "announcements/jingle.wav",
        tones = {
          { freq = 523, seconds = 0.09 },
          { freq = 659, seconds = 0.09 },
          { freq = 784, seconds = 0.12 },
        },
      },
      alarm = {
        -- wav = "announcements/alarm_jingle.wav",
        tones = {
          { freq = 92, seconds = 0.17 },
          { silence = 0.035 },
          { freq = 74, seconds = 0.20 },
          { freq = 63, seconds = 0.24 },
        },
      },
    },
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
