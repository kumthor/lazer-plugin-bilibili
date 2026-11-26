-- Catalog operations: search, song, playlists/favorites, discovery, comments.
--
-- Paging is owned by bili.pager: the host computes `hasMore` from the number of
-- rows it receives (`list.length >= limit`), so every op must return exactly
-- min(limit, remaining). Two paging families exist and they are not
-- interchangeable:
--
--   * Remote pages that can be SHORTER than ps (favourite folders: measured
--     ps=40 -> 38 rows, ps=20 -> 19). Page boundaries come from the observed
--     length of every page already fetched — never from `floor(offset/cap)+1`.
--   * Remote pages that are exact position slices (comments: measured 20 rows
--     on pn=1/2/3/4/5/10/20/33/66 with no overlap). Those pass
--     `strict_seek = true` so a deep offset jumps to its page instead of
--     walking there: one request per page would burn the whole per-call request
--     budget (bili/pager.lua PLAINTEXT_BUDGET) before the window is reached.
local http = require("bili.http")
local wbi = require("bili.wbi")
local util = require("bili.util")
local store = require("bili.store")
local models = require("bili.models")
local auth = require("bili.auth")
local stream = require("bili.stream")
local lyrics = require("bili.lyrics")
local pager = require("bili.pager")
local ids = require("bili.ids")
local errors = require("bili.errors")

local M = {}

-- Login, logout and re-login change what every cursor is allowed to serve.
store.on_reset(function() pager.reset() end)

local function data_of(body)
  if type(body) ~= "table" or type(body.data) ~= "table" then return {} end
  return body.data
end

local function max_number(a, b)
  local left = util.number(a, 0)
  local right = util.number(b, 0)
  if left > right then return left end
  return right
end

