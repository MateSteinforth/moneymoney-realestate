-- Offline test harness: mocks the MoneyMoney API and runs the extension
-- against the local data/ files.  Run from the repository root:
--   lua tests/run.lua
-- Pass an object spec as argument to value your own objects locally
-- (nothing is written anywhere):
--   lua tests/run.lua "Name | 10115 | etw | 80 | 320000 | 2017-05"

package.path = "tests/?.lua;" .. package.path
local json = require("json")

ProtocolWebBanking = "WebBanking"
AccountTypePortfolio = "AccountTypePortfolio"
function WebBanking(t) end

local requested = {}
function Connection()
  return {
    request = function(_, method, url)
      requested[#requested + 1] = url
      local name = url:match("/data/([%w_]+%.json)$")
      local f = assert(io.open("data/" .. name, "r"), "missing data/" .. tostring(name))
      local content = f:read("a")
      f:close()
      return content, "UTF-8", "application/json"
    end
  }
end
function JSON(content)
  return { dictionary = function() return json.decode(content) end }
end

dofile("RealEstateTracker.lua")

local function run(username, password)
  requested = {}
  local err = InitializeSession(ProtocolWebBanking, "Immobilien (Preisindex)", username, nil, password or "x")
  if err then return nil, err end
  local accounts = ListAccounts({})
  local result = RefreshAccount(accounts[1], nil)
  EndSession()
  return result.securities
end

local function show(securities)
  for _, s in ipairs(securities) do
    print(string.format("  %-28s %12.0f €  (Kauf %12.0f €, %6.0f €/m²)  %s",
      s.name, s.amount, s.purchasePrice * s.quantity, s.price, s.market))
  end
end

if arg[1] then
  local secs, err = run(arg[1], arg[2])
  if not secs then print("Fehler: " .. err) os.exit(1) end
  show(secs)
  return
end

-- ---------------------------------------------------------------- tests (fictional objects)

local failures = 0
local function check(name, cond, msg)
  if cond then
    print("ok   " .. name)
  else
    failures = failures + 1
    print("FAIL " .. name .. (msg and (": " .. msg) or ""))
  end
end

assert(SupportsBank(ProtocolWebBanking, "Immobilien (Preisindex)"))
check("SupportsBank rejects others", not SupportsBank(ProtocolWebBanking, "Sparkasse"))

local secs, err = run(table.concat({
  "Beispielwohnung | 10115 | etw | 80 | 320.000 | 2017-05",
  "Beispielhaus | 49074 | haus | 140 | 280000 € | 2012",
  "Landhaus | 17033 | efh |  | 1,2 Mio | Q3/2020 | afa=1 | faktor=1,1",
  "Wien | AT | etw | 60 | 250000 | 15.03.2018",
  "Neu | 80331 | etw | 50 | 500000 | 2026-Q2",
}, "; "))
check("valid config parses", secs ~= nil, err)
if secs then
  show(secs)
  check("five securities", #secs == 5)
  local w, h, l, at, new = secs[1], secs[2], secs[3], secs[4], secs[5]
  check("Berlin uses GREIX Berlin", w.market:find("GREIX Berlin", 1, true) ~= nil, w.market)
  check("Osnabrück uses Destatis type", h.market:find("Destatis", 1, true) ~= nil, h.market)
  check("Austria uses Eurostat", at.market:find("Eurostat", 1, true) ~= nil, at.market)
  check("quantity is m²", w.quantity == 80 and math.abs(w.price * 80 - w.amount) < 0.01)
  check("no m² -> quantity 1", l.quantity == 1 and l.price == l.amount)
  check("purchasePrice per m²", w.purchasePrice == 4000)
  check("Berlin flat 2017 appreciated", w.amount > 320000 * 1.1 and w.amount < 320000 * 2.5, tostring(w.amount))
  check("bought in latest quarter = price", math.abs(new.amount - 500000) < 1, tostring(new.amount))
  check("trade timestamp set", type(w.tradeTimestamp) == "number")
  check("only data urls requested", #requested == 2 and requested[1]:find("raw.githubusercontent.com", 1, true) ~= nil)
end

-- afa/faktor are applied multiplicatively
local a = run("A | 17033 | efh | | 100000 | 2020-Q3")
local b = run("B | 17033 | efh | | 100000 | 2020-Q3 | faktor=1.1")
check("faktor scales value", a and b and math.abs(b[1].amount / a[1].amount - 1.1) < 1e-9)
local c = run("C | 17033 | efh | | 100000 | 2020-Q3 | afa=2")
check("afa reduces value", a and c and c[1].amount < a[1].amount)

-- Explicit index override
local o = run("O | 10115 | etw | 80 | 320000 | 2017 | index=de-kt4")
check("index override", o and o[1].market:find("Dünn besiedelte", 1, true) ~= nil, o and o[1].market)

-- Objects in the password field
local p = run("A | 10115 | etw | 80 | 320000 | 2017", "B | 20095 | etw | 50 | 200000 | 2015")
check("objects from password field", p and #p == 2)

-- Unknown PLZ falls back to prefix / national index
local u = run("U | 10999 | etw | 50 | 200000 | 2015")
check("PLZ fallback", u ~= nil)

-- Purchase before index start
local old = run("Alt | AT | etw | 50 | 100000 | 1999")
check("old purchase noted", old and old[1].market:find("Index erst ab", 1, true) ~= nil, old and old[1].market)

-- Validation errors
local bad = {
  { "", "Keine Objekte" },
  { "Nur | 10115", "erwartet" },
  { "X | 1011 | etw | 80 | 320000 | 2017", "PLZ" },
  { "X | 10115 | schloss | 80 | 320000 | 2017", "Typ" },
  { "X | 10115 | etw | 80 | viel | 2017", "Kaufpreis" },
  { "X | 10115 | etw | 80 | 320000 | gestern", "Kaufdatum" },
  { "X | 10115 | etw | 80 | 320000 | 13/2017", "Kaufdatum" },
  { "X | 10115 | etw | 80 | 320000 | 2017 | afa", "Option" },
}
for _, case in ipairs(bad) do
  local s, e = run(case[1])
  check("rejects '" .. case[1] .. "'", s == nil and e:find(case[2], 1, true) ~= nil, e)
end

print(failures == 0 and "\nall tests passed" or ("\n" .. failures .. " test(s) failed"))
os.exit(failures == 0 and 0 or 1)
