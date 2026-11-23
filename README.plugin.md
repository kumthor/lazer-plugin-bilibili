# 哔哩哔哩（Lazer Lua 插件）

把 B 站当作曲库：搜索、播放、歌词、收藏夹、排行榜、热门、相关推荐、UP 主投稿、评论、多分 P、扫码 / Cookie 登录。改编自 BiliMusic 的接口实现，运行于 Lazer v2.0.210 的 Lua 插件宿主。

## 安装

1. 下载 `community.bilibili.music.zip`（不要解压后改目录结构，ZIP 根目录必须是 `manifest.json`）。
2. Lazer → 插件管理 → 导入 ZIP 插件 → 选择该 ZIP。
3. 列表出现「哔哩哔哩」并处于启用状态即可；首次联网会请求网络授权，需要允许。

## 登录

两种方式，任选其一：

- **扫码**（推荐）：插件登录框点扫码 → 用哔哩哔哩 App 扫二维码 → 在 App 里确认。已真机验证：扫码成功后自动下发并保存登录态，无需手动复制 Cookie。
- **Cookie**（兜底）：浏览器登录 `www.bilibili.com`，从开发者工具复制完整 Cookie（必须含 `SESSDATA` 与 `bili_jct`），粘贴到插件的 Cookie 登录框。缺少任一项会直接拒绝（不发出请求），因为缺 `bili_jct` 时收藏等写操作必然失败。

> 扫码若提示「不支持的二维码」：本插件 `qrUrl` 返回裸 URL 字符串（早期版本误返回 Lua table，被 Lazer 2.0.210 桥接成 `{hint:..., url:...}` 字符串而渲染成废码，已修复）。若仍失败，先**重新打开登录页生成新码**（`qrcode_key` 有时效，过期也会报此错），不要复用旧码；反复失败再用 Cookie 登录兜底。

## 能力

- 搜索（WBI 签名，秒级 `wts`）、单曲详情、音频流（按编码与带宽选档，可指定 `original`/`flac`）
- 歌词（B 站站内字幕为主源，语言优先级 人工中文 > `ai-zh` > 其他 `ai-*`；返回逐行时间轴由宿主合成；lrclib 仅作兜底）
- 首页热门、全站排行（id 形如 `chart:0`）、相关推荐、UP 主投稿、评论
- 多分 P：`homeFeed.albums` / `albums` 暴露多 P 视频，`albumSongs` 列出各 P，曲目身份为 `bvid:cid`；首页专辑架只收音乐区（`pid_v2 == 1003`），单 P 投稿也是「1 首歌的专辑」；专辑名带 ` · N P` 后缀，正在播放页因此能看出这里能选 P
- 登录后：本人收藏夹、默认收藏夹喜欢列表、加/取消喜欢、**添加到歌单**、**新建歌单**

## 曲目身份（`bvid` 与 `bvid:cid`）

v0.2.0 起，曲目 id 可能是 `BV1xx411c7mD`（整个视频）或 `BV1xx411c7mD:43727326650`（精确到某一 P）。

- **所有 op 收到 song id 都先过 `ids.parse`**，再从结果里取自己需要的部分：需要"整个视频"的接口（`view`/`playurl`/`reply`/`fav`）只用 `bvid`，需要"精确到 P"的接口（`stream`/`lyrics`/`song`）用 `bvid + cid`。
- 纯 `bvid` 的行为与旧版逐字节一致，宿主已有的歌词与播放缓存仍然命中。
- 榜单（`charts`）与首页热门（`homeFeed.featuredSongs`）的行**自带 `cid`**，因此这两块的 id 带冒号；搜索、相关推荐、收藏夹的行在真站响应里没有 `cid`（收藏夹只有 `ugc.first_cid`），所以那些 id 是纯 `bvid`。
- v0.3.1 修掉了一个只在这两块出现的缺陷：`setFavorite` 与 `comments` 曾把未解析的 id 整个拼进 `view?bvid=`，`:` 被编码成 `%3A`，真站返回 `-400`——榜单和首页热门的每一首点收藏、点评论都会失败，而同一首歌"加入歌单"却是好的。

