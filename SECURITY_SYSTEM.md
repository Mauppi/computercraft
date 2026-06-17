# CC: Tweaked Facility Security System

## Server computer

1. Put `security_system.lua`, `security_system_app.lua`, `security_system_defaults.lua`, `security_system_rednet.lua`, `security_system_notifications.lua`, and `security_system_announcements.lua` on the main security computer.
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

1. Put `security_system.lua`, `security_system_app.lua`, `security_system_defaults.lua`, `security_system_rednet.lua`, `security_system_notifications.lua`, and `security_system_announcements.lua` on each kiosk computer.
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

`security_system.lua` is now only a small launcher. It uses `require("security_system_app")` to load the main app module. The app module uses `require("security_system_defaults")`, `require("security_system_rednet")`, `require("security_system_notifications")`, and `require("security_system_announcements")` for defaults, encrypted Rednet wrapping, kiosk notification handling, and announcement audio.

`startup_auto_update.lua` fetches `security_system_manifest.lua` from `https://raw.githubusercontent.com/Mauppi/computercraft/master/security_system_manifest.lua`, then downloads every listed app file from the manifest's `baseUrl`. The required files are `security_system_defaults.lua`, `security_system_rednet.lua`, `security_system_notifications.lua`, `security_system_announcements.lua`, `security_system_app.lua`, and `security_system.lua`; the manifest can also keep startup scripts, examples, docs, and WAV assets synced. Its default after-update behavior is `run` for server mode and `reboot` for kiosk mode. HTTP must be enabled in the CC:Tweaked server config.

If a writable disk drive is attached and has enough free space, `startup_auto_update.lua` installs downloaded app files and WAV assets under `disk/security_system` or the largest available `disk*/security_system` mount instead of filling the computer's local storage. Normal small CC floppy disks may be too small for the full app, so the updater falls back to computer storage when the largest disk has less than the required free-space threshold. The computer-local `security_config.lua` remains on the computer, so server/kiosk mode and local identity do not move unexpectedly. WAV playback checks normal config paths first, then the updater's disk install root.

On a fresh server computer, `startup_auto_update.lua` installs `security_config.lua` from the manifest's `serverConfig` entry before starting the app. It only does this when `security_config.lua` is missing; existing server configs are never overwritten by auto-update. If a fresh server cannot download a valid server config, the updater refuses to start instead of letting the app generate built-in defaults. The app has the same missing-config safeguard for manual starts.

For kiosk mode, `startup_auto_update.lua` also asks the main security server for a kiosk config using Rednet op `kiosk_config`. The server returns branding, kiosk settings, Rednet settings, monitor config, notifications, announcements, and alarm audio settings. If the synced config changes, the updater treats it like an update and follows the kiosk after-update action, which defaults to reboot. After config sync, the updater scans `announcements`, `notifications`, and `alarm` for every `.wav` path in voice lines, jingles, notification sounds, and alarm sounds, downloads those files in binary mode from the manifest `baseUrl`, `announcements.assetBaseUrl`, `notifications.assetBaseUrl`, or `alarm.assetBaseUrl`, and validates that each downloaded clip is a WAV file. A fresh kiosk still needs kiosk mode selected before its first config exists; set `MODE_OVERRIDE = "kiosk"` in `startup_auto_update.lua`, run `startup_auto_update kiosk` once, create `security_mode.txt` or `.security_mode` containing `kiosk`, or label the computer with `kiosk`. In kiosk mode the updater now downloads files first, then copies `security_kiosk_config.example.lua` to `security_config.lua`; if an older bad server/default config already exists, it is backed up as `security_config.lua.pre_kiosk.bak` or `disk/security_system/security_config.pre_kiosk.bak` and replaced with the kiosk example.

Locked kiosks do not expose a Quit option and disable normal Ctrl+T termination in kiosk mode. Set `kiosk.locked = false` only for development computers.
Logged-in employees can quit kiosk mode only if the server approves the `quitKiosk` permission. `kiosk.quitClearance` is only a local display fallback; server permissions remain authoritative.

