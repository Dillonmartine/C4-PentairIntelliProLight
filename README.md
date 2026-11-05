# IntelliCenter Pool Light — Control4 Driver

**File:** `intellicenter_pool_light.c4z` · **Version:** 1.0.0 · **Type:** DriverWorks, `light_v2` proxy

This driver controls a Pentair **IntelliBrite** pool or spa light from Control4. It uses the Pentair **IntelliCenter** controller's local protocol, which is JSON over TCP on port 6681, so there is no cloud service, account, or bridge.

- The light shows up in Control4 as a plain **on/off** light. It has no dimmer and no color wheel, because the IntelliBrite can't dim and can only show its fixed set of colors.
- The IntelliBrite colors and shows are in **Lighting Extras**. In Navigator, open the light's Extras tab and choose from the *Pool Light Colors* list. Picking a color turns the light on in that color.
- The driver stays in sync with changes made from the Pentair app, IntelliCenter schedules, or the wall panel.

---

## Supported colors

| Color / Show | IntelliCenter code |
|---|---|
| Party | `PARTY` |
| Romance | `ROMAN` |
| Caribbean | `CARIB` |
| American | `AMERCA` |
| California Sunset | `SSET` |
| Royal | `ROYAL` |
| Blue | `BLUER` |
| Green | `GREENR` |
| Red | `REDR` |
| White | `WHITER` |
| Magenta | `MAGNTAR` |

The driver doesn't support SAm mode or the Sync / Swim / Set / Hold / Recall functions.

---

## Requirements

- A Pentair IntelliCenter controller on the same network as the Control4 controller, with a static IP or DHCP reservation
- At least one circuit configured on the IntelliCenter as an IntelliBrite light (subtype `INTELLI`)
- Control4 Composer Pro

---

## Installation

1. **Add the driver.** In Composer Pro, choose *Driver → Add or Update Driver* and select `intellicenter_pool_light.c4z`.
2. **Add it to a room.** Search for *IntelliCenter Pool Light* and add it to the room where the light belongs.
3. **Point it at the controller.** Set the **IP Address** property to the IntelliCenter's IP. Leave **Port** at `6681`. You can instead bind the *IntelliCenter* connection under *Connections → Network*.
4. **Confirm the connection.** **Connection Status** should change to `Connected to <ip>:6681`. The driver then finds the IntelliBrite circuits on its own:
   - **If there is one IntelliBrite light**, the driver selects it automatically.
   - **If there are several**, pick one in the **Light Circuit** dropdown. Each IntelliBrite light you want to control needs its own copy of the driver.
5. **Try it.** Turn the light on and off from Navigator, then pick a color on the **Extras** tab.

---

## Properties

| Property | Description |
|---|---|
| **Driver Version** | Read-only. |
| **IP Address** | IntelliCenter IP address. |
| **Port** | Defaults to `6681`, the raw TCP JSON port. Port 6680 is the WebSocket variant, which this driver doesn't support. |
| **Connection Status** | Read-only connection state. |
| **Light Circuit** | Dropdown of IntelliBrite circuits, filled in at discovery, for example `Pool Light  [C0003]`. |
| **Light Circuit Override** | Optional. A circuit ID (`C0003`) or circuit name. It applies only while *Light Circuit* is still on its placeholder, which helps on Directors that can't fill in dropdown lists. |
| **Color On Power-Up** | `(keep last color)` by default, so the light comes back in its previous color. Choose a color to use it on every ON. |
| **Current Color** | Read-only. The color the controller reports. |
| **Light Status** | Read-only. `On` or `Off`. |
| **Poll Interval** | `Off`, `30 seconds`, `1 minute` (default), or `5 minutes`. A backup to the controller's push updates. Polling also detects a dead connection. |
| **Extras Section Style** | `1` (default), `2`, or `3`. Three ways of formatting the Extras section. Change this only if the Extras tab doesn't appear (see Troubleshooting). |
| **Debug Mode** | `Off`, `Print`, or `Print and Log`. *Print* writes every message sent and received to the Lua output window. |
| **Last Result** | Read-only. The result of the most recent command, or the reason it failed. |

---

## Using the light