## 专辑名（`albumName`）与分 P 入口

v0.4.5 起，`albumName` 不再是所有视频共用的泛名 `B站视频`，而是 `视频标题 · N P`。这条改动只为了"让人看出这里能选 P"：**正在播放页的专辑名是唯一不依赖列表的分 P 入口**（宽屏列表另有一列专辑名，点标题行只播 P1，那是宿主把列表本身当队列的结果，插件无法在队列层拆分）。

N 的来源按行的可得性分两类，**不猜**：

| 来源 | N 取自 | 实测依据 |
|---|---|---|
| `popular` / `ranking` / `related` / `space.arc` 行 | 行内的 `videos` | 依次 20/20、97/97、40/40、有（`evidence/t12/R1_music_ranking.log`、`R5_popular_pid.log`） |
| `view`（`song` / `albumSongs`） | `view.pages` 的条数 | 与 `videos` 一致（同一次对照实测） |
| `search` 行 | **留空**，等播放时由 `song()` 填 → `标题 · N P` | search 行不带 `videos`：真机 0/20（`test/fixtures/search.json` 的 `_note`） |
| 收藏夹行 | **留空**，同上 | 真机 0/19（`test/fixtures/fav_resources.json` 的 `_note`） |

**后缀只给多 P（`parts >= 2`）加。** 单 P 行显示纯标题：单 P 加 ` · 1 P` 只让专辑列与标题列更像重复的一行字，而 1 P 的视频本来就没有 P 可选，后缀帮不上忙。`albumId` 始终是 `bvid`，所以四类行都仍可点进专辑页。

### 为什么 search / 收藏夹行留空而不是写纯标题（v0.4.6）

v0.4.5 让这两类行写纯标题，结果是**用户点进播放页看不到「N P」**：宿主的队列合并规则是

```dart
// music_platform_state.dart:635
album: entry.album.isEmpty ? updated.album : entry.album,
```

只要队列条目里的 `album` 非空，之后 `song()` 返回什么都进不来，播放页永远停在纯标题。留空才能让 `hydrate()` 把它升级成带后缀的那一版——`_loadCurrentArtwork()` 在每条播放路径上都会被调用（`app_state.dart` 里 6 处）。

**代价（用户已确认接受）**：搜索与收藏夹行在宽屏（≥940px）列表里那一列专辑名变空白。原本那一列与标题逐字重复，空白反而比重复干净。

`albumKey` 来自 `albumId`（`platform_catalog.dart:33`），与名字无关，所以留空不影响 `hasAlbum`：那两列的点按仍能进专辑页。

**标题与后缀共用一个 32 列的整串预算**（`util.fit_label`，宽字符按 2 列算）。原因不是美观：宿主用 `maxLines: 1 + overflow: ellipsis` 渲染专辑名（`player_controls_bar.dart:131`、`desktop_now_playing.dart:532`），截断发生在**末尾**——60 列的 B站标题会把 ` · N P` 整段吃掉，专辑行又变回"看不出有几 P"。所以裁剪必须在插件侧做，而且**后缀宽度要先从预算里扣掉**：先量 ` · N P` 占几列，剩下的列数（再减掉省略号自己那 1 列）才给标题。只把标题裁到固定列数再拼后缀是不够的——那只是把后缀往前挪了几个字，宽屏专辑列照样放不下（实测：固定裁 24 列 + 8 列后缀 = 33 列 > 32 列预算，`evidence/t13/FIT_LABEL_PROBE.log`）。只裁 `albumName`，不裁 `title`（标题列有 `flex: 3`，用户要读全）。

**没有 `videos` 的行不裁也不写**（search / 收藏夹）：那时没有后缀要保护，裁了只会白丢标题信息；而写纯标题会让宿主把它钉死在队列里（见上一节），所以这两类行的 `albumName` 是空串。

