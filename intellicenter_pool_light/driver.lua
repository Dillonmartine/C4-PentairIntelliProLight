--[[
  IntelliCenter Pool Light - Control4 DriverWorks driver
  ------------------------------------------------------------------
  Drives one Pentair IntelliBrite light circuit on an IntelliCenter
  controller over the controller's LOCAL protocol: newline-terminated
  JSON over TCP, port 6681. No cloud, no account.

  What Control4 sees:
    * a light_v2 light that is ON/OFF only. IntelliBrite has no dimming,
      so the dimmer is not declared, and there is no colour wheel - the
      IntelliBrite cannot take an arbitrary colour, only its fixed set.
    * a Lighting Extras section, "Pool Light Colors", holding the eleven
      IntelliBrite colours and shows. Picking one turns the light on in
      that colour.
    * programming commands Set Pool Light Color / Next Pool Light Color,
      events, and a POOL_LIGHT_COLOR variable.

  Protocol (same as the Python script this was ported from):
    request   {"messageID":..,"command":"GetParamList",
               "condition":"OBJTYP=CIRCUIT",
               "objectList":[{"objnam":"INCR","keys":[...]}]}
    set       {"messageID":..,"command":"SetParamList",
               "objectList":[{"objnam":"C0003",
                              "params":{"STATUS":"ON","ACT":"CARIB"}}]}
    subscribe {"messageID":..,"command":"RequestParamList",
               "objectList":[{"objnam":"C0003","keys":[...]}]}
  A reply echoes the messageID and carries "response":"200" on success.
  The controller also pushes unsolicited NotifyList messages when
  something changes - from its own schedule, the Pentair app, or a
  panel - and the driver applies those to the UI as they arrive.

  Lua 5.1 / LuaJIT compatible. No external module dependencies.
--]]

DRIVER_VERSION = "1.0.0"
LOG_PREFIX     = "IntelliCenter: "

NET_BINDING    = 6001
LIGHT_BINDING  = 5001
DEFAULT_PORT   = 6681

REQUEST_TIMEOUT_S  = 15      -- a request unanswered this long is failed
RECONNECT_MS       = 30000   -- retry the TCP connection this often
POST_SET_POLL_MS   = 2000    -- re-read state this long after a change
RX_MAX_BYTES       = 2097152 -- discard a runaway receive buffer

-- IntelliBrite colours and shows, in the order Pentair lists them.
-- code = the value written to the circuit's ACT attribute; the controller
-- reports the active one back in USE.
COLORS = {
  { name = "Party",             code = "PARTY"   },
  { name = "Romance",           code = "ROMAN"   },
  { name = "Caribbean",         code = "CARIB"   },
  { name = "American",          code = "AMERCA"  },
  { name = "California Sunset", code = "SSET"    },
  { name = "Royal",             code = "ROYAL"   },
  { name = "Blue",              code = "BLUER"   },
  { name = "Green",             code = "GREENR"  },
  { name = "Red",               code = "REDR"    },
  { name = "White",             code = "WHITER"  },
  { name = "Magenta",           code = "MAGNTAR" },
}

-- IntelliBrite circuits report SUBTYP "INTELLI". If a controller has
-- none, these other colour subtypes are offered instead, with a warning.
INTELLIBRITE_SUBTYPE = "INTELLI"
OTHER_COLOR_SUBTYPES = {
  MAGIC2 = true, GLOW = true, GLOWT = true, SAM = true, SAL = true, COLORW = true,
}

STATE_KEYS = { "OBJTYP", "SUBTYP", "SNAME", "STATUS", "USE" }

PersistData = PersistData or {}


-- ==================================================================
-- Logging
-- ==================================================================

function DbgMode()
  if Properties == nil then return "Off" end
  return Properties["Debug Mode"] or "Off"
end

function Dbg(msg)
  local mode = DbgMode()
  if mode == "Off" then return end
  local line = LOG_PREFIX .. tostring(msg)
  print(line)
  if mode == "Print and Log" then
    pcall(function() C4:ErrorLog(line) end)
  end
end

function Say(msg)
  -- user-facing: always printed to the Lua output window
  print(LOG_PREFIX .. tostring(msg))
end

function SetResult(msg)
  pcall(function() C4:UpdateProperty("Last Result", tostring(msg)) end)
  Say(msg)
end

function SetProp(name, value)
  pcall(function() C4:UpdateProperty(name, tostring(value)) end)
end

function Trim(s)
  s = tostring(s or "")
  return (string.gsub(s, "^%s*(.-)%s*$", "%1"))
end


-- ==================================================================
-- Minimal JSON codec (decode + encode), unchanged from the Govee driver
-- ==================================================================

JSON = {}

local function jsonSkipWs(s, i)
  local n = #s
  while i <= n do
    local c = string.sub(s, i, i)
    if c == " " or c == "\t" or c == "\n" or c == "\r" then
      i = i + 1
    else
      break
    end
  end
  return i
end

local function jsonUtf8(cp)
  if cp < 0x80 then
    return string.char(cp)
  elseif cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
  else
    local b1 = 0xE0 + math.floor(cp / 0x1000)
    local b2 = 0x80 + (math.floor(cp / 0x40) % 0x40)
    local b3 = 0x80 + (cp % 0x40)
    return string.char(b1, b2, b3)
  end
end

local jsonValue

local function jsonString(s, i)
  -- s[i] is the opening quote
  local out = {}
  i = i + 1
  local n = #s
  while i <= n do
    local c = string.sub(s, i, i)
    if c == '"' then
      return table.concat(out), i + 1
    elseif c == "\\" then
      local e = string.sub(s, i + 1, i + 1)
      if e == "n" then
        table.insert(out, "\n")
      elseif e == "t" then
        table.insert(out, "\t")
      elseif e == "r" then
        table.insert(out, "\r")
      elseif e == "b" then
        table.insert(out, "\b")
      elseif e == "f" then
        table.insert(out, "\f")
      elseif e == "u" then
        local hex = string.sub(s, i + 2, i + 5)
        local cp = tonumber(hex, 16)
        if cp == nil then
          table.insert(out, "?")
        else
          table.insert(out, jsonUtf8(cp))
        end
        i = i + 4
      else
        table.insert(out, e)
      end
      i = i + 2
    else
      table.insert(out, c)
      i = i + 1
    end
  end
  return nil, i, "unterminated string"