Kiosks stay synced to the server alarm/lockdown state through rednet broadcasts and a periodic heartbeat. If a kiosk has a speaker attached, it mirrors active alarm sounds locally.

Logged-in kiosks auto-logout after `kiosk.autoLogoutSeconds` of no input. Logged-out kiosks reboot after `kiosk.autoRebootLoggedOutSeconds`, defaulting to 1800 seconds.

## Setup Wizard And Door Controllers

Use the server console command `setup` after an admin `login <admin-pin>` to configure facility hardware from the terminal. The setup wizard can scan server peripherals, scan a remote door controller, add or update doors, remove doors, add/remove facility sensors, add/remove emergency buttons, add/remove generators, and map/remove reader sources. Each change is saved to `security_config.lua` immediately.

Kiosks also expose `Facility setup` for employees whose clearance meets `employees.permissions.setupFacility`, default C5. The kiosk sends setup requests to the server with the logged-in session token, and the server enforces the clearance before changing config.

An authorized kiosk can also make itself a permanent door controller from `Facility setup` -> `This kiosk door-controller mode`. This keeps the employee kiosk UI running, saves `kiosk.controller.enabled = true` in the kiosk's local `security_config.lua`, answers server endpoint read/write/scan requests, and forwards local RFID/NFC/card scans as controller reader sources. The auto-updater preserves this local `kiosk.controller` block when it syncs kiosk config from the server.

For distributed doors, put a computer near one door or a small group of doors, attach its redstone integrators/sensors, give it the same Rednet protocol/encryption settings as the server, and run:

```lua
security_system controller
```

or set its config mode:

```lua
return {
  mode = "controller",
  rednet = {
    enabled = true,
    protocol = "cc_security_v1",
    serverId = 12,
    encryption = {
      enabled = true,
      key = "replace-with-a-shared-facility-secret",
      allowPlaintext = false,
    },
  },
}
```

The server remains authoritative. Controller computers only answer encrypted endpoint read/write/scan requests. A door can point at one controller for all of its endpoints:

```lua
doors = {
  lab_a = {
    label = "Lab A",
    controller = 23,
    output = { side = "front" },
    contact = { side = "back", openWhen = true },
    requestExit = { side = "right", activeWhen = true },
  },
}
```

Use one controller computer per door when wiring is dense, or one controller for a few nearby doors when the redstone/peripheral layout is shared. The setup wizard stores the controller id on the door, so its output/contact/exit endpoints inherit that controller automatically.

When using a kiosk as its own door controller, use that kiosk's computer id as the door `controller`. Scanner sources from that kiosk use `controller:<kioskId>:<peripheral>`, for example `controller:31:rfid_scanner_0`. The kiosk setup flow defaults new door/sensor/button prompts to its own controller id after local controller mode is enabled.

## Badge Writers And Door Scanners

The server console supports NFC badge writing after `login <admin-pin>`:

```lua
badge writers
badge write <data> [nfc-peripheral]
badge issue <user> [data] [nfc-peripheral] [doorAccess]
```

`badge issue` writes the raw data to an NFC card with a local NFC reader/writer peripheral, then assigns the badge to the employee account. Leave `data` blank in the setup wizard to generate a unique badge id. `doorAccess` is optional: leave it blank for kiosk login only, use `*` for all doors, or use a comma-separated door list such as `main,vault`.

High-clearance kiosks can do the same from `Facility setup` -> `Issue/write employee badge` if the kiosk has an NFC writer peripheral attached. The server enforces `employees.permissions.issueBadges`, default C5.

Kiosk sign-in supports attached `rfid_scanner` peripherals and generic NFC/card reader methods. Use `Scan badge` on the sign-in screen; the kiosk sends the scanned credential candidates to the server, and the server only creates a session if the badge is assigned to an employee.

Recommended door scanner layout:

- Put the main server computer somewhere safe and keep the employee accounts, badge assignments, logs, and config there.
- Put a door controller computer near every door, or near a small cluster of nearby doors. Attach redstone integrators, lock outputs, door contact sensors, request-exit buttons, NFC/RFID readers, and emergency buttons to that local controller where possible.
- Run `security_system controller` on each door controller and use the setup wizard from the server or an authorized kiosk to scan that controller and add/update the doors.
- Map each scanner source to the door it controls. Server-attached scanners use their peripheral name, such as `rfid_scanner_0`. Door-controller scanners are forwarded as `controller:<computerId>:<peripheral>`, such as `controller:23:rfid_scanner_0`.
- Use RFID scanners for hands-free or area badge reads, and NFC readers/writers for issuing cards and deliberate tap-to-open points. Keep kiosk RFID scanners for employee login/admin setup, not as the primary door unlock path unless the kiosk is physically at that doorway.
- Prefer one scanner source per door side when possible: outside reader opens the door, inside request-exit button opens the door, contact sensor detects forced-open state.

## Rednet Encryption And Notifications

The app uses `security_system_rednet.lua` to wrap Rednet messages. To enable encrypted Rednet traffic, set the same key on the server and every kiosk:

```lua
rednet = {
  enabled = true,
  protocol = "cc_security_v1",
  encryption = {
    enabled = true,
    key = "replace-with-a-shared-facility-secret",
    allowPlaintext = false,
  },
}
```

When encryption is enabled, plaintext Rednet packets are rejected unless `allowPlaintext = true`. Kiosks with the wrong key will not discover or talk to the server.

Kiosks receive real-time notifications for facility feed posts, direct messages, alarms, alarm resets, and lockdown changes. Recent notifications appear in the kiosk header and in the kiosk menu's Notifications view. Attached kiosk speakers play notification sounds configured under `notifications.sounds`.

DMs and facility feed posts can use short WAV clips through `speaker.playAudio`. By default, only notification kinds `dm` and `social` may play notification WAVs; alarm, emergency, lockdown, announcement, and alarm reset events are blocked from this path so they keep using the alarm/announcement audio systems or Minecraft sound fallback.

```lua
notifications = {
  wavKinds = { dm = true, social = true },
  sounds = {
    dm = {
      { wav = "notifications/dm.wav", volume = 0.9 },
      { name = "minecraft:block.note_block.bell", volume = 1.3, pitch = 1.6 },
    },
    social = {
      { wav = "notifications/social.wav", volume = 0.8 },
      { name = "minecraft:block.note_block.chime", volume = 1.0, pitch = 1.2 },
    },
  },
}
```

## Employee Notes And Clearance

Kiosk notes now support full-note reading, editing by list number, and safe updates. A wrong note id no longer creates a duplicate note.

Employee clearance controls kiosk security actions:

- C1 can use normal employee features and trigger emergency alarms.
- C2 can trigger regular security alarms.
- C3 can reset alarms and operate doors.
- C4 can start or clear lockdown.
- C5 can manage employees from the server console and authorize kiosk exit.

Change thresholds in `employees.permissions`, including `quitKiosk`.

Facility logs are available from the kiosk menu. The server tags new log lines with a clearance marker such as `C2` or `C5`, and employees only receive log lines at or below their clearance. Configure this with `logs.clearances` and the `viewLogs` permission.

Long log views use an interactive pager: Enter or N goes forward, P goes back, and Q closes the view.

## Facility Announcements

Admins can send a facility announcement from the server console:

```lua
announce <message>
```

Announcements are pushed to kiosks as real-time notifications. Kiosks with speakers play a stitched `speaker.playAudio` buffer when available: jingle, optional WAV/PCM voice line segments, then generated PCM voice if no file-backed voice line is configured. Configure this under `announcements`; scheduled announcements can be enabled with `announcements.auto.enabled = true`.

Event and action announcements are configurable under `announcements.events` and `announcements.actions`. Each entry can use `variations` for random text, `voiceLine` for a configured WAV/PCM voice line, `chance` for probabilistic lines (`0.5` or `50` both mean 50%), and `cooldownSeconds` to avoid spam. Placeholders like `{facility}`, `{reason}`, `{actor}`, `{sensor}`, `{user}`, and `{action}` are replaced from the event or audit detail.

Action announcements that happen at the same moment as an alarm can delay speaker buffers, so alarm-raising fault actions such as `SENSOR_FAULT` are best left disabled unless you intentionally want a separate spoken fault notice.

