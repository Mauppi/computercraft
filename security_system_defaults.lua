-- Default configuration for the CC: Tweaked facility security system.
-- Loaded by security_system_app.lua.

local LOG_FILE = "security_audit.log"
local ACCOUNTS_FILE = "security_accounts.lua"
local SOCIAL_FILE = "security_social.lua"
local PROTOCOL = "cc_security_v1"
return {
  mode = "server",
  siteName = "Base Security",
  facilityName = "Base Security",
  branding = {
    facilityName = "Base Security",
    shortName = "SEC",
    kioskTitle = "Employee Kiosk",
    motto = "Authorized staff only",
    primaryColor = "blue",
    accentColor = "lime",
    textColor = "white",
  },
  logFile = LOG_FILE,
  lockDoorsOnExit = true,
  clearAlarmOnExit = false,
  defaultOpenSeconds = 4,
  forcedGraceSeconds = 2,
  badgeCooldownSeconds = 3,
  pollSeconds = 1,

  adminPins = { "0000" },
  adminSessionSeconds = 300,

  rednet = {
    enabled = true,
    protocol = PROTOCOL,
    serverId = nil,
    discoverySeconds = 2,
    encryption = {
      enabled = false,
      key = "",
      allowPlaintext = false,
    },
  },

  configSync = {
    enabled = true,
    allowKioskPull = true,
    includeMonitors = true,
    includeAnnouncements = true,
    includeAlarm = true,
  },

  employees = {
    enabled = true,
    allowSelfRegistration = false,
    accountsFile = ACCOUNTS_FILE,
    socialFile = SOCIAL_FILE,
    maxNoteLength = 4096,
    maxPostLength = 512,
    maxMessageLength = 512,
    maxFeedItems = 100,
    sessionSeconds = 1800,
    defaultClearance = 1,
    clearanceLevels = {
      employee = 1,
      operator = 2,
      security = 3,
      manager = 4,
      admin = 5,
    },
    permissions = {
      postFeed = 1,
      sendMessage = 1,
      viewStatus = 1,
      viewLogs = 2,
      triggerEmergency = 1,
      triggerAlarm = 2,
      resetAlarm = 3,
      operateDoors = 3,
      lockdown = 4,
      issueBadges = 5,
      setupFacility = 5,
      manageEmployees = 5,
      quitKiosk = 5,
    },
    initialAccounts = {
      -- admin = { pin = "2468", displayName = "Facility Admin", role = "admin" },
    },
  },

  logs = {
    readLines = 80,
    defaultClearance = 2,
    clearances = {
      ACCESS_GRANTED = 2,
      ACCESS_DENIED = 3,
      ALARM_RAISED = 2,
      ALARM_ESCALATED = 2,
      ALARM_RESET = 2,
      ANNOUNCEMENT = 1,
      DOOR_LOCK = 2,
      EMPLOYEE_LOGIN = 3,
      EMPLOYEE_LOGIN_DENIED = 3,
      EMPLOYEE_BADGE_LOGIN = 3,
      EMPLOYEE_BADGE_LOGIN_DENIED = 3,
      EMPLOYEE_ADD = 5,
      EMPLOYEE_ROLE = 5,
      EMPLOYEE_CLEARANCE = 5,
      BADGE_ISSUE = 5,
      BADGE_WRITE = 5,
      KIOSK_QUIT = 5,
      SETUP_CHANGE = 5,
      SETUP_DENIED = 5,
      LOCKDOWN = 3,
      LOCKDOWN_CLEAR = 3,
      SENSOR_FAULT = 2,
      SENSOR_CLEAR = 2,
      SOCIAL_POST = 2,
      SOCIAL_DM = 4,
    },
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
      default = {
        { name = "minecraft:block.note_block.pling", volume = 1.2, pitch = 1.35 },
      },
      social = {
        -- { wav = "notifications/social.wav", volume = 0.8 },
        { name = "minecraft:block.note_block.chime", volume = 1.0, pitch = 1.2 },
      },
      dm = {
        -- { wav = "notifications/dm.wav", volume = 0.9 },
        { name = "minecraft:block.note_block.bell", volume = 1.3, pitch = 1.6 },
        { name = "minecraft:block.note_block.pling", volume = 0.9, pitch = 1.9 },
      },
      alarm = {
        { name = "minecraft:block.note_block.bass", volume = 2.0, pitch = 0.55 },
        { name = "minecraft:block.note_block.bell", volume = 2.0, pitch = 0.75 },
      },
      emergency = {
        { name = "minecraft:block.note_block.bell", volume = 2.5, pitch = 2.0 },
        { name = "minecraft:block.note_block.bass", volume = 2.0, pitch = 0.45 },
      },
      lockdown = {
        { name = "minecraft:block.note_block.bass", volume = 2.4, pitch = 0.5 },
        { name = "minecraft:block.note_block.didgeridoo", volume = 2.0, pitch = 0.7 },
      },
      lockdown_clear = {
        { name = "minecraft:block.note_block.chime", volume = 1.2, pitch = 1.4 },
      },
      announcement = {
        { name = "minecraft:block.note_block.chime", volume = 1.4, pitch = 0.9 },
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
    characterSeconds = 0.055,
    spaceSeconds = 0.075,
    maxCharacters = 96,
    auto = {
      enabled = false,
      intervalSeconds = 900,
    },
    lines = {
      "Remember: report hazards before hazards report you.",
      "Facility notice: keep badges visible in restricted areas.",
    },
    voiceLines = {
      -- alert = { wav = "announcements/alert.wav" },
      -- lockdown = { files = { "announcements/lockdown_1.wav", "announcements/lockdown_2.wav" } },
      -- short = { pcm = { 0, 12, 24, 12, 0, -12, -24, -12 } },
    },
    jingles = {
      announcement = {
        -- wav = "announcements/jingle.wav",
        tones = {
          { freq = 523, seconds = 0.09 },
          { freq = 659, seconds = 0.09 },
          { freq = 784, seconds = 0.12 },
          { silence = 0.045 },
        },
      },
      alarm = {
        -- wav = "announcements/alarm_jingle.wav",
        tones = {
          { freq = 92, seconds = 0.17 },
          { silence = 0.035 },
          { freq = 74, seconds = 0.20 },
          { freq = 118, seconds = 0.16 },
          { silence = 0.045 },
          { freq = 63, seconds = 0.24 },
        },
      },
    },
    fallbackSounds = {
      { name = "minecraft:block.note_block.chime", volume = 1.4, pitch = 0.9 },
      { name = "minecraft:block.note_block.bell", volume = 1.0, pitch = 1.25 },
    },
    alarmFallbackSounds = {
      { name = "minecraft:block.note_block.bass", volume = 2.0, pitch = 0.45 },
      { name = "minecraft:block.note_block.didgeridoo", volume = 1.7, pitch = 0.65 },
    },
  },

  monitors = {
    enabled = true,
    textScale = 0.5,
    refreshSeconds = 2,
    rotateSeconds = 14,
    posterSeconds = 10,
    defaultView = "overview",
    alarmBanner = true,
    viewRotation = { "overview", "facility", "doors", "security", "posters" },
    devices = {
      -- monitor_0 = { view = "overview", textScale = 0.5 },
      -- right = { view = "posters", textScale = 1 },
      -- ["*"] = { view = "cycle" },
    },
    posters = {
      {
        title = "WORK SAFELY",
        subtitle = "Report faults before faults report you",
        body = {
          "Use emergency buttons for immediate hazards.",
          "Keep badges visible in restricted zones.",
        },
        footer = "Facility Safety Office",
        theme = "blue",
      },
      {
        title = "ACCESS IS A PRIVILEGE",
        subtitle = "Every door event is logged",
        body = {
          "Do not share badges, PINs, or kiosk sessions.",
          "Security clearance protects the whole facility.",
        },
        footer = "Security Directorate",
        theme = "red",
      },
      {
        title = "POWER KEEPS US MOVING",
        subtitle = "Watch load, stress, and capacity",
        body = {
          "Unusual readings require immediate maintenance.",
          "Create kinetic faults route to power alarms.",
        },
        footer = "Engineering",
        theme = "green",
      },
    },
  },

  alarm = {
    repeatSeconds = 1.5,
    deniedBeforeAlarm = 3,
    chat = true,
    sampleRate = 48000,
    maxSamples = 128000,
    audio = {
      chunkSamples = 128000,
      loopGapSeconds = 0.05,
    },
    syncAssets = true,
    assetsRequired = false,
    -- assetBaseUrl = "https://raw.githubusercontent.com/Mauppi/computercraft/master/",
    sounds = {
      -- { wav = "alarms/security_loop.wav", volume = 1.2 },
      -- { files = { "alarms/security_1.wav", "alarms/security_2.wav" }, volume = 1.2 },
      -- { pcm = { 0, 28, 56, 28, 0, -28, -56, -28 }, volume = 1.0 },
      { name = "minecraft:block.note_block.pling", volume = 3, pitch = 0.6 },
      { name = "minecraft:block.note_block.bell", volume = 3, pitch = 1.8 },
    },
    dsp = {
      enabled = true,
      volume = 1.2,
      sampleRate = 48000,
      duration = 0.35,
      patterns = {
        security = {
          { freq = 155, sweep = -48, duration = 0.38, gain = 1.0, sub = 0.75, harmonic = 0.52, detune = 0.22, tremolo = 7, pulse = 5, noise = 0.08, crush = 3 },
          { freq = 242, sweep = 92, duration = 0.24, gain = 0.95, sub = 0.48, harmonic = 0.66, detune = 0.18, tremolo = 12, pulse = 8, noise = 0.06, crush = 2 },
          { freq = 118, sweep = -8, duration = 0.22, gain = 0.9, sub = 0.9, harmonic = 0.35, detune = 0.3, tremolo = 5, pulse = 4, noise = 0.1, crush = 4 },
        },
        power_fault = {
          { freq = 78, sweep = 22, duration = 0.42, gain = 1.0, sub = 1.0, harmonic = 0.32, detune = 0.18, tremolo = 4, pulse = 3, noise = 0.12, crush = 5 },
          { freq = 148, sweep = -70, duration = 0.28, gain = 0.98, sub = 0.9, harmonic = 0.44, detune = 0.24, tremolo = 7, pulse = 5, noise = 0.1, crush = 4 },
        },
        facility_fault = {
          { freq = 230, sweep = -110, duration = 0.26, gain = 0.9, sub = 0.55, harmonic = 0.62, detune = 0.14, tremolo = 9, pulse = 6, noise = 0.07, crush = 2 },
          { freq = 360, sweep = -180, duration = 0.22, gain = 0.82, sub = 0.38, harmonic = 0.7, detune = 0.16, tremolo = 13, pulse = 7, noise = 0.06, crush = 2 },
        },
        emergency = {
          { freq = 720, sweep = 620, duration = 0.16, gain = 1.0, sub = 0.32, harmonic = 0.78, detune = 0.1, tremolo = 22, pulse = 11, noise = 0.06, crush = 2 },
          { freq = 138, sweep = -54, duration = 0.32, gain = 1.0, sub = 1.0, harmonic = 0.44, detune = 0.34, tremolo = 9, pulse = 5, noise = 0.12, crush = 5 },
          { freq = 980, sweep = -520, duration = 0.16, gain = 0.98, sub = 0.24, harmonic = 0.82, detune = 0.12, tremolo = 24, pulse = 12, noise = 0.06, crush = 2 },
        },
      },
    },
    outputs = {
      -- { side = "top" },
      -- { peripheral = "redstoneIntegrator_0", side = "back" },
    },
    profiles = {
      security = {
        label = "Security Alarm",
      },
      power_fault = {
        label = "Power Fault",
        sounds = {
          { name = "minecraft:block.note_block.bass", volume = 3, pitch = 0.7 },
          { name = "minecraft:block.note_block.pling", volume = 3, pitch = 1.2 },
        },
      },
      facility_fault = {
        label = "Facility Fault",
        sounds = {
          { name = "minecraft:block.note_block.bit", volume = 3, pitch = 0.8 },
          { name = "minecraft:block.note_block.bit", volume = 3, pitch = 1.6 },
        },
      },
      emergency = {
        label = "Emergency Alarm",
        repeatSeconds = 0.9,
        sounds = {
          { name = "minecraft:block.note_block.bell", volume = 3, pitch = 2.0 },
          { name = "minecraft:block.note_block.pling", volume = 3, pitch = 0.5 },
        },
      },
    },
  },

  facility = {
    enabled = true,
    autoDiscoverCreateStress = false,
    autoStressMaxLoad = 0.9,
    autoStressProfile = "power_fault",
  },

  setup = {
    enabled = true,
    kiosk = true,
    clearance = 5,
    remoteEndpointTimeout = 0.75,
    defaultDoorController = nil,
    defaultDoorSide = "front",
    defaultContactSide = "back",
    defaultExitSide = "right",
  },

  -- Source name to door id. Use "*" as a fallback for any reader.
  -- Disk drives, badge readers, player detectors, and remote reader peripherals
  -- are all treated as sources.
  -- Door controller reader sources look like controller:<computerId>:<peripheral>.
  readers = {
    ["*"] = "main",
  },

  -- Global credentials. The key is the credential string:
  --   disk:12345
  --   label:Guard Badge
  --   nfc:card-data
  --   rfid:badge-data
  --   player:Steve
  --   badge:custom-token
  credentials = {
    -- ["label:Guard Badge"] = { name = "Guard Badge", doors = { "main" } },
    -- ["player:Steve"] = { name = "Steve", doors = { "*" } },
  },

  doors = {
    main = {
      label = "Main Door",
      controller = "server",
      output = { side = "front" },
      activeOpen = true,
      openSeconds = 4,
      alarmOnDenied = true,
      badges = {
        -- "label:Guard Badge",
        -- "disk:12345",
      },
      players = {
        -- "Steve",
      },
      pins = {
        -- "1234",
      },

      -- Optional forced-open contact.
      -- contact = { side = "back", openWhen = true },

      -- Optional request-to-exit button.
      -- requestExit = { side = "right", activeWhen = true },
    },
  },

  sensors = {
    -- { name = "Vault Tripwire", input = { side = "left" }, alarmWhen = true },
    -- {
    --   name = "Main Stress Network",
    --   type = "create_stress",
    --   peripheral = "stressometer_0",
    --   maxLoad = 0.9,
    --   profile = "power_fault",
    -- },
  },

  emergencyButtons = {
    -- { name = "Lobby Emergency Button", input = { side = "top" }, activeWhen = true },
  },

  generators = {
    -- Alias for facility power sensors. Create stressometers and Create: Avionics
    -- kinetic peripherals can be monitored here.
  },
}