end

local function jsonNumber(s, i)
  local j = i
  local n = #s
  while j <= n do
    local c = string.sub(s, j, j)
    if string.find(c, "[%d%+%-%.eE]") then
      j = j + 1
    else
      break
    end
  end
  local num = tonumber(string.sub(s, i, j - 1))
  return num, j
end

local function jsonArray(s, i)
  local arr = {}
  i = jsonSkipWs(s, i + 1)
  if string.sub(s, i, i) == "]" then
    return arr, i + 1
  end
  while true do
    local v
    v, i = jsonValue(s, i)
    -- guard: table.insert(t, nil) is an error in some 5.1 builds, and a
    -- JSON null inside an array has no useful representation here anyway
    if v ~= nil then
      table.insert(arr, v)
    end
    i = jsonSkipWs(s, i)
    local c = string.sub(s, i, i)
    if c == "," then
      i = jsonSkipWs(s, i + 1)
    elseif c == "]" then
      return arr, i + 1
    else
      return arr, i, "expected , or ] in array"
    end
  end
end

local function jsonObject(s, i)
  local obj = {}
  i = jsonSkipWs(s, i + 1)
  if string.sub(s, i, i) == "}" then
    return obj, i + 1
  end
  while true do
    i = jsonSkipWs(s, i)
    if string.sub(s, i, i) ~= '"' then
      return obj, i, "expected key string"
    end
    local key
    key, i = jsonString(s, i)
    i = jsonSkipWs(s, i)
    if string.sub(s, i, i) ~= ":" then
      return obj, i, "expected :"
    end
    i = jsonSkipWs(s, i + 1)
    local v
    v, i = jsonValue(s, i)
    if key ~= nil then
      obj[key] = v
    end
    i = jsonSkipWs(s, i)
    local c = string.sub(s, i, i)
    if c == "," then
      i = i + 1
    elseif c == "}" then
      return obj, i + 1
    else
      return obj, i, "expected , or } in object"
    end
  end
end

jsonValue = function(s, i)
  i = jsonSkipWs(s, i)
  local c = string.sub(s, i, i)
  if c == "{" then
    return jsonObject(s, i)
  elseif c == "[" then
    return jsonArray(s, i)
  elseif c == '"' then
    return jsonString(s, i)
  elseif string.sub(s, i, i + 3) == "true" then
    return true, i + 4
  elseif string.sub(s, i, i + 4) == "false" then
    return false, i + 5
  elseif string.sub(s, i, i + 3) == "null" then
    return nil, i + 4
  else
    return jsonNumber(s, i)
  end
end

function JSON.decode(s)
  if type(s) ~= "string" or s == "" then
    return nil, "empty body"
  end
  local ok, v = pcall(function()
    local val = jsonValue(s, 1)
    return val
  end)
  if not ok then
    return nil, "json parse error: " .. tostring(v)
  end
  return v, nil
end

local function jsonEscape(str)
  str = string.gsub(str, "\\", "\\\\")
  str = string.gsub(str, '"', '\\"')
  str = string.gsub(str, "\n", "\\n")
  str = string.gsub(str, "\r", "\\r")
  str = string.gsub(str, "\t", "\\t")
  return str
end

function JSON.encode(v)
  local t = type(v)
  if v == nil then
    return "null"
  elseif t == "boolean" then
    if v then return "true" end
    return "false"
  elseif t == "number" then
    if v == math.floor(v) and math.abs(v) < 1e15 then
      return string.format("%d", v)
    end
    return tostring(v)
  elseif t == "string" then
    return '"' .. jsonEscape(v) .. '"'
  elseif t == "table" then
    if v[1] ~= nil or next(v) == nil then
      local parts = {}
      for idx = 1, #v do
        table.insert(parts, JSON.encode(v[idx]))
      end
      return "[" .. table.concat(parts, ",") .. "]"
    end
    local keys = {}
    for k, _ in pairs(v) do
      table.insert(keys, tostring(k))
    end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
      table.insert(parts, '"' .. jsonEscape(k) .. '":' .. JSON.encode(v[k]))
    end
    return "{" .. table.concat(parts, ",") .. "}"
  end
  return "null"
end


-- ==================================================================
-- Colour lookup
-- ==================================================================

function ColorByName(raw)
  local s = string.lower(Trim(raw))
  if s == "" then return nil end
  for _, c in ipairs(COLORS) do
    if string.lower(c.name) == s or string.lower(c.code) == s then
      return c
    end
  end
  -- tolerate the short name the Pentair app and older docs use
  if s == "sunset" then return ColorByName("California Sunset") end
  return nil
end

function ColorByCode(code)
  code = string.upper(Trim(code))
  for _, c in ipairs(COLORS) do
    if c.code == code then return c end
  end
  return nil
end

function ColorIndex(code)
  for i, c in ipairs(COLORS) do
    if c.code == code then return i end
  end
  return nil
end


-- ==================================================================
-- Timers
--
-- C4:SetTimer(ms, callback, repeat) is the convenient form; C4:AddTimer
-- plus the global OnTimerExpired is the older one. Same fallback as the
-- Govee driver: try the first, fall back to the second.
-- ==================================================================

gAddTimers = {}   -- AddTimer id -> { fn = , rep = }

function StartTimer(ms, repeating, fn)
  local h = {}
  local ok = pcall(function()
    h.obj = C4:SetTimer(ms, function() fn() end, repeating and true or false)
  end)
  if ok and h.obj ~= nil then
    h.kind = "set"
    return h
  end

  local secs = math.floor((ms + 999) / 1000)
  if secs < 1 then secs = 1 end
  local ok2 = pcall(function()
    h.id = C4:AddTimer(secs, "SECONDS", repeating and true or false)
  end)
  if ok2 and h.id ~= nil then
    h.kind = "add"
    gAddTimers[h.id] = { fn = fn, rep = repeating }
    return h
  end
  Dbg("no usable timer API")
  return nil
