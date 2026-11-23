-- Pure helpers for the Bilibili provider.
--
-- The embedded Lua 5.3 subset has no `%d/%s/...` classes, no capture groups and
-- no `#string`. Everything here scans bytes with string.find(..., true) and
-- string.sub, and uses string.len.
local M = {}

function M.text(value)
  if value == nil then return "" end
  local kind = type(value)
  if kind == "string" then return value end
  if kind == "number" then
    if math.floor(value) == value then return tostring(math.floor(value)) end
    return tostring(value)
  end
  if kind == "boolean" then return value and "true" or "false" end
  return ""
end

function M.number(value, fallback)
  local result = fallback
  if result == nil then result = 0 end
  local kind = type(value)
  if kind == "number" then return math.floor(value) end
  if kind ~= "string" then return result end
  local parsed = tonumber(value)
  if parsed == nil then return result end
  return math.floor(parsed)
end

-- `nil` when the value is not a number at all. M.number cannot express that:
-- its fallback defaults to 0, which would turn "endpoint did not report a
-- total" into "there are zero rows".
function M.opt_number(value)
  if value == nil then return nil end
  local kind = type(value)
  if kind == "number" then return math.floor(value) end
  if kind ~= "string" then return nil end
  local parsed = tonumber(value)
  if parsed == nil then return nil end
  return math.floor(parsed)
end

function M.list(value)
  if type(value) == "table" then return value end
  return {}
end

function M.field(value, ...)
  if type(value) ~= "table" then return nil end
  local count = select("#", ...)
  for index = 1, count do
    local key = select(index, ...)
    local item = value[key]
    if item ~= nil then return item end
  end
  return nil
end

function M.trim(value)
  local source = M.text(value)
  local first = 1
  local last = string.len(source)
  while first <= last and string.byte(source, first) <= 32 do first = first + 1 end
  while last >= first and string.byte(source, last) <= 32 do last = last - 1 end
  return string.sub(source, first, last)
end

-- `//i0.hdslb.com/x.jpg` and `http://...` -> `https://...`.
function M.https(value)
  if type(value) ~= "string" then return nil end
  local url = M.trim(value)
  if url == "" then return nil end
  if string.sub(url, 1, 2) == "//" then return "https:" .. url end
  if string.sub(url, 1, 7) == "http://" then return "https://" .. string.sub(url, 8) end
  return url
end

function M.image(value)
  return M.https(value)
end