`albumSongs` 的 N 取 `#pages` 而不是过滤掉空 `cid` 之后的条数：`albumName` 描述的是"这支视频有几 P"，不是"这里能播几 P"（`T13#05b`）。

**已知限制**：多 P 视频的列表行 `duration` 是整个合集的总时长（`ranking` 实测 `row=25142s` vs `P1=228s`，`evidence/t13/T00_list_duration.log`），而点那一行只播 P1。这是宿主不区分"容器 / 分片"的后果，插件侧零请求修不了，已登记给宿主。

## 榜单 id 形式

`charts()` 返回的 `id` 是 `chart:<rid>`（当前只有 `chart:0` = 全站排行），不是收藏夹的 `media_id`。

宿主读榜单的方式是 `charts()` 拿到 id，再对每个 id 调 `playlistSongs(id)`（`catalog.dart` 的 `providerCharts()`，两者在同一个 `Future.wait` 里）。旧版返回的 `rank:all` 会被原样发到 `/x/v3/fav/resource/list`，稳定返回 400，整个 `Future.wait` 抛错——榜单在界面上永远不出现。带前缀后 `playlistSongs` 能分清"这是榜单"还是"这是收藏夹"，一次 ranking 响应由 6 h 缓存共用。

## 收藏夹写路径

`playlists()` 的行现在带 `writable:true` 与 `owner:<mid>`。宿主按这两个字段分桶（`platform_catalog.dart` 的 `collections()`）：

```
personal   = isFavorites && (writable || owner == account.id)
created    = writable && id != personal.id
subscribed = !writable && id != personal.id
```

缺这两个字段时 `writable` 默认 false、`owner` 为 null，于是全部夹子落进 `subscribed`，`created` 恒空，播放器的「添加到歌单」弹窗只剩一条合成的「我喜欢的音乐」。

`addToPlaylist` 与 `createPlaylist` 与 `writable` 同版本上线：只补字段不补 op，会把"弹窗里 1 项能用"变成"4 项里 3 项点了必失败"。

`removeFromPlaylist` **不实现**。宿主传的是列表**位置**（`lua_music_gateway.dart:468-474`），B 站 `del_media_ids` 要的是 `aid`；位置与插件内分页游标只在下述条件下才一致，映射错了会删错歌。移除歌曲请到 B 站客户端操作。

## 分页语义（重要）

宿主用**返回行数**判定"还有没有下一页"（`hasMore = 返回行数 >= limit`），所以插件必须每次都返回 `min(limit, 剩余)` 行。

