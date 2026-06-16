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
  },

  kiosk = {
    locked = true,
    syncSeconds = 2,
    alarmSoundSeconds = 1.5,
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
}
