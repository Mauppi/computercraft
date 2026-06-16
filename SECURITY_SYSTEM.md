# CC: Tweaked Facility Security System

## Server computer

1. Put `security_system.lua` on the main security computer.
2. Copy `security_config.example.lua` to `security_config.lua`.
3. Edit `security_config.lua` for your doors, readers, branding, employee accounts, alarm outputs, and facility sensors.
4. Attach/open a modem if kiosks or remote clients should connect.
5. For auto-updates, copy `startup_auto_update.lua` to `startup.lua`.
6. To start manually, run:

```lua
security_system
```

The server owns the authoritative config and writes:

- `security_accounts.lua` for employee accounts and personal notes.
- `security_social.lua` for the facility feed and direct messages.
- `security_audit.log` for security events.

Use the server console command `employee add <user> <pin> [display name]` after `login <admin-pin>` to add facility employees without editing data files.
Use `employee clearance <user> <level>` to grant limited kiosk administration. The default levels are employee 1, operator 2, security 3, manager 4, and admin 5.

## Kiosk computers

1. Put the same `security_system.lua` on each kiosk computer.
2. Copy `security_kiosk_config.example.lua` to `security_config.lua`.
3. Set `rednet.serverId` to the main server computer id, or leave it `nil` for broadcast discovery.
4. For kiosk-only autorun, copy `startup_kiosk.lua` to `startup.lua` on the kiosk computer.
5. For auto-updating autorun, copy `startup_auto_update.lua` to `startup.lua` instead.
6. To start manually, run:

```lua
security_system kiosk
```

Employees can sign in, edit personal notes, read/post to the facility feed, send direct messages, view the employee directory, and check facility status.

`startup_kiosk.lua` creates a kiosk config from `security_kiosk_config.example.lua` if `security_config.lua` does not exist, starts kiosk mode, and restarts it if it exits.

`startup_auto_update.lua` fetches `security_system.lua` from `https://raw.githubusercontent.com/Mauppi/computercraft/master/security_system.lua`. Its default after-update behavior is `run` for server mode and `reboot` for kiosk mode. HTTP must be enabled in the CC:Tweaked server config.

Locked kiosks do not expose a Quit option and disable normal Ctrl+T termination in kiosk mode. Set `kiosk.locked = false` only for development computers.

Kiosks stay synced to the server alarm/lockdown state through rednet broadcasts and a periodic heartbeat. If a kiosk has a speaker attached, it mirrors active alarm sounds locally.

## Employee Notes And Clearance

Kiosk notes now support full-note reading, editing by list number, and safe updates. A wrong note id no longer creates a duplicate note.

Employee clearance controls kiosk security actions:

- C1 can use normal employee features and trigger emergency alarms.
- C2 can trigger regular security alarms.
- C3 can reset alarms and operate doors.
- C4 can start or clear lockdown.
- C5 can manage employees from the server console.

Change thresholds in `employees.permissions`.

Facility logs are available from the kiosk menu. The server tags new log lines with a clearance marker such as `C2` or `C5`, and employees only receive log lines at or below their clearance. Configure this with `logs.clearances` and the `viewLogs` permission.

## Alarm Audio And Emergency Buttons

Speakers use generated PCM/DSP alarm pulses through `speaker.playAudio` when available, with Minecraft sound fallback. Configure or disable this under `alarm.dsp`.

Emergency button example:

```lua
emergencyButtons = {
  { name = "Lobby Emergency Button", input = { side = "top" }, activeWhen = true, profile = "emergency" },
}
```

## Monitor Dashboards And Posters

Attach any CC:Tweaked monitor and enable `monitors` in `security_config.lua`. Per-monitor views are configured by peripheral name:

```lua
monitors = {
  enabled = true,
  textScale = 0.5,
  refreshSeconds = 2,
  devices = {
    monitor_0 = { view = "overview", theme = "blue" },
    monitor_1 = { view = "facility", theme = "green" },
    monitor_2 = { view = "doors", theme = "black" },
    monitor_3 = { view = "posters", textScale = 1, theme = "red" },
    ["*"] = { view = "cycle" },
  },
}
```

Views:

- `overview`: facility state, door counts, active faults, active sessions, and recent doors.
- `facility`: sensor/generator data, fault state, and load bars for Create stress data.
- `doors`: door matrix with locked/open state and last actor.
- `security`: alarm, lockdown, and emergency button state.
- `posters`: facility poster slideshow.
- `cycle`: rotates through `monitors.viewRotation`.

Poster slides are configured in `monitors.posters`:

```lua
{
  title = "WORK SAFELY",
  subtitle = "Report faults before faults report you",
  body = {
    "Use emergency buttons for immediate hazards.",
    "Keep badges visible in restricted zones.",
  },
  footer = "Facility Safety Office",
  theme = "blue",
}
```

Alarm banners overlay dashboards and posters unless `monitors.alarmBanner = false`.

## Facility sensors

Simple redstone fault input:

```lua
{ name = "Boiler Pressure Switch", input = { side = "left" }, alarmWhen = true, profile = "facility_fault" }
```

Generic peripheral threshold:

```lua
{ name = "Coolant Tank", type = "peripheral", peripheral = "fluidTank_0", method = "getFluidLevel", max = 9000, profile = "facility_fault" }
```

Create stressometer or Create: Avionics kinetic monitor:

```lua
{ name = "Main Kinetic Grid", peripheral = "stressometer_0", maxLoad = 0.9, profile = "power_fault" }
```

Create support is optional. Base Create stressometers expose stress/capacity readings; Create: Avionics kinetic peripherals can also be checked when they expose stress methods.
