-- RealEstateTracker.lua
-- MoneyMoney extension: values real estate as a portfolio position.
--
-- Method: purchase price, rolled forward with a regional, transaction-based
-- price index (repeat-sales logic):
--
--   value = purchase price × index(latest quarter) / index(purchase quarter)
--           × adjustment × (1 − depreciation)^years
--
-- Index data (GREIX, Destatis, Eurostat) is rebuilt quarterly by a GitHub
-- Action and served from the repository; see README.md.
--
-- Setup in MoneyMoney: Account → Add account → Other → "Immobilien (Preisindex)".
-- Username: one or more objects, separated by ";"
--   Name | PLZ | Typ | m² | Kaufpreis | Kaufdatum [| option=value ...]
--   e.g. Musterstraße 1 | 10115 | etw | 80 | 320000 | 2017-05
-- Password: anything (unused), or further objects in the same format.

WebBanking {
  version = 1.00,
  url = "https://github.com/MateSteinforth/moneymoney-realestate",
  services = { "Immobilien (Preisindex)" },
  description = "Marktwert von Immobilien: Kaufpreis fortgeschrieben mit regionalem Preisindex (GREIX, Destatis, Eurostat)"
}

local SERVICE = "Immobilien (Preisindex)"
local DATA_URL = "https://raw.githubusercontent.com/MateSteinforth/moneymoney-realestate/main/data/"

local TYPE_ALIASES = {
  etw = "etw", wohnung = "etw", eigentumswohnung = "etw", apartment = "etw", flat = "etw",
  efh = "efh", haus = "efh", house = "efh", einfamilienhaus = "efh", zfh = "efh", rh = "efh", dhh = "efh",
  mfh = "mfh", mehrfamilienhaus = "mfh"
}
local TYPE_LABELS = { etw = "Eigentumswohnung", efh = "Ein-/Zweifamilienhaus", mfh = "Mehrfamilienhaus" }
-- Eurostat uses EL for Greece.
local COUNTRY_ALIASES = { GR = "EL" }

local objects = nil

-- ---------------------------------------------------------------- parsing

local function trim(s)
  return (s or ""):match("^%s*(.-)%s*$")
end