end

function StopTimer(h)
  if h == nil then return end
  if h.kind == "set" then
    pcall(function() h.obj:Cancel() end)
  elseif h.kind == "add" then
    gAddTimers[h.id] = nil
    pcall(function() C4:KillTimer(h.id) end)
  end
end

function OnTimerExpired(idTimer)
  local t = gAddTimers[idTimer]
  if t == nil then return end
  if not t.rep then gAddTimers[idTimer] = nil end
  t.fn()
end


-- ==================================================================
-- Receive framing
--
-- Each message is a single JSON object followed by CRLF. Rather than trust
-- the terminator, frames are cut on balanced braces outside strings, so a
-- reply split across TCP segments, two replies in one segment, or a
-- firmware that terminates with LF only are all handled the same way.
-- The scan is incremental: bytes already examined are not re-examined.
-- ==================================================================

gRx = nil

function RxReset()
  gRx = { buf = "", pos = 1, depth = 0, inStr = false, esc = false, start = nil }
end
RxReset()

function RxFeed(data)
  local r = gRx
  r.buf = r.buf .. (data or "")
  local buf = r.buf
  local n = #buf
  local i = r.pos
  local frames = {}

  while i <= n do
    local b = string.byte(buf, i)
    if r.depth == 0 then
      if b == 123 then          -- {
        r.depth = 1
        r.start = i
      end
      -- anything between frames (CR, LF, whitespace) is skipped
    elseif r.inStr then
      if r.esc then
        r.esc = false
      elseif b == 92 then       -- backslash
        r.esc = true
      elseif b == 34 then       -- "
        r.inStr = false
      end
    else
      if b == 34 then
        r.inStr = true
      elseif b == 123 then
        r.depth = r.depth + 1
      elseif b == 125 then      -- }
        r.depth = r.depth - 1
        if r.depth == 0 then
          table.insert(frames, string.sub(buf, r.start, i))
          r.start = nil
        end
      end
    end
    i = i + 1
  end

  if r.depth == 0 then
    r.buf, r.pos = "", 1
  else
    -- keep only the unfinished frame
    r.buf = string.sub(buf, r.start)
    r.pos = i - r.start + 1
    r.start = 1
    if #r.buf > RX_MAX_BYTES then
      Say("receive buffer overflow - discarding " .. tostring(#r.buf) .. " bytes")
      RxReset()
    end
  end
  return frames
end


-- ==================================================================
-- Connection
--
-- The TCP connection is the driver's network binding (id 6001). Set the
-- "IP Address" property, or bind the connection in Composer's Network
-- tab - either works. Director keeps the connection up (keep_connection)
-- and the reconnect timer below covers anything it does not.
-- ==================================================================

gOnline      = false
gNetIp       = nil      -- IP the binding was last created with
gPending     = {}       -- messageID -> { cb, command, sent }
gSeq         = 0
gReconnTimer = nil

function ConfiguredIp()
  return Trim(Properties and Properties["IP Address"] or "")
end

function ConfiguredPort()
  local p = tonumber(Properties and Properties["Port"] or "")
  if p == nil or p < 1 or p > 65535 then return DEFAULT_PORT end
  return p
end

function SetConnStatus(text)
  SetProp("Connection Status", text)
  Dbg("connection: " .. text)
end

function Connect(reason)
  local ip = ConfiguredIp()
  local port = ConfiguredPort()
  if ip ~= "" and ip ~= gNetIp then
    local ok = pcall(function() C4:CreateNetworkConnection(NET_BINDING, ip) end)
    Dbg("CreateNetworkConnection " .. ip .. " ok=" .. tostring(ok))
    if ok then gNetIp = ip end
  end
  if ip == "" and gNetIp == nil then
    SetConnStatus("Set the IP Address property (or bind the IntelliCenter " ..
                  "connection in Composer)")
  else
    SetConnStatus("Connecting to " .. (ip ~= "" and ip or "bound address") ..
                  ":" .. tostring(port) .. "...")
  end
  pcall(function() C4:NetConnect(NET_BINDING, port) end)
  Dbg("NetConnect (" .. tostring(reason or "") .. ")")
  StartReconnectTimer()
end

function Disconnect()
  pcall(function() C4:NetDisconnect(NET_BINDING, ConfiguredPort()) end)
end

function Reconnect(reason)
  Disconnect()
  OnNetOffline("reconnect: " .. tostring(reason or ""))
  Connect(reason)
end

function StartReconnectTimer()
  if gReconnTimer ~= nil then return end
  gReconnTimer = StartTimer(RECONNECT_MS, true, function()
    if not gOnline then Connect("retry") else SweepPending() end
  end)
end

function FailAllPending(why)
  local p = gPending
  gPending = {}
  for _, req in pairs(p) do
    pcall(function() req.cb(nil, why) end)
  end
end

function OnNetOnline()
  if gOnline then return end
  gOnline = true
  RxReset()
  SetConnStatus("Connected to " .. (gNetIp or ConfiguredIp()) .. ":" ..
                tostring(ConfiguredPort()))
  ReportOnline(true)
  pcall(function() C4:FireEvent("Connected") end)
  DiscoverLights(nil)
end

function OnNetOffline(why)
  local was = gOnline
  gOnline = false
  RxReset()
  FailAllPending("disconnected")
  if was then
    SetConnStatus("Disconnected" .. (why and (" (" .. why .. ")") or ""))
    pcall(function() C4:FireEvent("Disconnected") end)
  end
  ReportOnline(false)
end

function OnConnectionStatusChanged(idBinding, nPort, strStatus)
  if idBinding ~= NET_BINDING then return end
  Dbg("OnConnectionStatusChanged " .. tostring(nPort) .. " " .. tostring(strStatus))
  if strStatus == "ONLINE" then
    OnNetOnline()
  else
    OnNetOffline(tostring(strStatus))
  end
end

function ReceivedFromNetwork(idBinding, nPort, strData)
  if idBinding ~= NET_BINDING then return end
  -- data arriving at all proves the link is up, even if the status
  -- callback was missed
  if not gOnline then OnNetOnline() end
  for _, frame in ipairs(RxFeed(strData)) do
    local msg, err = JSON.decode(frame)
    if type(msg) == "table" then
      local ok, e = pcall(HandleMessage, msg)
      if not ok then Say("error handling message: " .. tostring(e)) end
    else
      Say("unparseable message (" .. tostring(err) .. "): " ..
          string.sub(frame, 1, 200))
    end
  end
end

function NewMessageId()
  gSeq = gSeq + 1
  return string.format("c4-%d-%04x", gSeq, math.random(0, 65535))
end

-- cb(msg) on success, cb(nil, err) on failure. Returns false if the
-- request could not be sent at all (cb has already been called).
function SendRequest(command, payload, cb)
  cb = cb or function() end
  if not gOnline then
    cb(nil, "not connected to IntelliCenter")
    return false
  end
  local msg = {}
  for k, v in pairs(payload or {}) do msg[k] = v end
  msg.command = command
  msg.messageID = NewMessageId()

  local line = JSON.encode(msg) .. "\r\n"
  gPending[msg.messageID] = { cb = cb, command = command, sent = os.time() }
  local ok, err = pcall(function()
    C4:SendToNetwork(NET_BINDING, ConfiguredPort(), line)
  end)
  if not ok then
    gPending[msg.messageID] = nil
    cb(nil, "send failed: " .. tostring(err))
    return false
  end
  Dbg(">> " .. line)
  return true
end

-- Requests that never get an answer mean the socket is up but the
-- controller is not talking (a half-open connection, a reboot). Fail them,
-- and reconnect, rather than leaving callers waiting forever.
function SweepPending()
  local now = os.time()
  local stale = {}
  for id, req in pairs(gPending) do
    if now - req.sent > REQUEST_TIMEOUT_S then table.insert(stale, id) end
  end
  if #stale == 0 then return end
  for _, id in ipairs(stale) do
    local req = gPending[id]
    gPending[id] = nil
    pcall(function() req.cb(nil, "timed out") end)
  end
  Say(tostring(#stale) .. " request(s) timed out - reconnecting")
  Reconnect("request timeout")
end

function HandleMessage(msg)
  Dbg("<< " .. tostring(msg.command) .. " id=" .. tostring(msg.messageID) ..
      " response=" .. tostring(msg.response))

  -- any objectList, whether a reply or a pushed NotifyList, updates state
  if type(msg.objectList) == "table" then
    MergeObjects(msg.objectList)
  end

  local id = msg.messageID
  if id ~= nil and gPending[id] ~= nil then
    local req = gPending[id]
    gPending[id] = nil
    local status = tostring(msg.response or "200")
    if status ~= "200" then
      req.cb(nil, req.command .. " failed: response " .. status ..
             (msg.description and (" " .. tostring(msg.description)) or ""))
    else
      req.cb(msg)
    end
  end
end


-- ==================================================================
-- Controller state
-- ==================================================================

gCircuits = {}   -- objnam -> { objnam, OBJTYP, SUBTYP, SNAME, STATUS, USE }
gLights   = {}   -- the circuits offered in the Light Circuit list
gLightsAreFallback = false
gSubscribed = nil   -- objnam the push subscription was made for

function MergeObjects(list)
  local touched = false
  local sel = SelectedObjnam()
  for _, o in ipairs(list) do
    if type(o) == "table" and o.objnam ~= nil and type(o.params) == "table" then
      local known = gCircuits[o.objnam]
      if known == nil and o.params.OBJTYP == "CIRCUIT" then
        known = { objnam = o.objnam }
        gCircuits[o.objnam] = known
      end
      if known ~= nil then
        for k, v in pairs(o.params) do known[k] = v end
        if o.objnam == sel then touched = true end
      end
    end
  end
  if touched then ApplyLightState() end
end

function DiscoverLights(fnAfter)
  SendRequest("GetParamList", {
    condition = "OBJTYP=CIRCUIT",
    objectList = { { objnam = "INCR", keys = STATE_KEYS } },
  }, function(msg, err)
    if msg == nil then
      SetResult("Discovery failed: " .. tostring(err))
      if fnAfter then fnAfter(false) end
      return
    end
    -- MergeObjects already filed every circuit; now pick the lights
    local intelli, other = {}, {}
    for _, c in pairs(gCircuits) do
      if c.SUBTYP == INTELLIBRITE_SUBTYPE then
        table.insert(intelli, c)
      elseif OTHER_COLOR_SUBTYPES[c.SUBTYP or ""] then
        table.insert(other, c)
      end
    end
    gLightsAreFallback = (#intelli == 0 and #other > 0)
    gLights = gLightsAreFallback and other or intelli
    table.sort(gLights, function(a, b) return a.objnam < b.objnam end)
    RefreshLightList()
    OnSelectionChanged("discovery")
    if fnAfter then fnAfter(true) end
  end)
end

function LightLabel(c)
  local nm = c.SNAME
  if nm == nil or nm == "" then nm = c.objnam end
  return nm .. "  [" .. c.objnam .. "]"
end

-- "Light Circuit" is a dropdown filled at runtime. "Light Circuit
-- Override" takes an objnam or a name, for a Director that cannot write
-- property lists. With neither set and exactly one IntelliBrite on the
-- controller, that one is used.
function SelectedObjnam()
  local function resolve(raw)
    local s = Trim(raw)
    if s == "" or string.find(s, "^%(") ~= nil then return nil end
    local inside = string.match(s, "%[([^%]]+)%]%s*$")
    if inside ~= nil then return Trim(inside) end
    local low = string.lower(s)
    for objnam, c in pairs(gCircuits) do
      if string.lower(objnam) == low or string.lower(c.SNAME or "") == low then
        return objnam
      end
    end
    -- not discovered yet: treat it as an objnam and let the controller judge
    if string.match(s, "^%u%d+$") then return s end
    return nil
  end

  local pick = resolve(Properties and Properties["Light Circuit"] or "")
  if pick ~= nil then return pick end
  pick = resolve(Properties and Properties["Light Circuit Override"] or "")
  if pick ~= nil then return pick end
  if #gLights == 1 then return gLights[1].objnam end
  return nil
end

function SelectedLight()
  local objnam = SelectedObjnam()
  if objnam == nil then return nil end
  return gCircuits[objnam] or { objnam = objnam }
end

function SelectedLabel()
  local c = SelectedLight()
  if c == nil then return "(no light selected)" end
  return LightLabel(c)
end


-- ==================================================================
-- Runtime-populated LIST property (same fallback chain as the Govee driver)
-- ==================================================================

gPropertyListForm = nil
gSuppressApply = false

function SetListItems(propName, items)
  local csv = table.concat(items, ",")
  local attempts = {
    { form = "table",   fn = function() C4:UpdatePropertyList(propName, items) end },
    { form = "csv",     fn = function() C4:UpdatePropertyList(propName, csv) end },
    { form = "setlist", fn = function() C4:SetPropertyList(propName, csv) end },
  }
  if gPropertyListForm ~= nil then
    for i, a in ipairs(attempts) do
      if a.form == gPropertyListForm and i > 1 then
        table.insert(attempts, 1, table.remove(attempts, i))
        break
      end
    end
  end
  for _, a in ipairs(attempts) do
    if pcall(a.fn) then
      gPropertyListForm = a.form
      Dbg("populated '" .. propName .. "' via " .. a.form)
      return true
    end
  end
  gPropertyListForm = "none"
  return false
end

function RefreshLightList()
  local items = {}
  for _, c in ipairs(gLights) do table.insert(items, LightLabel(c)) end
  if #items == 0 then items = { "(no IntelliBrite lights found)" } end

  gSuppressApply = true
  local ok = SetListItems("Light Circuit", items)
  gSuppressApply = false

  local msg
  if #gLights == 0 then
    msg = "No IntelliBrite lights found. Run List All Circuits to see what " ..
          "the controller reports."
  else
    msg = string.format("Found %d %s light(s): %s", #gLights,
      gLightsAreFallback and "colour (non-IntelliBrite)" or "IntelliBrite",
      table.concat(items, ", "))
    if gLightsAreFallback then
      msg = msg .. ". WARNING: none are IntelliBrite; the colour list is " ..
            "IntelliBrite's and may not all apply."
    end
  end
  if not ok then
    msg = msg .. " This Director cannot write property lists - type the " ..
          "objnam (e.g. C0003) into Light Circuit Override."
  end
  SetResult(msg)
end

function OnSelectionChanged(reason)
  local c = SelectedLight()
  if c == nil then
    if #gLights > 1 then
      SetResult("Several lights found - pick one in the Light Circuit dropdown.")
    end
    return
  end
  Dbg("selected " .. LightLabel(c) .. " (" .. tostring(reason) .. ")")
  Subscribe(c.objnam)
  PollNow()
  pcall(PushExtras)
end

-- Ask the controller to push changes to this circuit. The reply carries the
-- current values; later changes arrive as NotifyList. If a firmware refuses
-- the subscription, the poll timer still keeps the UI in step.
function Subscribe(objnam)
  if objnam == nil or gSubscribed == objnam then return end
  SendRequest("RequestParamList", {
    objectList = { { objnam = objnam, keys = STATE_KEYS } },
  }, function(msg, err)
    if msg ~= nil then
      gSubscribed = objnam
      Dbg("subscribed to " .. objnam)
    else
      Say("subscription to " .. objnam .. " failed (" .. tostring(err) ..
          ") - relying on polling")
    end
  end)
end


-- ==================================================================
-- Polling (also serves as the keepalive that detects a dead link)
-- ==================================================================

gPollTimer = nil

function PollIntervalMs()
  local v = Properties and Properties["Poll Interval"] or "1 minute"
  if v == "Off" then return nil end
  if v == "30 seconds" then return 30000 end
  if v == "5 minutes" then return 300000 end
  return 60000
end

function StartPollTimer()
  StopTimer(gPollTimer)
  gPollTimer = nil
  local ms = PollIntervalMs()
  if ms == nil then return end
  gPollTimer = StartTimer(ms, true, function()
    SweepPending()
    if gOnline then PollNow() end
  end)
end

function PollNow(fnAfter)
  local c = SelectedLight()
  if c == nil then
    if fnAfter then fnAfter(false, "no light selected") end
    return
  end
  SendRequest("GetParamList", {
    objectList = { { objnam = c.objnam, keys = STATE_KEYS } },
  }, function(msg, err)
    if msg == nil then
      Dbg("poll failed: " .. tostring(err))
      if fnAfter then fnAfter(false, err) end
      return
    end
    -- MergeObjects has applied the values; make sure the UI is current
    -- even if nothing changed (first poll after a restart)
    ApplyLightState(true)
    if fnAfter then fnAfter(true) end
  end)
end

function PollSoon()
  StartTimer(POST_SET_POLL_MS, false, function() PollNow() end)
end


-- ==================================================================
-- Reporting to the light proxy
-- ==================================================================

gOn  = nil   -- last on/off reported (nil = never reported)
gUse = nil   -- last USE code reported

function ReportOnline(online)
  local v = online and "true" or "false"
  pcall(function()
    C4:SendToProxy(LIGHT_BINDING, "ONLINE_CHANGED",
                   { STATE = v, ONLINE = v, state = v }, "NOTIFY")
  end)
end

-- light_v2 has no separate on/off notification: brightness is the state,
-- 0 meaning off. This light is on/off only, so it reports 100 or 0. Every
-- plausible parameter spelling is sent, exactly as the Govee driver does.
function SendLightLevel(level)
  local v = tostring(level)
  local b = tostring(LIGHT_BINDING)
  local t = {
    LIGHT_BRIGHTNESS_CURRENT = v, LIGHT_BRIGHTNESS_TARGET = v,
    LIGHT_BRIGHTNESS = v, BRIGHTNESS = v, LEVEL = v, CURRENT = v, TARGET = v,
    RATE = "0", LIGHT_BRIGHTNESS_RATE = "0",
    OUTPUT = b, BINDING_ID = b, OUTPUT_BINDING_ID = b,
  }
  pcall(function() C4:SendToProxy(LIGHT_BINDING, "LIGHT_BRIGHTNESS_CHANGING", t, "NOTIFY") end)
  pcall(function() C4:SendToProxy(LIGHT_BINDING, "LIGHT_BRIGHTNESS_CHANGED", t, "NOTIFY") end)
  pcall(function() C4:SendToProxy(LIGHT_BINDING, "LIGHT_LEVEL", t, "NOTIFY") end)
end

function CurrentColorName()
  local c = ColorByCode(gUse or "")
  if c ~= nil then return c.name end
  return nil
end

-- Push the selected circuit's state to the proxy, extras, properties,
-- variables and events. Only changes are announced unless force is set.
function ApplyLightState(force)
  local c = SelectedLight()
  if c == nil then return end

  local on = (string.upper(tostring(c.STATUS or "")) == "ON")
  if c.STATUS ~= nil and (force or on ~= gOn) then
    local changed = (gOn ~= nil and on ~= gOn)
    gOn = on
    SendLightLevel(on and 100 or 0)
    SetProp("Light Status", on and "On" or "Off")
    pcall(function() C4:SetVariable("POOL_LIGHT_ON", on and "1" or "0") end)
    if changed then
      pcall(function() C4:FireEvent(on and "Light On" or "Light Off") end)
    end
  end

  local use = c.USE
  if use ~= nil and (force or use ~= gUse) then
    local changed = (gUse ~= nil and use ~= gUse)
    gUse = use
    local name = CurrentColorName() or (use ~= "" and use or "Unknown")
    SetProp("Current Color", name)
    pcall(function() C4:SetVariable("POOL_LIGHT_COLOR", name) end)
    SendExtrasNotify("EXTRAS_STATE_CHANGED", BuildExtrasStateXml())
    if changed then pcall(function() C4:FireEvent("Color Changed") end) end
  end
end


-- ==================================================================
-- Commands to the controller
-- ==================================================================

function SetCircuit(params, label, fnAfter)
  local c = SelectedLight()
  if c == nil then
    SetResult(label .. ": no light selected. Pick one in Light Circuit.")
    if fnAfter then fnAfter(false) end
    return
  end
  SendRequest("SetParamList", {
    objectList = { { objnam = c.objnam, params = params } },
  }, function(msg, err)
    if msg == nil then
      SetResult(label .. " failed: " .. tostring(err))
      if fnAfter then fnAfter(false) end
      return
    end
    -- reflect it now; the controller's own NotifyList / the follow-up poll
    -- confirms it
    local merged = {}
    for k, v in pairs(params) do
      if k == "ACT" then merged.USE = v else merged[k] = v end
    end
    MergeObjects({ { objnam = c.objnam, params = merged } })
    SetResult(label .. " on " .. LightLabel(c))
    PollSoon()
    if fnAfter then fnAfter(true) end
  end)
end

function LightOn()
  local params = { STATUS = "ON" }
  local pref = ColorByName(Properties and Properties["Color On Power-Up"] or "")
  if pref ~= nil then params.ACT = pref.code end
  SetCircuit(params, pref and ("On, " .. pref.name) or "On")
end

function LightOff()
  SetCircuit({ STATUS = "OFF" }, "Off")
end

-- Turning the light on and choosing the effect are sent together: an
-- effect sent to a dark IntelliBrite is not shown.
function SetColor(raw, fnAfter)
  local col = ColorByName(raw)
  if col == nil then
    SetResult("Unknown colour '" .. tostring(raw) .. "'. Use one of: " ..
              ColorNamesCsv())
    if fnAfter then fnAfter(false) end
    return
  end
  SetCircuit({ STATUS = "ON", ACT = col.code }, "Colour " .. col.name, fnAfter)
end

function NextColor()
  local i = ColorIndex(gUse or "") or 0
  local nxt = COLORS[(i % #COLORS) + 1]
  SetColor(nxt.name)
end

function ColorNamesCsv()
  local t = {}
  for _, c in ipairs(COLORS) do table.insert(t, c.name) end
  return table.concat(t, ", ")
end


-- ==================================================================
-- Lighting Extras
--
-- Built exactly as in the Govee driver (see its README for the spec
-- notes): has_extras, objects inside a section, each object carrying its
-- own command attribute, list items as a <list> child, and the
-- <extras_state><extra><object/></extra></extras_state> state document.
-- The "Extras Section Style" property keeps the three section spellings.
-- ==================================================================

EXTRAS_LIST_ID   = "pool_color"
EXTRAS_SECTION   = "Pool Light Colors"
EXTRAS_CMD_COLOR = "PoolColorSelected"

function XmlEscape(str)
  str = tostring(str or "")
  str = string.gsub(str, "&", "&amp;")
  str = string.gsub(str, "<", "&lt;")
  str = string.gsub(str, ">", "&gt;")
  str = string.gsub(str, '"', "&quot;")
  str = string.gsub(str, "'", "&apos;")
  return str
end

function ExtrasSectionStyle()
  local v = tonumber(Trim(Properties and Properties["Extras Section Style"] or "1"))
  if v == nil or v < 1 or v > 3 then return 1 end
  return v
end

function SetExtrasCapability(on)
  return pcall(function() C4:SetCapability("has_extras", on and true or false) end)
end

function ExtrasColorObjectXml()
  local x = {}
  table.insert(x, string.format(
    '<object id="%s" type="list" command="%s" label="Color" ' ..
    'hidden="false" readonly="false" value="%s">',
    EXTRAS_LIST_ID, EXTRAS_CMD_COLOR, XmlEscape(CurrentColorName() or "")))
  table.insert(x, '<list maxSelections="1" minSelections="1">')
  for _, c in ipairs(COLORS) do
    local e = XmlEscape(c.name)
    table.insert(x, string.format(
      '<item id="%s" name="%s" value="%s" text="%s"/>', e, e, e, e))
  end
  table.insert(x, "</list>")
  table.insert(x, "</object>")
  return table.concat(x, "")
end

function BuildExtrasSetupXml()
  local objects = ExtrasColorObjectXml()
  local label = XmlEscape(EXTRAS_SECTION)
  local style = ExtrasSectionStyle()
  local xml
  if style == 2 then
    xml = '<extras_setup><extra><section label="' .. label .. '">' ..
          objects .. "</section></extra></extras_setup>"
  elseif style == 3 then
    xml = '<extras_setup><section label="' .. label .. '">' ..
          objects .. "</section></extras_setup>"
  else
    xml = '<extras_setup><extra label="' .. label .. '">' ..
          objects .. "</extra></extras_setup>"
  end
  return xml, style
end

function ExtrasStateXmlFor(value)
  return string.format(
    '<extras_state><extra><object id="%s" value="%s"/></extra></extras_state>',
    EXTRAS_LIST_ID, XmlEscape(value or ""))
end

function BuildExtrasStateXml()
  return ExtrasStateXmlFor(CurrentColorName() or "")
end

function SendExtrasNotify(notify, xml)
  return pcall(function()
    C4:SendToProxy(LIGHT_BINDING, notify, { XML = xml }, "NOTIFY")
  end)
end

function PushExtras()
  SetExtrasCapability(true)
  local setup, style = BuildExtrasSetupXml()
  local okSetup = SendExtrasNotify("EXTRAS_SETUP_CHANGED", setup)
  local okState = SendExtrasNotify("EXTRAS_STATE_CHANGED", BuildExtrasStateXml())
  Dbg("pushed extras: style " .. tostring(style) .. " setup=" ..
      tostring(okSetup) .. " state=" .. tostring(okState))
  return okSetup and okState, style
end

-- The UI waits up to 10 s for EXTRAS_STATE_CHANGED and reverts the
-- control otherwise, so the selection is acknowledged before the
-- controller is asked. If the controller then refuses, the state is sent
-- again with the colour actually showing, so the UI does not lie.
function HandleExtrasCommand(strCommand, tParams)
  local value = tostring(tParams.value or tParams.VALUE or "")
  Dbg("extras '" .. tostring(strCommand) .. "' value=" .. value)
  SendExtrasNotify("EXTRAS_STATE_CHANGED", ExtrasStateXmlFor(value))
  SetColor(value, function(ok)
    if not ok then
      SendExtrasNotify("EXTRAS_STATE_CHANGED", BuildExtrasStateXml())
    end
  end)
  return true
end


-- ==================================================================
-- Proxy handling: light_v2, on/off only
-- ==================================================================

function DumpParams(tParams)
  if type(tParams) ~= "table" then return tostring(tParams) end
  local keys = {}
  for k, _ in pairs(tParams) do table.insert(keys, tostring(k)) end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do table.insert(parts, k .. "=" .. tostring(tParams[k])) end
  return "{" .. table.concat(parts, ", ") .. "}"
end

function ReceivedFromProxy(idBinding, strCommand, tParams)
  tParams = tParams or {}
  Dbg("ReceivedFromProxy " .. tostring(strCommand) .. " " .. DumpParams(tParams))

  if strCommand == "ON" then
    LightOn()

  elseif strCommand == "OFF" then
    LightOff()

  elseif strCommand == "TOGGLE" then
    if gOn then LightOff() else LightOn() end

  elseif strCommand == "SET_LEVEL" or strCommand == "RAMP_TO_LEVEL" then
    -- not dimmable: scenes and keypads may still send a level, so any
    -- level above zero means on
    local level = tonumber(tParams.LEVEL or tParams.Level or tParams.level or
                           tParams.LIGHT_BRIGHTNESS_TARGET or 0) or 0
    if level > 0 then LightOn() else LightOff() end

  elseif strCommand == "BUTTON_ACTION" then
    -- BUTTON_ID 0 = top (on), 1 = bottom (off), 2 = toggle; ACTION 1 = press
    local action = tostring(tParams.ACTION or "")
    local button = tostring(tParams.BUTTON_ID or "")
    if action == "1" or action == "PRESS" then
      if button == "0" then LightOn()
      elseif button == "1" then LightOff()
      elseif button == "2" then ReceivedFromProxy(idBinding, "TOGGLE", {})
      end
    end

  elseif strCommand == "GET_CONNECTED_STATE" then
    ReportOnline(gOnline)
    if gOn ~= nil then SendLightLevel(gOn and 100 or 0) end

  elseif strCommand == EXTRAS_CMD_COLOR or
         (tParams.id ~= nil and tostring(tParams.id) == EXTRAS_LIST_ID) then
    HandleExtrasCommand(strCommand, tParams)

  elseif strCommand == "GET_EXTRAS_SETUP" then
    SetExtrasCapability(true)
    SendExtrasNotify("EXTRAS_SETUP_CHANGED", (BuildExtrasSetupXml()))

  elseif strCommand == "GET_EXTRAS_STATE" then
    SendExtrasNotify("EXTRAS_STATE_CHANGED", BuildExtrasStateXml())

  elseif strCommand == "SYNCHRONIZE" then
    ReportState()

  elseif strCommand == "SET_COLOR_TARGET" or strCommand == "SET_COLOR_STOP" then
    -- no colour wheel is declared, so these should never arrive
    Dbg("ignored " .. strCommand .. " - colours are in Lighting Extras")

  else
    Say("UNHANDLED proxy command '" .. tostring(strCommand) .. "' " ..
        DumpParams(tParams))
  end
end

function ReportState()
  ReportOnline(gOnline)
  if gOn ~= nil then SendLightLevel(gOn and 100 or 0) end
  PushExtras()
end


-- ==================================================================
-- Actions and programming commands
-- ==================================================================

function Param(tParams, ...)
  for _, k in ipairs({ ... }) do
    local v = tParams[k]
    if v ~= nil and tostring(v) ~= "" then return tostring(v) end
  end
  return ""
end

LUA_ACTION = {}

function LUA_ACTION.Reconnect(tParams)
  Reconnect("action")
  SetResult("Reconnecting...")
end

function LUA_ACTION.DiscoverLights(tParams)
  if not gOnline then
    SetResult("Not connected - check IP Address and Connection Status.")
    return
  end
  DiscoverLights(nil)
end

function LUA_ACTION.ListCircuits(tParams)
  local function list()
    local rows = {}
    for _, c in pairs(gCircuits) do table.insert(rows, c) end
    table.sort(rows, function(a, b) return a.objnam < b.objnam end)
    Say("---- circuits on the controller ----")
    for _, c in ipairs(rows) do
      local col = ColorByCode(c.USE or "")
      Say(string.format("%-8s %-22s %-8s %-4s %s", c.objnam, tostring(c.SNAME or ""),
          tostring(c.SUBTYP or ""), tostring(c.STATUS or ""),
          col and col.name or tostring(c.USE or "")))
    end
    SetResult("Listed " .. tostring(#rows) .. " circuit(s) in the Lua output window.")
  end
  if not gOnline then
    SetResult("Not connected - check IP Address and Connection Status.")
    return
  end
  DiscoverLights(function() list() end)
end

function LUA_ACTION.SetColor(tParams)
  SetColor(Param(tParams, "Color", "COLOR", "color"))
end

function LUA_ACTION.PollNow(tParams)
  PollNow(function(ok, err)
    if ok then
      SetResult(SelectedLabel() .. ": " .. tostring(Properties["Light Status"]) ..
                ", " .. tostring(Properties["Current Color"]))
    else
      SetResult("Poll failed: " .. tostring(err))
    end
  end)
end

function LUA_ACTION.PushExtras(tParams)
  local ok, style = PushExtras()
  SetResult("Pushed extras (section style " .. tostring(style) .. ", ok=" ..
            tostring(ok) .. "). Check the Extras tab on the light in Navigator.")
end

function LUA_ACTION.DumpExtras(tParams)
  local setup, style = BuildExtrasSetupXml()
  Say("---- EXTRAS_SETUP_CHANGED payload, section style " .. tostring(style) .. " ----")
  Say(setup)
  Say("---- EXTRAS_STATE_CHANGED payload ----")
  Say(BuildExtrasStateXml())
  SetResult("Dumped extras XML to the Lua output window.")
end

function LUA_ACTION.ReportState(tParams)
  ReportState()
  SetResult("Re-sent online state, on/off and extras to the light proxy.")
end

COMMANDS = {}
COMMANDS["SetPoolLightColor"]  = function(tParams) LUA_ACTION.SetColor(tParams) end
COMMANDS["NextPoolLightColor"] = function(tParams) NextColor() end
-- aliases in case a Composer build dispatches on the description
COMMANDS["Set Pool Light Color"]  = COMMANDS["SetPoolLightColor"]
COMMANDS["Next Pool Light Color"] = COMMANDS["NextPoolLightColor"]

function RunHandler(kind, label, fn, tParams)
  local ok, err = pcall(function() fn(tParams) end)
  if not ok then
    SetResult(kind .. " '" .. tostring(label) .. "' error: " .. tostring(err))
    pcall(function() C4:ErrorLog(LOG_PREFIX .. kind .. " error: " .. tostring(err)) end)
  end
end

function ExecuteCommand(strCommand, tParams)
  tParams = tParams or {}
  local pfn = COMMANDS[strCommand]
  if pfn ~= nil then
    RunHandler("Command", strCommand, pfn, tParams)
    return
  end
  local cmd = strCommand
  if cmd == "LUA_ACTION" then
    cmd = tParams["ACTION"] or tParams["Action"] or tParams["action"] or ""
  end
  local fn = LUA_ACTION[cmd]
  if fn ~= nil then
    RunHandler("Action", cmd, fn, tParams)
    return
  end
  Dbg("unhandled command: " .. tostring(cmd))
end


-- ==================================================================
-- Properties and lifecycle
-- ==================================================================

function OnPropertyChanged(strProperty)
  local value = Properties[strProperty]
  Dbg("property changed: " .. tostring(strProperty) .. " = " .. tostring(value))
  if gSuppressApply and strProperty ~= "Debug Mode" then return end

  if strProperty == "IP Address" or strProperty == "Port" then
    gSubscribed = nil
    Reconnect("address changed")

  elseif strProperty == "Light Circuit" or strProperty == "Light Circuit Override" then
    gSubscribed = nil
    gOn, gUse = nil, nil
    OnSelectionChanged("property")

  elseif strProperty == "Poll Interval" then
    StartPollTimer()

  elseif strProperty == "Extras Section Style" then
    pcall(PushExtras)

  elseif strProperty == "Debug Mode" then
    Say("Debug Mode = " .. tostring(value))
  end
end

function OnDriverInit()
  pcall(function() C4:AllowExecute(true) end)
  math.randomseed(os.time())
  SetProp("Driver Version", DRIVER_VERSION)
  pcall(function() C4:AddVariable("POOL_LIGHT_COLOR", "Unknown", "STRING", true, false) end)
  pcall(function() C4:AddVariable("POOL_LIGHT_ON", "0", "BOOL", true, false) end)
end

function OnDriverLateInit()
  SetExtrasCapability(true)
  ReportOnline(false)
  pcall(PushExtras)
  StartPollTimer()
  Connect("startup")
end

function OnDriverDestroyed()
  StopTimer(gPollTimer)
  StopTimer(gReconnTimer)
  Disconnect()
end
