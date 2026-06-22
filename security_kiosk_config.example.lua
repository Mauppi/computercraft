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
    remoteAudioChunkSamples = 2048,
    remoteAudioLeadSeconds = 0.75,
    alarmAnnouncements = true,
    queueLimit = 12,
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
      { voiceLine = "slopday_website" },
      { voiceLine = "slopday_goon" },
      { voiceLine = "slopday_animals" },
      { voiceLine = "slopday_sloppingit" },
      { voiceLine = "slopdaysus" },
    },
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
          "Security alarm engaged in {area}. Cause: {reason}.",
          "Attention personnel. Security response required near {doorLabel}.",
          "{facility} security alarm active. Area: {area}. Await clearance.",
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
          "Emergency alarm engaged. Area: {area}. Follow facility response procedures.",
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
      attention = { files = { "announcements/vo_attention.wav" } },
      memeorpo = { files = { "announcements/vo_memeorpo.wav" } },
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
    scanSeconds = 15,
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
        repeatSeconds = 1.25,
        sounds = {
          { files = { "announcements/red_alert_a.wav", "announcements/red_alert_a.wav", "announcements/red_alert_a.wav", "announcements/red_alert_b.wav", "announcements/red_alert_b.wav", "announcements/red_alert_b.wav" }, volume = 1.2 },
        },
      },
    },
  },
}
