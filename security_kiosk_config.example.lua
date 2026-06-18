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
    includeMonitors = true,
    includeAnnouncements = true,
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
    voice = false,
    syntheticVoice = false,
    requireVoiceLine = true,
    volume = 1,
    sampleRate = 48000,
    maxSamples = 128000,
    chunkSamples = 24000,
    streamGraceSeconds = 30,
    watchdogSeconds = 0.05,
    tailSeconds = 0.5,
    maxChunksPerFeed = 8,
    prebufferSeconds = 2.5,
    serverPlayback = true,
    alarmAnnouncements = true,
    syncAssets = true,
    assetsRequired = false,
    -- assetBaseUrl = "https://raw.githubusercontent.com/Mauppi/computercraft/master/",
    characterSeconds = 0.055,
    spaceSeconds = 0.075,
    maxCharacters = 96,
    auto = {
      enabled = true,
      intervalSeconds = 30,
    },
    lines = {
      { voiceLine = "memeorpo" },
      { voiceLine = "slopday" },
      { voiceLine = "slopday_cancelled" },
      { voiceLine = "slopday_slop" },
      { voiceLine = "slopday_nonono" },
    },
    eventAnnouncements = true,
    events = {
      alarm = {
        title = "Security Alarm",
        voiceLine = "alarm",
        cooldownSeconds = 2,
        variations = {
          "Security alarm engaged. Cause: {reason}.",
          "Attention personnel. Security response required. {reason}.",
          "{facility} alarm condition active. Await clearance.",
        },
      },
      emergency = {
        title = "Emergency Alarm",
        voiceLine = "alarm",
        cooldownSeconds = 2,
        variations = {
          "Emergency alarm engaged. Follow facility response procedures.",
          "Emergency condition declared. Move with purpose and await instruction.",
          "{facility} emergency response is now active.",
        },
      },
      alarm_reset = {
        title = "Alarm Reset",
        voiceLine = "alarm_clear",
        cooldownSeconds = 2,
        variations = {
          "Alarm condition cleared. Resume normal duties.",
          "Security alarm reset. Continue monitoring your area.",
          "{facility} alarm state has returned to clear.",
        },
      },
      lockdown = {
        title = "Lockdown Active",
        voiceLine = "lockdown",
        cooldownSeconds = 2,
        variations = {
          "Lockdown engaged. Secure your area and await authorization.",
          "{facility} lockdown is active. Remain at your assigned station.",
          "Access restrictions engaged. Lockdown procedures are in effect.",
        },
      },
      lockdown_clear = {
        title = "Lockdown Clear",
        voiceLine = "lockdown_clear",
        cooldownSeconds = 2,
        variations = {
          "Lockdown cleared. Normal access may resume.",
          "{facility} lockdown has been lifted.",
          "Access restrictions cleared. Thank you for your compliance.",
        },
      },
    },
    actions = {
      SENSOR_FAULT = {
        enabled = false,
        title = "Facility Fault",
        cooldownSeconds = 20,
        variations = {
          "Facility sensor fault detected at {sensor}.",
          "Maintenance attention requested for sensor {sensor}.",
          "Fault condition logged. Sensor source: {sensor}.",
        },
      },
      REMOTE_SENSOR_FAULT = {
        enabled = false,
        title = "Remote Facility Fault",
        cooldownSeconds = 20,
        variations = {
          "Remote sensor fault reported by controller {sender}.",
          "Remote facility fault detected at {sensor}.",
          "Remote fault report received. Profile: {profile}.",
        },
      },
      SENSOR_CLEAR = {
        title = "Facility Fault Clear",
        cooldownSeconds = 20,
        chance = 0.5,
        variations = {
          "Sensor {sensor} has returned to normal.",
          "Fault clear logged for {sensor}.",
        },
      },
      BADGE_ISSUE = {
        title = "Badge Issued",
        cooldownSeconds = 4,
        variations = {
          "Badge credentials issued for {user}.",
          "Employee badge record updated for {user}.",
        },
      },
      SETUP_CHANGE = {
        title = "Facility Setup Updated",
        cooldownSeconds = 6,
        chance = 0.5,
        variations = {
          "Facility configuration updated by {actor}.",
          "Setup change recorded: {action}.",
        },
      },
    },
    voiceLines = {
      memeorpo = { files = { "announcements/vo_memeorpo.wav" } },
      lockdown = { files = { "announcements/vo_lockdown.wav", "announcements/vo_engaged.wav" } },
      lockdown_clear = { files = { "announcements/vo_lockdown.wav", "announcements/vo_disengaged.wav" } },
      alarm = { files = { "announcements/vo_alarm.wav", "announcements/vo_engaged.wav" } },
      alarm_clear = { files = { "announcements/vo_alarm.wav", "announcements/vo_disengaged.wav" } },
      slopday = { files = { "announcements/slopday.wav" } },
      slopday_cancelled = { files = { "announcements/slopdaycancelled.wav" } },
      slopday_slop = { files = { "announcements/slopdayslop.wav" } },
      slopday_nonono = { files = { "announcements/slopdaynonono.wav" } },
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
    fallbackSounds = {
    },
    alarmFallbackSounds = {
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

    alarm = {
    repeatSeconds = 1.25,
    syncLeadSeconds = 1.5,
    deniedBeforeAlarm = 3,
    chat = true,
    sampleRate = 48000,
    maxSamples = 128000,
    audio = {
      chunkSamples = 128000,
      loopGapSeconds = 0.05,
    },
    syncAssets = true,
    assetsRequired = true,
    assetBaseUrl = "https://raw.githubusercontent.com/Mauppi/computercraft/master/",

    -- Speakers are discovered automatically. WAV/PCM entries loop through
    -- speaker.playAudio before generated DSP fallback is used.
    sounds = {
      -- { wav = "announcements/red_alert.wav", volume = 1.2 },
      { files = { "announcements/red_alert_a.wav", "announcements/red_alert_a.wav", "announcements/red_alert_a.wav", "announcements/red_alert_b.wav", "announcements/red_alert_b.wav", "announcements/red_alert_b.wav" }, volume = 1.2 },
      -- { pcm = { 0, 28, 56, 28, 0, -28, -56, -28 }, volume = 1.0 },
      -- { name = "minecraft:block.note_block.pling", volume = 3, pitch = 0.6 },
      -- { name = "minecraft:block.note_block.bell", volume = 3, pitch = 1.8 },
    },

    -- Uses speaker.playAudio when available. Existing Minecraft sounds remain
    -- as a fallback for older/simple speaker setups.
    dsp = {
      enabled = true,
      volume = 1.2,
      sampleRate = 48000,
      duration = 0.35,
      -- Omit patterns to use the built-in low/dissonant alarm profiles.
      -- Override patterns.security/power_fault/facility_fault/emergency here if desired.
    },

    -- Sirens, lamps, Create contraptions, or redstone integrators can be driven here.
    outputs = {
      { side = "top" },
      -- { peripheral = "redstoneIntegrator_0", side = "back" },
    },

    profiles = {
      security = {
        label = "Security Alarm",
      },
      power_fault = {
        label = "Power Fault",
        sounds = {
        },
        outputs = {
          { side = "top" },
        },
      },
      facility_fault = {
        label = "Facility Fault",
        sounds = {
        },
      },
      emergency = {
        label = "Emergency Alarm",
        repeatSeconds = 7.1,
        sounds = {
        },
      },
    },
  },
}
