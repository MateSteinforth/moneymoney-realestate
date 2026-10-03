-- Minimal JSON decoder for the test harness (MoneyMoney provides JSON() natively).
local json = {}

local function skip(s, i)
  return s:find("[^%s]", i) or #s + 1
end

local decode

local function decodeString(s, i)
  local out, j = {}, i + 1
  while true do
    local c = s:sub(j, j)
    if c == '"' then return table.concat(out), j + 1 end
    if c == "\\" then
      local e = s:sub(j + 1, j + 1)
      local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
      if e == "u" then
        out[#out + 1] = utf8.char(tonumber(s:sub(j + 2, j + 5), 16))
        j = j + 6
      else
        out[#out + 1] = map[e] or e
        j = j + 2
      end
    else
      out[#out + 1] = c
      j = j + 1
    end
  end
end

function decode(s, i)
  i = skip(s, i)
  local c = s:sub(i, i)
  if c == "{" then
    local t = {}
    i = skip(s, i + 1)
    if s:sub(i, i) == "}" then return t, i + 1 end
    while true do
      local k
      k, i = decodeString(s, skip(s, i))
      i = skip(s, i) + 1 -- ':'
      t[k], i = decode(s, i)
      i = skip(s, i)
      local d = s:sub(i, i)
      i = i + 1
      if d == "}" then return t, i end
    end
  elseif c == "[" then
    local t = {}
    i = skip(s, i + 1)
    if s:sub(i, i) == "]" then return t, i + 1 end
    while true do
      t[#t + 1], i = decode(s, i)
      i = skip(s, i)
      local d = s:sub(i, i)
      i = i + 1
      if d == "]" then return t, i end
    end
  elseif c == '"' then
    return decodeString(s, i)
  elseif s:sub(i, i + 3) == "true" then
    return true, i + 4
  elseif s:sub(i, i + 4) == "false" then
    return false, i + 5
  elseif s:sub(i, i + 3) == "null" then
    return nil, i + 4
  else
    local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
    return tonumber(num), i + #num
  end
end

function json.decode(s)
  return (decode(s, 1))
end

return json
