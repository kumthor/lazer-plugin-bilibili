# evidence/ — 入库的实测读数

本目录**只收录文档与代码注释里直接引用过的读数**，用于让「某条结论来自哪次测量」可核对。完整证据链（抓包原样字节、变体源码、打包/安装日志）在本地开发目录，体积与身份信息不适合入库。

## 脱敏约定

入库前统一做了等长替换，**读数的形状与布局不变**：

| 原文 | 替换为 | 说明 |
| :--- | :--- | :--- |
| 被访问的 UP 主 mid | `7000003` / `7000004` | 投稿接口的被访问对象 |
| 本机账号 mid / 默认收藏夹 id | `7000002` / `7100001` | 插件作者的私有数据 |
| UP 主昵称 | `uploader_07x` 等 | 等字节 ASCII 占位 |
| 证据日志里引用的 UP 主 mid | `7000003` / `7000031` | 与 fixture 同一套占位 |
| `<本机>/bili-lazer-plugin/` | `<plugin>/` | 本地路径 |
| `<本机>/lazer-plugin-bilibili/` | `<repo>/` | 本地路径 |
| Lazer 用户数据目录 | `<lazer-data>` | 本机路径 |

两处注释提到但**未入库**的路径：`bili/lyrics.lua` 里的 `evidence/puremusic_backup/`（11 份宿主落盘的 `pureMusic:true` 空壳，含账号数据，只留在本地）、`evidence/t11/` 与 `evidence/t9/` 下的抓包原样字节与变体源码。`bili/lyrics.lua` 的注释保留该路径是因为它是那次测量的记录，不是可点链接。

`test/fixtures/space_arc_real_p1..p5.json` 是同一套真实投稿响应，做了**等字节**脱敏（标题/简介/作者/mid 全部占位，`&` 与 `<` 保留），所以解码成本与 `clean_title` 成本与真机一致——这是 `T11#01/#02` 能当成本断言用的前提。

## 索引

### T14 — 搜索页能不能便宜地拿到 P 数

| 文件 | 内容 |
| :--- | :--- |
| `t14/probe_search_variants.log` | 四种搜索变体：plain 412（被 ban）、`wbi/search/type?video` 20 行但 `withVideos=0`、`search/all/v2` 同理、番剧桶 0 行 |
| `t14/probe_batch_parts.log` | 66 个搜索字段全表（**无 `videos`、无 `pages`**）、逗号批量 `-400` |
| `t14/probe_search_parts_cost.log` | 逐行补 P 数的代价：搜索 697 ms，加 30 次 `pagelist` = 2 681 ms（+2.85×） |
| `t14/probe_pagelist.log` | `pagelist` 与 `view.pages` 逐行对照，30 行全部 `agree=true`；`pagelist` 串行不撞 250k 预算 |
| `t14/probe_pagelist.mjs` | 探针源码（只读公开接口，不写文件） |

### T13 — 多 P 视频的专辑名与列宽预算

| 文件 | 内容 |
| :--- | :--- |
| `t13/T00_list_duration.log` | 榜单 97 行 / 热门 20 行的多 P 分布；`BV1q4FTeBEMj` 行 `duration=25142` = 100 个 P 之和，P1 只有 228 s |
| `t13/FIT_LABEL_PROBE.log` | 直调生产代码的 `fit_label` 读数：7 组 budget/后缀/标题组合的 baseCols / suffixCols / **outCols** |
| `t13/CLIP_PROBE.log` | 本运行时按**字符**索引（`string.len("【")==1`），宽字符判定必须按码位而不是 UTF-8 首字节 |
| `t13/CLIP_FINAL.log` | 为什么第一版 `clip(24)` 不够、定稿算法、修前修后对照（33 列 → 31 列） |
| `t13/N_negative_controls.log` | N1–N7 七条负向控制的红/绿读数 |
| `t13/G_gates.log` | 静态门 12 项全 0 |
| `t13/W_dual_host_contract_final.log` | 双宿主 154/154（基线链 140→150→152→153→154） |
| `t13/PACKAGE.log` / `t13/INSTALL.log` | v0.4.6 打包 15/15 逐字节一致、安装 15/15 md5 一致 |
| `t13/SMOKE.log` | 从已安装目录跑真实网络：`albumName budget: samples=100 over32=0 widest=31` |

### T12 — 首页音乐架限定音乐区

