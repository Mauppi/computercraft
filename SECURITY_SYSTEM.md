# CC: Tweaked Facility Security System

## Server computer

1. Put `security_system.lua` on the main security computer.
2. Copy `security_config.example.lua` to `security_config.lua`.
3. Edit `security_config.lua` for your doors, readers, branding, employee accounts, alarm outputs, and facility sensors.
4. Attach/open a modem if kiosks or remote clients should connect.
5. Run:

```lua
security_system
```

The server owns the authoritative config and writes:

- `security_accounts.lua` for employee accounts and personal notes.
- `security_social.lua` for the facility feed and direct messages.
- `security_audit.log` for security events.

Use the server console command `employee add <user> <pin> [display name]` after `login <admin-pin>` to add facility employees without editing data files.

## Kiosk computers

1. Put the same `security_system.lua` on each kiosk computer.
2. Copy `security_kiosk_config.example.lua` to `security_config.lua`.
3. Set `rednet.serverId` to the main server computer id, or leave it `nil` for broadcast discovery.
4. For autorun, copy `startup_kiosk.lua` to `startup.lua` on the kiosk computer.
5. To start manually, run:

```lua
security_system kiosk
```

Employees can sign in, edit personal notes, read/post to the facility feed, send direct messages, view the employee directory, and check facility status.

`startup_kiosk.lua` creates a kiosk config from `security_kiosk_config.example.lua` if `security_config.lua` does not exist, starts kiosk mode, and restarts it if it exits.

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
