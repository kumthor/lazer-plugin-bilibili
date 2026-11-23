# E12 前置门：歌词三态在双宿主上的落盘行为

日期：2026-11-21（Asia/Shanghai）
结论先行：**两版不一致 → 维持 `errors.throw("transient")`（code 70），不改 `{}`。**

---

## 1. 三态定义

| 态 | 含义 | 宿主应表现 |
|---|---|---|
| 有歌词 | 拿到时间轴 | 渲染歌词 |
| 暂不可用 | 网络/接口/CDN 失败 | "重试"，可恢复 |
| 确认无内容 | 两个源都答了、都没有 | 纯音乐，不该无限重试 |

第三态能不能用"返回空表"表达，取决于宿主拿到空表后**会不会把它写进盘**。

## 2. 2.0.210（发行版，真机）

### 2.1 空答复确实落盘，且落盘文件没有时间戳

盘上现存 22 个 `cached_lyrics/*.json`。历史空壳（`evidence/puremusic_backup/`）逐字节是：

```json
{"version":1,"lrc":null,"yrc":null,"tlyric":null,"ytlrc":null,"rlyric":null,"yromalrc":null,"ttml":null,"pureMusic":true}
```

键集合实测为 `version,lrc,yrc,tlyric,ytlrc,rlyric,yromalrc,ttml,pureMusic` —— **没有 `savedAt`**。

有歌词的条目同样没有 `savedAt`（`4dc46104….json`、`0dea44ab….json`、`30808ca9….json` 三个键集合一致）。

### 2.2 这条事实的含义

源码树 2.0.300 的 `lib/lyrics/cached_lyrics_store.dart:67-73` 是：

```dart
if (!payload.pureMusic) continue;
final savedAt = DateTime.tryParse(data['savedAt'] as String? ?? '');
if (savedAt == null) continue;               // 没有时间戳 = 视为过期
if (DateTime.now().toUtc().difference(savedAt) > pureMusicTtl) continue;
return payload;
```

`pureMusicTtl`（24 h）**只在 `savedAt` 存在时才有机会生效**。2.0.210 写出的空壳没有这个字段，所以在 2.0.300 的读逻辑下它们会被当成过期直接跳过。

但 2.0.210 自己的读逻辑不看 `savedAt` —— 这正是 T2/T3 两轮里空壳一旦落下就必须手工删盘才能恢复的原因（记录到 11 个 121 字节行，删完才有歌词）。**在 2.0.210 上，一次空答复 = 永久纯音乐。**

### 2.3 纯音乐曲目的真机取证

```
实测探针（E12 模式，抓本机真机响应）
== BV1GJ411x7h7 "【官方 MV】Never Gonna Give You Up - Rick Astley" cid=137649199 dur=213s
  player code=0 subtitle count=0
  lrclib hits=0
```

匿名态下：字幕列表为空、lrclib 无命中。这正是"确认无内容"的输入。若插件在此返回 `{}`，2.0.210 会写下 121 字节空壳，此后**该曲目再也不会被询问**——即使之后登录、或 B 站补了字幕。

## 3. 2.0.300（源码树，静态判定）

`lib/data/platform_catalog.dart:408-411`：

```dart
if (values.isEmpty) return const GatewayLyrics();
```

`GatewayLyrics()` 的 `pureMusic` 默认 `false`（`music_models.dart:337`）。随后 `app_state.dart:_readLyrics` 的 `publish()` 里 `cacheable = true`，调 `cataloh.lyricsCache.save(...)`；而 `cached_lyrics_store.dart:87`：

```dart
if (!payload.hasTimedLyric && !payload.pureMusic) return;
```

空 + 非 pureMusic → **直接 return，不落盘**。

所以在 2.0.300 上返回 `{}` 是安全的：空答复只是"这次没有"，不写盘、下次还会问。

## 4. 判定

| 宿主 | 返回 `{}` 的后果 |
|---|---|
| 2.0.210 | 落盘 121 B 空壳，无 `savedAt`，TTL 永不生效 → **永久纯音乐** |
| 2.0.300 | 不落盘，下次仍询问 → 安全 |

**不一致。** 按「两版行为不一致时不得改成空表」的判定：维持 `70`，并在 README 写明"2.0.210 上纯音乐会显示重试"。

这不是保守，是这台机器上的唯一正确选择：`minAppVersion` 就是 2.0.210，而它的读逻辑没有过期机制。

## 5. 落地

- `src/bili/lyrics.lua` 的末态保持 `errors.throw("transient")`，注释指向本文件；
- `README.md`「已知限制」写明代价；
- 契约断言 `T6#19`：两个源都空 → `code 70`；`T6#20`（原 `T6#19`）网络失败同样 `70` 但 `reason` 不泄露内容。

## 6. 若将来要改

前提是宿主版本抬高到带 `savedAt` 的一代（`minAppVersion` 提升，或检测到 `cached_lyrics` 条目含 `savedAt`）。届时应：

1. 先确认该版本写盘时带 `savedAt`；
2. 再把第三态改为返回 `{}`；
3. 加断言"empty 只在确认无字幕且 LRCLIB 无命中时返回"，网络失败仍 `70`。

在这三步完成前改这一条，等于把"暂时取不到"永久写死成"这首歌没有歌词"。