| 文件 | 内容 |
| :--- | :--- |
| `t12/R1_music_ranking.log` | `rid=3` / `rid=0` 的行数、`videos` 分布与字段表 |
| `t12/R2_popular_tname.log` | 同一个 `tid` 跨分区出现（`tid=253` 动漫杂谈），故判据用 `pid_v2` |
| `t12/R5_popular_pid.log` | 热门 20 行的 `pid_v2` 分布：音乐区 0/20，且 `pid_v2=0` 是真实取值 |
| `t12/R6_music_ranking_score.log` | `score` 存在但恒为 0 |
| `t12/R7_music_ranking_zones.log` | `rid=3` 的分区分布：86/97 是音乐，11 行属其他区 |
| `t12/T01_sort_budget.log` | `table.sort` 在 97~100 行上把 `homeFeed` 推过 250k 预算（408） |
| `t12/G_gates.log` | 静态门 12 项全 0 |

### T11 — UP 主页 `artistSongs(limit=100)` 的 408
`artistSongs(limit=100)` 的 408

| 文件 | 内容 |
| :--- | :--- |
| `t11/capture_space_arc_report.json` | 真机抓包读数：pn=1..5，`code=0`，51 886 / 63 747 / 63 234 / 45 334 / 175 字节，50/50/50/38/0 行，`count=188` |
| `t11/R1_baseline.log` | 基线复现：`limit=20/50` 通过，`limit=100` 抛 408 |
| `t11/R2_breakdown.log` | 成本分解：`baseline=85/100`、`clean_title_fast=100/100`、`no_duration=95/100`、`no_artist=100/100` |
| `t11/R3_live.log` | 修复后真机端到端：188 行与 900 行两例，全程零 408 |
| `t11/N_no_fastpath.log` | 负向控制：去掉快路径后 `T11#01`/`T11#02` 变红、`T11#03` 仍绿 |

### T9 / T10 — 分页、评论双桶、首页专辑架

| 文件 | 内容 |
| :--- | :--- |
| `t9/R3_comments_latch.log` | 非空页缺 `count` 会把评论区永久钉在第一页 |
| `t9/R16_offline_cliff_hoist.log` | 把整视频级计算移出循环后离线 160 行通过 |
| `t9/R19_reply_sort_pages.log` / `t9/R29_reply_sort_live.log` | 评论 `sort=0/1/2` 的实测差别，`sort=2` 与 `1` 同义 |
| `t9/R20_album_host_hasmore_live.log` | 62 P 合集只开到第 30 P（页长夹取的代价） |
| `t9/R25_homefeed_chart_mapped.log` / `t9/R27_homefeed_chart_raw.log` | 映射后 408 vs 读原始行 6 请求正常 |
| `t10/G_contract.log` | v0.4.2 契约 134/134 |

### T8 — 搜索与收藏夹的边界

| 文件 | 内容 |
| :--- | :--- |
| `t8/R1_out_of_range.log` | 越界页同时返回空数组与 `media_count: 0` |
| `t8/R5_host_ceiling_offline.log` | 明文族 153–232 次、签名族 22–75 次被 408 打断 |
| `t8/R7_live_poison_open_folder.log` | 一次整夹读取把收藏夹毒成空 |
| `t8/R9_past_end_offline.log` | 60 条之后是空页，空页不携带总数 |
| `t8/R13_search_live_fine.log` / `t8/R17_search_decode_cliff.log` | 搜索真机 40 通过、45 是 408；离线 90 行通过、100 行 408 |
| `t8/R18_popular_videos.log` | 20 条热门全是单 P |
| `t8/R19_album_songs_cost.log` | 合集整页返回的代价 |
| `t8/G8_homefeed_cost_after.log` | 首页专辑架 0 → 5 的读数 |

### T7 / T6 — 请求预算、登录与歌词

| 文件 | 内容 |
| :--- | :--- |
| `t7/R2_artist_budget.log` | 签名族 14 次成功、17 页 408 |
| `t7/G0_capture_fields.log` | 各接口真站字段清单与行数 |
| `t7/capture_search.json` | 搜索响应样例（截断，仅留结构） |
| `t6/G0_old_code_red.log` | 旧代码的跨主机 `Set-Cookie` 泄漏与 buvid 断言失败 |
| `t6/G12_folder_add.log` / `t6/G12e_deal_delay.log` | 新建收藏夹的响应形状与写入延迟 |
| `t6/probe_reply_pages.txt` | 评论页严格位置切片，跨页零重复 |
| `t6/E12_puremusic_matrix.md` | 2.0.210 与 2.0.300 对空歌词答复的落盘差异 |
