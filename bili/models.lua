-- B-site response -> Lazer model mapping. One normaliser per entity keeps every
-- operation consistent.
local util = require("bili.util")

local M = {}

-- 专辑名的**总**显示列预算（标题 + ` · N P` 后缀一起算）。
--
-- 两处构造点（本文件的 `M.song` 与 `catalog.album_songs`）必须用同一个数，
-- 否则同一支视频从列表进和从专辑页进会得到不同的专辑名。
--
-- 为什么是"总预算"而不是"标题预算"：宿主用 `maxLines:1 + overflow:ellipsis`
-- 渲染整串（player_controls_bar.dart:131、desktop_now_playing.dart:532），省略号
-- 加在**整串末尾**。只裁标题再把后缀接上去，等于把后缀推到窗口外。
-- T13/T02 实测：`BV1q4FTeBEMj` 标题 53 字，` · 100 P` 会被整段吃掉。
--
-- 32 列 ≈ 16 个全角字，或 24 列标题 + 8 列 ` · 100 P`。整串在宽屏列表的专辑列
-- 里不再触发宿主省略号。
M.ALBUM_LABEL_COLUMNS = 32

function M.artist(mid, name)
  return { id = util.text(mid), name = util.clean_title(name) }
end

-- 搜索结果里的 UP 主行。字段名与 bili_user 对齐；albumCount 必须是 0，
-- 否则 artist_page 会渲染出一个空的"专辑"区。
function M.artist_row(row)
  if type(row) ~= "table" then row = {} end
  return {
    id = util.text(row.mid),
    name = util.clean_title(row.uname),
    coverUrl = util.image(row.upic),
    description = util.text(row.usign),
    albumCount = 0,
  }
end

-- UP 主详情（宿主的 artist op）。B站没有"歌手专辑"概念，UP 投稿走 artistSongs，
-- 这里只回填名字/头像，albumCount 保持 0，避免歌手页渲染出不存在的专辑条目。
function M.artist_detail(mid, card)
  card = type(card) == "table" and card or {}
  local name = util.clean_title(util.field(card, "name", "uname"))
  if name == "" then name = "B站用户" end
  return {
    id = util.text(mid),
    name = name,
    coverUrl = util.image(util.field(card, "face")),
    description = util.text(util.field(card, "sign")),
    albumCount = 0,
  }
end

