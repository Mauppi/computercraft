-- Files required by the CC: Tweaked facility security system updater.
-- The updater fetches this file first, then downloads each listed file from baseUrl.

return {
  appName = "facility_security_system",
  baseUrl = "https://raw.githubusercontent.com/Mauppi/computercraft/master/",
  entry = "security_system.lua",

  assets = {
    -- Add announcement WAV assets here when committing audio files.
    -- Entries are optional by default unless required = true.
    -- { path = "announcements/jingle.wav", binary = true, kind = "wav" },
    -- { path = "announcements/alarm_jingle.wav", binary = true, kind = "wav" },
    -- { path = "announcements/badge_notice.wav", binary = true, kind = "wav" },
  },

  files = {
    {
      path = "security_system_defaults.lua",
      required = true,
      minSize = 2000,
      contains = {
        "Default configuration",
        "return {",
        "alarm = {",
      },
    },
    {
      path = "security_system_rednet.lua",
      required = true,
      minSize = 2000,
      contains = {
        "Rednet message wrapping",
        "__securitySystem",
        "function M.wrap",
      },
    },
    {
      path = "security_system_notifications.lua",
      required = true,
      minSize = 1000,
      contains = {
        "Kiosk notification",
        "function M.push",
        "function M.playSound",
      },
    },
    {
      path = "security_system_announcements.lua",
      required = true,
      minSize = 1000,
      contains = {
        "Facility announcement audio",
        "function M.loadWav",
        "function M.buildVoiceBuffer",
        "function M.buildAnnouncementBuffer",
        "function M.play",
      },
    },
    {
      path = "security_system_app.lua",
      required = true,
      minSize = 2000,
      contains = {
        "CC: Tweaked security system",
        "security_system_defaults",
        "security_system_rednet",
        "security_system_notifications",
        "security_system_announcements",
        "function controllerMain()",
        "kiosk_setup",
        "kiosk_badge_login",
        "controller_credential",
        "function main()",
        "return {",
      },
    },
    {
      path = "security_system.lua",
      required = true,
      minSize = 300,
      contains = {
        "security_system_app",
        "app.run",
      },
    },
    {
      path = "security_system_manifest.lua",
      required = true,
      minSize = 300,
      contains = "security_system_app.lua",
    },
    {
      path = "startup_auto_update.lua",
      required = false,
      minSize = 1000,
      contains = "security_system_manifest.lua",
    },
    {
      path = "startup_kiosk.lua",
      required = false,
      minSize = 500,
      contains = "SECURITY_PROGRAM",
    },
    {
      path = "security_config.example.lua",
      required = false,
      minSize = 500,
      contains = "North Ridge Facility",
    },
    {
      path = "security_kiosk_config.example.lua",
      required = false,
      minSize = 300,
      contains = "mode = \"kiosk\"",
    },
    {
      path = "SECURITY_SYSTEM.md",
      required = false,
      minSize = 500,
      contains = "Facility Security System",
    },
  },
}
