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
      enabled = true,
      key = "FAPKEY",
      allowPlaintext = false,
    },
  },

  configSync = {
    enabled = true,
    includeAlarm = true,
  },

  kiosk = {
    locked = true,
    syncSeconds = 2,
    alarmSoundSeconds = 1.5,
    quitClearance = 5,
    autoLogoutSeconds = 600,
    autoRebootLoggedOutSeconds = 1800,
    controller = {
      enabled = false,
      permanent = false,
      credentialForwarding = true,
      helloSeconds = 30,
      pollSeconds = 0.25,
    },
  },

  notifications = {
    enabled = true,
    maxItems = 12,
    sound = true,
    sampleRate = 48000,
    maxSamples = 128000,
    wavKinds = {
      dm = true,
      social = true,
    },
    sounds = {
      social = {
        -- { wav = "notifications/social.wav", volume = 0.8 },
        { wav = "announcements/jingle_notification.wav", volume = 0.8 },
      },
      dm = {
        -- { wav = "notifications/dm.wav", volume = 0.9 },
        { wav = "announcements/jingle_notification.wav", volume = 0.8 },
      },
    },
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
      memeorpo = { files = { "announcements/vo_memeorpo.wav" } },
      lockdown = { files = { "announcements/vo_lockdown.wav", "announcements/vo_engaged.wav" } },
      lockdown_clear = { files = { "announcements/vo_lockdown.wav", "announcements/vo_disengaged.wav" } },
      alarm = { files = { "announcements/vo_alarm.wav", "announcements/vo_engaged.wav" } },
      alarm_clear = { files = { "announcements/vo_alarm.wav", "announcements/vo_disengaged.wav" } },
      slopday = { files = { "announcements/slop day.wav" } },
      slopday_cancelled = { files = { "announcements/slop day cancelled.wav" } },
      slopday_slop = { files = { "announcements/slop day slop.wav" } },
    },
    jingles = {
      announcement = {
        wav = "announcements/announcement_jingle.wav",
        tones = {
        },
      },
      alarm = {
        wav = "announcements/jingle_alarm.wav",
        tones = {
        },
      },
    },
  },

  branding = {
    facilityName = "F-Aperture",
    shortName = "FAP",
    kioskTitle = "Employee Terminal",
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
