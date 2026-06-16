-- Example configuration for security_system.lua.
-- Copy or rename this file to security_config.lua, or let the program generate
-- a starter config on first run.

return {
  mode = "server",
  siteName = "Base Security",
  facilityName = "North Ridge Facility",
  branding = {
    facilityName = "North Ridge Facility",
    shortName = "NRF",
    kioskTitle = "Employee Kiosk",
    motto = "Check in. Stay informed. Report faults.",
    primaryColor = "blue",
    accentColor = "lime",
    textColor = "white",
  },
  logFile = "security_audit.log",

  -- Keep the first admin PIN private. Change this before real use.
  adminPins = { "2468" },

  defaultOpenSeconds = 4,
  forcedGraceSeconds = 2,
  badgeCooldownSeconds = 3,
  pollSeconds = 1,

  rednet = {
    enabled = true,
    protocol = "cc_security_v1",
    -- Optional: kiosks can set serverId to this computer's id.
    serverId = nil,
    discoverySeconds = 2,
  },

  employees = {
    enabled = true,
    allowSelfRegistration = false,
    accountsFile = "security_accounts.lua",
    socialFile = "security_social.lua",
    sessionSeconds = 1800,
    maxNoteLength = 4096,
    maxPostLength = 512,
    maxMessageLength = 512,
    maxFeedItems = 100,
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
      manageEmployees = 5,
    },
    initialAccounts = {
      admin = { pin = "2468", displayName = "Facility Admin", role = "admin", clearance = 5 },
      alex = { pin = "1234", displayName = "Alex", role = "employee", clearance = 1 },
      sam = { pin = "2222", displayName = "Sam Security", role = "security", clearance = 3 },
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
      DOOR_LOCK = 2,
      EMPLOYEE_LOGIN = 3,
      EMPLOYEE_LOGIN_DENIED = 3,
      EMPLOYEE_ADD = 5,
      EMPLOYEE_ROLE = 5,
      EMPLOYEE_CLEARANCE = 5,
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
  },

  monitors = {
    enabled = true,
    textScale = 0.5,
    refreshSeconds = 2,
    rotateSeconds = 14,
    posterSeconds = 10,
    defaultView = "overview",
    alarmBanner = true,

    -- Views: overview, facility, doors, security, posters, or cycle.
    -- Use the real monitor peripheral names shown by `peripheral.getNames()`.
    devices = {
      -- monitor_0 = { view = "overview", textScale = 0.5, theme = "blue" },
      -- monitor_1 = { view = "facility", textScale = 0.5, theme = "green" },
      -- monitor_2 = { view = "doors", textScale = 0.5, theme = "black" },
      -- monitor_3 = { view = "posters", textScale = 1, theme = "red" },
      -- ["*"] = { view = "cycle", views = { "overview", "facility", "doors", "security", "posters" } },
    },

    viewRotation = { "overview", "facility", "doors", "security", "posters" },

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

    -- Speakers are discovered automatically.
    sounds = {
      { name = "minecraft:block.note_block.pling", volume = 3, pitch = 0.6 },
      { name = "minecraft:block.note_block.bell", volume = 3, pitch = 1.8 },
    },

    -- Uses speaker.playAudio when available. Existing Minecraft sounds remain
    -- as a fallback for older/simple speaker setups.
    dsp = {
      enabled = true,
      volume = 1.2,
      sampleRate = 48000,
      duration = 0.35,
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
          { name = "minecraft:block.note_block.bass", volume = 3, pitch = 0.7 },
          { name = "minecraft:block.note_block.pling", volume = 3, pitch = 1.2 },
        },
        outputs = {
          { side = "top" },
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

    -- Optional automatic scan for Create Stressometers and Create: Avionics
    -- kinetic peripherals that expose stress methods.
    autoDiscoverCreateStress = false,
    autoStressMaxLoad = 0.9,
    autoStressProfile = "power_fault",

    -- If remote sensor computers send facility_fault messages, set a key here
    -- and include it in those messages.
    -- remoteSensorKey = "change-me",
  },

  -- Reader source to door mapping. Examples:
  --   left = "front_door"              -- disk drive on the left side
  --   playerDetector_0 = "front_door"  -- Advanced Peripherals player detector
  --   badge_reader_0 = "vault"         -- any badge/card peripheral with a common read method
  --   ["*"] = "front_door"             -- fallback for any reader
  readers = {
    left = "front_door",
    playerDetector_0 = "front_door",
    ["*"] = "front_door",
  },

  -- Global credentials can unlock one or more doors.
  -- Supported credential forms include:
  --   disk:<disk-id>
  --   label:<disk-label>
  --   nfc:<card-data>
  --   rfid:<badge-data>
  --   player:<player-name>
  --   badge:<token-from-card-reader>
  credentials = {
    ["label:Guard Badge"] = { name = "Guard Badge", doors = { "front_door" } },
    ["rfid:guard-rfid-token"] = { name = "Guard RFID", doors = { "front_door" } },
    ["player:Steve"] = { name = "Steve", doors = { "*" } },
  },

  doors = {
    front_door = {
      label = "Front Door",

      -- Iron doors normally open when redstone is on.
      output = { side = "front" },
      activeOpen = true,
      openSeconds = 4,

      -- Local per-door credentials.
      badges = {
        "label:Guard Badge",
        "rfid:guard-rfid-token",
        -- "disk:12345",
        -- "nfc:front-door-card",
        -- "badge:abc123",
      },
      players = {
        "Steve",
      },
      pins = {
        "1234",
      },

      -- Optional forced-open sensor. When this input means "open" while the
      -- door should be locked, the alarm is raised.
      contact = { side = "back", openWhen = true },

      -- Optional request-to-exit button or pressure plate.
      requestExit = { side = "right", activeWhen = true },

      alarmOnDenied = true,
      deniedBeforeAlarm = 3,
    },

    vault = {
      label = "Vault",
      output = { peripheral = "redstoneIntegrator_0", side = "left" },
      activeOpen = true,
      openSeconds = 3,
      badges = {
        "label:Vault Badge",
      },
      pins = {
        "9876",
      },
      contact = { peripheral = "redstoneIntegrator_0", side = "right", openWhen = true },
      alarmOnDenied = true,
      deniedBeforeAlarm = 1,
    },
  },

  sensors = {
    { name = "Tripwire", input = { side = "bottom" }, alarmWhen = true, profile = "security" },

    -- Generic redstone fault input.
    { name = "Boiler Pressure Switch", input = { side = "left" }, alarmWhen = true, profile = "facility_fault" },

    -- Generic peripheral/method threshold. Works with many CC:C Bridge,
    -- Advanced Peripherals, or Create: Avionics peripherals if the method exists.
    -- { name = "Coolant Tank", type = "peripheral", peripheral = "fluidTank_0", method = "getFluidLevel", max = 9000, profile = "facility_fault" },
  },

  emergencyButtons = {
    -- Any redstone button, pressure plate, tripwire, or redstone integrator input.
    { name = "Lobby Emergency Button", input = { side = "top" }, activeWhen = true, profile = "emergency" },
    -- { name = "Vault Emergency Button", input = { peripheral = "redstoneIntegrator_0", side = "bottom" }, activeWhen = true, profile = "emergency" },
  },

  generators = {
    -- Create stressometer power/fault monitoring. Alarms when load is >= 90%.
    -- Base Create exposes getStress() and getStressCapacity() on Stressometers.
    -- Create: Avionics kinetic blocks can also be monitored when they expose
    -- getStressImpact(), getStressContribution(), or isOverstressed().
    { name = "Main Kinetic Grid", peripheral = "stressometer_0", maxLoad = 0.9, profile = "power_fault" },
  },
}