-- Rows -> song models, dropping entries that carry no playable id. A row
-- without a bvid used to surface as `id=""`, which the host renders as a blank
-- track that can never resolve.
--
-- `opts.leaveAlbumBlank` exists for ONE reason (S1 / T14): rows that carry no
-- `videos` (search and favourites) must not bake a title into `albumName`,
-- because the host's queue merge keeps that value forever
-- (`music_platform_state.dart:635`) and `song()` can then never upgrade it to
-- the part-aware name. Leaving it empty lets `hydrate()` fill it in when the
-- user actually plays the row, which is the only place they need the count.
--
-- Rows that DO carry `videos` (popular / ranking / related / space_arc) keep
-- writing the name immediately: they have a real N, and the list is where that
-- number is worth showing.
local function song_rows(rows, opts)
  local leave_blank = type(opts) == "table" and opts.leaveAlbumBlank == true
  local out = {}
  local source = util.list(rows)
  for index = 1, #source do
    local item = source[index]
    if type(item) == "table" then
      local bvid = util.text(util.field(item, "bvid", "bv_id"))
      if bvid ~= "" then
        local cid = util.text(util.field(item, "cid"))
        local song = models.song(item, {
          id = ids.of(bvid, cid),
          leaveAlbumBlank = leave_blank,
        })
        -- 历史遗留：`models.song` 已经用同一个 bvid 设过 albumId，这里是幂等
        -- 重赋值。保留是因为删它只会扩大 diff，没有收益；**不要**把它读成
        -- "albumId 在这里有第二套规则"。
        song.albumId = bvid
        out[#out + 1] = song
      end
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Search and detail
-- ---------------------------------------------------------------------------

-- Hard ceiling on search rows per call, and the remote page size — the two are
-- the SAME number on purpose.
--
-- The host runs the whole `search` op under a 250k-instruction budget
-- (lua_plugin_runtime_io.dart:1096). What the budget actually pays for is
-- DECODED ROWS, not `limit`: both buckets (video + UP) are walked inside one
-- invocation, and each one decodes a whole remote page even when the caller
-- asked for fewer. Measured offline with wire-shaped rows:
--
--   40 rows per bucket (80 total) -> answers
--   50 rows per bucket (100 total) -> 408, at any `limit`, including limit=1
--   (evidence/t8/R17_search_decode_cliff.log)
--
-- That is why the old `cap = 50` was the real defect behind T8/D3: a limit the
-- caller could never receive, because the page it had to decode first was
-- already fatal. Setting cap == ceiling means one page per bucket, 35 rows each,
-- 70 decoded rows — under the measured 80-row boundary with margin.
--
-- Live, both buckets populated, the same op answers limit=40 and 408s at 45
-- (evidence/t8/R13_search_live_fine.log, R14_search_live_swing.log), so 35 also
-- keeps a margin under the live edge rather than sitting on it.
--
-- The response is clamped instead of failing: the host derives `hasMore` from
-- `rows.length >= limit` (lua_music_gateway.dart:197), so 35 honest rows read as
-- "more to come" at limit=35, while a 408 replaces the whole search page with an
-- error card. Fewer rows beats no rows.
local SEARCH_ROW_CEILING = 35
-- One page per bucket at the ceiling: see above.
local SEARCH_PAGE_SIZE = SEARCH_ROW_CEILING

function M.search(query, limit, offset)
  local keyword = util.text(query)
  if keyword == "" then return { songs = {}, albums = {}, artists = {}, playlists = {} } end
  local asked = util.number(limit, 30)
  if asked < 1 then asked = 30 end
  local want = asked
  local clamped = false
  if want > SEARCH_ROW_CEILING then
    want = SEARCH_ROW_CEILING
    clamped = true
  end
  local skip = util.number(offset, 0)
  if skip < 0 then skip = 0 end
  local cap = SEARCH_PAGE_SIZE
  local hops = pager.hops(skip, want, cap)

  -- One cursor per bucket: video and UP rows come from the same endpoint with a
  -- different search_type, and their totals differ.
  --
  -- SIGNED family: /x/web-interface/wbi/search/type is wbi-signed, so it shares
  -- the 12-request ceiling with space/arc rather than the plaintext 32
  -- (evidence/t7/R2_artist_budget.log).
  local songs = pager.walk("search:video:" .. keyword, function(pn)
    local body = wbi.get("/x/web-interface/wbi/search/type", {
      search_type = "video", keyword = keyword, page = pn, page_size = cap,
    })
    local data = data_of(body)
    return song_rows(data.result, { leaveAlbumBlank = true }),
           util.opt_number(data.numResults)
  end, want, skip, hops, nil, { cap = cap, budget = pager.SIGNED_BUDGET })

  local artists = pager.walk("search:user:" .. keyword, function(pn)
    local body = wbi.get("/x/web-interface/wbi/search/type", {
      search_type = "bili_user", keyword = keyword, page = pn, page_size = cap,
    })
    local data = data_of(body)
    return util.map_rows(util.list(data.result), models.artist_row),
           util.opt_number(data.numResults)
  end, want, skip, hops, nil, { cap = cap, budget = pager.SIGNED_BUDGET })

  -- albums / playlists 有意留空：B 站没有"歌手专辑"，番剧搜索不稳定
  -- （同一关键词两次结果 11 与 0），空桶比假桶诚实。
  --
  -- `truncated` tells the client the clamp happened. It is not read by 2.0.210's
  -- gateway, but a caller that sees fewer rows than it asked for can now tell
  -- "we hit the ceiling" from "the search ran out".
  return {
    songs = songs, albums = {}, artists = artists, playlists = {},
    truncated = clamped, limit = want, requestedLimit = asked,
  }
end

-- Song detail. `id` may be `bvid` or `bvid:cid`. The returned id MIRRORS the
-- request: a plain bvid keeps resolving to a plain bvid so the host's existing
-- cache entries (lyrics, play state) still hit; asking for a part keeps the part.
function M.song(id)
  local bvid, cid = ids.parse(id)
  local body = http.get("/x/web-interface/view", { bvid = bvid })
  local data = data_of(body)
  local pages = util.list(data.pages)
  local part = nil
  local part_index = 1
  for index = 1, #pages do
    if cid ~= "" and util.text(pages[index].cid) == cid then
      part = pages[index]
      part_index = index
      break
    end
  end
  -- An explicit part that does not exist is a 404, not a reason to answer with
  -- P1: the old fallback returned P1's title and duration under the requested
  -- cid, so the client showed one part's name for another part's audio. The
  -- check is local (the pages are already in hand), so no extra request.
  if cid ~= "" and part == nil then errors.throw("notfound") end
  if part == nil and #pages > 0 then part = pages[1] end

  local song = models.song(data, {
    id = ids.format(bvid, cid),
    -- 精确到某一 P 时标题与时长都取该 P 的：view 顶层的 duration 是整个合集，
    -- 用它会让 P2 的进度条按 25 分钟的合集长度走。
    title = part ~= nil and cid ~= "" and util.text(part.part) or "",
    durationMs = part ~= nil and cid ~= "" and
                 (util.number(part.duration, 0) * 1000) or nil,
    -- 专辑名要的 N 是"这支视频有几 P"，不是"当前这一 P"。`#pages` 已在手，
    -- 零请求；T13/D5 要求专辑页与列表页对同一支视频给出同一个专辑名。
    parts = #pages > 0 and #pages or nil,
  })
  song.extra = {
    cid = part ~= nil and util.text(part.cid) or "",
    parts = #pages,
    part = part_index,
    desc = util.text(data.desc),
  }
  return song
end

-- The video itself is the album: B站 has no separate album entity, and a
-- multi-part video is the closest thing to one.
function M.album(id)
  local bvid, cid = ids.parse(id)
  local body = http.get("/x/web-interface/view", { bvid = bvid })
  local data = data_of(body)
  local pages = util.list(data.pages)
  local owner = type(data.owner) == "table" and data.owner or {}
  return {
    id = bvid,
    title = util.clean_title(util.text(data.title)),
    coverUrl = util.image(util.field(data, "pic", "cover")),
    songCount = #pages,
    artists = { models.artist(owner.mid, owner.name) },
  }
end

-- Parts of a video as songs. `id` is the album id (plain bvid); each row is
-- identified by `bvid:cid` so playing P2 never resolves P1's audio.
--
-- `ALBUM_SONG_CEILING` bounds ROWS PER CALL, not the album. The host reads
-- `hasMore` from `rows.length >= limit` (lua_music_gateway.dart:200) and asks
-- again with `offset += rows.length`, so a full page is simply the next page
-- while a short one is a permanent dead end — a 30-row clamp on a 62-part
-- album made every part past the 30th unreachable
-- (evidence/t9/R20_album_host_hasmore_live.log).
--
-- The ceiling exists because the whole op runs under one instruction budget and
-- the cost is per ROW MAPPED, not per request: returning every part of a 62-part
-- video answered 408 and the album opened as an error card
-- (evidence/t8/R19_album_songs_cost.log). Hoisting the per-video work out of
-- the row loop moved that wall past 160 rows offline
-- (evidence/t9/R16_offline_cliff_hoist.log); 100 keeps a wide margin under it
-- and is exactly the page size the host already asks for.
local ALBUM_SONG_CEILING = 100

function M.album_songs(id, limit, offset)
  local bvid, _ = ids.parse(id)
  local body = http.get("/x/web-interface/view", { bvid = bvid })
  local data = data_of(body)
  local pages = util.list(data.pages)
  local want = util.number(limit, 100)
  if want < 1 then want = 100 end
  if want > ALBUM_SONG_CEILING then want = ALBUM_SONG_CEILING end
  local skip = util.number(offset, 0)
  if skip < 0 then skip = 0 end

  -- Filter BEFORE slicing. A part whose `cid` is empty cannot be played, so it
  -- is dropped from the row space — but the host advances `offset` by the number
  -- of rows it RECEIVED (music_models.dart:250). Slicing the raw `pages` and
  -- dropping rows afterwards would therefore both shorten the page (the host
  -- reads a short page as "no more") and shift the window by the number of
  -- dropped rows, repeating or skipping parts. One filtered list, one index
  -- space, both for `skip` and for `want`.
  local mappable = {}
  for index = 1, #pages do
    local page = pages[index]
    if type(page) == "table" and util.text(page.cid) ~= "" then
      mappable[#mappable + 1] = page
    end
  end
  local rows = pager.slice(mappable, want, skip)

  local owner = type(data.owner) == "table" and data.owner or {}
  -- Per-VIDEO work, hoisted out of the row loop: `clean_title`, `image` and
  -- `models.artist` each cost a full pass over the same inputs for every part,
  -- which is what put the 408 wall at 63 rows. Only the part-dependent title is
  -- still built per row.
  --
  -- 专辑名带 `· N P` 后缀，N 取 `#pages` 而**不是** `#mappable`：mappable 会
  -- 丢掉 cid 为空的 P（上面那段过滤），而 albumName 描述的是"这支视频有几 P"，
  -- 不是"这里能播几 P"。用 mappable 会在有坏 P 时说小总数。T13/D5 + 负向控制 N3。
  --
  -- 标题与后缀共用 `models.ALBUM_LABEL_COLUMNS` 列预算，后缀宽度先扣：宿主按
  -- **整串末尾**省略号截断（player_controls_bar.dart:131、desktop_now_playing.dart:532），
  -- 53 字的 B站标题会把 ` · N P` 整段吃掉。与 models.song 共用同一套口径，
  -- 两条路径出来的专辑名对同一支视频才逐字相同。
  --
  -- 没有 `pages` 时（`#pages == 0`）不裁：那时没有后缀要保护，裁了只会白白
  -- 丢掉标题的信息。
  --
  -- **后缀只给多 P 加**（`#pages > 1`），与 `models.song` 同一条规则：单 P 视频
  -- 没有 P 可选，` · 1 P` 只是让专辑列多一行字。
  local album_base = util.clean_title(util.text(data.title))
  if album_base == "" then album_base = "B站视频" end
  local album_name = album_base
  if #pages > 1 then
    album_name = util.fit_label(album_base,
                                " · " .. tostring(#pages) .. " P",
                                models.ALBUM_LABEL_COLUMNS)
  end
  local artists = { models.artist(owner.mid, owner.name) }
  local cover = util.image(util.field(data, "pic", "cover"))
  local multi = #mappable > 1
  local out = {}
  for index = 1, #rows do
    local page = rows[index]
    local cid = util.text(page.cid)
    local part = util.text(page.part)
    local title
    if part ~= "" and multi then
      title = util.clean_title("P" .. tostring(util.number(page.page, index + skip)) .. " " .. part)
    else
      -- 单 P 的标题是纯标题，不能跟着 albumName 带上 `· 1 P`：T13/D3 要求
      -- 标题与专辑名不同，否则列表里两列显示同一串字。
      title = album_base
    end
    out[#out + 1] = {
      id = ids.format(bvid, cid),
      title = title,
      artists = artists,
      albumId = bvid,
      albumName = album_name,
      coverUrl = cover,
      durationMs = util.parse_duration(page.duration),
      contentType = "video/mp4",
    }
  end
  return out
end

function M.stream(id, quality, cid)
  return stream.stream(id, quality, cid)
end

function M.lyrics(id)
  -- 宿主传进来的是 bvid. B站字幕主源直接用它走三步链路, 标题/时长在
  -- lyrics 模块内部由 view 接口顺带取, 这里不再把 id 换成标题.
  return lyrics.lyrics(id)
end

-- ---------------------------------------------------------------------------
-- Favorites / playlists
-- ---------------------------------------------------------------------------

local function current_mid()
  if store.mid == nil or store.mid <= 0 then auth.require_user() end
  return store.mid
end

local function folder_is_default(folder)
  local title = util.text(util.field(folder, "title", "name"))
  return string.find(title, "默认收藏夹", 1, true) ~= nil or
         util.number(util.field(folder, "media_id", "id"), 0) == 0
end

local function folder_id(folder)
  return util.text(util.field(folder, "media_id", "id"))
end

-- Cover backfill cache. list-all returns no cover at all, so each folder needs
-- one extra `ps=1` request. Without a cache that is N requests every time the
-- library panel opens; with a 6 h TTL it is N once per session.
local COVER_TTL_MS = 6 * 60 * 60 * 1000
local COVER_LIMIT = 100
-- Hard ceiling per call: a library with hundreds of folders must not turn one
-- UI open into hundreds of requests. Folders past the budget keep the folder's
-- own (empty) cover and get filled on the next open.
local COVER_BUDGET = 20
local covers = {}
local cover_order = {}

store.on_reset(function()
  covers = {}
  cover_order = {}
end)

local function cover_get(id)
  local entry = covers[id]
  if entry == nil then return nil end
  if host.now() - entry.at >= COVER_TTL_MS then
    covers[id] = nil
    return nil
  end
  return entry.value
end

local function cover_put(id, value)
  if covers[id] == nil then
    cover_order[#cover_order + 1] = id
    while #cover_order > COVER_LIMIT do
      local oldest = table.remove(cover_order, 1)
      covers[oldest] = nil
    end
  end
  -- A failed lookup is cached as an empty string so an empty or broken folder
  -- is not retried on every open; models.playlist treats "" as "no cover".
  covers[id] = { value = value or "", at = host.now() }
end

-- 收藏夹 list-all 不返回封面，用第一个视频的 cover 回填。
-- 改用免 412 风控的 resource/ids + resource/infos 接口
local function folder_cover(folder, budget)
  local id = folder_id(folder)
  if id == "" then return nil end
  local cached = cover_get(id)
  if cached ~= nil then return cached == "" and nil or cached end
  if budget.used >= COVER_BUDGET then
    budget.truncated = true
    return nil
  end
  budget.used = budget.used + 1
  local ok, body = pcall(http.get, "/x/v3/fav/resource/ids", { media_id = id })
  if not ok then return nil end
  local items = util.list(data_of(body))
  if #items == 0 then
    cover_put(id, nil)
    return nil
  end
  local first = items[1]
  local res_key = tostring(first.id) .. ":" .. tostring(first.type or 2)
  local ok_info, body_info = pcall(http.get, "/x/v3/fav/resource/infos", { resources = res_key })
  if not ok_info then return nil end
  local info_list = util.list(data_of(body_info))
  if #info_list == 0 then
    cover_put(id, nil)
    return nil
  end
  local url = util.image(util.field(info_list[1], "cover", "pic"))
  cover_put(id, url)
  return url
end

function M.playlists(limit, offset)
  if store.cookie() == "" then return {} end
  local mid = current_mid()
  -- 使用原生带 cover 封面的 /x/v3/fav/folder/created/list 接口，杜绝逐个请求与 COVER_BUDGET 截断
  local body = http.get("/x/v3/fav/folder/created/list", { up_mid = mid, pn = 1, ps = 100 })
  local data = data_of(body)
  local rows = util.list(data.list)
  local total_count = util.number(data.count, 0)
  if total_count > #rows and #rows > 0 then
    local page_count = math.ceil(total_count / 100)
    for p = 2, page_count do
      local p_body = http.get("/x/v3/fav/folder/created/list", { up_mid = mid, pn = p, ps = 100 })
      local p_rows = util.list(data_of(p_body).list)
      if #p_rows == 0 then break end
      for index = 1, #p_rows do
        rows[#rows + 1] = p_rows[index]
      end
    end
  end
  local page = pager.slice(rows, limit, offset)
  return util.map_rows(page, function(item)
    return models.playlist(item, folder_is_default(item), nil, mid)
  end)
end

-- Remote-paged listing (favourite folder / default folder / UP uploads).
--
-- `opts.budget` names the request family (see pager.lua). `opts.cap` is the
-- remote page size.
--
-- Truncation must be VISIBLE (task book §3.3). The host decides `hasMore` from
-- `rows.length >= limit`, so a walk that ran out of request budget and returned
-- a short page reads as "this is the end of the folder" — the user loses the
-- rest of a 2000-song folder with no error and no way to scroll further. T7/D5
-- was exactly that: offset=1200,limit=100 answered 80 rows with hasMore=false.
--
-- The chosen handling is "raise a retryable error, never a short page": the
-- plugin cannot sleep, so continuing to request only burns the rest of the
-- budget, and returning fewer rows is indistinguishable from a real end. A
-- transient error makes the client show "retry", which is the honest answer.
local function folder_page(key, load, limit, offset, cap, budget)
  local want = util.number(limit, 50)
  if want < 1 then want = 50 end
  local skip = util.number(offset, 0)
  if skip < 0 then skip = 0 end
  local hops = pager.hops(skip, want, cap)
  local rows, _, truncated = pager.walk(key, load, want, skip, hops, nil, {
    cap = cap, budget = budget,
  })
  -- 收藏夹行同样没有 `videos`（fav_resources.json 的 `_note`：0/19），处理
  -- 与 search 一致：专辑名留空，等播放时由 `song()` 补成「标题 · N P」。S1。
  local out = song_rows(rows, { leaveAlbumBlank = true })
  -- Only a truncated walk that did NOT fill the window is a lie. A truncated
  -- walk that still returned `want` rows is a complete page: the client has
  -- what it asked for and its own next call will page on.
  if truncated and #out < want then errors.throw("transient") end
  return out
end

-- ---------------------------------------------------------------------------
-- Charts
-- ---------------------------------------------------------------------------
--
-- A chart id has to be something `playlistSongs` can consume, because that is
-- exactly how the host reads a chart (catalog.dart providerCharts: charts()
-- then playlistSongs(chart.id) for each one, inside one Future.wait). The old
-- `rank:all` id went straight to /x/v3/fav/resource/list and came back 400, so
-- the whole Future.wait threw and no chart ever rendered.
--
--   charts()                 -> [{ id = "chart:0", ... }]
--   playlistSongs("chart:0") -> that chart's rows
--   playlistSongs("12345")   -> favourite folder (unchanged)
--
-- The rows are cached so opening the panel is one ranking request, not two:
-- charts() fills the cache and the immediately following playlistSongs reads
-- it back.
local CHART_TTL_MS = 6 * 60 * 60 * 1000
local CHART_LIMIT = 8
local CHART_RID = "0"
local chart_cache = {}
local chart_order = {}

store.on_reset(function()
  chart_cache = {}
  chart_order = {}
end)

local function chart_key(rid) return "chart:" .. rid end

local function chart_get(rid)
  local entry = chart_cache[chart_key(rid)]
  if entry == nil then return nil end
  if host.now() - entry.at >= CHART_TTL_MS then
    chart_cache[chart_key(rid)] = nil
    return nil
  end
  return entry.rows
end

local function chart_put(rid, rows)
  local key = chart_key(rid)
  if chart_cache[key] == nil then
    chart_order[#chart_order + 1] = key
    while #chart_order > CHART_LIMIT do
      local oldest = table.remove(chart_order, 1)
      chart_cache[oldest] = nil
    end
  end
  chart_cache[key] = { rows = rows, at = host.now() }
end

-- Raw ranking rows, cached BEFORE mapping.
--
-- T8/T03: the album shelf asks the chart for multi-part rows, and the mapped
-- `song` shape has no `videos` — `song_rows` projects only id/title/artist/
-- cover/duration, so `util.number(item.videos, 0)` was always 0 and the shelf
-- stayed empty on the live host (evidence/t8/G8_homefeed_cost_after.log:
-- `albums(18) {} newRequests=1`). Cache the wire rows and map per caller.
local function chart_raw(rid)
  local cached = chart_get(rid)
  if cached ~= nil then return cached end
  local body = http.get("/x/web-interface/ranking/v2", { rid = rid, type = "all" })
  local rows = util.list(data_of(body).list)
  chart_put(rid, rows)
  return rows
end

local function chart_rows(rid)
  return song_rows(chart_raw(rid))
end

-- `id` is a chart id (`chart:<rid>`) or a favourite folder's media_id.
local function is_chart(id)
  return string.sub(id, 1, 6) == "chart:"
end

local FAV_IDS_TTL_MS = 5 * 60 * 1000
local fav_ids_cache = {}
local fav_ids_order = {}

store.on_reset(function()
  fav_ids_cache = {}
  fav_ids_order = {}
end)

local function fav_ids_get(media_id)
  local entry = fav_ids_cache[media_id]
  if entry == nil then return nil end
  if host.now() - entry.at >= FAV_IDS_TTL_MS then
    fav_ids_cache[media_id] = nil
    return nil
  end
  return entry.ids
end

local function fav_ids_put(media_id, ids)
  if fav_ids_cache[media_id] == nil then
    fav_ids_order[#fav_ids_order + 1] = media_id
    while #fav_ids_order > 30 do
      local oldest = table.remove(fav_ids_order, 1)
      fav_ids_cache[oldest] = nil
    end
  end
  fav_ids_cache[media_id] = { ids = ids, at = host.now() }
end

local function get_fav_ids(media_id)
  local cached = fav_ids_get(media_id)
  if cached ~= nil then return cached end
  local body = http.get("/x/v3/fav/resource/ids", { media_id = media_id })
  local rows = util.list(data_of(body))
  fav_ids_put(media_id, rows)
  return rows
end

local function fav_page(media_id, limit, offset)
  local want = util.number(limit, 50)
  if want < 1 then want = 50 end
  local skip = util.number(offset, 0)
  if skip < 0 then skip = 0 end

  local all_items = get_fav_ids(media_id)
  local page = pager.slice(all_items, want, skip)
  if #page == 0 then return {} end

  local res_parts = {}
  for i = 1, #page do
    local it = page[i]
    if it.id then
      local t = it.type or 2
      res_parts[#res_parts + 1] = tostring(it.id) .. ":" .. tostring(t)
    end
  end
  if #res_parts == 0 then return {} end

  local res_str = table.concat(res_parts, ",")
  local body = http.get("/x/v3/fav/resource/infos", { resources = res_str })
  local info_rows = util.list(data_of(body))
  return song_rows(info_rows)
end

function M.playlist_songs(id, limit, offset)
  local media = util.text(id)
  if is_chart(media) then
    local rid = string.sub(media, 7)
    if rid == "" then errors.throw("param") end
    return pager.slice(chart_rows(rid), limit, offset)
  end
  return fav_page(media, limit, offset)
end

function M.favorites(limit, offset)
  if store.cookie() == "" then return {} end
  local mid = current_mid()
  local body = http.get("/x/v3/fav/folder/created/list-all", { up_mid = mid })
  local rows = util.list(data_of(body).list)
  local default_id = nil
  for index = 1, #rows do
    if folder_is_default(rows[index]) then
      default_id = folder_id(rows[index])
      break
    end
  end
  if default_id == nil or default_id == "" then return {} end
  return fav_page(default_id, limit, offset)
end

-- `id` is a song identity and MUST go through ids.parse. T7/D1: this op used a
-- bare `util.text(id)`, so every row coming from `charts` or
-- `homeFeed.featured` — which carry `bvid:cid` since v0.2.0 — was sent as
-- `view?bvid=BV…%3A43727326650` and answered 400. The whole chart was
-- un-favouritable while `addToPlaylist` on the same id worked, because only that
-- path parsed the identity. The cid is not needed here (fav/resource/deal takes
-- an aid), but the bvid must be extracted rather than passed through.
function M.set_favorite(id, favorite)
  auth.require_user()
  local bvid, _ = ids.parse(id)
  local view = http.get("/x/web-interface/view", { bvid = bvid })
  local aid = util.number(data_of(view).aid, 0)
  if aid <= 0 then error("Gateway code -400", 0) end
  local folders = http.get("/x/v3/fav/folder/created/list-all", { up_mid = store.mid })
  local rows = util.list(data_of(folders).list)
  local default_id = nil
  for index = 1, #rows do
    if folder_is_default(rows[index]) then
      default_id = folder_id(rows[index])
      break
    end
  end
  if default_id == nil or default_id == "" then error("Gateway code -400", 0) end
  local field = favorite and "add_media_ids" or "del_media_ids"
  http.post("/x/v3/fav/resource/deal", {
    rid = aid,
    type = 2,
    [field] = default_id,
    csrf = store.csrf(),
  })
  -- The folder listing and its contents both changed; stale cursors would keep
  -- serving the removed track.
  pager.reset("fav:" .. default_id)
  return true
end

-- ---------------------------------------------------------------------------
-- Playlist writes
-- ---------------------------------------------------------------------------
--
-- `writable:true` (models.playlist) and these two ops ship together on purpose.
-- Before T02 the picker listed one synthesised row ("我喜欢的音乐") and its
-- "新建" button hit a 501. Adding `writable` alone would have surfaced the real
-- folders and turned every one of them into a 501 on tap — from "one thing
-- works" to "three of four fail". Neither half is useful without the other.

-- One `view` per song to turn a bvid into the `aid` that fav/resource/deal
-- wants. Capped, not truncated: a caller that asks for 21 songs gets `param`
-- and no request is sent, because silently adding the first 20 would report
-- success for a write that did not happen.
local ADD_BUDGET = 20

local function aid_of(bvid)
  local view = http.get("/x/web-interface/view", { bvid = bvid })
  local aid = util.number(data_of(view).aid, 0)
  if aid <= 0 then error("Gateway code -400", 0) end
  return aid
end

function M.add_to_playlist(playlist, songs)
  auth.require_user()
  local media = util.text(playlist)
  if media == "" then errors.throw("param") end
  -- A chart is a read-only view of the ranking; it has no media_id to write to.
  if is_chart(media) then errors.throw("param") end
  local list = util.list(songs)
  local count = #list
  if count == 0 then errors.throw("param") end
  if count > ADD_BUDGET then errors.throw("param") end

  -- De-duplicated by bvid: the host sends one song today, but a repeated id
  -- would otherwise cost two view requests and produce the same aid twice.
  local seen = {}
  local aids = {}
  for index = 1, count do
    local bvid, _ = ids.parse(list[index])
    if seen[bvid] ~= true then
      seen[bvid] = true
      aids[#aids + 1] = aid_of(bvid)
    end
  end

  http.post("/x/v3/fav/resource/deal", {
    rid = table.concat(aids, ","),
    type = 2,
    add_media_ids = media,
    csrf = store.csrf(),
  })
  -- Never retried: http.post goes straight to perform with no retry flag, and
  -- a replay of this write would add the same item twice.
  --
  -- The write is asynchronous on Bili's side: measured 2026-11-21
  -- (evidence/t6/G12e_deal_delay.log), a song added to a folder created seconds
  -- earlier is invisible to fav/resource/list for ~1.5 s. Dropping the cursor
  -- is still correct — it makes the NEXT read fetch fresh rows — but a caller
  -- that reads immediately may see the pre-write list. That is Bili's
  -- consistency window, not a lost write: the row appears on the next open.
  pager.reset("fav:" .. media)
  return true
end

-- `/x/v3/fav/folder/add` probed live 2026-11-21 (evidence/t6/G12_folder_add.log):
-- form `title` + `privacy` (0 = public) + `csrf`, answer `{code:0, data:{id}}`
-- where `data.id` is the media_id `playlistSongs` consumes. The probe folder was
-- deleted again in the same run, so the account is back to its six folders.
--
-- Note on `success_num`: fav/resource/deal answers `code:0` with
-- `success_num:0` even when the write DID land (verified: a folder's
-- media_count went 13 -> 14 under that exact answer, G12c_deal_probe2.log). So
-- that field cannot be used to report success or failure, and neither can an
-- immediate read-back: the write is visible to fav/resource/list only after
-- ~1.5 s (G12e_deal_delay.log). The op reports what the API said, not a guess.
function M.create_playlist(name, is_public)
  auth.require_user()
  local title = util.trim(util.text(name))
  if title == "" then errors.throw("param") end
  local body = http.post("/x/v3/fav/folder/add", {
    title = title,
    privacy = is_public and 0 or 1,
    csrf = store.csrf(),
  })
  local data = data_of(body)
  local id = util.text(util.field(data, "id", "media_id"))
  if id == "" then errors.throw("transient") end
  -- The folder list changed, so the cached listing is stale.
  pager.reset()
  return models.playlist(data, false, nil, store.mid)
end

-- Risk-control codes the platform uses to refuse an anonymous UP lookup.
-- Measured 2026-11-21: four parameter sets (including the full `dm_img_*`
-- set), own mid and someone else's, all answered -403 没有权限访问.
local BLOCKED = { ["forbidden"] = true, ["ratelimit"] = true }

function M.artist_songs(id, limit, offset)
  local mid = util.text(id)
  -- SIGNED family: every call here is wbi-signed and may also refresh the salt,
  -- so its request ceiling is 12, not the plaintext 32 (evidence/t7/
  -- R2_artist_budget.log: 14 signed calls succeed, 17 pages is already a 408 and
  -- the VM is rebuilt). With the plaintext budget this op killed the host at
  -- offset=800 instead of answering — T7/D4.
  local ok, rows = pcall(folder_page, "arc:" .. mid, function(pn)
    local body = wbi.get("/x/space/wbi/arc/search", {
      mid = mid, ps = 50, pn = pn, order = "pubdate",
    })
    local data = data_of(body)
    local page = type(data.page) == "table" and data.page or {}
    return util.list((data.list or {}).vlist), util.opt_number(page.count)
  end, limit, offset, 50, pager.SIGNED_BUDGET)
  if ok then return rows end
  -- The host has no try around artistSongs (platform_catalog.dart:313), so one
  -- exception fails artistDetails as a whole and the page degrades to a single
  -- "load failed" card. A blocked endpoint is not a network fault: report an
  -- empty page so the artist page still renders its hero and "暂无热门歌曲".
  if BLOCKED[errors.kind_from(rows)] then return {} end
  -- A real network failure must NOT be swallowed into "this artist has no
  -- uploads" — that is the silent-empty bug this task exists to remove.
  error(rows, 0)
end

-- UP 主详情：宿主进「歌手」页先调 artist 拿名字/头像。B站 UP 不是歌手，
-- 用匿名可用的 /x/web-interface/card 即可，失败时回退到 id 占位，不抛错。
function M.artist(id, limit, offset)
  local mid = util.text(id)
  local ok, body = pcall(http.get, "/x/web-interface/card", { mid = mid })
  local card = {}
  if ok and type(body.data) == "table" and type(body.data.card) == "table" then
    card = body.data.card
  end
  return models.artist_detail(mid, card)
end

-- B站没有"歌手专辑"这一层，UP 投稿全部由 artistSongs 提供。返回空页让宿主
-- 的 artistAlbumPageFor 正常结束，避免 unsupported operation 冒泡成"资料加载失败"。
function M.artist_albums(id, limit, offset)
  return {}
end

-- ---------------------------------------------------------------------------
-- Multi-part videos as albums (T04, plan A)
-- ---------------------------------------------------------------------------
--
-- `album` / `albumSongs` were fully implemented but unreachable: the host only
-- enters an album from a row in `homeFeed.albums` or `albums()`, and neither
-- existed. Declaring `browseAlbums` without implementing `albums` is worse than
-- not declaring it — platform_catalog.dart:117 really calls albums() inside a
-- Future.wait, so a missing op empties the whole home page.
--
-- So both land together: homeFeed.albums is the MUSIC-zone rows among the
-- popular rows PLUS the music-zone chart, and albums() serves the same cached
-- list. "Music zone" is decided by `pid_v2` (see MUSIC_PID_V2 below); a shelf
-- that pulled in games and films was the bug this replaces.
--
-- T8/D5: the first version sent one `view` request per candidate to learn
-- whether it had several parts, so opening the home page always cost 8 probes
-- and the album list was still empty whenever those 8 happened to be single-P.
-- The popular/ranking rows already carry `videos` (the part count) — measured
-- 24/24 against `pages` in T7 — so the decision is free. `view` is now sent
-- only for rows that claim more than one part, and only to fill in the title,
-- cover and exact `songCount` that the feed row does not have. A single-part
-- row is complete without a request, which is what lets the shelf carry single-P
-- uploads at all.
local ALBUM_TTL_MS = 6 * 60 * 60 * 1000
local ALBUM_LIMIT = 16
-- The shelf is a MUSIC shelf, so a row has to prove it belongs to the music
-- zone. `pid_v2` is the criterion, not `tid`: the same `tid` appears in two
-- zones on the wire (evidence/t12/R2_popular_tname.log — tid=253 动漫杂谈 shows
-- up once as 二次元 and once as 音乐 via tidv2=2023 AI音乐). `pid_v2 = 0` is a
-- REAL value, not a missing field: 2 of 20 popular rows carry it
-- (evidence/t12/R5_popular_pid.log), so the test is `== MUSIC_PID_V2` and never
-- "the field exists".
local MUSIC_PID_V2 = 1003
-- The music zone's own chart. `CHART_RID` ("0") stays the all-site chart that
-- charts() and playlistSongs("chart:0") serve; this one is read only by the
-- album shelf, so the chart page keeps its row count and its order.
--
-- Note that rid=3 is not a music-only feed: 86/97 rows are music and the other
-- 11 are other zones (evidence/t12/R7_music_ranking_zones.log), which is why
-- the chart rows go through the same `pid_v2` filter as the popular rows.
local MUSIC_CHART_RID = "3"
-- One shelf cache slot, shared by both entry points. T10 changed the normal
-- source so that `homeFeed` and `albums()` ask for the same candidate set; two
-- slots would then just pay for the same list twice. A DEGRADED result is
-- never written here (see `album_rows`): a temporary chart failure must not be
-- frozen into a 6 h empty shelf.
local album_cache = {}
local popular_cache = nil

store.on_reset(function()
  album_cache = {}
  popular_cache = nil
end)

-- One popular response shared by homeFeed and the album probe. They used to
-- fetch it separately, so opening the home page cost two identical requests.
local function popular_rows()
  if popular_cache ~= nil and host.now() - popular_cache.at < ALBUM_TTL_MS then
    return popular_cache.rows
  end
  local body = http.get("/x/web-interface/popular", { ps = 20, pn = 1 })
  local rows = util.list(data_of(body).list)
  popular_cache = { rows = rows, at = host.now() }
  return rows
end

-- Row -> album, using the feed row itself as the source of truth.
--
-- `videos` is the part count on the wire. A row that claims ZERO parts is not a
-- video at all, so it is rejected; a row that claims ONE part is a real album of
-- one song and is kept. That is a deliberate change from "multi-part only": the
-- host enters an album from a shelf row and renders `songCount`, and a
-- single-part upload whose `songCount` is 1 is telling the truth, not using a
-- placeholder — `albumSongs` returns exactly one row for it (M.album_songs reads
-- `view.pages`). The old `videos > 1` gate existed only because the shelf could
-- not afford a `view` per row; now it does not need one (see `album_rows`).
--
-- `detail` is the optional `view` answer, fetched only for multi-part rows so
-- the album can carry the video's own title/cover instead of the feed's.
local function album_from(item, detail)
  local bvid = util.text(item.bvid)
  if bvid == "" then return nil end
  local videos = util.number(item.videos, 0)
  if videos < 1 then return nil end
  local data = type(detail) == "table" and data_of(detail) or nil
  local pages = data ~= nil and util.list(data.pages) or nil
  -- Feed rows and `view` both nest the uploader under `owner`; a search-style
  -- row puts it at the top level. Read both shapes rather than one.
  local feed_owner = type(item.owner) == "table" and item.owner or item
  local owner = models.artist(
    util.field(feed_owner, "mid", "uid"),
    util.field(feed_owner, "name", "author", "uname"))
  local count = videos
  if pages ~= nil and #pages > 0 then count = #pages end
  local title = util.text(item.title)
  local cover = util.field(item, "pic", "cover")
  if data ~= nil then
    local own = util.text(data.title)
    if own ~= "" then title = own end
    local own_cover = util.field(data, "pic", "cover")
    if own_cover ~= nil and own_cover ~= "" then cover = own_cover end
    local own_owner = type(data.owner) == "table" and data.owner or {}
    if util.text(own_owner.name) ~= "" then
      owner = models.artist(own_owner.mid, own_owner.name)
    end
  end
  return {
    id = bvid,
    title = util.clean_title(title),
    coverUrl = util.image(cover),
    songCount = count,
    artists = { owner },
  }
end

-- ---------------------------------------------------------------------------
-- Fresh listening material (T15)
-- ---------------------------------------------------------------------------
--
-- The shelf used to be the music chart, and the music chart is not new: measured
-- 97 rows with a median `pubdate` of 14487 hours (603 DAYS) and 0/97 inside 24 h
-- (evidence/t15/probe_base_age.log). "为你推荐的新发行" was therefore a synonym
-- for "the ranking", which the user reported as the defect ("排行榜的变化很小
-- 而且也不新").
--
-- Source: `/x/web-interface/wbi/search/type?search_type=video&order=pubdate`.
-- It is the only endpoint measured that carries ALL THREE of `pubdate` (so the
-- row is genuinely new), `typeid` (so the zone is filterable) and
-- `play`/`like`/`favorites` (so heat is comparable inside the window). The four
-- alternatives were each rejected on measurement, not on taste:
--
--   ranking/v2?rid=3   0/97 inside 24 h, median 603 days (§above)
--   popular            music zone 0/20 (1/80 across four pages) — cannot carry
--                      the shelf alone
--   newlist            hard-banned: `-412 request was banned` with a valid salted
--                      signature and a real cookie, while popular/ranking/view
--                      answered 200 in the same second
--                      (evidence/t15/probe_newlist_wbi.log)
--   rcmd (recommend)   median 302 h, and its rows carry NO zone field at all
--                      (26 keys, no tid/tname/pid_v2/videos), so the plugin
--                      could not filter what it was handed
--                      (evidence/t15/probe_rcmd_fields.log)
--
-- "New" beats "pure heat" on purpose (D2): a row published minutes ago has
-- `play == 0`, so ranking by heat across the whole window would only ever
-- surface old-but-popular rows again. The window is built first, and heat only
-- orders rows INSIDE it.
-- T16 词表。三通道，用户 2026-11-24 定的比例：ASMR 最高、长内容次之、
-- 短内容最少；`公开课` 整词删除（它是 208 的主力，23/30 行落在校园学习），
-- `讲座` 保留但只占长通道的四分之一。
--
-- 换词的依据是 t16 的三份实测，不是感觉：
--
--   evidence/t16/probe_asmr_channels.log
--     ASMR/助眠/白噪音/哄睡 四词 120 行 → 71 行落在 tid=21 日常，
--     而那 71 行 100% 带 asmr/助眠 等标记；对照词「分享课」的 21 行
--     0 条带标记。所以 21 不能整体放行，「21 + 标记」却是可分离的。
--   evidence/t16/probe_long_after_208.log
--     去掉 208 后长通道 6 词只剩 32 行，其中 `文学朗读` 一个词贡献 19 行；
--     `公开课` 去 208 后只剩 2 行，`课堂实录` 只剩 1 行 —— 两个都换掉。
--   evidence/t16/probe_final_vocab.log
--     本词表 10 词 ps=30 的去重候选：long 31 / asmr 52 / short 51，
--     解码 465,598 B（现状 206,027 B 的 2.26x）。
local FRESH_WORDS = {
  { channel = "asmr", word = "ASMR" },
  { channel = "asmr", word = "助眠" },
  { channel = "asmr", word = "白噪音" },
  { channel = "long", word = "有声书" },
  { channel = "long", word = "文学朗读" },
  { channel = "long", word = "听书" },
  { channel = "long", word = "讲座" },
  { channel = "short", word = "鬼畜" },
  { channel = "short", word = "歌切" },
  { channel = "short", word = "纯音乐" },
}

-- 30 rows per word, one page. `page_size` is capped at 50 by the endpoint
-- (`page_size=100` answers `-400`, evidence/t15/probe_search_window.log), but
-- the real constraint is DECODING cost, not the cap: the host runs the whole
-- `homeFeed` op under a 250k-instruction budget (lua_plugin_runtime_io.dart:1096).
--
-- T9/R25 recorded the cliff as "mapping 100 chart rows answers 408". That wall
-- is measured on MAPPED rows, not decoded ones, and this op maps only the 16
-- filtered slots — so the task book's projection that ps=30 would 408 was
-- tested rather than assumed, and it does NOT:
--
--   T15 baseline (6 words, ps=20)  search 191,549 B + popular 33,182 = 224,731
--   T15 shipped  (6 words, ps=30)  search 280,677 B + popular 33,182 = 313,859
--   T16 now     (10 words, ps=30)  search 465,598 B + popular 33,182 = 498,780
--
-- 498,780 B is 2.42x the pre-T15 op and 1.59x what T15 shipped. That is a real
-- step up, so it is gated rather than assumed: contract case T16#05 feeds the
-- 300 REAL captured rows (evidence/t16/fresh_rows_t16.json, 66 fields/row,
-- `<em>` in titles, full descriptions) through `homeFeed` and requires 16 slots
-- instead of a 408. If that case ever goes red, the fix is fewer words or
-- ps=20 — not a bigger budget.
--
-- The reason the decode can grow while the op still answers is unchanged: the
-- filter runs on RAW rows, so the budget is spent on the 16 rows that get
-- MAPPED, not on the 300 that get decoded.
local FRESH_PAGE_SIZE = 30

-- 20 minutes, matching the host's own `home:` cache (catalog.dart:490). A
-- shorter TTL here buys nothing: the host would still serve the old feed until
-- its own cache expired.
local FRESH_TTL_MS = 20 * 60 * 1000

-- Zone whitelists. Keyword search with `order=pubdate` is a POOR topicalian
-- match — the top rows for 有声书 included T1 电竞 and 两性科普
-- (evidence/t15/probe_heat_metric.log) — so the keyword's only job is "find
-- something new" and the `typeid` does the actual topic decision (D9).
--
-- Three channels since T16, because one threshold cannot serve all ends: 鬼畜
-- has a median duration of 67 s, 助眠 2326 s and 文学朗读 51315 s (t15/t16
-- probes). Filtering the short channel by ">= 10 min" would delete the whole
-- 鬼畜 class; filtering the asmr channel by tid alone would delete it entirely
-- (below).
--
-- `21 日常` is still ABSENT from both tables. It was the single largest noise
-- source: 64 of the 141 long-whitelist hits, appearing in the top rows of
-- 广播剧 x20, 评书 x21, 助眠 x18, ASMR x19 (evidence/t15/probe_typeid_whitelist.log).
--
-- `208 校园学习` was REMOVED in T16 on the user's instruction, and the supply
-- measurement backs the removal: with 208 in the list it supplied 48 of the 141
-- long hits, and after removing it the remaining long words still deliver 31
-- distinct rows (evidence/t16/probe_long_after_208.log). Nothing else needed 208.
local LONG_TIDS = {
  ["195"] = true, -- 动态漫.广播剧
  ["228"] = true, -- 人文历史
  ["124"] = true, -- 社科·法律·心理
  ["201"] = true, -- 科学科普
  ["207"] = true, -- 财经商业
}
local SHORT_TIDS = {
  ["31"] = true,  -- 翻唱
  ["130"] = true, -- 音乐综合
  ["59"] = true,  -- 演奏
  ["29"] = true,  -- 音乐现场
  ["193"] = true, -- MV
  ["30"] = true,  -- VOCALOID·UTAU
  ["26"] = true,  -- 音MAD
  ["22"] = true,  -- 鬼畜调教
  ["216"] = true, -- 鬼畜剧场
  ["126"] = true, -- 人力VOCALOID
}

-- A duration past 24 h is treated as a data defect, not as a long video. Seven
-- of 120 rows measured exceeded it, and every one read as a serialised novel or
-- a live replay registered as a single upload — the longest was 841120 s, or
-- 9.7 days (evidence/t15/T00-duration-anomaly.log). Those rows still belong on
-- the shelf; they just do not get to print "233.6h" on a two-line card.
local DURATION_CEILING = 86400

-- 16 slots in the pattern below: 8 asmr + 6 long + 2 short.
--
-- The weighting is the user's 2026-11-24 decision ("提高 ASMR 权重"). It is a
-- SLOT ratio, not a heat multiplier: ASMR rows are ranked by the same
-- `play + like*10` as everything else, they simply get half the shelf. A score
-- multiplier would have been unverifiable — the three channels have disjoint
-- play ranges at any instant (asmr rows are minutes old with play in the tens,
-- short rows are hours old with play in the thousands), so any multiplier would
-- mostly be measuring row age, not preference.
--
-- The six long slots are also the "减少公开课/讲座" answer: `公开课` is gone from
-- the word list entirely and `讲座` is one of four long words, so the long
-- channel as a whole now gets 6 slots instead of 12.
--
-- One shelf cannot be split in three: the host hardcodes the shelf title
-- (`home_pages.dart:290` in 2.1.0) and `HomeFeed` has no extra slot for a
-- plugin, so every channel lands in `homeFeed.albums` and the CARD TEXT is the
-- only place the distinction can be shown (D5/D6).
local FRESH_SLOTS = 16

-- Slot -> channel. Repeats twice over the 16 slots, so it must be read as
-- "per 8 slots: 4 asmr, 3 long, 1 short" and the totals follow.
--
-- The pattern, not a set of per-channel counters, is the source of truth: a
-- counter pair (asmr 8 / long 6) can be satisfied by a thousand orders, and the
-- order is what the user sees. This one opens on two asmr cards, never puts two
-- shorts adjacent, and never runs more than two longs in a row.
local FRESH_PATTERN = { "asmr", "asmr", "long", "asmr", "long", "asmr", "long", "short" }
local FRESH_PATTERN_LEN = #FRESH_PATTERN

-- Fill order when a slot's own channel is exhausted. Weight order, so a dead
-- ASMR channel fills with long content rather than with 鬼畜.
local FRESH_CHANNEL_ORDER = { "asmr", "long", "short" }

-- `play + like*10` over the measured window: p10=1 / p50=50 / p90=362 /
-- p99=2371, with only 30/300 rows at zero. Single `play` has 53/300 zeroes and
-- `like/play` has 97/300, so both collapse a large share of the window into one
-- indistinguishable bucket (D11, evidence/t15/probe_heat_metric.log).
--
-- The formula is cheap ON PURPOSE: a comparator closure over ~97 rows already
-- answered 408 (evidence/t12/T01_sort_budget.log), so this is a plain additive
-- score computed once per row, never a `table.sort` over the whole page.
local function fresh_heat(item)
  return util.number(item.play, 0) + util.number(item.like, 0) * 10
end

-- ASMR is the one channel that cannot be decided by `typeid` alone.
--
-- Measured (evidence/t16/probe_asmr_channels.log): the four ASMR-ish words put
-- 71 of 120 rows in `21 日常`, and those 71 rows carry an asmr/助眠/白噪音 token
-- in the title or tags 71/71 times. The control matters more than the hit rate:
-- a non-ASMR word's 21 rows carried the token 0/4 times. So within tid 21 the
-- token separates the two populations, and outside tid 21 the whitelist already
-- decides.
--
-- The token list is deliberately short and literal. `放松` / `静心` / `冥想`
-- look tempting but they also describe 五音疗愈 and 学习背景音, which is exactly
-- the 208-style content the user asked to stop showing.
local ASMR_TAG = {
  "asmr", "助眠", "白噪音", "白噪声", "哄睡", "环境音", "睡眠",
}

local ASMR_ZONE_TID = "21"

local function fresh_is_asmr_row(item)
  local text = string.lower(util.text(item.title) .. " " .. util.text(item.tag))
  for index = 1, #ASMR_TAG do
    if string.find(text, ASMR_TAG[index], 1, true) ~= nil then return true end
  end
  return false
end

-- Display name for the token that ACTUALLY put this row in the ASMR channel.
--
-- v0.6.0 printed a flat `ASMR` on every asmr-channel row so the channel could
-- be told apart from the short channel's 音乐综合 rows. That fixed the
-- collision but threw away information the wire already carries: the three
-- words plus the tag field distinguish 助眠 / 白噪音 / 哄睡 / 环境音 / 睡眠,
-- and a card that says `白噪音 · 20:11` is strictly more use than `ASMR · 20:11`.
--
-- The rule is positional, not priority-based: the token that appears EARLIEST
-- in the title wins, and only when the title carries none of them does the tag
-- field decide. Filename-style uploads ("心跳声", "好看呆呆芦荟胶") have no
-- token in the title at all, so their tag decides; measured on the T16 capture,
-- 36/61 rows carry a token in the title and 25/61 only in the tag
-- (evidence/t17/label_tokens.log).
--
-- This deliberately does NOT fall back to the wire zone. A 日常 zone is
-- meaningless on a card, and a real zone (人文历史 / 音乐综合) collides with the
-- long/short channels' own labels — that collision is what v0.6.0 was fixing.
-- `ASMR` stays as the last resort for a row matched by the umbrella token only.
local ASMR_LABEL_BY_TAG = {
  ["asmr"] = "ASMR", ["助眠"] = "助眠", ["白噪音"] = "白噪音",
  ["白噪声"] = "白噪音", ["哄睡"] = "哄睡", ["环境音"] = "环境音",
  -- 睡眠 is folded into 助眠 on purpose: it is the same intent to the listener
  -- and it appeared on 1 of 61 rows, so a `睡眠 · …` label would be a one-off
  -- that teaches nothing (evidence/t17/label_tokens.log).
  ["睡眠"] = "助眠",
}

-- Tag hits are searched AFTER every title hit, so `TAG_BASE` only has to be
-- larger than any title length, not a real position.
local ASMR_TAG_BASE = 1000000

local function fresh_asmr_label(item)
  local title = string.lower(util.clean_title(util.text(item.title)))
  local tags = string.lower(util.text(item.tag))
  local best_at = nil
  local best = nil
  for index = 1, #ASMR_TAG do
    local needle = ASMR_TAG[index]
    local at = string.find(title, needle, 1, true)
    if at == nil then
      local in_tag = string.find(tags, needle, 1, true)
      if in_tag ~= nil then at = ASMR_TAG_BASE + in_tag end
    end
    if at ~= nil and (best_at == nil or at < best_at) then
      best_at = at
      best = needle
    end
  end
  if best == nil then return "ASMR" end
  return ASMR_LABEL_BY_TAG[best]
end

-- Zone of a row, or nil when it belongs on no shelf at all.
--
-- `want` is the channel of the WORD that produced the row, and it decides two
-- things a `typeid` alone cannot:
--
--   * Only asmr-configured words may fill the ASMR channel. A 日常 row found by
--     鬼畜 is a vlog; the same row found by 助眠 is ASMR. Zone alone cannot tell.
--   * An asmr word's row that names itself ASMR is ASMR even when it was filed
--     under a real zone — measured crossovers are 助眠→228 人文历史 x2 and
--     助眠→130 音乐综合 x1 (evidence/t16/probe_final_vocab.log). Filing those
--     under "long"/"short" would spend an ASMR word to fill a non-ASMR slot.
--
-- The token rule never widens the typeid gate: a row still has to sit in 21 or
-- in one of the whitelists, so an ASMR-titled 网络游戏 upload cannot get on the
-- shelf by calling itself ASMR.
local function fresh_channel_of(item, want)
  local tid = util.text(item.typeid)
  local known = tid == ASMR_ZONE_TID or LONG_TIDS[tid] or SHORT_TIDS[tid]
  if want == "asmr" and known and fresh_is_asmr_row(item) then return "asmr" end
  if LONG_TIDS[tid] then return "long" end
  if SHORT_TIDS[tid] then return "short" end
  return nil
end

-- "分区 · 时长". The card's second line is the only place the plugin can express
-- anything about the row (`home_pages.dart:1209-1225` renders title then
-- `album.artist`), and `Album` has no duration field at all
-- (`models.dart:394-424`), so the zone and the length both go into
-- `artists[1].name` (D6).
--
-- ASMR-channel rows name the token that selected them (助眠 / 白噪音 / 哄睡 / …)
-- instead of the wire zone, and instead of a flat `ASMR`.
--
-- Both alternatives were measured and both are worse:
--   * the wire zone — the live shelf put a 白噪音 playlist (wire zone 音乐综合)
--     in slot 1 and two real 音乐综合 rows from the SHORT channel in slots 8 and
--     16: three identical `音乐综合 · …` labels for two different channels, so
--     the weight the user asked for was invisible (evidence/t16/R1_live_channels.log)
--   * a flat `ASMR` — it separates the channels but discards the distinction the
--     capture already carries, and 24 of 61 rows would print the umbrella term
--     while naming themselves 助眠 or 白噪音 in the title
--     (evidence/t17/label_tokens.log)
--
-- The card text is the ONLY channel signal the host gives us (D5/D6), so it has
-- to be both channel-distinguishing AND specific. Long and short rows keep their
-- real zone name because there the zone IS the useful information.
local function fresh_label(item, channel)
  local zone = util.clean_title(util.text(item.typename))
  if zone == "" then zone = "B站视频" end
  if channel == "asmr" then zone = fresh_asmr_label(item) end
  local seconds = 0
  if type(item.duration) == "number" then seconds = math.floor(item.duration) end
  local text = util.text(item.duration)
  local length = string.len(text)
  local total = 0
  local start = 1
  if length > 0 then
    while true do
      local colon = string.find(text, ":", start, true)
      local part
      if colon == nil then part = string.sub(text, start) else part = string.sub(text, start, colon - 1) end
      local piece = tonumber(util.trim(part))
      if piece == nil or piece < 0 then piece = 0 end
      total = total * 60 + piece
      if colon == nil then break end
      start = colon + 1
    end
    seconds = total
  end
  if seconds <= 0 or seconds > DURATION_CEILING then return zone end
  if seconds >= 3600 then
    return zone .. " · " .. string.format("%.1fh", seconds / 3600)
  end
  if seconds >= 60 then
    return zone .. " · " .. tostring(math.floor(seconds / 60)) .. ":" ..
      string.format("%02d", seconds % 60)
  end
  return zone .. " · " .. tostring(seconds) .. "s"
end

-- Raw search rows, cached per word and BEFORE any mapping.
--
-- Same shape as `popular_rows` / `chart_raw` and for the same reason: the
-- budget is spent on rows that get MAPPED, so the filter has to happen while
-- the rows are still raw (`videos` survives, `typeid` is still a number).
local fresh_cache = {}

store.on_reset(function()
  fresh_cache = {}
end)

local function fresh_page(word)
  local cached = fresh_cache[word]
  if cached ~= nil and host.now() - cached.at < FRESH_TTL_MS then
    return cached.rows
  end
  local body = wbi.get("/x/web-interface/wbi/search/type", {
    search_type = "video", keyword = word, order = "pubdate",
    page = 1, page_size = FRESH_PAGE_SIZE,
  })
  local rows = util.list(data_of(body).result)
  fresh_cache[word] = { rows = rows, at = host.now() }
  return rows
end

-- One channel's candidates, best-first, already filtered to its whitelist.
--
-- The sort runs over the FILTERED channel only (about 25 rows, measured), never
-- over the whole page: T12 already proved a `table.sort` plus a comparator
-- closure over 97 rows pushes this op past the 250k budget
-- (evidence/t12/T01_sort_budget.log). For the same reason it is a hand-written
-- insertion sort on a precomputed heat array rather than `table.sort` with a
-- closure: the closure is the expensive part (one cross-VM call per comparison),
-- and the sizes here are small enough that O(n^2) with no closure is cheaper.
--
-- `owner` is the shelf-wide bvid set. It is shared across the three calls on
-- purpose: `fresh_channel_of` can put the SAME row in two channels — an ASMR
-- word's row that self-reports 助眠 AND sits in 228 goes to asmr, but a long
-- word's identical row goes to long — and the two rows were then shelved twice
-- under two different labels (`ASMR · 39:52` next to `人文历史 · 39:52` for the
-- same bvid). Per-channel `seen` cannot catch that; the set has to span the
-- shelf. Channels are built asmr → long → short, so the higher-weight channel
-- keeps the row.
local function fresh_channel(channel, allow_degrade, owner)
  local rows = {}
  local heat = {}
  local seen = owner
  local failed = 0
  local words = 0
  local last_error = nil
  for index = 1, #FRESH_WORDS do
    local entry = FRESH_WORDS[index]
    if entry.channel == channel then
      words = words + 1
      local ok, page = pcall(fresh_page, entry.word)
      if ok then
        local source = util.list(page)
        for row = 1, #source do
          local item = source[row]
          -- Filtering happens HERE, on raw rows, before any mapping: the budget
          -- is spent per mapped row (T9/R25).
          if type(item) == "table" and fresh_channel_of(item, entry.channel) == channel then
            local bvid = util.text(item.bvid)
            if bvid ~= "" and seen[bvid] == nil then
              seen[bvid] = true
              rows[#rows + 1] = item
              heat[#rows] = fresh_heat(item)
            end
          end
        end
      else
        failed = failed + 1
        last_error = page
      end
    end
  end
  -- A dead channel is a real failure; a mostly-dead one is not (T15#08). Only
  -- when EVERY word of the channel failed does this surface, and only to a
  -- caller that did not ask to degrade.
  if words > 0 and failed >= words and not allow_degrade then error(last_error, 0) end
  for at = 2, #rows do
    local item = rows[at]
    local score = heat[at]
    local bvid = util.text(item.bvid)
    local cursor = at - 1
    while cursor >= 1 do
      local other = heat[cursor]
      local swap = false
      if other < score then
        swap = true
      elseif other == score and util.text(rows[cursor].bvid) > bvid then
        swap = true
      end
      if not swap then break end
      rows[cursor + 1] = rows[cursor]
      heat[cursor + 1] = heat[cursor]
      cursor = cursor - 1
    end
    rows[cursor + 1] = item
    heat[cursor + 1] = score
  end
  return rows, failed
end

local function fresh_albums(allow_degrade)
  -- One bvid set for all three channels: see the note on `fresh_channel`'s
  -- `owner` argument. Order matters — asmr is built first, so a row that
  -- qualifies for asmr is claimed there and cannot reappear as long/short.
  local claimed = {}
  local asmr_rows, asmr_failed = fresh_channel("asmr", allow_degrade, claimed)
  local long_rows, long_failed = fresh_channel("long", allow_degrade, claimed)
  local short_rows, short_failed = fresh_channel("short", allow_degrade, claimed)
  local degraded = asmr_failed > 0 or long_failed > 0 or short_failed > 0
  local pools = { asmr = asmr_rows, long = long_rows, short = short_rows }
  local cursors = { asmr = 1, long = 1, short = 1 }
  local out = {}
  local padded = 0
  local function push(item, channel)
    local bvid = util.text(item.bvid)
    if bvid == "" then return false end
    out[#out + 1] = {
      id = bvid,
      title = util.clean_title(item.title),
      coverUrl = util.image(util.field(item, "pic", "cover")),
      -- Search rows carry no `videos` (0/20 on the live answer), so the honest
      -- count for one upload is 1. `albumSongs` really does return exactly one
      -- row for it.
      songCount = 1,
      artists = { models.artist(util.field(item, "mid", "uid"), fresh_label(item, channel)) },
    }
    return true
  end
  -- Try one row from `channel`; returns false when that pool is exhausted.
  --
  -- `channel` is the pool the row was filtered into, which is also the row's own
  -- channel — a row lands in exactly one pool because `fresh_channel_of` decides
  -- on `typeid` first and the pools are keyed by that decision. So passing the
  -- pool name to `fresh_label` cannot mislabel a row that arrived by fallback.
  local function take(channel)
    local pool = pools[channel]
    local at = cursors[channel]
    local total = #pools[channel]
    while at <= total do
      local ok = push(pool[at], channel)
      at = at + 1
      cursors[channel] = at
      if ok then return true end
    end
    cursors[channel] = at
    return false
  end
  for slot = 1, FRESH_SLOTS do
    local want = FRESH_PATTERN[(slot - 1) % FRESH_PATTERN_LEN + 1]
    if not take(want) then
      -- Degradation, recorded rather than hidden: never cycle a row back in, and
      -- never leave the slot empty while another pool still has rows.
      for order = 1, #FRESH_CHANNEL_ORDER do
        local fallback = FRESH_CHANNEL_ORDER[order]
        if fallback ~= want and take(fallback) then
          padded = padded + 1
          break
        end
      end
    end
  end
  return out, degraded, padded
end

-- Rows that belong on the music shelf.
--
-- Two sources, deduplicated by bvid, in two layers:
--
--   popular — the list `featuredSongs` comes from, restricted to the music zone
--             (`pid_v2 == MUSIC_PID_V2`). Its rows keep the popular order.
--   music   — `/x/web-interface/ranking/v2?rid=3`, RAW rows, whole chart, in the
--             order the endpoint returned them.
--
-- The chart is filtered by `pid_v2` as well, and that is NOT redundant: the
-- music-zone chart is mostly but not entirely music — measured 86/97 rows carry
-- pid_v2 == 1003 and the rest are 娱乐/二次元/鬼畜/游戏/知识/科技数码/动物/其他
-- (evidence/t12/R7_music_ranking_zones.log). An unfiltered chart therefore puts
-- a 鬼畜 video on the music shelf.
--
-- The chart is NOT re-sorted by `score`. `score` is present on 97/97 rows and is
-- 0 on 97/97 of them (same log), so sorting on it is a no-op semantically — and
-- it is not free: a Lua `table.sort` with a comparator over 97 rows pushed
-- `homeFeed` past the 250k instruction budget and answered 408
-- (evidence/t12/T01_sort_budget.log). The endpoint's own order is the ranking
-- order, so keeping it is both correct and cheaper.
--
-- Shelf order is therefore: popular music rows in popular order, then chart rows
-- in chart order. That is the only definition the wire supports.
--
-- A popular page with ZERO music rows is normal, not an error: measured live,
-- 0/20 popular rows were in the music zone (evidence/t12/R5_popular_pid.log), so
-- the shelf falls back to the chart alone and still forms. Nothing here may
-- pad it with non-music rows to make it look fuller.
--
-- T10/D2: folding the chart in used to blow the 250k instruction budget
-- (`homeFeed THREW 408`). The cause was never the chart's size, it was MAPPING
-- it: `chart_rows` turns 100 rows into song shapes (no `videos` left, and 100
-- decoded rows is what the budget is spent on) —
-- evidence/t9/R25_homefeed_chart_mapped.log. Reading the RAW rows costs 6
-- requests and returns albums fine — evidence/t9/R27_homefeed_chart_raw.log.
--
-- `allow_degrade` guards the chart request alone. Popular is the home page's
-- main content, so its failure must still surface; anything else (a bad row
-- mapper, a broken view loop) is a programming error and must not be laundered
-- into "the home page is empty today".
-- `allow_degrade` used to guard the chart request so a chart failure did not
-- empty the home page. Since T15 the home page does not read the chart at all
-- (see `fresh_shelf`), and `albums()` is an explicit browse action that must
-- surface its failures (T10#12), so there is no caller left that wants the
-- degraded branch. Removed rather than kept as a dead parameter.
local function album_candidates()
  local out = {}
  local seen = {}
  -- `videos` is read from the RAW row on purpose: `song_rows` drops it, and
  -- mapping the candidates before deciding cost T9/R25 its 408.
  local function add(item)
    local bvid = util.text(item.bvid)
    if bvid == "" or seen[bvid] ~= nil then return end
    if util.number(item.videos, 0) < 1 then return end
    seen[bvid] = true
    out[#out + 1] = item
  end
  local function add_music(rows)
    local source = util.list(rows)
    for index = 1, #source do
      local item = source[index]
      if util.number(item.pid_v2, 0) == MUSIC_PID_V2 then add(item) end
    end
  end
  add_music(popular_rows())
  add_music(chart_raw(MUSIC_CHART_RID))
  return out
end

-- Build the shelf from the candidate set. One cache slot; `albums()` is the
-- only reader since T15.
local function album_rows()
  local cached = album_cache.wide
  if cached ~= nil and host.now() - cached.at < ALBUM_TTL_MS then
    return cached.rows
  end
  local candidates = album_candidates()
  local out = {}
  -- Count ATTEMPTS, not successes: with a success counter one failed `view`
  -- silently pushes the real spend past ALBUM_LIMIT while the budget assertion
  -- still reads 16 (T10/D5).
  --
  -- Only a MULTI-PART candidate costs an attempt. A single-part row is complete
  -- as it stands (title, cover, and `videos = 1` is the exact song count), so it
  -- must not spend the budget: `view` is not sent for it at all. Charging
  -- single-part rows against ALBUM_LIMIT would cap a chart of 97 single-part
  -- rows at 16 albums for no information gained.
  local attempts = 0
  for index = 1, #candidates do
    local item = candidates[index]
    local videos = util.number(item.videos, 0)
    if videos > 1 then
      if attempts >= ALBUM_LIMIT then break end
      attempts = attempts + 1
      -- This request buys real information (the video's own title/cover and the
      -- exact part count). A failure skips the request, not the album: the feed
      -- row still says how many parts there are, and one dead video must not
      -- take the whole shelf down.
      local ok, body = pcall(http.get, "/x/web-interface/view", { bvid = util.text(item.bvid) })
      local album = album_from(item, ok and body or nil)
      if album ~= nil then out[#out + 1] = album end
    else
      local album = album_from(item, nil)
      if album ~= nil then out[#out + 1] = album end
    end
  end
  album_cache.wide = { rows = out, at = host.now() }
  return out
end

-- The home shelf's T15 source: 16 fresh listening rows, 12 long + 4 short.
--
-- Deliberately SEPARATE from `album_rows` (which still serves `albums()`, the
-- browse page). The two shelves mean different things: the browse page is "find
-- a multi-part container to open", and the home shelf is "recommend something
-- to listen to right now". Folding them together was the T10 defect in reverse —
-- one candidate set serving two questions. Here the split is intentional.
--
-- Degradation is narrow: one dead word keeps the other words' rows and the
-- result is NOT cached, so the next open retries. Every fresh word dead falls
-- through to the old `album_rows` candidate set, so the shelf is never empty if
-- popular still answers (T15#09).
local fresh_album_cache = nil

store.on_reset(function()
  fresh_album_cache = nil
end)

local function fresh_shelf(allow_degrade)
  local cached = fresh_album_cache
  if cached ~= nil and host.now() - cached.at < FRESH_TTL_MS then
    return cached.rows
  end
  local ok, rows, degraded = pcall(fresh_albums, allow_degrade)
  if ok then
    if #rows > 0 then
      if not degraded then fresh_album_cache = { rows = rows, at = host.now() } end
      return rows
    end
  elseif not allow_degrade then
    error(rows, 0)
  end
  -- Either every word failed, or every row was filtered out. The old candidate
  -- set is the fallback: it is worse (603-day-old chart rows) but it is real,
  -- and an empty shelf with a live home page is the worse outcome.
  return album_rows()
end

-- The browse shelf. Same candidate set as the home page (T10/D4), and it does
-- NOT degrade: this is an explicit "show me the album shelf" call, so a chart
-- failure belongs to the caller, as it did before T10.
function M.albums(limit, offset)
  return pager.slice(album_rows(), limit, offset)
end

-- ---------------------------------------------------------------------------
-- Discovery
-- ---------------------------------------------------------------------------

-- Home. `albums` is the T15 fresh-listening shelf (see fresh_shelf);
-- `featuredSongs` still comes from the popular list, which is what it always
-- was.
function M.home_feed()
  return {
    featuredSongs = song_rows(popular_rows()),
    albums = fresh_shelf(true),
  }
end

function M.charts()
  local rows = chart_rows(CHART_RID)
  return {
    { id = chart_key(CHART_RID), name = "全站排行", songCount = #rows },
  }
end

function M.recommendations(limit, seed)
  local take = util.number(limit, 30)
  if take < 1 then take = 30 end
  if take > 100 then take = 100 end
  local id = util.text(seed)
  if id == "" then
    local popular = http.get("/x/web-interface/popular", { ps = 1, pn = 1 })
    local rows = util.list(data_of(popular).list)
    if #rows == 0 then return {} end
    id = util.text(rows[1].bvid)
  end
  local body = http.get("/x/web-interface/archive/related", { bvid = id })
  local out = {}
  local rows = util.list(data_of(body))
  for index = 1, #rows do
    if #out >= take then break end
    local item = rows[index]
    if type(item) == "table" and util.text(item.bvid) ~= "" then
      out[#out + 1] = models.song(item)
    end
  end
  return out
end

-- ---------------------------------------------------------------------------
-- Comments
-- ---------------------------------------------------------------------------

-- The host advances its own offset by the number of rows it received
-- (`song_comments_controller.dart`), so a short remote page must not be treated
-- as the last page and the offset must not be divided by ps to guess a page
-- number: both produced duplicated and permanently missing comments.
function M.comments(id, limit, offset)
  local want = util.number(limit, 20)
  if want < 1 then want = 20 end
  local skip = util.number(offset, 0)
  if skip < 0 then skip = 0 end
  -- Same identity rule as set_favorite: a `bvid:cid` id from a chart or the home
  -- feed used to be pasted whole into `view?bvid=`, which answered 400 and made
  -- the comment panel fail for exactly the rows T6 had just made visible. The
  -- aid is per-video, so the cid is parsed and dropped on purpose.
  local bvid, _ = ids.parse(id)
  local view = http.get("/x/web-interface/view", { bvid = bvid })
  local aid = util.number(data_of(view).aid, 0)
  if aid <= 0 then error("Gateway code -400", 0) end

  local cap = 20
  local hops = pager.hops(skip, want, cap)
  -- nil means "the endpoint never reported a count"; 0 is a real answer. The
  -- old code collapsed both into 0 and then overwrote the total with the rows
  -- it happened to read, so a truncated walk reported itself as complete.
  local total = nil
  -- strict_seek: reply pages really are position slices (20 rows each, no
  -- overlap across pn=1/2/3/4/5/10/20/33/66 — evidence/t6/probe_reply_pages.txt),
  -- so a deep offset can jump straight to its page instead of walking there and
  -- running out of the per-call request budget (bili/pager.lua PLAINTEXT_BUDGET).
  --
  -- `sort=0` is TIME order. Measured live: sort=0 sums to 32 likes across the
  -- page while sort=1 and sort=2 both sum to 2 793 193 — i.e. the old `sort=2`
  -- was the hot list wearing the "latest" name (evidence/t9/R29_reply_sort_live.log).
  local replies, _, truncated = pager.walk("reply:" .. tostring(aid), function(pn)
    local body = http.get("/x/v2/reply", {
      type = 1, oid = aid, pn = pn, ps = cap, sort = 0,
    })
    local data = data_of(body)
    local page = type(data.page) == "table" and data.page or {}
    local count = max_number(page.count, page.acount)
    -- A page WITH rows that reports 0 (or nothing) says nothing about the size.
    -- Writing that 0 as the total made `skip >= total` true from then on, so one
    -- count-less response froze the thread at its first page forever
    -- (evidence/t9/R3_comments_latch.log). Unknown stays unknown.
    local reported = (count > 0) and count or nil
    if reported ~= nil then total = reported end
    return util.map_rows(util.list(data.replies), models.comment), reported
  end, want, skip, hops, nil, { cap = cap, strict_seek = true })

  -- The hot bucket is an EXTRA SCREEN, not a page: one request, first page only,
  -- never part of the walk, never part of `total`/`hasMore`. Requesting it on
  -- every page of `latest` would pay the same 20 rows again for a list the
  -- client already holds, and its ordering shifts with likes, so paging it
  -- would duplicate and skip rows (evidence/t9/R19_reply_sort_pages.log).
  local hot = {}
  if skip == 0 then
    -- Failure here must not touch `latest`: a blocked or rate-limited hot list
    -- is a missing panel, not a broken thread. The result is not cached, so the
    -- next call retries instead of serving an empty list for the session.
    local ok, body = pcall(http.get, "/x/v2/reply", {
      type = 1, oid = aid, pn = 1, ps = cap, sort = 1,
    })
    if ok then
      hot = util.map_rows(util.list(data_of(body).replies), models.comment)
    end
  end

  -- The endpoint's count is the ONLY source of `total`. `skip + #replies` used
  -- to stand in for it, which is the request offset wearing the total's name:
  -- comments(offset=1000) answered `total=1000` for a thread of 60
  -- (evidence/t8/R9_past_end_offline.log) and the panel then said "1000 条" with
  -- nothing to load. A count the endpoint never sent stays unknown: the host
  -- reads a missing `total` as 0 (SongCommentPage.fromJson), which is the honest
  -- "we do not know" and never a fabricated deep number.
  return {
    latest = replies,
    hot = hot,
    total = total,
    -- A truncated walk is not "the end": say there is more, so the client keeps
    -- asking instead of closing the thread on a budget cutoff.
    hasMore = truncated or (total ~= nil and skip + #replies < total),
  }
end

return M