-- Every song-returning op uses this shape (task book §4.5).
-- `overrides.id` wins: it is how a caller pins the identity to one part
-- (`bvid:cid`) instead of letting the row's bvid decide.
function M.song(item, overrides)
  if type(item) ~= "table" then item = {} end
  overrides = overrides or {}
  local bvid = util.text(util.field(item, "bvid", "bv_id"))
  if bvid == "" then bvid = util.text(overrides.bvid) end
  local mid = util.field(item, "mid")
  if mid == nil then
    local owner = item.owner
    if type(owner) == "table" then mid = owner.mid end
    local upper = item.upper
    if type(upper) == "table" then mid = upper.mid end
  end
  local author = util.field(item, "author")
  if author == nil then
    local owner = item.owner
    if type(owner) == "table" then author = owner.name end
    local upper = item.upper
    if type(upper) == "table" then author = upper.name end
  end
  local cover = util.image(util.field(item, "pic", "cover"))
  if cover == nil then cover = util.image(overrides.cover) end
  -- 各接口时长字段不统一：search/view 用 duration，UP 投稿 vlist 用
  -- length（"MM:SS"），部分接口给 duration_seconds（秒）。统一按字符串/秒
  -- 交给 parse_duration，避免把秒再乘一次 1000。
  local duration = util.field(item, "duration", "length")
  if duration == nil then duration = util.field(item, "duration_seconds") end
  local duration_ms = util.parse_duration(duration)
  -- An explicit override wins: a caller that resolved one part knows the part's
  -- duration, while the row's `duration` is the whole collection.
  local forced = util.opt_number(overrides.durationMs)
  if forced ~= nil then
    duration_ms = forced
  elseif duration_ms == 0 then
    duration_ms = util.number(overrides.durationMs, 0)
  end
  local id = util.text(overrides.id)
  if id == "" then id = bvid end
  -- 标题只清一次、两处复用：`albumName` 也要这串字，各行再清一遍就会在
  -- 40 行/桶的预算上多付一次全扫（catalog.lua:36-51 的 408 悬崖）。
  local base_title = util.clean_title(util.field(item, "title"))
  local title = util.text(overrides.title)
  if title == "" then title = base_title end

  -- 专辑名 = 视频标题 · N P。T13/D3。
  --
  -- N 的来源按行的可得性分两种，**不猜**：
  --   * 列表行（popular / ranking / related / space_arc）与 view 都带 `videos`
  --     （实测 popular 20/20、ranking 97/97、related 40/40，view 顶层同名字段
  --     即分 P 数），直接用它；
  --   * search 行与收藏夹行**没有** videos（实测 0/20 与 0/19，见
  --     test/fixtures/search.json 与 fav_resources.json 的 `_note`），此时
  --     albumName 就是纯标题、**不加后缀**。留空串会让
  --     desktop_now_playing.dart:532 渲染一块零宽可点区域（该处无空值兜底），
  --     而猜一个数字会写出"这里其实只有 1 P"的假信息。T13/D4。
  --
  -- 谁想把这个 `else` 分支改成 `parts = 2` 之类的默认值，先读上一条注释。
  --
  -- **后缀只给多 P（parts >= 2）加**。T13/D3 原来写的是"统一加后缀"，用户
  -- 在真机看过宽屏专辑列之后改成这一条：单 P 行加 ` · 1 P` 只让专辑列与标题列
  -- 更像重复的一行字，而 ` · 1 P` 这个信息对"能不能选 P"没有帮助——1 P 的
  -- 视频本来就没有 P 可选。多 P 才是那个需要被看见的入口。
  --
  -- 因此 `parts == 1` 与 `parts == nil` 走同一条分支（纯标题）。区别只在于
  -- 前者是"确认只有 1 P"，后者是"不知道有几 P"——**两者的显示相同，是因为
  -- 两者的用户动作相同**（都不需要去专辑页挑 P），不是因为把未知当成 1。
  local parts = util.opt_number(overrides.parts)
  if parts == nil then parts = util.opt_number(util.field(item, "videos")) end
  if parts ~= nil and parts < 1 then parts = nil end
  local leave_album_blank = overrides.leaveAlbumBlank == true
  -- 标题裁剪（T13/T02）：宿主用 `maxLines:1 + overflow:ellipsis` 渲染整串
  -- （player_controls_bar.dart:131、desktop_now_playing.dart:532），省略号加在
  -- **整串末尾**。B站标题动辄 50 列以上，` · N P` 会被整段吃掉，入口又变回
  -- "看不出有几 P"。
  --
  -- 所以用 `util.fit_label`：**先量后缀，剩下的列数才给标题**。裁剪量与后缀
  -- 宽度联动，` · 100 P` 永远留得住；只裁标题到固定宽度再拼后缀是不够的，
  -- 那只是把后缀往前挪了一点。
  --
  -- 只裁 albumName，不裁 `title`：标题列有 flex:3 且用户要读全，专辑列是入口。
  --
  -- **没有 `videos` 的行不裁**（search / 收藏夹）：那时没有后缀要保护，裁了
  -- 只会白丢标题信息，还会破坏"albumName 与 title 逐字相同"这条 D4 的性质。
  -- T13#03/#04 钉的就是这条。
  -- `leave_album_blank` 是 S1（T14）的唯一开关，只有一个调用方会用：
  -- **没有 `videos` 的行**（search / 收藏夹）。
  --
  -- 为什么必须留空而不能"先写纯标题、等 song() 再改"：宿主的合并规则是
  --   album: entry.album.isEmpty ? updated.album : entry.album
  -- （music_platform_state.dart:635）。一旦队列条目里的 album 非空，之后
  -- `song()` 返回什么都进不来——播放页永远停在纯标题，用户看不到"N P"。
  -- 留空是让 `hydrate()` 有机会把它填成带后缀的那一版，而 hydrate 在每条
  -- 播放路径上都会被调用（app_state.dart 里 _loadCurrentArtwork 有 6 处
  -- 调用点）。
  --
  -- 代价（用户已确认接受）：搜索/收藏夹行在宽屏（>=940px）列表里那一列
  -- 专辑名变空白。原本那一列与标题逐字重复，空白反而比重复干净。
  --
  -- 传了这个参数的行，**任何情况下都不写 albumName**，包括 parts > 1 的
  -- 情况——但 search/收藏夹行本来就没有 parts，两条规则不会打架。
  local album_name = ""
  if bvid ~= "" and not leave_album_blank then
    local album_base = base_title
    if album_base == "" then album_base = "B站视频" end
    if parts ~= nil and parts > 1 then
      album_name = util.fit_label(album_base,
                                  " · " .. tostring(parts) .. " P",
                                  M.ALBUM_LABEL_COLUMNS)
    else
      album_name = album_base
    end
  end
  return {
    id = id,
    title = title,
    artists = { M.artist(mid, author) },
    albumId = bvid,
    albumName = album_name,
    coverUrl = cover,
    durationMs = duration_ms,
    contentType = "video/mp4",
  }
