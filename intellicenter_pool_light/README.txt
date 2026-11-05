IntelliCenter Pool Light - Control4 DriverWorks driver
======================================================
Version 1.0.0

WHAT IT IS
  A light_v2 driver for one Pentair IntelliBrite light circuit on an
  IntelliCenter controller. It talks to the controller directly over the
  local network (JSON over TCP, port 6681). There is no cloud and no account.
  It is a port of intellicenter_light.py, built on the Govee Scene Light
  driver's structure.

    * The light is ON/OFF only. IntelliBrite cannot dim, so no dimmer is
      declared. There is no colour wheel either, because the IntelliBrite
      cannot show an arbitrary colour.
    * Colours live in Lighting Extras: an Extras tab on the light in
      Navigator, with a "Pool Light Colors" section listing the IntelliBrite
      colours and shows. Picking one turns the light on in that colour.

INTELLIBRITE COLOURS  (name -> IntelliCenter ACT/USE code)
  Party PARTY, Romance ROMAN, Caribbean CARIB, American AMERCA,
  California Sunset SSET, Royal ROYAL, Blue BLUER, Green GREENR,
  Red REDR, White WHITER, Magenta MAGNTAR

  Not included: SAm mode and the Sync/Swim/Set/Hold/Recall functions.
  IntelliCenter's codes for those are not documented in the sources this
  driver was built from.

INSTALL
  1. Composer Pro -> Driver -> Add or Update Driver -> intellicenter_pool_light.c4z
  2. Add "IntelliCenter Pool Light" to a room.
  3. Set the IP Address property to the IntelliCenter's address. Give the
     controller a DHCP reservation so the address does not change.
     Alternatively, bind the "IntelliCenter" connection in Composer's
     Connections -> Network tab.
  4. Connection Status should read "Connected to ...". The driver discovers
     the IntelliBrite circuits on its own.
       One IntelliBrite light    It is used automatically.
       Several                   Pick one in the Light Circuit dropdown.
                                 Add one driver per light.
  5. Open the light in Navigator and use the Extras tab to pick a colour.

PROPERTIES
  IP Address / Port        Controller address. Port defaults to 6681, the raw
                           TCP JSON port. 6680 is the WebSocket variant and
                           does NOT work with this driver.
  Connection Status        Read-only.
  Light Circuit            Dropdown filled at discovery. Entries look like
                           "Pool Light  [C0003]".
  Light Circuit Override   Free text: an objnam (C0003) or a circuit name. It
                           is used only while the dropdown is on its
                           placeholder, for Directors that cannot write
                           property lists.
  Color On Power-Up        "(keep last color)" by default, so the
                           IntelliBrite comes back in its last colour. Pick a
                           colour to force that colour on every ON.
  Current Color            Read-only. Also the POOL_LIGHT_COLOR variable.
  Light Status             Read-only On/Off. Also the POOL_LIGHT_ON variable.
  Poll Interval            Off, 30 s, 1 min (default), or 5 min. See STATE.
  Extras Section Style     1/2/3. Same meaning as in the Govee driver. If 1
                           shows no Extras tab, try 2, then 3, and run
                           "Push Lighting Extras" after each.
  Debug Mode               Off / Print / Print and Log. Print shows every
                           message in both directions.

STATE / STAYING IN SYNC
  After discovery the driver subscribes to the selected circuit with
  RequestParamList. The controller then pushes a NotifyList whenever the
  light changes, whether from its own schedule, the Pentair app, or the wall
  panel, and the UI follows immediately.

  The poll timer also re-reads the circuit (GetParamList) as a backstop for
  firmware that does not push. It doubles as a keepalive: a request that
  goes unanswered for 15 s is failed and the socket is reconnected, which
  catches a half-open connection after a controller reboot. While
  disconnected, the driver retries every 30 s and the light shows as
  disconnected in Navigator.

  After every change the driver re-reads the light 2 s later to confirm it.

  Turning the light on and choosing a colour are sent in one SetParamList
  ({"STATUS":"ON","ACT":"CARIB"}), because an effect sent to a dark
  IntelliBrite is not shown.

EXTRAS BEHAVIOUR
  The UI reverts an Extras control if it gets no acknowledgement within
  10 s, so the selection is acknowledged at once. If the controller then
  rejects the change, the Extras list is set back to the colour that is
  actually showing, and Last Result says why.

PROXY COMMANDS
  ON, OFF, TOGGLE        STATUS ON/OFF. ON also applies Color On Power-Up
                         if it is set.
  SET_LEVEL / RAMP       Any level above 0 means on; 0 means off. Scenes
                         and keypads may still send levels.
  BUTTON_ACTION          Press on button 0 = on, 1 = off, 2 = toggle.
  GET_EXTRAS_SETUP / GET_EXTRAS_STATE / SYNCHRONIZE / GET_CONNECTED_STATE
  The three BUTTON_LINK connections are optional keypad inputs.

PROGRAMMING
  Commands  Set Pool Light Color (pick a colour)
            Next Pool Light Color (cycles; handy on a keypad button)
  Events    Connected, Disconnected, Light On, Light Off, Color Changed
  Variables POOL_LIGHT_COLOR (string), POOL_LIGHT_ON (bool)

ACTIONS
  Reconnect, Discover Lights, List All Circuits (prints every circuit with
  its subtype to the Lua output), Set Color, Poll Now, Push Lighting Extras,
  Dump Extras XML, Report State To UI.

SECURITY NOTE
  The IntelliCenter local protocol has no authentication and no encryption.
  Anything that can reach port 6681 can control the equipment, not only the
  light: pumps, heaters, and chemistry. Put the controller on a segment
  only the Control4 controller (and whatever else genuinely needs it) can
  reach.

TESTING STATUS
  Verified: driver.lua was run in a real Lua 5.1 interpreter against a
  mocked C4 API and a simulated IntelliCenter that answers GetParamList,
  RequestParamList and SetParamList and pushes NotifyList. 43 checks pass,
  covering:
    - discovery and IntelliBrite filtering
    - subscription
    - extras acknowledgement, and revert on rejection
    - on/off/toggle/level/keypad
    - Color On Power-Up
    - both programming commands, including Next wrapping round
    - replies split across TCP segments, several replies in one segment,
      LF-only terminators, and braces inside strings
    - request timeout leading to a reconnect
    - the two-light selection flow
  driver.xml was cross-checked against driver.lua: every action and
  command has a handler, every property and event the Lua uses is
  declared, and the colour lists agree.

  Not verified: loading in a real Director, and behaviour against real
  IntelliCenter firmware. The Extras section spelling remains the same open
  question it was in the Govee driver. Run with Debug Mode = Print the
  first time.