- 收藏夹远端页**短于请求的 `ps`**：失效稿件会在服务端被过滤（实测 `ps=40` 回 38 行、`ps=20` 回 19 行）。页边界只按已取到的页的实际长度累计定位。
- **越界页只证明"到头了"，不证明"有多少"**：`/x/v3/fav/resource/list` 在 `pn` 超过末页时同时返回 `medias: []` 和 `info.media_count: 0`（实测 `pn=4` 对 88 首的夹子，`evidence/t8/R1_out_of_range.log`）。因此游标里的 `total` **只在非空页上写入**，另有一个独立的 `proven`（本游标真实读到的行数下界）。两者分开维护才修掉了 v0.3.1 的"收藏夹打开是空的"：一次成功的整夹读取会顺带探到越界页，旧代码把那个 0 写进 `total`，之后同 key 的每次调用都在第一行提前返回，不发请求、不报错。评论的 `total` 同理——接口没给 `count` 时留空（宿主读成 0 = 未知），**绝不用请求偏移填充**。
- 收藏夹列表接口 `/x/v3/fav/folder/created/list-all` 一次返回全量（实测 6 行），**带 `pn` 会直接 `-400`**，所以在插件内本地切片。
- 评论页是**严格位置切片**（实测 `pn=1/2/3/4/5/10/20/33/66` 都是 20 行、跨页零重复），所以深 offset 直接跳页。
- **请求预算按族分开**，签名与明文不是同一种成本。两个数字都是对**实测范围**取的保守倍数，不是某一次测量的拷贝——宿主上限随载荷变化（行越长越贵），把单一数字写成常量正是上一版注释引用了一份不含该数字的日志的原因：明文族（`reply`/`fav_resource`/`popular`/`ranking`/`view`/`player`）实测在 153–232 次之间被 408 打断，取 **32**（4 倍以上余量）；签名族（`search`/`space/arc` 的 WBI 请求）实测随载荷在 22–75 次之间，取 **12**（低于最小观测值；每次签名还可能刷新 salt，`nav` 共用同一窗口）。测量条件与逐次读数见 `evidence/t8/R5_host_ceiling_offline.log`。v0.3.1 之前两族共用 32，导致 `artistSongs(offset≥800)` 直接把 VM 打挂。
- **`search` 单次最多返回 35 行**：宿主在 250k 指令预算下跑整条 `search`，而预算是按**解码的行数**计的，不是按 `limit`——两个桶（视频 + UP）各解一整页，实测 90 行通过、100 行 408（`evidence/t8/R17_search_decode_cliff.log`，`limit` 固定为 1 也一样）。真机 limit=40 通过、45 是 408（`R13`/`R14`）。旧代码 `cap=50` 让每桶解 50 行 = 100 行，所以任何 `limit` 都会 408——这才是"`search(limit=100)` 从来不可能成功"的真正原因。现在 `cap == 35`，一页一行、两桶共 70 行。超过 35 的请求**夹到 35 并在响应里标 `truncated`**，而不是返回 408：一个诚实的短页好过整页变成错误卡。注意宿主是按**返回行数**判末页的，所以 `limit > 35` 的调用方看到的是「35 行 = 到头了」——这正是下面那条已知限制，两处说的是同一件事，不矛盾。
- **`albumSongs` 单次最多返回 100 个 P（页长 = `min(limit, 剩余)`）**：`limit` 是**每页行数**，不是专辑上限。宿主按 `返回行数 >= limit` 判 `hasMore`、并按 `offset += 返回行数` 取下一页，所以满页就是"还有下一页"，短页就是"没有了"。v0.4.0 把页长夹到 30 来躲 408，结果是 62 P 的合集只开到第 30 个（`evidence/t9/R20_album_host_hasmore_live.log`）。408 的真实成因是**每行重复计算整视频级的量**（`clean_title`×2、`image`、`models.artist`），把这三项提到循环外后离线 160 行通过（`evidence/t9/R16_offline_cliff_hoist.log`），页长上限随之提到 100（= 宿主本来就用的页大小）。**空 `cid` 的 P 在切片之前就被过滤掉**，否则页会变短且宿主的下一个 `offset` 与下标错位（`T9#01b`）。
- **`search` 的 35 行夹取是已知限制**：超过 35 的请求会被夹到 35 并标 `truncated`。由于宿主按返回行数判末页，`limit > 35` 的调用方会**在第一次就被告知"没有更多"**——这是预算所迫的取舍，不是分页缺陷。
- **评论分两个桶**：`latest` 走 `sort=0`（时间序，可翻页，`total`/`hasMore` 只描述它）；`hot` 走 `sort=1`，**只在 `offset=0` 请求一次**，失败留空且不缓存，永远不参与分页。`sort=2` 与 `sort=1` 同义（实测点赞和都是 2 793 193，`evidence/t9/R29_reply_sort_live.log`），已停用。
- **专辑架的候选集同源一份，且两层都过音乐区筛**：`homeFeed.albums` 与 `albums()` 都读「热门 + 音乐区榜单（`rid=3`）**原始行**」，两层都要求 `pid_v2 == 1003`，按 bvid 去重（热门层在前），共用一个 6 h 缓存。`rid=3` 不是纯音乐区——实测 86/97 行是音乐、其余分属鬼畜/游戏/二次元等（`evidence/t12/R7_music_ranking_zones.log`），所以榜单行与热门行走同一道筛；`pid_v2 = 0` 是真实取值（`evidence/t12/R5_popular_pid.log`），判据必须是 `== 1003` 而不是「字段存在」。榜单**不按 `score` 重排**：97/97 行 `score` 全为 0，且 `table.sort` 在 97 行上把 `homeFeed` 推过 250k 预算直接 408（`evidence/t12/T01_sort_budget.log`）。真机 20 条热门全是单 P（`evidence/t8/R18_popular_videos.log`），只读热门的话专辑架恒空。**408 的成因是映射时机，不是榜单行数**：`chart_rows` 把 100 行映射成 song 形状（映射后没有 `videos`，且预算按解码行数计）会 408（`evidence/t9/R25_homefeed_chart_mapped.log`），只读原始行是 6 请求正常返回（`evidence/t9/R27_homefeed_chart_raw.log`）。榜单失败时**只丢榜单**：首页照常显示热门、专辑架退回热门候选，且这个降级结果**不写缓存**，下一次调用会重新尝试榜单（一次临时故障不会被钉 6 小时）；`albums()` 是显式浏览操作，榜单失败照旧上抛。
- 所以任何"从第 1 页走到第 66 页"的路径都不可行，跳页是必需的，不是优化。
- **截断必须可见**：翻页用尽预算又没凑满 `limit` 时，收藏夹/投稿族报可重试的 `code 70`，**不返回短页**。宿主按"返回行数 < limit"判末页，短页等于把"读不到"伪装成"没有了"（v0.3.1 之前 `offset=1200,limit=100` 会返回 80 行并让客户端收起列表）。已凑满 `limit` 的截断是完整页，照常返回。

