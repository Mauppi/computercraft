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
  credentialPollSeconds = 1,
  inputPollSeconds = 1,
  sensorPollSeconds = 5,
  redstoneDebounceSeconds = 0.05,
  stressDebounceSeconds = 0.2,

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
    area = "",
    locationArea = "",
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
      pollSeconds = 0.5,
      idlePollSeconds = 5,
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
    voice = false,
    syntheticVoice = false,
    requireVoiceLine = true,
    volume = 1,
    sampleRate = 48000,
    maxSamples = 128000,
    chunkSamples = 24000,
    streamGraceSeconds = 30,
    watchdogSeconds = 0.25,
    idleWatchdogSeconds = 2,
    tailSeconds = 0.5,
    maxChunksPerFeed = 8,
    prebufferSeconds = 2.5,
    refillSeconds = 0.75,
    syncLeadSeconds = 1.5,
    syncToleranceSeconds = 0.08,
    syncSkipLate = true,
    serverPlayback = true,
    serverPreparedAudio = true,
    clientAudioSynthesis = false,
    remoteAudioChunkSamples = 8192,
    remoteAudioYieldChunks = 4,
    remoteAudioYieldSeconds = 0.03,
    remoteAudioLeadSeconds = 1,
    alarmAnnouncements = true,
    queueLimit = 12,
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
    lines = {},
    eventAnnouncements = true,
    personnelTitles = {
      admin = { label = "Admin", voiceLine = "personnel_request_admin" },
      doctor = { label = "Doctor", voiceLine = "personnel_request_doctor" },
      employee = { label = "Employee", voiceLine = "personnel_request_employee" },
      engineer = { label = "Engineer", voiceLine = "personnel_request_engineer" },
      maintenance = { label = "Maintenance", voiceLine = "personnel_request_maintenance" },
      security = { label = "Security", voiceLine = "personnel_request_security" },
    },
    personnelReasons = {
      engineering = { label = "engineering", voiceLine = "personnel_reason_engineering" },
      general = { label = "general assistance", voiceLine = "personnel_reason_general" },
      maintenance = { label = "maintenance", voiceLine = "personnel_reason_maintenance" },
      medical = { label = "medical assistance", voiceLine = "personnel_reason_medical" },
      meeting = { label = "meeting", voiceLine = "personnel_reason_meeting" },
      questioning = { label = "questioning", voiceLine = "personnel_reason_questioning" },
      security = { label = "security", voiceLine = "personnel_reason_security" },
    },
    events = {
      alarm = {
        title = "Security Alarm",
        voiceLine = "security_alarm_engaged",
        cooldownSeconds = 2,
        variations = {
          "Security alarm active in {area}. Cause: {reason}.",
          "Attention. Security response required near {doorLabel}.",
          "{facility} security alarm condition active. Area: {area}. Await clearance.",
        },
      },
      ["alarm:security"] = {
        title = "Security Alarm",
        voiceLine = "security_alarm_engaged",
        cooldownSeconds = 2,
        variations = {
          "Security alarm engaged in {area}. Cause: {reason}.",
          "Security response requested at {doorLabel}, {area}.",
          "Unauthorized condition detected in {area}. Security alarm engaged.",
        },
      },
      ["alarm:facility_fault"] = {
        title = "Facility Fault Alarm",
        voiceLine = "facility_fault_engaged",
        cooldownSeconds = 2,
        variations = {
          "Facility fault alarm engaged. Area: {area}. Cause: {reason}.",
          "Maintenance response required in {area}. Facility alarm engaged.",
          "Fault condition active near {doorLabel}. Await engineering clearance.",
        },
      },
      ["alarm:power_fault"] = {
        title = "Power Fault Alarm",
        voiceLine = "power_fault_engaged",
        cooldownSeconds = 2,
        variations = {
          "Power fault alarm engaged. Area: {area}. Cause: {reason}.",
          "Engineering response required. Power anomaly detected in {area}.",
          "Create electrical fault condition active. Await maintenance clearance.",
        },
      },
      emergency = {
        title = "Emergency Alarm",
        voiceLine = "emergency_alarm_engaged",
        cooldownSeconds = 2,
        variations = {
          "Emergency alarm active. Area: {area}. Follow facility response procedures.",
          "Emergency condition declared in {area}. Move with purpose and await instruction.",
          "{facility} emergency response is now active.",
        },
      },
      alarm_reset = {
        title = "Alarm Reset",
        voiceLine = "security_alarm_disengaged",
        cooldownSeconds = 2,
        variations = {
          "Alarm condition disengaged in {area}. Resume normal duties.",
          "Security alarm reset for {doorLabel}. Continue monitoring your area.",
          "{facility} alarm state has returned to clear.",
        },
      },
      ["alarm_reset:security"] = {
        title = "Security Alarm Reset",
        voiceLine = "security_alarm_disengaged",
        cooldownSeconds = 2,
        variations = {
          "Security alarm disengaged in {area}.",
          "Security alarm reset near {doorLabel}. Resume normal duties.",
          "Area {area} has returned to security clear.",
        },
      },
      ["alarm_reset:facility_fault"] = {
        title = "Facility Fault Clear",
        voiceLine = "facility_fault_disengaged",
        cooldownSeconds = 2,
        variations = {
          "Facility fault alarm disengaged in {area}.",
          "Maintenance fault clear for {area}. Continue monitoring.",
          "Facility fault state cleared near {doorLabel}.",
        },
      },
      ["alarm_reset:power_fault"] = {
        title = "Power Fault Clear",
        voiceLine = "power_fault_disengaged",
        cooldownSeconds = 2,
        variations = {
          "Power fault alarm disengaged. Engineering systems normal.",
          "Power anomaly cleared in {area}. Continue monitoring generators.",
          "Create electrical fault state cleared.",
        },
      },
      ["alarm_reset:emergency"] = {
        title = "Emergency Alarm Reset",
        voiceLine = "emergency_alarm_disengaged",
        cooldownSeconds = 2,
        variations = {
          "Emergency alarm disengaged in {area}.",
          "Emergency response cleared. Await supervisor confirmation.",
          "{facility} emergency state has returned to clear.",
        },
      },
      lockdown = {
        title = "Lockdown Active",
        voiceLine = "lockdown",
        cooldownSeconds = 2,
        variations = {
          "Lockdown active. Secure your area and await authorization.",
          "{facility} lockdown is now active. Remain at your assigned station.",
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
      personnel_request = {
        title = "Personnel Request",
        voiceLines = { "{personnelVoiceLine}", "{personnelNameVoiceLine}", "personnel_request", "{areaVoiceLine}", "{personnelReasonVoiceLine}" },
        cooldownSeconds = 3,
        variations = {
          "{personnel} requested in {area} for {personnelReasonLabel}. Title: {personnelTitle}.",
          "{personnelTitle} personnel request from {requester} for {personnelReasonLabel}. Report to {area}.",
          "Area {area} requests {personnelTitle} for {personnelReasonLabel}. Respond when available.",
        },
      },
    },
    actions = {
      ACCESS_GRANTED = {
        enabled = false,
        title = "Door Access",
        cooldownSeconds = 4,
        chance = 0.35,
        variations = {
          "Door access granted for {actor} at {doorLabel}. Area: {area}.",
          "{actor} entered {area} through {doorLabel}.",
          "Access event logged. Personnel {actor}. Area {area}.",
        },
      },
      ACCESS_DENIED = {
        enabled = false,
        title = "Door Access Denied",
        cooldownSeconds = 4,
        variations = {
          "Access denied for {actor} at {doorLabel}. Area: {area}.",
          "Rejected credential at {doorLabel}. Security observe {area}.",
          "Unauthorized access attempt logged in {area}.",
        },
      },
      DOOR_LOCK = {
        enabled = false,
        title = "Door Secured",
        cooldownSeconds = 8,
        chance = 0.35,
        variations = {
          "{doorLabel} secured. Area: {area}.",
          "Door state secured in {area}.",
          "{area} access point locked.",
        },
      },
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
      -- alert = { wav = "announcements/alert.wav" },
      -- lockdown = { files = { "announcements/lockdown_1.wav", "announcements/lockdown_2.wav" } },
      -- short = { pcm = { 0, 12, 24, 12, 0, -12, -24, -12 } },
      attention = { files = { "announcements/vo_attention.wav" } },
      lockdown = { files = { "announcements/vo_lockdown.wav", "announcements/vo_engaged.wav" } },
      lockdown_clear = { files = { "announcements/vo_lockdown.wav", "announcements/vo_disengaged.wav" } },
      alarm = { files = { "announcements/vo_alarm.wav", "announcements/vo_engaged.wav" } },
      alarm_clear = { files = { "announcements/vo_alarm.wav", "announcements/vo_disengaged.wav" } },
      security_alarm_engaged = { files = { "announcements/vo_secalarm.wav", "announcements/vo_engaged.wav" } },
      security_alarm_disengaged = { files = { "announcements/vo_secalarm.wav", "announcements/vo_disengaged.wav" } },
      emergency_alarm_engaged = { files = { "announcements/vo_attention.wav", "announcements/vo_alarm.wav", "announcements/vo_engaged.wav" } },
      emergency_alarm_disengaged = { files = { "announcements/vo_attention.wav", "announcements/vo_alarm.wav", "announcements/vo_disengaged.wav" } },
      facility_fault_engaged = { files = { "announcements/vo_attention.wav", "announcements/vo_alarm.wav", "announcements/vo_engaged.wav" } },
      facility_fault_disengaged = { files = { "announcements/vo_attention.wav", "announcements/vo_alarm.wav", "announcements/vo_disengaged.wav" } },
      power_fault_engaged = { files = { "announcements/vo_attention.wav", "announcements/vo_alarm.wav", "announcements/vo_engaged.wav" } },
      power_fault_disengaged = { files = { "announcements/vo_attention.wav", "announcements/vo_alarm.wav", "announcements/vo_disengaged.wav" } },
      door_access = { files = { "announcements/vo_attention.wav" } },
      door_denied = { files = { "announcements/vo_attention.wav" } },
      door_secured = { files = { "announcements/vo_attention.wav" } },
      personnel_request = {
        files = { "announcements/vo_yourequested.wav" },
      },
      personnel_request_admin = {
        files = { "announcements/vo_admin.wav" },
      },
      personnel_request_doctor = {
        files = { "announcements/vo_doctor.wav" },
      },
      personnel_request_employee = {
        files = { "announcements/vo_employee.wav" },
      },
      personnel_request_engineer = {
        files = { "announcements/vo_engineer.wav" },
      },
      personnel_request_maintenance = {
        files = { "announcements/vo_maintenance.wav" },
      },
      personnel_request_security = {
        files = { "announcements/vo_security.wav" },
      },
      person_crafthessu = { files = { "announcements/vo_person_crafthessu.wav" } },
      person_faceremover = { files = { "announcements/vo_person_faceremover.wav" } },
      person_lucsaani = { files = { "announcements/vo_person_lucsaani.wav" } },
      person_mauppi = { files = { "announcements/vo_person_mauppi.wav" } },
      person_skaahejo = { files = { "announcements/vo_person_skaahejo.wav" } },
      place_frontentrance = { files = { "announcements/vo_place_frontentrance.wav" } },
      place_mainshaft = { files = { "announcements/vo_place_mainshaft.wav" } },
      place_serverroom = { files = { "announcements/vo_place_serverroom.wav" } },
      word_for = { files = { "announcements/vo_for.wav" } },
      personnel_reason_engineering = { files = { "announcements/vo_for.wav", "announcements/vo_engineer.wav" } },
      personnel_reason_general = { files = { "announcements/vo_for.wav", "announcements/vo_personnelrequest_general_reason.wav" } },
      personnel_reason_maintenance = {
        variations = {
          { files = { "announcements/vo_for.wav", "announcements/vo_maintenance.wav" } },
          { files = { "announcements/vo_for.wav", "announcements/vo_engineer.wav" } },
        },
      },
      personnel_reason_medical = { files = { "announcements/vo_for.wav", "announcements/vo_doctor.wav" } },
      personnel_reason_meeting = { files = { "announcements/vo_for.wav", "announcements/vo_meeting.wav" } },
      personnel_reason_questioning = { files = { "announcements/vo_for.wav", "announcements/vo_questioning.wav" } },
      personnel_reason_security = { files = { "announcements/vo_for.wav", "announcements/vo_security.wav" } },
      slopday = { files = { "announcements/slopday.wav" } },
      slopday_cancelled = { files = { "announcements/slopdaycancelled.wav" } },
      slopday_slop = { files = { "announcements/slopdayslop.wav" } },
      slopday_nonono = { files = { "announcements/slopdaynonono.wav" } },
      slopday_website = { files = { "announcements/slopdaywebsite.wav" } },
      slopday_goon = { files = { "announcements/slopdaygoon.wav" } },
      slopday_animals = { files = { "announcements/slopdayanimals.wav" } },
      slopday_sloppingit = { files = { "announcements/slopdaysloppingit.wav" } },
      slopdaysus = { files = { "announcements/slopdaySuS.wav" } },
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
    scanSeconds = 15,
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
    syncLeadSeconds = 1.5,
    syncToleranceSeconds = 0.08,
    syncSkipLate = true,
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