local function split(s, sep)
  local out = {}
  for part in (s .. sep):gmatch("(.-)" .. sep) do
    out[#out + 1] = trim(part)
  end
  return out
end

-- "320000", "320.000", "320.000,00", "320,000", "320000 €", "1,2 Mio" → number
local function parseAmount(s)
  s = trim(s):lower():gsub("€", ""):gsub("eur", ""):gsub("%s", "")
  local factor = 1
  if s:match("mio%.?$") then
    factor, s = 1e6, s:gsub("mio%.?$", "")
  elseif s:match("k$") then
    factor, s = 1e3, s:gsub("k$", "")
  end
  if s:match("^%d+[,.]%d%d$") then
    s = s:gsub(",", ".") -- decimal cents
  else
    s = s:gsub("[.,](%d%d%d)", "%1") -- thousands separators
    s = s:gsub(",", ".")
  end
  local n = tonumber(s)
  return n and n * factor or nil
end

-- Returns year, quarter (nil quarter = whole year), month, day.
local function parseDate(s)
  s = trim(s):upper()
  local y, q = s:match("^(%d%d%d%d)%s*[-/ ]?%s*Q([1-4])$")
  if not y then q, y = s:match("^Q([1-4])%s*[-/ ]?%s*(%d%d%d%d)$") end
  if y then return tonumber(y), tonumber(q), (tonumber(q) - 1) * 3 + 2, 15 end

  local d, m
  y, m, d = s:match("^(%d%d%d%d)-(%d%d?)-(%d%d?)$")
  if not y then d, m, y = s:match("^(%d%d?)%.(%d%d?)%.(%d%d%d%d)$") end
  if not y then y, m = s:match("^(%d%d%d%d)-(%d%d?)$") end
  if not y then m, y = s:match("^(%d%d?)[./](%d%d%d%d)$") end
  if y then
    m = tonumber(m)
    if m < 1 or m > 12 then return nil end
    return tonumber(y), math.floor((m - 1) / 3) + 1, m, tonumber(d) or 15
  end

  y = s:match("^(%d%d%d%d)$")
  if y then return tonumber(y), nil, 7, 1 end
  return nil
end

local function parseObject(spec, n)
  local f = split(spec, "|")
  local function fail(msg)
    error(string.format("Objekt %d (%s): %s", n, f[1] ~= "" and f[1] or "?", msg), 0)
  end
  if #f < 6 then
    fail("erwartet 'Name | PLZ | Typ | m² | Kaufpreis | Kaufdatum', gefunden " .. #f .. " Felder")
  end

  local obj = { name = f[1], options = {} }
  if obj.name == "" then fail("Name fehlt") end

  -- Location: German PLZ, or ISO country code (optionally followed by a postcode).
  local loc = f[2]:upper()
  if loc:match("^%d%d%d%d%d$") then
    obj.country, obj.plz = "DE", loc
  elseif loc:match("^DE[%s%-]?%d%d%d%d%d$") then
    obj.country, obj.plz = "DE", loc:match("(%d%d%d%d%d)$")
  elseif loc:match("^%a%a") then
    obj.country = loc:sub(1, 2)
    obj.country = COUNTRY_ALIASES[obj.country] or obj.country
  else
    fail("PLZ '" .. f[2] .. "' ungültig (5-stellige PLZ oder Ländercode wie AT, ES)")
  end

  obj.type = TYPE_ALIASES[f[3]:lower()]
  if not obj.type then fail("Typ '" .. f[3] .. "' unbekannt (etw, efh oder mfh)") end

  if f[4] ~= "" then
    obj.sqm = parseAmount(f[4])
    if not obj.sqm or obj.sqm <= 0 then fail("Fläche '" .. f[4] .. "' ungültig") end
  end

  obj.price = parseAmount(f[5])
  if not obj.price or obj.price <= 0 then fail("Kaufpreis '" .. f[5] .. "' ungültig") end

  obj.year, obj.quarter, obj.month, obj.day = parseDate(f[6])
  if not obj.year then fail("Kaufdatum '" .. f[6] .. "' ungültig (z.B. 2017, 2017-Q2, 05/2017, 15.05.2017)") end

  for i = 7, #f do
    local k, v = f[i]:match("^(%w+)%s*=%s*(.+)$")
    if not k then fail("Option '" .. f[i] .. "' ungültig (Format: name=wert)") end
    obj.options[k:lower()] = trim(v)
  end
  local o = obj.options
  obj.depreciation = 0
  if o.afa then
    obj.depreciation = parseAmount(o.afa)
    if not obj.depreciation or obj.depreciation < 0 or obj.depreciation >= 100 then fail("afa ungültig (Prozent pro Jahr)") end
  end
  obj.adjust = 1
  if o.faktor then
    obj.adjust = tonumber((o.faktor:gsub(",", ".")))
    if not obj.adjust or obj.adjust <= 0 then fail("faktor ungültig (z.B. 1.05)") end
  end
  obj.currency = o.waehrung and o.waehrung:upper() or "EUR"
  return obj
end

local function parseConfig(text)
  local list = {}
  for spec in ((text or "") .. ";"):gmatch("([^;\n]*)[;\n]") do
    if trim(spec) ~= "" then
      list[#list + 1] = parseObject(spec, #list + 1)
    end
  end
  return list
end

-- ---------------------------------------------------------------- data

local function fetchJSON(connection, name)
  local content = connection:request("GET", DATA_URL .. name, nil, nil, { Accept = "application/json" })
  local ok, data = pcall(function() return JSON(content):dictionary() end)
  if not ok or type(data) ~= "table" then
    error("Indexdaten konnten nicht geladen werden: " .. name, 0)
  end
  return data
end

local function quarterIndex(label)
  local y, q = tostring(label):match("^(%d%d%d%d)%-Q([1-4])$")
  return y and tonumber(y) * 4 + tonumber(q) - 1 or nil
end

local function quarterLabel(qi)
  return string.format("%d-Q%d", math.floor(qi / 4), qi % 4 + 1)
end

local function resolveArea(obj, plzData)
  if obj.options.index then return obj.options.index end
  if obj.country ~= "DE" then return "eu-" .. obj.country end
  return plzData.plz[obj.plz] or plzData.prefix[obj.plz:sub(1, 3)] or "de"
end

local function seriesValue(s, qi)
  return s.v[qi - quarterIndex(s.start) + 1]
end

-- Index level at purchase: the quarter, or the mean of the year if no quarter was given.
local function purchaseLevel(s, obj)
  local first, last = quarterIndex(s.start), quarterIndex(s["end"])
  local quarters = {}
  if obj.quarter then
    quarters[1] = obj.year * 4 + obj.quarter - 1
  else
    for q = 0, 3 do quarters[#quarters + 1] = obj.year * 4 + q end
  end
  local sum, n = 0, 0
  for _, qi in ipairs(quarters) do
    local clamped = math.max(first, math.min(last, qi))
    sum, n = sum + seriesValue(s, clamped), n + 1
  end
  local note
  if quarters[1] < first then
    note = "Index erst ab " .. s.start
  end
  return sum / n, note
end

local function value(obj, indices, plzData)
  local area = resolveArea(obj, plzData)
  local s = indices.series[area .. ":" .. obj.type] or indices.series[area .. ":all"]
  if not s then
    error(string.format("%s: kein Index für '%s' (%s)", obj.name, area, TYPE_LABELS[obj.type]), 0)
  end

  local latest = quarterIndex(s["end"])
  local buyLevel, note = purchaseLevel(s, obj)
  local nowLevel = seriesValue(s, latest)
  local buyQi = obj.year * 4 + (obj.quarter or 2.5) - 1
  local years = math.max(0, (latest - buyQi) / 4)

  local total = obj.price * nowLevel / buyLevel * obj.adjust * (1 - obj.depreciation / 100) ^ years
  local areaInfo = indices.areas[area] or {}
  return {
    total = total,
    latest = s["end"],
    label = areaInfo.label or area,
    note = note
  }
end

local function timestamp(obj)
  if not (os and os.time) then return nil end
  local ok, t = pcall(os.time, { year = obj.year, month = obj.month, day = obj.day, hour = 12 })
  return ok and t or nil
end

-- ---------------------------------------------------------------- WebBanking interface

function SupportsBank(protocol, bankCode)
  return protocol == ProtocolWebBanking and bankCode == SERVICE
end

function InitializeSession(protocol, bankCode, username, username2, password, username3)
  local ok, result = pcall(function()
    local list = parseConfig(username)
    if password and password:find("|", 1, true) then
      for _, obj in ipairs(parseConfig(password)) do list[#list + 1] = obj end
    end
    return list
  end)
  if not ok then return result end
  if #result == 0 then
    return "Keine Objekte konfiguriert. Benutzername: 'Name | PLZ | Typ | m² | Kaufpreis | Kaufdatum'"
  end
  objects = result
  return nil
end

function ListAccounts(knownAccounts)
  return {
    {
      name = "Immobilien",
      accountNumber = "Immobilien",
      portfolio = true,
      currency = "EUR",
      type = AccountTypePortfolio
    }
  }
end

function RefreshAccount(account, since)
  local connection = Connection()
  local indices = fetchJSON(connection, "indices.json")
  local plzData = { plz = {}, prefix = {} }
  for _, obj in ipairs(objects) do
    if obj.country == "DE" and not obj.options.index then
      plzData = fetchJSON(connection, "de_plz.json")
      break
    end
  end

  local securities = {}
  for _, obj in ipairs(objects) do
    local v = value(obj, indices, plzData)
    local qty = obj.sqm or 1
    local market = v.label .. ", Stand " .. v.latest
    if v.note then market = market .. " (" .. v.note .. ")" end
    securities[#securities + 1] = {
      name = obj.name,
      securityNumber = obj.plz or obj.country,
      market = market,
      currency = obj.currency,
      quantity = qty,
      price = v.total / qty,
      purchasePrice = obj.price / qty,
      amount = v.total,
      tradeTimestamp = timestamp(obj)
    }
  end
  return { securities = securities }
end

function EndSession()
  objects = nil
end
