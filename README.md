# 🎵 Lazer Bilibili Music Plugin (哔哩哔哩插件)

把 **B 站当作曲库**的 [Lazer](https://github.com/chuxuehaocai/Lazer) Lua 插件：搜索、播放、歌词、收藏夹、排行榜、热门、相关推荐、UP 主投稿、评论、多分 P、扫码 / Cookie 登录。

纯 Lua 实现，无原生依赖，打包体积约 **57 KB**（15 个文件），运行在 Lazer 的隔离 Lua 插件沙箱里。

---

## ✨ 特性

- **扫码 / Cookie 双登录**：插件登录框点扫码 → B 站 App 确认即完成登录，登录态自动持久化；Cookie 粘贴作兜底。
- **搜索（WBI 签名）**：视频与 UP 主双桶检索，`w_rid` / `wts` 按官方 WBI 规则实时签名。
- **音频流**：`playurl` 自动选最高音质，可指定 `original` / `flac`；每路响应都带 `Referer`，裸请求必 403。
- **歌词**：以视频自带的字幕为主源（与视频同源、时间轴零误差），返回逐行 `lines[]` 交宿主合成；`lrclib` 仅作兜底。
- **发现**：首页热门、全站排行、相关推荐、UP 主投稿（自动翻页读全）、评论区（最新 / 热门双桶）。
- **多分 P**：`homeFeed.albums` / `albums` 暴露多 P 视频，`albumSongs` 列出各 P，曲目身份为 `bvid:cid`。首页专辑架只收**音乐区**（`pid_v2 == 1003`），单 P 投稿也是一个「1 首歌的专辑」。
- **收藏**：本人收藏夹、默认收藏夹喜欢列表、加/取消喜欢、添加到歌单、新建歌单（`csrf=bili_jct`）。
- **错误归一**：上游错误码统一映射成宿主可读状态，失败只回状态码，不泄露响应正文 / Cookie / 签名 URL。

---

## 📦 安装

### 方式一：Release ZIP

1. 打开本仓库的 [Releases](../../releases)，下载最新的 `community.bilibili.music.zip`。
2. Lazer → 设置 → 插件管理 → **导入 ZIP 插件**，选择该文件（**不要解压后改目录结构**，ZIP 根目录必须是 `manifest.json`）。
3. 列表出现「哔哩哔哩」并启用；首次联网会弹出网络授权，需要允许。
4. 在播放器音源切换列表选择「哔哩哔哩」。

### 方式二：本地构建

```bash
node tools/build.js        # 产出 dist/community.bilibili.music.zip + SHA-256
```

---

## 🔑 登录

| 方式 | 步骤 |
| :--- | :--- |
| **扫码**（推荐） | 登录框点扫码 → 用哔哩哔哩 App 扫二维码 → 在 App 里确认。扫码成功后 `poll` 的 `Set-Cookie` 会下发全套登录态，插件自动保存。 |
| **Cookie**（兜底） | 浏览器登录 `www.bilibili.com` → 开发者工具复制完整 Cookie（必须含 `SESSDATA` 与 `bili_jct`）→ 粘贴进登录框。 |

> 扫码报「不支持的二维码」时，先**重新打开登录页生成新码**（`qrcode_key` 有时效，复用旧码必然失败），再试 Cookie 登录。

---

## 🧩 操作契约

插件入口返回 `call(operation, args)`，实现了 Lazer v2.0.210 提供的以下操作：

| 分类 | 操作 |
| :--- | :--- |
| 元信息 | `describe` |
| 登录 | `qrKey` / `qrUrl` / `qrCheck`（800/801/802/803） / `loginCookie` / `session` / `logout` |
| 曲库 | `search` / `song` / `stream` / `lyrics` / `homeFeed` / `charts` / `recommendations` / `comments` |
| 歌单 | `playlists` / `playlistSongs` / `favorites` / `setFavorite` / `addToPlaylist` / `createPlaylist` / `artist` / `artistSongs` / `artistAlbums` |
| 多 P | `albumSongs` |

错误码归一：`-101/-400/401/301/302 → 40 → HTTP 401`；`-352 → 70`（可重试的匿名风控）；`-412/412 → 429`（风控限流）；未知 op 返回结构化 `error` 而不崩。

### 曲目身份：`bvid` 与 `bvid:cid`

曲目 id 可能是 `BV1xx411c7mD`（整个视频）或 `BV1xx411c7mD:43727326650`（精确到某一 P）。

- 所有 op 收到 song id 都先过 `ids.parse`，再从结果里取自己需要的部分：需要「整个视频」的接口（`view`/`playurl`/`reply`/`fav`）只用 `bvid`，需要「精确到 P」的接口（`stream`/`lyrics`/`song`）用 `bvid + cid`。
- 纯 `bvid` 的行为与旧版逐字节一致，宿主已有的歌词与播放缓存仍然命中。
- 榜单（`charts`）与首页热门（`homeFeed.featuredSongs`）的行自带 `cid`，因此这两块的 id 带冒号；搜索、相关推荐、收藏夹的行在真站响应里没有 `cid`，所以是纯 `bvid`。

### 分页语义

宿主用**返回行数**判定「还有没有下一页」（`hasMore = 返回行数 >= limit`），所以插件必须每次都返回 `min(limit, 剩余)` 行。

- 收藏夹远端页可能短于请求的 `ps`（失效稿件在服务端被过滤），页边界只按已取到页的实际长度累计定位。
- **越界页只证明「到头了」，不证明「有多少」**：`/x/v3/fav/resource/list` 在 `pn` 超过末页时同时返回 `medias: []` 和 `info.media_count: 0`。游标里的 `total` 只在非空页写入，另设 `proven`（真实读到的行数下界），两个停止条件分开。
- 评论页是严格位置切片，深 offset 直接跳页；收藏夹不能跳页，只能顺序走。
- **请求预算按族分开**：签名族（`search` / `space/arc` 的 WBI 请求）12 次，明文族 32 次。预算耗尽又没凑满 `limit` 时报可重试错误，**不返回短页**——短页等于把「读不到」伪装成「没有了」。
- **`search` 单次最多返回 35 行**：预算是按解码的行数计的，不是按 `limit`。超过的请求夹到 35 并标 `truncated`，而不是返回 408。
- **`albumSongs` 每页最多 100 个 P**：408 的真实成因是每行重复计算整视频级的量，把这些提到循环外后 100 行可以通过。空 `cid` 的 P 在切片之前就过滤掉，否则页会变短且宿主的下一个 `offset` 与下标错位。
- **`artistSongs` 每页 100 行**：宿主打开 UP 主页固定调 `artistSongs(limit=100, offset=0)`，插件连发两页 `ps=50`。页长**不能夹到 50**——宿主按「返回行数 >= limit」判 `hasMore`，50/100 会被读成「没有更多投稿」，第 51 条起永远不可达。v0.4.2 在这里 408 的原因是映射阶段的指令成本：`clean_title` 逐字节扫描每行标题，真机 38 字段/行的投稿页映射到第 86–95 行就撞满 250k 预算。v0.4.3 给无 `<` 且无 `&` 的标题加了快路径后，`limit=100` 一次返回 100 行，188 条与 900 条的 UP 主页 `all()` 全程零 408。
- **评论分两个桶**：`latest` 走时间序、可翻页，`total`/`hasMore` 只描述它；`hot` 只在 `offset=0` 请求一次，失败留空且不缓存，永远不参与分页。
- **专辑架候选集同源一份且限定音乐区**：`homeFeed.albums` 与 `albums()` 都读「热门 + 音乐区榜单（`rid=3`）原始行」，两层都过 `pid_v2 == 1003` 筛，按 bvid 去重（热门层在前），共用一个 6 h 缓存。单 P 行直接上架、零 `view` 请求；只有多 P 候选才花预算（上限 16 次尝试）。榜单失败时只丢榜单候选，且降级结果不写缓存。

---

## 🛠 源码结构

```text
manifest.json        id / provider / 能力 / 网络白名单
main.lua             操作路由、错误归一、media 规则
bili/util.lua        纯文本切分、时长解析、标题清洗（无 % 模式类、无 #string）
bili/errors.lua      上游错误码 → 宿主状态码归一
bili/ids.lua         bvid / bvid:cid 解析
bili/store.lua       持久化 Cookie + 内存 session / QR 态
bili/http.lua        host.http 包装：UA / Referer、buvid、set-cookie 吸收、错误映射
bili/wbi.lua         WBI salt 缓存与签名（w_rid = md5(query + salt)，注入 wts）
bili/models.lua      响应 → 客户端模型映射
bili/auth.lua        session / 扫码 / Cookie 登录 / logout
bili/pager.lua       统一分页器：远端聚合、本地切片、跳页、游标
bili/catalog.lua     搜索、详情、歌单、发现、评论、封面回填、专辑候选
bili/stream.lua      playurl → 音质选择 + Referer 头
bili/lyrics.lua      字幕三步主源 → lines[]，lrclib 兜底
```

实现中遇到的关键宿主约束（残版 Lua 5.3、250 000 指令预算、只有 14 个 host API）与踩坑结论，见 [docs/implementation.md](docs/implementation.md)。

---

## ✅ 测试

离线契约测试共 **140 个 test**：用 `LuaPluginRuntime` 加载真实的 `manifest.json` + `*.lua`，把确定性 JSON fixture 从 `httpHandler` 喂进去，全程不联网。

```bash
# 本仓库没有 pubspec.yaml，借 Lazer 源码树的 flutter 环境跑：
cp test/plugin_contract_test.dart <Lazer>/test/plugin_contract_test.dart
cd <Lazer>
PLUGIN_ROOT=/path/to/lazer-plugin-bilibili flutter test test/plugin_contract_test.dart
```

覆盖范围远超「插件返回了什么」，而是验证「宿主拿这个结果会怎么做」：

- 直接模拟宿主的 `hasMore`、`nextOffset` 与 `all()`；
- fixture 使用真站字段与真实末端行为（越界页的 `media_count: 0`、短页、缺 `count` 的非空页）；
- 每个测试独立 VM 与独立存储，消除状态串联；
- 负向控制：把 `chart_raw` 换回 `chart_rows`、把页长夹回 30，必须让一组断言变红，证明那些结构确实承重。

---

## ⚠️ 已知限制

- 只取音频流（`m4s` / FLAC），不含视频画面；音质靠 `quality` 参数，v2.0.210 无插件设置页扩展点。
- 搜索单次最多 35 行；`limit > 35` 时宿主会判定末页。
- 歌词主源依赖登录态；匿名时歌词不可用、UP 主页提示登录。8 小时以上的合集只取前 1200 行。
- **纯音乐会显示「重试」**：插件从不返回空歌词表。v2.0.210 会把空答复落成不带 `savedAt` 的 `pureMusic:true` 空壳且无法过期，所以「两个源都没有」一律报可重试错误，而不是「纯音乐」。
- UP 投稿接口受平台限制时可能为空列表，此时名字与头像仍正常显示。
- 高频访问可能触发 B 站风控（`-412`），插件返回结构化错误，不自动重试。
- 搜索页仍是 4 个 tab，其中专辑 / 歌单为空——B 站没有对应「专辑」层，收成 2 tab 需要改宿主 UI。
- 宿主 401 的统一文案是「请检查用户名和密码」，用于扫码场景略别扭，文案在宿主内写死。
- 不实现楼中楼、评论点赞与位置式 `removeFromPlaylist`（宿主传列表位置、B 站要 `aid`，映射错了会删错歌）。

---

## 🔒 隐私

`Cookie` / `SESSDATA` 仅保存在插件的 `lua_plugin_data` 存储沙箱，用于维持登录态。所有失败只返回状态码，不包含响应正文、Cookie 或签名 URL。

设备标识（`buvid3`/`buvid4`）同样只存在该沙箱里：它是风控需要的稳定设备态，不是凭据；不持久化的话每次 VM 重建都会换一个新设备号，反而更容易被风控。

重定向信任边界：同主机 30x 才吸收 `Set-Cookie`（合并基数是本次请求实际携带的 cookie），跨主机 30x 一行都不吸收且该链后续响应也不再吸收；最多 3 跳。

---

## 💖 鸣谢与参考来源

- [chuxuehaocai/Lazer](https://github.com/chuxuehaocai/Lazer) —— 宿主。插件的 `manifest` 契约、host API 集合、`lines[]` 歌词协议、错误码语义全部以它的实际行为为准。
- [licpp/BiliMusic-Desktop](https://github.com/licpp/BiliMusic-Desktop) —— **B 站接口与 WBI 签名的参考实现**。本插件的接口路径、参数与签名规则对照本项目（Tauri + Rust）的实现重写；插件是独立的 Lua 代码，不含其源码。
- [SocialSisterYi/bilibili-API-collect](https://github.com/SocialSisterYi/bilibili-API-collect) —— B 站 Web 接口的公开文档，用于核对 WBI 与登录流程。

---

## 📄 许可证

本项目遵循 MIT 协议开源，见 [LICENSE](LICENSE)。仅供技术学习与交流；音频内容版权归哔哩哔哩及相应版权方所有。