**From Navigator, keypads, and scenes**
- **On / Off / Toggle** switch the light. If *Color On Power-Up* is set to a color, **On** uses that color.
- If a scene or keypad sends a brightness level, any level above 0 turns the light on and 0 turns it off.
- The three button links (On, Toggle, Off) can be bound to keypad buttons.

**From the Extras tab**
- Picking a color sends *on + color* to the controller as a single command, since IntelliBrite only shows a color while it's on.
- The selection updates right away. If the controller rejects the change, the list goes back to the color the light is actually showing, and **Last Result** shows the reason.

---

## Programming

**Commands**
- **Set Pool Light Color** (choose a color)
- **Next Pool Light Color** (cycles through the list in order and wraps back to Party; works well on a keypad button)

**Events**
- Connected · Disconnected · Light On · Light Off · Color Changed

**Variables**
- `POOL_LIGHT_COLOR` (string): the current color name
- `POOL_LIGHT_ON` (boolean): on or off

---

## Actions (Composer → Actions tab)

| Action | What it does |
|---|---|
| **Reconnect** | Drops the connection and reconnects. |
| **Discover Lights** | Scans the controller again and refreshes the *Light Circuit* list. |
| **List All Circuits** | Prints every circuit on the controller (ID, name, subtype, state) to the Lua output window. |
| **Set Color** | Sets a color directly, for testing. |
| **Poll Now** | Reads the light's state immediately. |
| **Push Lighting Extras** | Sends the Extras setup to the UI again. |
| **Dump Extras XML** | Prints the Extras XML to the Lua output window. |
| **Report State To UI** | Sends the online status, on/off state, and Extras to the light proxy again. |

---

## How it stays in sync

- **Push updates.** After discovery, the driver subscribes to the selected circuit. The IntelliCenter then reports each change as it happens, including changes made outside Control4.
- **Polling.** The light is also read on the *Poll Interval* schedule, and again 2 seconds after every command to confirm it took effect.
- **Connection monitoring.** If a request gets no reply within 15 seconds, the driver assumes the connection is dead and reconnects. This covers cases like an IntelliCenter reboot. While disconnected, it retries every 30 seconds and Navigator shows the light as offline.

---

## Troubleshooting

| Symptom | What to check |
|---|---|
| **Connection Status never shows Connected** | Check the IP address, and that the Control4 controller can reach TCP port 6681 on the IntelliCenter (VLANs and firewalls). Then run **Reconnect**. |
| **"No IntelliBrite lights found"** | Run **List All Circuits** and look at the subtype column. The light circuit must be set up as an IntelliBrite (`INTELLI`) on the IntelliCenter. If it's another color light type, the driver uses it anyway with a warning, but some colors may not work. |
| **Light Circuit dropdown stays empty** | Some Directors can't fill in dropdown lists. Type the circuit ID (for example `C0003`, from **List All Circuits**) into **Light Circuit Override**. |
| **No Extras tab in Navigator** | Set **Extras Section Style** to `2` and run **Push Lighting Extras**, then reopen the light in Navigator. If it still doesn't appear, try `3`. |
| **Color in Control4 doesn't match the pool** | Run **Poll Now**. If they still differ, set **Debug Mode** to `Print` and check the Lua output for errors or rejected commands. |
| **Anything else** | Set **Debug Mode** to `Print`, repeat the action, and check **Last Result** and the Lua output window. |

---

## Security note

The IntelliCenter local protocol has **no authentication and no encryption**. Anything on the network that can reach port 6681 can control all of the pool equipment, not only the light: pumps, heaters, and chemistry included. Put the IntelliCenter on a network segment that only the Control4 controller and other systems that truly need it can reach.

---

## Testing status

- **Tested on hardware:** installed and working on a Control4 controller with a live Pentair IntelliCenter and IntelliBrite light.
- **Automated tests:** the driver logic also ran in a Lua 5.1 interpreter against a mocked Control4 API and a simulated IntelliCenter, and 43 checks passed. They covered discovery, push updates, on/off/toggle, Extras selection and rollback, both programming commands, split and combined network messages, timeout and reconnect, and the multi-light setup.
- If something doesn't work on a new install, set **Debug Mode** to `Print` and check the Lua output window.

---