Voice lines can be raw PCM tables, one WAV file, or multiple WAV segments:

```lua
announcements = {
  syncAssets = true,
  assetsRequired = false,
  -- assetBaseUrl = "https://raw.githubusercontent.com/Mauppi/computercraft/master/",
  events = {
    lockdown = {
      voiceLine = "lockdown",
      cooldownSeconds = 2,
      variations = {
        "Lockdown active. Secure your area.",
        "{facility} lockdown is active. Await authorization.",
      },
    },
    alarm_reset = {
      voiceLine = "alarm_clear",
      variations = {
        "Alarm condition cleared.",
        "{facility} alarm state has returned to clear.",
      },
    },
  },
  actions = {
    SENSOR_FAULT = {
      cooldownSeconds = 20,
      variations = {
        "Facility sensor fault detected at {sensor}.",
        "Maintenance attention requested for sensor {sensor}.",
      },
    },
    SETUP_CHANGE = {
      chance = 0.5,
      cooldownSeconds = 6,
      variations = {
        "Facility configuration updated by {actor}.",
        "Setup change recorded: {action}.",
      },
    },
  },
  voiceLines = {
    badge_notice = { wav = "announcements/badge_notice.wav" },
    lockdown = {
      files = {
        "announcements/lockdown_1.wav",
        "announcements/lockdown_2.wav",
      },
    },
  },
  jingles = {
    announcement = { wav = "announcements/jingle.wav" },
    alarm = { wav = "announcements/alarm_jingle.wav" },
  },
}
```

WAV loading supports RIFF/WAVE PCM clips at 8-bit or 16-bit, mono or stereo. Clips are resampled to `announcements.sampleRate`, default `48000`, and mixed down to the signed 8-bit sample values expected by CC:Tweaked speakers. Keep stitched clips short enough for the configured `announcements.maxSamples`, default `128000`, or split long lines into shorter announcement segments.

Committed audio can also be listed explicitly in `security_system_manifest.lua` under `assets`, `audioFiles`, or `wavs`. Those entries are optional unless `required = true` is set.

## Alarm Audio And Emergency Buttons

Speakers use generated PCM/DSP alarm pulses through `speaker.playAudio` when available, with Minecraft sound fallback. The default DSP profiles use low dissonant tones, sub harmonics, detune, pulsing, sample crush, tremolo, and grit for a more menacing alarm sound. Configure or disable this under `alarm.dsp`.

Alarm loop entries under `alarm.sounds` can also be WAV files, stitched WAV segments, or raw PCM sample tables. When a selected loop entry has `wav`, `files`, or `pcm`, it streams through `speaker.playAudio` in chunks and waits for the full clip to finish before looping or rotating to the next alarm sound. The server broadcasts `alarm.soundStartAt` before audio starts so server and kiosk speakers begin together; `alarm.syncLeadSeconds`, default `1.5`, controls how much delivery time Rednet gets. `alarm.audio.chunkSamples` controls each speaker buffer packet, default `128000`, and `alarm.audio.loopGapSeconds` controls the gap between completed loops.

```lua
alarm = {
  syncLeadSeconds = 1.5,
  sampleRate = 48000,
  maxSamples = 128000,
  audio = { chunkSamples = 128000, loopGapSeconds = 0.05 },
  syncAssets = true,
  sounds = {
    { wav = "alarms/security_loop.wav", volume = 1.2 },
    { files = { "alarms/klaxon_a.wav", "alarms/klaxon_b.wav" }, volume = 1.2 },
    { pcm = { 0, 28, 56, 28, 0, -28, -56, -28 }, volume = 1.0 },
  },
}
```

Lockdown changes also send kiosk notifications. Configure their speaker alerts under `notifications.sounds.lockdown` and `notifications.sounds.lockdown_clear`.

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

Kiosk computers also render attached monitors. The kiosk monitor loop starts with kiosk mode, refreshes from the main server using the unauthenticated `status` request when a server is known, and then draws the same views from the server snapshot. If the kiosk is not connected yet, poster views still render from local config.

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
