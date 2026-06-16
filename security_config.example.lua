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
    initialAccounts = {
      admin = { pin = "2468", displayName = "Facility Admin", role = "admin" },
      alex = { pin = "1234", displayName = "Alex", role = "employee" },
    },
  },

  monitors = {
    enabled = true,
    textScale = 0.5,
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

  generators = {
    -- Create stressometer power/fault monitoring. Alarms when load is >= 90%.
    -- Base Create exposes getStress() and getStressCapacity() on Stressometers.
    -- Create: Avionics kinetic blocks can also be monitored when they expose
    -- getStressImpact(), getStressContribution(), or isOverstressed().
    { name = "Main Kinetic Grid", peripheral = "stressometer_0", maxLoad = 0.9, profile = "power_fault" },
  },
}