-- Search titles embed `<em class="keyword">…</em>`. Strip everything between a
-- '<' and the next '>' with a plain-text scan; captures are unavailable.
--
-- Fast path: a title with no '<' and no '&' is returned as-is. The scan below
-- copies the string ONE BYTE AT A TIME into a table and then runs five
-- `M.replace` passes over the result, so a 60-byte upload title used to cost
-- ~150 interpreter instructions to produce a value identical to `M.trim`. That
-- is invisible on a 20-row page and fatal on the host's UP-artist call, which
-- asks for 100 rows at once (platform_catalog.dart:285-287): measured on the
-- real two-page /x/space/wbi/arc/search response (evidence/t11), the mapping
-- stage alone hit the 250k instruction budget at row 86-95 while two 50-row
-- pages decoded fine. With this path the same 100 rows map in one call
-- (evidence/t11/R2_breakdown.log). Semantics are unchanged: with no markup the
-- scan's output IS `source`, and with no '&' all five replacements are the
-- identity.
function M.clean_title(value)
  local source = M.text(value)
  if string.find(source, "<", 1, true) == nil and
     string.find(source, "&", 1, true) == nil then
    return M.trim(source)
  end
  local out = {}
  local index = 1
  local length = string.len(source)
  local skip = false
  while index <= length do
    local ch = string.sub(source, index, index)
    if skip then
      if ch == ">" then skip = false end
    elseif ch == "<" then
      skip = true
    else
      out[#out + 1] = ch
    end
    index = index + 1
  end
  local cleaned = table.concat(out)
  -- Decode the common entities BiliMusic's clean_html handles.
  cleaned = M.replace(cleaned, "&amp;", "&")
  cleaned = M.replace(cleaned, "&lt;", "<")
  cleaned = M.replace(cleaned, "&gt;", ">")
  cleaned = M.replace(cleaned, "&quot;", "\"")
  cleaned = M.replace(cleaned, "&#39;", "'")
  return M.trim(cleaned)
end

-- Plain substring replacement (host gsub third arg cannot be a function).
function M.replace(source, needle, replacement)
  local text = M.text(source)
  if needle == "" then return text end
  local out = {}
  local at = 1
  while at <= string.len(text) do
    local found = string.find(text, needle, at, true)
    if found == nil then
      out[#out + 1] = string.sub(text, at)
      break
    end
    out[#out + 1] = string.sub(text, at, found - 1)
    out[#out + 1] = replacement
    at = found + string.len(needle)
  end
  return table.concat(out)
end

-- Clip a title to at most `limit` DISPLAY COLUMNS, cutting on a UTF-8 boundary.
--
-- The host renders `albumName` with `maxLines: 1, overflow: ellipsis`
-- (player_controls_bar.dart:131, desktop_now_playing.dart:532), so it clips at
-- the END. A 60-column B站 upload title therefore ate the whole ` · N P`
-- suffix and the album row stopped saying how many parts the video has — which
-- is exactly the entry the suffix exists to advertise. Clipping here keeps the
-- suffix (it is appended AFTER this call) and spends the ellipsis on the title
-- instead.
--
-- Columns, not bytes: CJK titles are 3 bytes per glyph, and the limit is
-- carried in the unit the UI actually measures in. Wide glyphs (CJK, fullwidth
-- punctuation, most emoji) count 2 columns so a mixed title is clipped at
-- roughly the same pixel width as a latin one. The embedded runtime has no
-- `%`-classes and no `#`, so bytes are walked explicitly.
local ELLIPSIS = "…"

-- Wide-glyph test on a CODE POINT.
--
-- This runtime indexes strings by CHARACTER, not by byte: `string.len("【")` is
-- 1 and `string.byte("【")` is 12304 (measured, evidence/t13/CLIP_PROBE.log).
-- So the ranges below are the standard East Asian Wide ones in code-point
-- space, not UTF-8 lead bytes — an earlier draft compared lead bytes and
-- advanced the cursor by 4 for every CJK glyph, which skipped three characters
-- per step and clipped a 24-column label at 46 characters.
local function glyph_cols(source, index)
  local cp = string.byte(source, index)
  if cp == nil then return 1 end
  if cp < 4352 then return 1 end                      -- below U+1100: narrow
  if cp <= 4447 then return 2 end                     -- U+1100-115F hangul jamo
  if cp < 11904 then return 1 end                     -- U+1160-2E7F: narrow
  if cp <= 42191 then return 2 end                    -- U+2E80-A4CF CJK + kana + Yi
  if cp < 44032 then return 1 end                     -- U+A4D0-ABFF: narrow
  if cp <= 55203 then return 2 end                    -- U+AC00-D7A3 hangul syllables
  if cp < 63744 then return 1 end                     -- U+D7A4-F8FF: narrow
  if cp <= 64255 then return 2 end                    -- U+F900-FAFF CJK compat
  if cp < 65072 then return 1 end                     -- U+FB00-FE2F: narrow
  if cp <= 65135 then return 2 end                    -- U+FE30-FE6F CJK compat forms
  if cp < 65280 then return 1 end                     -- U+FE70-FEFF: narrow
  if cp <= 65376 then return 2 end                    -- U+FF00-FF60 fullwidth
  if cp < 65504 then return 1 end                     -- U+FF61-FFDF: narrow
  if cp <= 65510 then return 2 end                    -- U+FFE0-FFE6 fullwidth signs
  if cp < 127744 then return 1 end                    -- below U+1F300: narrow
  if cp <= 129791 then return 2 end                   -- U+1F300-1FAFF emoji
  return 1
end

-- Display columns of a whole string.
function M.columns(text)
  local source = M.text(text)
  local total = string.len(source)
  local width = 0
  local index = 1
  while index <= total do
    width = width + glyph_cols(source, index)
    index = index + 1
  end
  return width
end

-- `text` clipped to `limit` display columns, with a trailing ellipsis when it
-- was actually shortened. Returns `text` untouched when it already fits.
--
-- One `string.sub` per character: the runtime already slices by character, so
-- there is no multi-byte boundary to preserve and no cursor to advance by hand.
function M.clip(text, limit)
  local source = M.text(text)
  local max = M.number(limit, 0)
  if max <= 0 then return source end
  local total = string.len(source)
  local width = 0
  local index = 1
  while index <= total do
    local cols = glyph_cols(source, index)
    if width + cols > max then break end
    width = width + cols
    index = index + 1
  end
  if index > total then return source end
  local kept = M.trim(string.sub(source, 1, index - 1))
  if kept == "" then return ELLIPSIS end
  return kept .. ELLIPSIS
end

-- `base .. suffix` fitted into a SINGLE total column budget.
--
-- This is the one the album name uses. Clipping `base` to a fixed width and
-- then appending ` · N P` does not work: the host renders the whole string with
-- one `overflow: ellipsis`, so the budget has to cover the suffix too. The
-- suffix is measured first and the remaining columns go to the title, which is
-- what keeps ` · 100 P` on screen no matter how long the title is.
--
-- When the suffix alone already exceeds `budget`, the suffix wins and the title
-- is dropped entirely: knowing "this video has 100 parts" is the entire point of
-- the label, and a truncated ` · 10…` would be a wrong number.
function M.fit_label(base, suffix, budget)
  local tail = M.text(suffix)
  local max = M.number(budget, 0)
  local source = M.text(base)
  if max <= 0 then return source .. tail end
  local tail_width = M.columns(tail)
  local room = max - tail_width
  if room <= 0 then return M.trim(tail) end
  -- The ellipsis itself costs one column: `clip` fills `limit` columns and THEN
  -- appends "…", so handing it the whole `room` overruns the budget by exactly
  -- one column. Measured: `fit_label(long, " · 100 P", 32)` returned 33 columns
  -- before this subtraction (evidence/t13/FIT_LABEL_PROBE.log). One column past
  -- the budget is the difference between the host keeping the suffix and
  -- ellipsing it away, which is the entire defect this function exists for.
  if room < 2 then return M.trim(tail) end
  local clipped = M.clip(source, room - 1)
  return clipped .. tail
end

-- Search results carry "4:19"; view carries seconds (213); long videos carry
-- "1:02:03". Accumulate segment by segment (BiliMusic bilibili.rs:1917-1922):
-- the old code split on the FIRST colon only, so `tonumber("02:03")` was nil,
-- the seconds fell back to 0 and 1:02:03 became 60 000 ms instead of 3 723 000.
-- An illegal segment counts as 0 (same semantics as `unwrap_or(0)`), and
-- anything past 24 h is clamped so the client progress bar cannot overflow.
local DAY_MS = 86400000

function M.parse_duration(value)
  if type(value) == "number" then
    local ms = math.floor(value * 1000)
    if ms > DAY_MS then ms = DAY_MS end
    return ms
  end
  if type(value) ~= "string" then return 0 end
  local text = M.trim(value)
  if text == "" then return 0 end
  local total = 0
  local start = 1
  while true do
    local colon = string.find(text, ":", start, true)
    local part
    if colon == nil then
      part = string.sub(text, start)
    else
      part = string.sub(text, start, colon - 1)
    end
    local piece = tonumber(M.trim(part))
    if piece == nil or piece < 0 then piece = 0 end
    total = total * 60 + piece
    if colon == nil then break end
    start = colon + 1
  end
  local ms = math.floor(total * 1000)
  if ms > DAY_MS then ms = DAY_MS end
  return ms
end

function M.map_rows(values, mapper)
  local out = {}
  local source = M.list(values)
  for index = 1, #source do
    local mapped = mapper(source[index])
    if mapped ~= nil then out[#out + 1] = mapped end
  end
  return out
end

function M.split_lines(value)
  local out = {}
  local source = M.text(value)
  local start = 1
  local length = string.len(source)
  for index = 1, length do
    local byte = string.byte(source, index)
    if byte == 10 or byte == 13 then
      local line = string.sub(source, start, index - 1)
      if line ~= "" then out[#out + 1] = line end
      start = index + 1
    end
  end
  if start <= length then
    local line = string.sub(source, start)
    if line ~= "" then out[#out + 1] = line end
  end
  return out
end

local function strip_header_name(line)
  local trimmed = M.trim(line)
  if string.lower(string.sub(trimmed, 1, 11)) == "set-cookie:" then
    return string.sub(trimmed, 12)
  end
  if string.lower(string.sub(trimmed, 1, 7)) == "cookie:" then
    return string.sub(trimmed, 8)
  end
  return trimmed
end

function M.cookie_header(value)
  local raw = M.text(value)
  if raw == "" then return "" end
  local lines = M.split_lines(raw)
  for index = 1, #lines do lines[index] = strip_header_name(lines[index]) end
  local compact = host.cookie_compact(table.concat(lines, "; "))
  if compact == nil then return "" end
  return compact
end

return M