## 已知限制

- 只取音频流（DASH `m4s` / FLAC），不含视频画面；音质选择通过参数，不提供设置页（v2.0.210 无该扩展）。
- 歌词取 B 站视频自带字幕（与视频同源、时间轴零误差），需要登录态；无字幕时才去 lrclib 按标题与艺术家打分匹配。
- **纯音乐会显示"重试"**：本插件从不返回空歌词表。E12 双宿主验证（`evidence/t6/E12_puremusic_matrix.md`）结论是两版行为不一致——2.0.300 拿到空答复不落盘（`cached_lyrics_store.dart:87` 直接 return），但 2.0.210 会落成 121 字节 `pureMusic:true` 空壳，且**该空壳不含 `savedAt`**，所以 2.0.300 的 24 h TTL 也救不回来。`minAppVersion` 是 2.0.210，因此"两个源都没有"一律报 `code 70`。代价是确认无字幕的纯音乐曲目会一直显示可重试的错误，而不是"纯音乐"。
- **UP 主页投稿按宿主的页大小整页返回**：宿主打开 UP 主页固定调 `artistSongs(limit=100, offset=0)`（`platform_catalog.dart:285-287`），插件为凑满 100 行连发两页 `ps=50`。**不能把页长夹到 50**：宿主按"返回行数 >= limit"判 `hasMore`，50/100 会被读成"没有更多投稿"，第 51 条起永远不可达。v0.4.2 在这里 408 的真实成因是**映射阶段的指令成本**，不是网络、不是解码、不是登录：两页各约 50–64 KB 的响应解码只花掉预算的一小部分，而 `clean_title` 对每一行做**逐字节**扫描（把每个字节 `string.sub` 出来塞进 table，再跑五遍 `M.replace` 解实体），一行 60 字节的标题约 150 条指令。真机 38 字段/行的投稿页上，映射到第 86–95 行就撞满 250k 预算（`evidence/t11/R2_breakdown.log`）。现在 `clean_title` 在**没有 `<` 且没有 `&`** 时直接 `M.trim` 返回——此时逐字节扫描的输出与原串逐字相同、五遍实体替换全是恒等变换，语义不变；带标记的标题仍走原路径（`T11#03` 逐字断言）。修复后 `limit=100` 一次调用返回 100 行，188 条投稿的 UP 主页 `all()` 走到 188 行、900 条走到 900 行，全程零 408（`evidence/t11/R3_live.log`）。
- **重型 fixture 是必需的**：`limit=100` 的契约测试原先用 6 字段短行（`_bulkVlist`），而真站每行 38 字段、标题最长 60 字节、部分标题自带 `&`。轻量行测出的"100 行全绿"不代表真机能过——这正是 T11 的覆盖缺口。`_realArcMode` 用 `evidence/t11` 落盘的**真机原样字节**（未再编码）跑 `T11#01`/`T11#02`，去掉 `clean_title` 快路径时这两条会精确变红（负向控制见 `evidence/t11/N_no_fastpath.log`）。
- UP 主页投稿接口 `/x/space/wbi/arc/search` 在 2026-11-21 曾对全部参数集返回 `-403 访问权限不足`；2026-11-22 复核已恢复（`mid=7000003` 与 `mid=7000031` 均 `code=0`，`evidence/t11/capture_space_arc_report.json`）。该接口被封锁时 UP 主页显示**空列表**而不是错误卡（`artistSongs` 对 `forbidden`/`ratelimit` 返回空页，其它失败照常抛），名字与头像仍正常显示。
- 分 P 入口覆盖热门流与音乐区榜单里的稿件（按行的 `videos >= 1` 判定，分类本身**零请求**）。**单 P 行也上架**：它就是一个 `songCount = 1` 的专辑，`albumSongs` 对它返回 1 行，这是真实值不是占位。只有 `videos > 1` 的候选才发 `view` 取自己的标题/封面与精确 P 数，上限 16 次尝试，6 h 缓存。
- UP 主页投稿在插件内自动翻页，单次调用最多 12 页（600 行）；更深的 offset 会返回可重试错误而不是静默截断。首次打开可能需要数秒（684 条实测 6.5 s），之后走宿主 30 分钟缓存。
- 高频访问可能触发 B 站风控：`-412`/HTTP 412/429 归为限流（`429`），**不自动重试**（插件没有 sleep 能力，立即重试只会加重封禁）；`-352` 是匿名风控，归为可重试的 `70` 而不是"登录失效"。
- **多 P 视频的列表行 `duration` 是整个合集的总时长**（实测某 100 P 合集行内 `25142 s`，而 P1 只有 `228 s`，`evidence/t13/T00_list_duration.log`），而点那一行只播 P1。这是宿主不区分「容器 / 分片」的后果（列表行就是一个队列项），插件侧零请求修不了：拿单 P 时长要逐行 `view`，`search` 一行的可支配预算已是零。
- 仅使用 v2.0.210 提供的 14 个 host API，向上兼容更新版本。

## 隐私

Cookie / SESSDATA 仅保存在本插件的 `lua_plugin_data` 存储沙箱，用于维持登录态；不会随错误信息外泄——所有操作失败只返回状态码，不含响应正文、Cookie 或签名 URL。

设备标识（`buvid3`/`buvid4`）同样只存在该沙箱里：它是风控需要的稳定设备态，不是凭据；不持久化的话每次 VM 重建都会换一个新设备号，反而更容易被风控。

信任边界（T6 §3.1）：

- **同主机 30x** → 吸收 `Set-Cookie`，合并基数是**本次请求实际携带的** cookie（不是存储里的值，否则会复活一个本次没发的 cookie）；
- **跨主机 30x** → 一行 cookie 都不吸收，且该链后续响应也不再吸收；会话 cookie 同时被剥离；
- 重定向最多 3 跳。

判据只有一条 `host_of(target) == host_of(url)`，在 `perform` 里决定——`absorb_set_cookie` 拿不到"本次请求带了什么"，让它推断就只能读存储，而那正是重定向不该被允许写的东西。