end

-- B站收藏夹 list-all 不返回封面；封面由 catalog 用第一个视频的 cover 回填。
-- 传入 cover_override 时优先用它，否则退回 folder 自带的 cover/pic。
--
-- `writable` and `owner` are what the host's collections() buckets on
-- (platform_catalog.dart:181-197):
--   personal   = isFavorites && (writable || owner == account.id)
--   created    = writable && id != personal.id
--   subscribed = !writable && id != personal.id
-- Omitting them made writable default to false and owner to null, so every
-- folder fell into `subscribed`, `created` stayed empty, and the "添加到歌单"
-- dialog listed only the synthesised "我喜欢的音乐" row.
--
-- `list-all` returns exactly the folders the signed-in account created, so
-- writable is true and owner is that account. `mid` is passed in rather than
-- read from the folder: the payload carries no owner field at all.
function M.playlist(folder, is_favorites, cover_override, mid)
  if type(folder) ~= "table" then folder = {} end
  local id = util.field(folder, "media_id", "id")
  local cover = util.image(cover_override)
  if cover == nil then cover = util.image(util.field(folder, "cover", "pic")) end
  local owner = util.text(mid)
  return {
    id = tostring(util.number(id, 0)),
    name = util.text(util.field(folder, "title", "name")),
    coverUrl = cover,
    songCount = util.number(util.field(folder, "media_count", "songCount"), 0),
    isFavorites = is_favorites == true,
    writable = owner ~= "",
    owner = owner ~= "" and owner or nil,
  }
end

function M.comment(item)
  if type(item) ~= "table" then item = {} end
  local member = type(item.member) == "table" and item.member or {}
  -- /x/v2/reply 的 content 是对象，正文在 content.message；部分接口和旧
  -- fixture 直接给字符串。util.text(table) 只会得到空串，所以先按类型取。
  local content = item.content
  local message
  if type(content) == "table" then
    message = util.text(content.message)
  else
    message = util.text(content)
  end
  if message == "" then message = util.text(item.message) end
  return {
    id = util.text(util.field(item, "rpid", "id")),
    content = message,
    author = util.text(member.uname),
    authorId = tostring(util.number(member.mid, 0)),
    avatarUrl = util.image(member.avatar),
    time = util.number(item.ctime, 0),
    liked = item.liked == true,
    likedCount = util.number(item.like, 0),
    replies = {},
  }
end

return M
