// Offline contract test for the 哔哩哔哩 Lazer plugin.
// Run from the Lazer source tree:
//   flutter test test/plugin_contract_test.dart
// It loads the real src/*.lua through LuaPluginRuntime and feeds deterministic
// JSON fixtures through httpHandler, so no network is used.
//
// T5: the handler is programmable per endpoint kind. A test installs a page
// generator with `_paged(kind, fn)` and gets exactly the rows it returns for
// each (pn, ps) — including short pages, which is how deleted/restricted rows
// look on the wire. `_calls()` reports how many requests each kind received.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lazer_nextgen/plugins/lua_plugin_runtime.dart';
import 'package:lazer_nextgen/plugins/plugin_manifest.dart';

final String _srcRoot = Platform.environment['PLUGIN_ROOT'] ?? _findRepoRoot();
final String _fixturesRoot = '$_srcRoot/test/fixtures';

/// 本仓库没有 pubspec.yaml，要借 Lazer 源码树的 flutter 环境跑。那种情况下
/// 当前目录是 Lazer 根，所以优先用 PLUGIN_ROOT 指回本仓库；否则从当前目录
/// 向上找 manifest.json + main.lua。
String _findRepoRoot() {
  var dir = Directory.current.absolute;
  for (var i = 0; i < 6; i++) {
    if (File('${dir.path}/manifest.json').existsSync() &&
        File('${dir.path}/main.lua').existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return Directory.current.absolute.path;
}

// ---------------------------------------------------------------------------
// Request bookkeeping
// ---------------------------------------------------------------------------

final List<String> _requestUrls = <String>[];
final Map<String, int> _requestCounts = <String, int>{};
/// Every request's (url, headers), so a test can assert on what was actually
/// sent — a redirect's second hop is invisible from the plugin's return value.
final List<Map<String, dynamic>> _requestHeaders = <Map<String, dynamic>>[];

void _resetCalls() {
  _requestUrls.clear();
  _requestCounts.clear();
  _requestHeaders.clear();
}

/// Cookie header of the last request whose URL contains `needle`, or null.
String? _cookieFor(String needle) {
  for (var i = _requestHeaders.length - 1; i >= 0; i--) {
    final entry = _requestHeaders[i];
    final url = entry['url'] as String;
    if (url.contains(needle)) {
      final headers = entry['headers'];
      if (headers is Map) {
        final value = headers['Cookie'];
        return value is String ? value : null;
      }
      return null;
    }
  }
  return null;
}

/// kind -> number of requests observed.
Map<String, int> _calls() => Map<String, int>.from(_requestCounts);

int _callsOf(String kind) => _requestCounts[kind] ?? 0;

// ---------------------------------------------------------------------------
// Programmable fixture layer
// ---------------------------------------------------------------------------

typedef _PageFn = List<Map<String, dynamic>> Function(int pn, int ps);

/// What the endpoint really does when asked for a page past the last row.
///
/// The old fixture answered every page with the same shape: a page that had no
/// rows still reported the full `total`. That is not what the wire does, and it
/// is the reason T7's 87 tests could not see T8/D1 — an out-of-range page that
/// reports `media_count: 0` poisons the cursor, but a fixture that reports 88
/// there never produces the condition. Each family now declares its real
/// behaviour, and a static gate (C11) refuses a `_paged` call that omits it.
enum PastEnd {
  /// `/x/v3/fav/resource/list`: `medias: []` AND `info.media_count: 0`
  /// (measured live, evidence/t8/R1_out_of_range.log).
  zeroedCount,

  /// `/x/v3/fav/folder/created/list-all`: the endpoint ignores paging and
  /// returns the whole list, so "past the end" never happens.
  notPaged,

  /// `/x/web-interface/wbi/search/type`: an out-of-range page keeps reporting
  /// the real `numResults`.
  keepsTotal,

  /// `/x/v2/reply` (`-400`) and `/x/space/wbi/arc/search` (`-799`): the endpoint
  /// answers with a gateway error code instead of an empty page.
  errorCode,

  /// The page envelope simply omits its count while returning no rows — the
  /// shape a filtered or disabled thread has. `catalog.comments` already guards
  /// `if count > 0`, so this is the case where the plugin must say "unknown"
  /// rather than invent a number from the request offset.
  emptyNoCount,
}

/// kind -> page generator. Absent kind falls back to the static fixture.
final Map<String, _PageFn> _pages = <String, _PageFn>{};
/// keyword -> generator, `search` only (T15).
///
/// The six fresh words MUST be distinguishable. One shared generator makes every
/// word answer the same bvids, the plugin dedupes them by bvid, and the shelf
/// collapses to whatever that one page held — which is exactly how the first
/// version of these tests "passed" with 2 albums.
final Map<String, _PageFn> _keywordPages = <String, _PageFn>{};
/// keyword -> upstream gateway code, `search` only (T15#08/#09).
final Map<String, int> _keywordErrors = <String, int>{};
/// kind -> total row count reported by the endpoint (null = endpoint omits it).
final Map<String, int?> _totals = <String, int?>{};
/// kind -> what an out-of-range page answers with.
final Map<String, PastEnd> _pastEnds = <String, PastEnd>{};
/// kind -> 覆盖**非空页**上报的 count（null = 用 `_totals`）。
/// T9/T03 用它构造"页里有行、却报 count=0"这种自相矛盾的响应：
/// 旧代码会把 0 当权威总数写进游标，之后每次调用都在第一行返回空表。
final Map<String, int> _countOverrides = <String, int>{};
/// 整页完全不写 `count`/`acount` 字段（T9#18：非空页缺 count）。
final Set<String> _omitCount = <String>{};
/// kind -> upstream gateway code to answer with.
final Map<String, int> _forcedErrors = <String, int>{};
/// kind -> remaining 302 hops.
final Map<String, int> _redirects = <String, int>{};
/// 同域一跳 + 跨域一跳的两段重定向，用于验证 Cookie 剥离。
bool _crossHostRedirect = false;
/// `_redirect()` 的每一跳都留在同主机（T6#02 需要同域 30x 带 Set-Cookie）。
bool _sameHostRedirects = false;
/// 跨主机那一跳的响应是否带 Set-Cookie（T6#01：它不得写进会话）。
String? _offsiteSetCookie;
/// 同主机 30x 的响应是否带 Set-Cookie（T6#02）。
String? _sameHostRedirectSetCookie;
/// kind -> HTTP status to answer with (as opposed to a gateway `code`).
final Map<String, int> _httpStatus = <String, int>{};
/// kind -> number of remaining malformed-JSON answers (a `transient` failure).
final Map<String, int> _malformed = <String, int>{};
/// kind -> artificial latency.
final Map<String, int> _slowPaths = <String, int>{};

/// T10#11：单个 `view` 失败的 bvid 集合。真站上一条被删除/受限的视频会让
/// `view` 回 `-412`，而首页专辑架必须靠 feed 行回退，不能整架清空。
final Set<String> _viewErrorBvids = <String>{};

/// Register a paged fixture. `pastEnd` is REQUIRED: see [PastEnd] and gate C11.
void _paged(String kind, _PageFn fn, {int? total, required PastEnd pastEnd}) {
  _pages[kind] = fn;
  _totals[kind] = total;
  _pastEnds[kind] = pastEnd;
}

void _forcedError(String kind, int code) => _forcedErrors[kind] = code;

/// Register a per-keyword `search` generator (T15).
void _keyworded(String keyword, _PageFn fn) => _keywordPages[keyword] = fn;

/// Make one keyword answer with an upstream gateway code (T15#08/#09).
void _keywordError(String keyword, int code) => _keywordErrors[keyword] = code;

void _redirect(String kind, int hops) => _redirects[kind] = hops;

void _slowPath(String kind, int ms) => _slowPaths[kind] = ms;

void _httpError(String kind, int status) => _httpStatus[kind] = status;

/// Next `count` answers for `kind` are malformed JSON, which http.lua maps to
/// `transient` — the one failure the salt refresh is supposed to absorb.
void _malformedOnce(String kind, [int count = 1]) => _malformed[kind] = count;

void _resetFixtureLayer() {
  _crossHostRedirect = false;
  _sameHostRedirects = false;
  _offsiteSetCookie = null;
  _sameHostRedirectSetCookie = null;
  _httpStatus.clear();
  _malformed.clear();
  _pages.clear();
  _keywordPages.clear();
  _keywordErrors.clear();
  _totals.clear();
  _pastEnds.clear();
  _countOverrides.clear();
  _omitCount.clear();
  _forcedErrors.clear();
  _redirects.clear();
  _slowPaths.clear();
  _viewErrorBvids.clear();
  _favFoldersNoCover = false;
  _multiPart = false;
  _multiPartHot = <String>{};
  _rankingOverride = null;
  _multiPartParts = 3;
  _emptyCidAt = 0;
  _realArcMode = false;
}

// Kept as named switches so the T4 assertions keep reading naturally.
bool _bulkArcMode = false;
bool _favFoldersNoCover = false;
/// 多 P fixture 开关：view/player 都切到多 P 数据。
bool _multiPart = false;
/// T11：让 `space_arc` 返回**真机原样响应**（evidence/t11 落盘，未再编码）。
///
/// 这个开关存在的理由就是 T11 的覆盖缺口：`_bulkVlist` 每行只有 6 个短字段，
/// 而真站每行 38 个字段、标题最长 60 字节、还带 `&`（真实标题里确实有
/// "单人&多人合作"这种），`clean_title` 的逐字节扫描成本差一个数量级。用轻
/// 量行测出来的 "100 行全绿" 不代表真机能过。
bool _realArcMode = false;
/// `_multiPartView` 的分 P 数。默认 3；T8#19 需要 40 才能观测到 30 行夹取。
int _multiPartParts = 3;
/// 让第 N 个 P 的 `cid` 为空（1-based，0 = 关闭）。空 cid 的行无法播放，
/// 插件必须在切片**之前**把它过滤掉，否则页长与宿主 `nextOffset` 同时错位
/// （T9#01b）。前三个 P 的取值是 T5#33/T5#36/T6#17 的逐字断言对象，不得改动。
int _emptyCidAt = 0;
/// 热门流里哪几个 bvid 是多 P 的（T6#15/#16 用）。空集 = 全部单 P。
Set<String> _multiPartHot = <String>{};
/// 榜单响应的整段替换（T8#18 用）：让某个 ranking 行带上 videos>1，
/// 而其余行为仍是真站 fixture。null = 用静态 fixture。
String? _rankingOverride;

Map<String, dynamic> get _multiPartView => <String, dynamic>{
  'code': 0,
  'data': {
    'bvid': 'BVmulti00001',
    'aid': 170002,
    'title': '三 P 视频',
    'desc': '多分 P',
    'pic': 'https://i2.hdslb.com/bfs/archive/multi.jpg',
    'duration': 1500,
    'owner': {'mid': 888, 'name': '音乐收藏家'},
    // 前三个 P 的 cid 与 part 是既有约定（T5#33/T5#36/T6#17 逐字断言），
    // 第 4 个起顺延。扩展分 P 数不能改动已断言的取值。
    'pages': List.generate(_multiPartParts, (i) {
      const cids = <int>[1001, 2002, 3003];
      const parts = <String>['第一部分', '第二部分', '第三部分'];
      final cid = i < cids.length ? cids[i] : 3000 + (i + 1) * 1000;
      final part = i < parts.length ? parts[i] : '第${i + 1}部分';
      return {
        // T9#01b：空 cid 的行无法播放，映射时会被丢弃。这里模拟真站上
        // 一个 P 的 cid 缺失的形状，用来验证"先过滤再切片"。
        'cid': (_emptyCidAt == i + 1) ? '' : cid,
        'page': i + 1,
        'part': part,
        'duration': 400 + i * 100,
      };
    }),
  },
};

Map<String, dynamic> get _multiPartPlayer => <String, dynamic>{
  'code': 0,
  'data': {
    'bvid': 'BVmulti00001',
    'subtitle': {
      'subtitles': [
        {'lan': 'ai-zh', 'lan_doc': '中文（自动生成）',
         'subtitle_url': '//aisubtitle.hdslb.com/subtitle/test/multi.json'},
      ],
    },
  },
};

/// A view answer for an arbitrary bvid with `parts` parts. T6#15/#16 need the
/// probe to see a mix of single- and multi-part videos in one popular page.
Map<String, dynamic> _viewWithParts(String bvid, int parts) => <String, dynamic>{
  'code': 0,
  'data': {
    'bvid': bvid,
    'aid': 170000 + parts,
    'title': '热门 $bvid',
    'desc': '',
    'pic': 'https://i2.hdslb.com/bfs/archive/$bvid.jpg',
    'duration': 300 * parts,
    'owner': {'mid': 700, 'name': '热门UP'},
    'pages': List.generate(parts, (i) => {
      'cid': 1000 + i,
      'page': i + 1,
      'part': '第${i + 1}部分',
      'duration': 300,
    }),
  },
};

List<Map<String, dynamic>> _bulkVlist(int pn) => List.generate(50, (i) => {
  'bvid': 'BVbulk${pn}_$i',
  'title': '批量歌曲 $pn-$i',
  'author': 'UP$pn',
  'mid': 1000 + pn,
  'pic': '//i0.hdslb.com/bfs/bulk/$pn-$i.jpg',
  'length': '3:00',  // 真机 vlist 时长字段
});

/// Numbered video rows. `from` is a 1-based global row number.
List<Map<String, dynamic>> _videoRows(int from, int count, {String prefix = 'BVpg'}) =>
    List.generate(count, (i) {
      final n = from + i;
      return <String, dynamic>{
        'bvid': '$prefix$n',
        'title': '分页歌曲 $n',
        'author': 'UP$n',
        'mid': 2000 + n,
        'pic': '//i0.hdslb.com/bfs/pg/$n.jpg',
        'duration': '3:00',
      };
    });

List<Map<String, dynamic>> _commentRows(int from, int count) =>
    List.generate(count, (i) {
      final n = from + i;
      return <String, dynamic>{
        'rpid': 500000 + n,
        'content': {'message': '评论 $n'},
        'ctime': 1700000000 + n,
        'like': n,
        'member': {'uname': '用户$n', 'mid': 3000 + n, 'avatar': '//i0.hdslb.com/bfs/face/$n.jpg'},
      };
    });

List<Map<String, dynamic>> _folderRows(int from, int count) =>
    List.generate(count, (i) {
      final n = from + i;
      return <String, dynamic>{
        'id': 900000 + n,
        'title': n == 1 ? '默认收藏夹' : '收藏夹 $n',
        'media_count': n,
      };
    });

/// A real UP row from the same search endpoint (`search_type=bili_user`).
///
/// It must be populated in budget tests: the live ceiling is set by BOTH buckets
/// (measured 40 live vs 50 offline-with-an-empty-UP-bucket), so an empty artist
/// list measures a cheaper call than the host ever makes.
List<Map<String, dynamic>> _wireArtistRows(int from, int count) =>
    List.generate(count, (i) {
      final n = from + i;
      return <String, dynamic>{
        'type': 'bili_user',
        'mid': 3000 + n,
        'uname': '<em class="keyword">周杰伦</em>音乐收藏家$n',
        'usign': '分享无损音乐合集，日更，欢迎关注与收藏。这里有一句足够长的签名，用来贴近真站载荷。',
        'upic': '//i0.hdslb.com/bfs/face/$n.jpg',
        'fans': 10000 + n,
        'videos': 200 + n,
        'level': 6,
        'gender': 1,
        'official_verify': const <String, dynamic>{'type': 0, 'desc': ''},
        'res': const <String, dynamic>{},
        'is_live': 0,
        'room_id': 0,
        'verify_info': '',
        'face_nft_type': 0,
        'nft_icon': '',
      };
    });

/// A real search row, cloned from a live capture (`evidence/t7/capture_search.json`,
/// 66 keys, 1527 bytes) with only the identifying fields varied.
///
/// Byte size matters: the host runs the whole `search` op under a 250k
/// instruction budget, and both buckets decode one full page each regardless of
/// `limit`. A fixture row heavier than the wire (this one used to carry a
/// three-sentence description repeated into `desc`) makes even `limit=1` a 408,
/// which measures the fixture instead of B站. The capture's `description` is
/// empty, `tag` is ~130 bytes and `duration` is a string — kept exactly so.
List<Map<String, dynamic>> _wireSearchRows(int from, int count) =>
    List.generate(count, (i) {
      final n = from + i;
      final bvid = 'BVwire${n.toString().padLeft(5, '0')}';
      return <String, dynamic>{
        'type': 'video',
        'id': 113911642789603 + n,
        'author': '无损音乐合集$n',
        'mid': 1346923466 + n,
        'typeid': '267',
        'typename': '电台',
        'arcurl': 'http://www.bilibili.com/video/$bvid',
        'aid': 113911642789603 + n,
        'bvid': bvid,
        'title': '<em class="keyword">周杰伦</em> $n 歌曲精选100首 歌词版纯享 地表最高音质 每一首都是顶级文案 中国流行音乐开拓者JAY',
        'description': '',
        'pic': '//i0.hdslb.com/bfs/archive/25c409c43790cc13bf9ebc473b36c4f650527653.jpg',
        'play': 100000 + n,
        'video_review': 100 + n,
        'favorites': 5000 + n,
        'tag': '周杰伦,无损音质,音乐合集,高音质,后台播放,纯享版,歌词版,华语流行,经典老歌,车载音乐',
        'review': 20 + n,
        'pubdate': 1700000000 + n,
        'senddate': 1700000000 + n,
        'duration': '41:54',
        'badgepay': false,
        'hit_columns': const <String>['title'],
        'view_type': '',
        'is_pay': 0,
        'is_union_video': 0,
        'rec_tags': const <String, dynamic>{},
        'new_rec_tags': const <Object?>[],
        'like': 3000 + n,
        'upic': '//i1.hdslb.com/bfs/face/2b0f8f0d1c8e6c0d6c1f6d2a9f3c7a5e0d8b4c1a.jpg',
        'corner': '',
        'cover': '',
        'desc': '',
        'url': '',
        'rec_reason': '',
        'danmaku': 50 + n,
        'biz_data': const <String, dynamic>{},
        'is_charge_video': 0,
        'vt': 0,
        'enable_vt': 0,
        'vt_display': '',
        'subtitle': '',
        'episode_count_text': '',
        'release_status': 0,
        'is_intervene': 0,
        'area': 0,
        'style': 0,
        'cate_name': '',
        'is_live_room_inline': 0,
        'live_status': 0,
        'live_time': '',
        'online': 0,
        'rank_index': 0,
        'rank_offset': 0,
        'roomid': 0,
        'short_id': 0,
        'spread_id': 0,
        'tags': '',
        'uface': '',
        'uid': 0,
        'uname': '',
        'user_cover': '',
        'parent_area_id': 0,
        'parent_area_name': '',
        'watched_show': const <String, dynamic>{},
        'cny_flag': 0,
        'card_status': 0,
      };
    });

int _intParam(Uri uri, List<String> names, int fallback) {
  for (final name in names) {
    final value = int.tryParse(uri.queryParameters[name] ?? '');
    if (value != null) return value;
  }
  return fallback;
}

String? _kindOf(Uri uri, String method) {
  final path = uri.path;
  if (path.contains('/x/web-interface/nav')) return 'nav';
  if (path.contains('/x/web-interface/wbi/search/type')) {
    return uri.queryParameters['search_type'] == 'bili_user' ? 'search_user' : 'search';
  }
  if (path.contains('/x/web-interface/card')) return 'card';
  if (path.contains('/x/web-interface/view')) return 'view';
  if (path.contains('/x/player/playurl')) return 'playurl';
  if (path.contains('/x/player/wbi/v2') || path.contains('/x/player/v2')) return 'player';
  if (uri.host == 'aisubtitle.hdslb.com') return 'subtitle';
  if (path.contains('/x/v3/fav/folder/created/list-all')) return 'list_all';
  if (path.contains('/x/v3/fav/folder/add')) return 'folder_add';
  if (path.contains('/x/v3/fav/folder/del')) return 'folder_del';
  if (path.contains('/x/v3/fav/resource/list')) return 'fav_resource';
  if (path.contains('/x/v3/fav/resource/deal') && method == 'POST') return 'fav_deal';
  if (path.contains('/x/web-interface/popular')) return 'popular';
  if (path.contains('/x/web-interface/ranking/v2')) return 'ranking';
  if (path.contains('/x/web-interface/archive/related')) return 'related';
  if (path.contains('/x/space/wbi/arc/search')) return 'space_arc';
  if (path.contains('/x/v2/reply')) {
    // T9/T02: the two comment buckets are different endpoints as far as the
    // plugin is concerned — `sort=1` is the hot screen, `sort=0` is the time
    // ordered page that gets walked. Counting them as one kind made it
    // impossible to assert "hot is fetched once, and never again while paging".
    return uri.queryParameters['sort'] == '1' ? 'reply_hot' : 'reply';
  }
  if (path.contains('/x/passport-login/web/qrcode/generate')) return 'qr_generate';
  if (path.contains('/x/passport-login/web/qrcode/poll')) return 'qr_poll';
  if (uri.host == 'lrclib.net') return 'lrclib';
  return null;
}

/// Gateway code an endpoint answers an out-of-range page with, or null when the
/// endpoint returns an empty page instead.
int? _pastEndCode(String kind) {
  switch (kind) {
    case 'reply':
    case 'reply_hot':
      return -400; // measured: pn past the end is 请求错误, not an empty page
    case 'space_arc':
      return -799; // measured: -799 with an empty vlist (evidence/t8/R1_out_of_range.log)
    default:
      return null;
  }
}

/// Wraps paged rows in the envelope that endpoint really uses.
///
/// `rows.isEmpty` is the out-of-range case, and [PastEnd] decides what the
/// endpoint does there — the fixture must not paper over it (T8/D2).
String _envelope(String kind, int pn, int ps, List<Map<String, dynamic>> rows) {
  final total = _totals[kind];
  final past = _pastEnds[kind];
  final empty = rows.isEmpty;
  if (empty && past == PastEnd.errorCode) {
    final code = _pastEndCode(kind) ?? -400;
    return jsonEncode({'code': code, 'message': '请求错误', 'ttl': 1});
  }
  // `zeroedCount`: the wire zeroes media_count on a page with no rows. That is
  // the fact the old fixture got wrong.
  final overridden = _countOverrides[kind];
  final reportedTotal = empty && past == PastEnd.zeroedCount
      ? 0
      : (overridden ?? total ?? rows.length);
  // `emptyNoCount`: the count is absent entirely, not zero. The plugin must not
  // turn "no answer" into a number.
  final countField = <String, dynamic>{};
  final omitCount = (empty && past == PastEnd.emptyNoCount) || _omitCount.contains(kind);
  if (!omitCount) {
    countField['count'] = reportedTotal;
    countField['acount'] = reportedTotal;
  }
  switch (kind) {
    case 'search':
    case 'search_user':
      return jsonEncode({
        'code': 0,
        'data': {
          'numResults': reportedTotal,
          'page': pn,
          'pagesize': ps,
          'result': rows,
        },
      });
    case 'space_arc':
      return jsonEncode({
        'code': 0,
        'data': {
          'list': {'vlist': rows},
          'page': {'pn': pn, 'ps': ps, 'count': reportedTotal},
        },
      });
    case 'fav_resource':
      return jsonEncode({
        'code': 0,
        'data': {
          'medias': rows,
          'has_more': total == null ? rows.length >= ps : (pn * ps) < total,
          'info': {'media_count': reportedTotal},
        },
      });
    case 'reply':
    case 'reply_hot':
      return jsonEncode({
        'code': 0,
        'data': {
          'page': <String, dynamic>{
            'num': pn,
            'size': ps,
            ...countField,
          },
          'replies': rows,
        },
      });
    case 'list_all':
      return jsonEncode({
        'code': 0,
        'data': {'count': reportedTotal, 'list': rows},
      });
    case 'popular':
    case 'ranking':
      return jsonEncode({'code': 0, 'data': {'list': rows}});
    case 'related':
      return jsonEncode({'code': 0, 'data': rows});
    default:
      return jsonEncode({'code': 0, 'data': {'list': rows}});
  }
}

Future<Map<String, dynamic>> _handler(Map<String, dynamic> spec) async {
  final url = spec['url'] as String;
  final method = (spec['method'] as String? ?? 'GET').toUpperCase();
  final uri = Uri.parse(url);
  final kind = _kindOf(uri, method);
  _requestUrls.add(url);
  _requestHeaders.add(<String, dynamic>{
    'url': url,
    'headers': spec['headers'],
  });
  if (kind != null) {
    _requestCounts[kind] = (_requestCounts[kind] ?? 0) + 1;
  }

  final pn = _intParam(uri, const ['pn', 'page'], 1);
  final ps = _intParam(uri, const ['ps', 'page_size'], 20);

  // A test-installed generator wins over every static fixture.
  if (kind != null) {
    final slow = _slowPaths[kind];
    if (slow != null && slow > 0) {
      await Future<void>.delayed(Duration(milliseconds: slow));
    }
    if (_crossHostRedirect && kind == 'view') {
      if (uri.host == 'api.bilibili.com' && uri.queryParameters['bvid'] != 'hop2') {
        // First hop: same host, so the session cookie must survive.
        return {
          'status': 302,
          'headers': {'location': '/x/web-interface/view?bvid=hop2'},
          'body': '',
        };
      }
      if (uri.host == 'api.bilibili.com' && uri.queryParameters['bvid'] == 'hop2') {
        // Second hop: another PERMITTED host. It must still be reachable, or the
        // "no cookie" assertion would only prove the request was never sent.
        return {
          'status': 302,
          'headers': {'location': 'https://www.bilibili.com/x/web-interface/view?bvid=hop2'},
          'body': '',
        };
      }
      if (uri.host == 'www.bilibili.com') {
        // T6#01: an off-site answer that sets a cookie must NOT reach the
        // session store. Before T01 this overwrote SESSDATA.
        final headers = <String, dynamic>{};
        if (_offsiteSetCookie != null) headers['set-cookie'] = _offsiteSetCookie;
        return {'status': 200, 'headers': headers, 'body': _fixture('view')};
      }
    }
    final hops = _redirects[kind] ?? 0;
    if (hops > 0) {
      _redirects[kind] = hops - 1;
      final headers = <String, dynamic>{
        // Hop 1 crosses hosts (must drop Cookie); later hops stay relative —
        // unless the test wants a same-host chain, where every hop is relative.
        'location': (hops == 1 && !_sameHostRedirects)
            ? 'https://evil.example.com/x/web-interface/view?bvid=redir'
            : '/x/web-interface/view?bvid=redir',
      };
      // T6#02: a SAME-host 30x is allowed to set a cookie.
      if (_sameHostRedirectSetCookie != null) {
        headers['set-cookie'] = _sameHostRedirectSetCookie;
      }
      return {'status': 302, 'headers': headers, 'body': ''};
    }
    final forcedStatus = _httpStatus[kind];
    if (forcedStatus != null) {
      return {
        'status': forcedStatus,
        'headers': <String, dynamic>{},
        'body': '{"code":0,"data":{}}',
      };
    }
    final malformed = _malformed[kind] ?? 0;
    if (malformed > 0) {
      _malformed[kind] = malformed - 1;
      return {'status': 200, 'headers': <String, dynamic>{}, 'body': 'not json'};
    }
    final forced = _forcedErrors[kind];
    if (forced != null) {
      return {
        'status': 200,
        'headers': <String, dynamic>{},
        'body': jsonEncode({'code': forced, 'message': 'forced'}),
      };
    }
    final generator = _pages[kind];
    if (generator != null) {
      return {
        'status': 200,
        'headers': <String, dynamic>{},
        'body': _envelope(kind, pn, ps, generator(pn, ps)),
      };
    }
    // T15: the fresh shelf asks `search` once per word, so a single shared
    // generator is not enough — every word would answer the same bvids.
    if (kind == 'search') {
      final keyword = uri.queryParameters['keyword'] ?? '';
      final forcedKeyword = _keywordErrors[keyword];
      if (forcedKeyword != null) {
        return {
          'status': 200,
          'headers': <String, dynamic>{},
          'body': jsonEncode({'code': forcedKeyword, 'message': 'forced'}),
        };
      }
      final keywordPage = _keywordPages[keyword];
      if (keywordPage != null) {
        return {
          'status': 200,
          'headers': <String, dynamic>{},
          'body': _envelope('search', pn, ps, keywordPage(pn, ps)),
        };
      }
    }
  }

  final globalForced = _forcedErrors['*'];
  if (globalForced != null) {
    return {
      'status': 200,
      'headers': <String, dynamic>{},
      'body': jsonEncode({'code': globalForced, 'message': 'forced'}),
    };
  }

  String body = '{}';
  final headers = <String, dynamic>{};
  switch (kind) {
    case 'nav':
      body = _fixture('nav');
      break;
    case 'search':
      body = _fixture('search');
      break;
    case 'search_user':
      body = _fixture('search_user');
      break;
    case 'card':
      body = _fixture('card');
      break;
    case 'view':
      // A bvid the wire would refuse is refused here too (see _wireRefusedBvid).
      final requested = uri.queryParameters['bvid'] ?? '';
      if (_wireRefusedBvid(requested)) {
        body = jsonEncode({'code': -400, 'message': '请求错误', 'ttl': 1});
        break;
      }
      if (_viewErrorBvids.contains(requested)) {
        // T10#11：一条视频被删除/受限时 view 回 -412，首页不得因此清空整架。
        body = jsonEncode({'code': -412, 'message': '请求被拦截', 'ttl': 1});
        break;
      }
      if (_multiPart) {
        body = jsonEncode(_multiPartView);
      } else if (_multiPartHot.isNotEmpty) {
        // T6#15/#16: 只有 _multiPartHot 里的 bvid 是多 P 的。
        body = jsonEncode(_viewWithParts(requested, _multiPartHot.contains(requested) ? 3 : 1));
      } else {
        body = _fixture('view');
      }
      break;
    case 'playurl':
      body = _fixture('playurl');
      break;
    case 'player':
      body = _multiPart ? jsonEncode(_multiPartPlayer) : _fixture('player_wbi');
      break;
    case 'subtitle':
      // 多 P fixture 的第二 P 用另一份字幕，才能证明读的不是第一 P 的。
      body = _fixture(_multiPart ? 'multi_subtitle' : 'subtitle');
      break;
    case 'list_all':
      if (_favFoldersNoCover) {
        final parsed = jsonDecode(_fixture('fav_folders')) as Map<String, dynamic>;
        for (final f in (parsed['data']['list'] as List)) {
          (f as Map).remove('cover');
          f.remove('pic');
        }
        body = jsonEncode(parsed);
      } else {
        body = _fixture('fav_folders');
      }
      break;
    case 'fav_resource':
      body = _fixture('fav_resources');
      break;
    case 'fav_deal':
      body = _fixture('fav_deal');
      break;
    case 'folder_add':
      body = _fixture('fav_folder_add');
      break;
    case 'folder_del':
      body = jsonEncode({'code': 0, 'data': 0});
      break;
    case 'popular':
      body = _fixture('popular');
      break;
    case 'ranking':
      body = _rankingOverride ?? _fixture('ranking');
      break;
    case 'related':
      body = _fixture('related');
      break;
    case 'space_arc':
      if (_bulkArcMode) {
        body = jsonEncode({'code': 0, 'data': {'list': {'vlist': _bulkVlist(pn)}}});
      } else if (_realArcMode) {
        // 真机原样字节：不做任何再编码，解码成本与映射成本都必须是真实的。
        body = _fixture('space_arc_real_p$pn');
      } else {
        body = _fixture('space_arc');
      }
      break;
    case 'reply':
      body = _fixture('reply');
      break;
    case 'reply_hot':
      // T9/T02: the hot bucket must be distinguishable from the time-ordered
      // page. Same rpids on both would let a plugin that never changed `sort`
      // pass, because the host de-duplicates by id.
      body = _fixture('reply_hot');
      break;
    case 'qr_generate':
      body = _fixture('qr_generate');
      break;
    case 'qr_poll':
      body = _fixture('qr_poll');
      headers['set-cookie'] =
          'SESSDATA=fake; Path=/; Domain=.bilibili.com\nbili_jct=csrf123; Path=/';
      break;
    case 'lrclib':
      body = _fixture('lrclib');
      break;
    default:
      body = '{}';
  }
  return {'status': 200, 'headers': headers, 'body': body};
}

final _manifest = PluginManifest.fromJson(const {
  'id': 'community.bilibili.music',
  'name': '哔哩哔哩',
  'version': '0.6.1',
  'provider': 'bilibili',
  'apiVersion': 1,
  // 与 src/manifest.json 逐项一致（T6#21 会断言；D12 曾是这里停在 v0.1.0）。
  'capabilities': [
    'search', 'playlists', 'favorites', 'lyrics',
    'homeFeed', 'charts', 'recommendations', 'comments',
    'album', 'albumSongs', 'browseAlbums',
  ],
  'permissions': {
    'network': [
      'api.bilibili.com', 'passport.bilibili.com', 'www.bilibili.com',
      '*.hdslb.com', '*.bilivideo.com', '*.bilivideo.cn', 'lrclib.net',
    ],
    'storage': true,
  },
});

Map<String, String> _loadSources() {
  final sources = <String, String>{};
  final root = Directory(_srcRoot);
  // Relative to the configured root, not to a hard-coded "/src/" segment: the
  // same suite has to run against the archived pre-T5 tree for the red-first
  // evidence, and that tree has no "/src/" in its path.
  final prefix = '${root.path.replaceAll('\\', '/')}/';
  for (final entity in root.listSync(recursive: true)) {
    if (entity is File && entity.path.endsWith('.lua')) {
      final full = entity.path.replaceAll('\\', '/');
      final rel = full.startsWith(prefix) ? full.substring(prefix.length) : full;
      sources[rel] = entity.readAsStringSync();
    }
  }
  return sources;
}

String _fixture(String name) =>
    File('$_fixturesRoot/$name.json').readAsStringSync();

/// The real /x/web-interface/view answers -400 for a bvid it cannot parse, and a
/// `BV…:cid` id pasted into `bvid=` is exactly that case. The old handler
/// returned the view fixture for ANY bvid, so an unresolved identity looked
/// like a success and T7#07 passed on the pre-T7 code. Fixtures must reject
/// what the wire rejects or they certify bugs.
///
/// Deliberately narrow: only the colon is refused, because that is the defect
/// being reproduced. A full bvid validator would reject the suite's synthetic
/// ids (`hop2`, `BVhot00001`) and turn unrelated cases red for no reason.
bool _wireRefusedBvid(String value) => value.contains(':');

void _expectNoError(Object? value) {
  if (value is Map && value.containsKey('error')) {
    fail('unexpected error: ${value['error']}');
  }
}

List<dynamic> _rows(Object? value) => value is List ? value : <dynamic>[];

/// A Lua list crosses the bridge as `[]` when non-empty and `{}` when empty, so
/// every list-returning op is read through this instead of a hard `as List`.
List<dynamic> _list(Object? value) => value is List ? value : <dynamic>[];

/// T15：一条搜索行，字段名与真站一致。
///
/// 真站 `search` 行有 66 个字段且**没有** `videos` / `pid_v2`（0/20 实测，
/// evidence/t15/fresh_rows_ps20.json），所以这里也不能有 —— 客户端若靠
/// `videos` 决定上架，会在真机上把每一行都当成 0 条。
Map<String, dynamic> _freshRow(
  String bvid, {
  required String word,
  required int typeid,
  required String typename,
  required String duration,
  int play = 0,
  int like = 0,
  int pubdate = 1795493309,
  String? title,
  /// 真站 299/300 行都带 `tag`（逗号分隔的标签串），ASMR 通道的标记门会读它。
  /// 默认空串：真站缺失时就是空串，不是 nil。
  String tag = '',
}) =>
    <String, dynamic>{
      'type': 'video',
      'id': 117669403629708,
      'author': 'UP-$bvid',
      'mid': 3747570478221563,
      'typeid': typeid,
      'typename': typename,
      'arcurl': 'http://www.bilibili.com/video/$bvid',
      'aid': 117669403629708,
      'bvid': bvid,
      'title': title ?? '$word 的第 $bvid 条结果',
      'description': '',
      'pic': '//i0.hdslb.com/bfs/archive/$bvid.jpg',
      'play': play,
      'favorites': 0,
      'review': 0,
      'pubdate': pubdate,
      'senddate': pubdate,
      'duration': duration,
      'tag': tag,
      'like': like,
      'upic': '//i0.hdslb.com/bfs/face/$bvid.jpg',
      'danmaku': 0,
      'subtitle': '',
    };

///
/// `pid_v2` 必须写：真机 popular 20/20 行都带它（evidence/t12/R5_popular_pid.log），
/// 而音乐架只收 `pid_v2 == 1003` 的行。缺字段会被当成 0（非音乐区），
/// 于是「热门全单 P」这个 fixture 会连候选都进不去，测出来的空架不是被测行为。
/// 需要非音乐区的反例时传 `pidV2`。
List<Map<String, dynamic>> _singlePartHot(int count, {int pidV2 = 1003}) =>
    List.generate(count, (i) {
      final n = i + 1;
      return <String, dynamic>{
        'bvid': 'BVhot${n.toString().padLeft(5, '0')}',
        'title': '热门 $n',
        'pic': '//i0.hdslb.com/bfs/hot/$n.jpg',
        'duration': '3:00',
        'author': 'UP$n',
        'mid': 100 + n,
        'videos': 1,
        'pid_v2': pidV2,
      };
    });

/// 榜单行（真机 ranking/v2 每行都带 `pid_v2`，见 evidence/t12/R1_music_ranking.log）。
///
/// **必须**同时把 bvid 写进 `_multiPartHot`：fixture 的 `view`
/// 只对集合内的 bvid 承认多 P，否则 `view` 回 1 个 P、`songCount` 被 `#pages`
/// 覆盖成 1，"这是专辑"的断言会静默通过而实际只有 1 首（T10 §4 M6）。
List<Map<String, dynamic>> _multiPartRank(int count, {int videos = 3, int pidV2 = 1003}) =>
    List.generate(count, (i) {
      final n = i + 1;
      final bvid = 'BVrank${n.toString().padLeft(5, '0')}';
      return <String, dynamic>{
        'bvid': bvid,
        'title': '榜单 $n',
        'pic': '//i0.hdslb.com/bfs/rank/$n.jpg',
        'duration': '3:00',
        'owner': {'mid': 300 + n, 'name': 'UP$n'},
        'videos': videos,
        'pid_v2': pidV2,
      };
    });

/// T16：十词三通道。`asmr` 词给 `tid 21`（日常）**并且**标题里带通道标记 ——
/// 这是实现了的判据：ASMR 是唯一不能只看 `typeid` 的通道，因为它的行 71/120
/// 落在 21，而 21 同时也是最大的干扰源（evidence/t16/probe_asmr_channels.log）。
/// 标题由 `word` 拼出来，所以 ASMR / 助眠 / 白噪音 三个词的标题天然带标记；
/// 长/短词不带，21 里的长/短行因此会被正确拒掉（T16#06 就是这条反例）。
///
/// 热度形状是**故意让 play 与 play+like*10 排序相反**的：`play` 随 n 递减、
/// `like` 随 n 递增，权重 10 让总分反超。
///
///   n=1  -> play=190, like=0   -> play 排序第 1，总分 190   -> 总分排序第 20
///   n=20 -> play=0,   like=285 -> play 排序第 20，总分 2850 -> 总分排序第 1
///
/// 这样 N4（把公式换成单 play）才会真的让 T16#09 变红。
void seedFreshWords({
  int perWord = 20,
  int longTid = 228,
  int shortTid = 31,
  int asmrTid = 21,
}) {
  const words = <String, String>{
    'ASMR': 'asmr', '助眠': 'asmr', '白噪音': 'asmr',
    '有声书': 'long', '文学朗读': 'long', '听书': 'long', '讲座': 'long',
    '鬼畜': 'short', '歌切': 'short', '纯音乐': 'short',
  };
  const zoneName = <String, String>{
    'asmr': '日常', 'long': '人文历史', 'short': '翻唱',
  };
  const prefix = <String, String>{'asmr': 'BVA', 'long': 'BVL', 'short': 'BVS'};
  for (final entry in words.entries) {
    final channel = entry.value;
    final isLong = channel == 'long';
    final isAsmr = channel == 'asmr';
    _keyworded(entry.key, (pn, ps) => List.generate(perWord, (i) {
      final n = i + 1;
      return _freshRow(
        '${prefix[channel]}${entry.key.hashCode.abs() % 1000}'
        '${n.toString().padLeft(3, '0')}',
        word: entry.key,
        typeid: isAsmr ? asmrTid : (isLong ? longTid : shortTid),
        typename: zoneName[channel]!,
        duration: isAsmr ? '40:00' : (isLong ? '55:00' : '3:00'),
        // play 降、like 升：单看 play 与看 play+like*10 的顺序正好相反。
        play: (perWord - n) * 10,
        like: i * 15,
        title: '${entry.key} $n',
      );
    }));
  }
}

/// T16 预算门：把 `evidence/t16/fresh_rows_t16.json` 的**真站行**原样喂进去。
///
/// 这不是「形状像真站」，而是 2026-11-24 抓下来的原始字节（300 行 /
/// 465,598 B，66 字段/行，标题里带 `<em class="keyword">`，`description` 是
/// 整段简介）。用它跑 homeFeed 才能回答 T9/R25 那个问题：真实规模会不会 408。
///
/// 文件缺失时直接失败而不是造行 —— 造出来的短行会让这条门失去意义。
void seedRealisticFreshWords() {
  final capture = File('$_srcRoot/evidence/t16/fresh_rows_t16.json');
  expect(capture.existsSync(), isTrue,
      reason: '真站捕获缺失，预算门无从谈起：${capture.path}');
  final parsed = jsonDecode(capture.readAsStringSync()) as Map<String, dynamic>;
  final pages = parsed['pages'] as Map<String, dynamic>;
  final pageSize = parsed['pageSize'] as int;
  final words = (parsed['words'] as List).cast<Map>();
  expect(words.length, 10, reason: 'T16 是十词');
  expect(pages.length, words.length, reason: '每词都要有真站页');
  for (final entry in pages.entries) {
    final result = (entry.value as List).cast<Map<String, dynamic>>();
    expect(result.length, pageSize, reason: '${entry.key} 的真站页必须有 $pageSize 行');
    _keyworded(entry.key, (pn, ps) => result);
  }
}

void main() {
  late LuaPluginRuntime rt;
  late Directory dir;

  // Every test gets a fresh VM and a fresh storage directory. Sharing one
  // runtime leaked state between cases (a login from one test made `playlists`
  // work in the next, and pager cursors survived across unrelated fixtures),
  // which is exactly what made the old suite order-dependent.
  setUp(() async {
    _resetCalls();
    _resetFixtureLayer();
    dir = await Directory.systemTemp.createTemp('bili-contract-');
    rt = LuaPluginRuntime(
      manifest: _manifest,
      sources: _loadSources(),
      dataDirectory: dir.path,
      httpHandler: _handler,
      networkGranted: true,
      timeout: const Duration(seconds: 60),
    );
    await rt.start();
  });

  tearDown(() async {
    rt.close();
    await dir.delete(recursive: true);
  });

  // Ops that need a signed-in account say so instead of inheriting a login.
  Future<void> login() async {
    final user = await rt.invoke('loginCookie', {'cookie': 'SESSDATA=fake; bili_jct=csrf123'});
    expect(user, isNotNull, reason: '测试前置登录失败');
  }

  /// Same as [login] but with an explicit cookie, so a test can assert the
  /// stored value byte for byte (T6#01).
  Future<void> login2(String cookie) async {
    final user = await rt.invoke('loginCookie', {'cookie': cookie});
    expect(user, isNotNull, reason: '测试前置登录失败');
  }

  test('decode sources + describe', () async {
    final result = await rt.invoke('describe') as Map;
    _expectNoError(result);
    final providers = result['providers'] as List;
    expect(providers.length, 1);
    final provider = providers.first as Map;
    expect(provider['id'], 'bilibili');
    expect(provider['name'], '哔哩哔哩');
    expect((provider['auth'] as List), contains('qr'));
    expect((provider['auth'] as List), contains('cookie'));
  });

  test('search maps titles/covers/durations, wbi signed', () async {
    final result = await rt.invoke('search', {'query': '周杰伦', 'limit': 20, 'offset': 0}) as Map;
    _expectNoError(result);
    final songs = result['songs'] as List;
    expect(songs.length, 2);
    final first = songs.first as Map;
    expect(first['id'], 'BV1GJ411x7h7');
    expect(first['title'], '【无损音质】周杰伦歌曲精选100首');
    expect(first['coverUrl'], 'https://i0.hdslb.com/bfs/archive/test1.jpg');
    expect(first['durationMs'], 259000);
    expect((first['artists'] as List).first['name'], '音乐收藏家');
  });

  test('song returns detail with cid/extra', () async {
    final result = await rt.invoke('song', {'id': 'BV1GJ411x7h7'}) as Map;
    _expectNoError(result);
    expect(result['id'], 'BV1GJ411x7h7');
    expect(result['durationMs'], 259000);
    final extra = result['extra'] as Map;
    expect(extra['cid'], '1001');
    expect(extra['parts'], 1);
  });

  test('stream picks FLAC and carries Referer', () async {
    final result = await rt.invoke('stream', {'id': 'BV1GJ411x7h7', 'quality': 'original'}) as Map;
    _expectNoError(result);
    // T5/T04: contentType/suffix 必须反映真实编码，旧代码一律报 m4s/audio/mp4。
    expect(result['contentType'], 'audio/flac');
    expect(result['suffix'], 'flac');
    expect(result['bitRate'], 1500000);
    final headers = result['headers'] as Map;
    expect(headers['Referer'], 'https://www.bilibili.com/');
    expect((result['url'] as String).startsWith('https://'), isTrue);
  });

  test('lyrics builds synced lines[] from B站 ai-zh subtitle', () async {
    final result = await rt.invoke('lyrics', {'id': 'BV1GJ411x7h7'}) as List;
    expect(result.length, 1);
    final entry = result.first as Map;
    expect(entry['synced'], isTrue);
    expect(entry.containsKey('lrc'), isFalse, reason: '主源只给 lines, 不给 lrc');
    final lines = entry['lines'] as List;
    expect(lines.length, 3);
    final first = lines.first as Map;
    expect(first['text'], '稻香', reason: '♪ 应被 gsub 清掉, 首尾空格也去掉');
    expect(first['startMs'], 0);
    expect((lines[1] as Map)['startMs'], 3500);
    expect((lines[2] as Map)['text'], '跌倒了就不敢继续往前走');
  });

  test('session / cookie: loginCookie maps nav profile', () async {
    final cookie = 'SESSDATA=fake; bili_jct=csrf123';
    final result = await rt.invoke('loginCookie', {'cookie': cookie}) as Map;
    _expectNoError(result);
    expect(result['id'], '12345');
    expect(result['name'], '测试UP');
  });

  test('playlists/favorites mark the default folder', () async {
    await login();
    final lists = _list(await rt.invoke('playlists', {'limit': 20, 'offset': 0}));
    expect(lists.length, 2);
    expect((lists.first as Map)['isFavorites'], isTrue);
    expect((lists.last as Map)['isFavorites'], isFalse);
    final favs = _list(await rt.invoke('favorites', {'limit': 20, 'offset': 0}));
    expect(favs.length, 2);
    expect((favs.first as Map)['id'], 'BV1GJ411x7h7');
  });

  test('setFavorite writes with csrf', () async {
    await login();
    final result = await rt.invoke('setFavorite', {'id': 'BV1GJ411x7h7', 'favorite': true});
    expect(result, isTrue);
  });

  test('homeFeed/charts/recommendations/comments shapes', () async {
    final home = await rt.invoke('homeFeed') as Map;
    expect((home['featuredSongs'] as List).length, 2);
    final charts = await rt.invoke('charts') as List;
    // T6#06 起 id 带 `chart:` 命名空间（旧的 `rank:all` 会被当成 media_id 发出去）。
    expect((charts.first as Map)['id'], startsWith('chart:'));
    final recs = await rt.invoke('recommendations', {'limit': 10}) as List;
    expect(recs.length, 2);
    final comments = await rt.invoke('comments', {'id': 'BV1GJ411x7h7', 'limit': 20, 'offset': 0}) as Map;
    final latest = comments['latest'] as List;
    expect(latest.length, 2);
    expect(comments['total'], 2);
    // 真实 /x/v2/reply 的 content 是对象；正文必须取 content.message。
    expect(latest.first['content'], '好听！');
    expect(latest.last['content'], '支持');
  });

  test('artistSongs wbi signed with wts (UP 主页投稿，缺 wts 会 412)', () async {
    _requestUrls.clear();
    final raw = await rt.invoke('artistSongs', {'id': '888', 'limit': 20, 'offset': 0});
    // A Lua empty table arrives as {}; non-empty rows as [].
    final rows = raw is List ? raw : <dynamic>[];
    expect(rows.length, 2);
    expect((rows.first as Map)['id'], 'BV1arc0001');
    // UP 主页 vlist 用 length("MM:SS")，必须映射成毫秒，否则时长不显示。
    expect((rows.first as Map)['durationMs'], 390000);   // 6:30
    expect((rows[1] as Map)['durationMs'], 135000);      // 2:15
    final arcUrl = _requestUrls.firstWhere(
      (u) => u.contains('/x/space/wbi/arc/search'),
      orElse: () => fail('artistSongs did not call /x/space/wbi/arc/search'),
    );
    expect(arcUrl, contains('mid=888'));
    expect(arcUrl, contains('wts='));
    expect(arcUrl, contains('w_rid='));
  });

  test('artist / artistAlbums: UP 主页不再报 unsupported (资料加载失败)', () async {
    final artist = await rt.invoke('artist', {'id': '888'}) as Map;
    _expectNoError(artist);
    expect(artist['id'], '888');
    expect(artist['name'], '音乐收藏家');
    expect(artist['coverUrl'], 'https://i0.hdslb.com/bfs/face/creator.jpg');
    expect(artist['albumCount'], 0);
    final albums = await rt.invoke('artistAlbums', {
      'id': '888', 'limit': 30, 'offset': 0,
    });
    expect(albums, isEmpty);
  });

  test('QR generate -> URL -> poll 803 with set-cookie', () async {
    final key = await rt.invoke('qrKey');
    expect(key, 'ABCDEF123456');
    final details = (await rt.invoke('qrUrl', {'key': key})).toString();
    expect(details, contains('qrcode_key=ABCDEF123456'));
    expect(details, contains('from=main_web'));
    // Must be a BARE URL: a Lua table toString breaks QrImageView on 2.0.210.
    expect(details, startsWith('https://'));
    expect(details, isNot(contains('{hint')));
    final status = await rt.invoke('qrCheck', {'key': key});
    expect(status, 803);
  });

  test('budget gate: synced lines[] returned fast', () async {
    // 主源返回 lines[] 交给宿主合成时间轴, 整条链路必须远低于 10s 网关预算.
    final stopwatch = Stopwatch()..start();
    final result = await rt.invoke('lyrics', {'id': 'BV1GJ411x7h7'}) as List;
    stopwatch.stop();
    expect(result.first['lines'], isA<List>());
    expect(stopwatch.elapsedMilliseconds, lessThan(20000));
  });

  test('budget gate: 100 songs map without instruction overflow', () async {
    // T5/D8: 这条以前只断言 fixture 的 2 行, HTTP handler 从未切到 100 行数据,
    // 所以"预算门"是假通过。现在真喂 100 行并要求全部映射出来。
    //
    // T8/D3: 上限改成 35（真机 45 就 408），所以这条同时验证"夹取不丢行、
    // 不重复、顺序正确"，而不是验证一个不可达的 100。
    _paged('search', (pn, ps) => _videoRows((pn - 1) * ps + 1, ps), total: 100, pastEnd: PastEnd.keepsTotal);
    final result = await rt.invoke('search', {'query': 'bulk', 'limit': 100, 'offset': 0}) as Map;
    _expectNoError(result);
    final songs = result['songs'] as List;
    expect(songs.length, 35);
    expect((songs.first as Map)['id'], 'BVpg1');
    expect((songs.last as Map)['id'], 'BVpg35');
    expect(result['truncated'], isTrue);
  });

  test('unknown operation returns structured error, no crash', () async {
    final result = await rt.invoke('noSuchOp') as Map;
    expect(result.containsKey('error'), isTrue);
  });

  // ---- T4: 4 new contract assertions ----

  test('T4#16 search leaves albums and playlists empty', () async {
    final result = await rt.invoke('search', {'query': '周杰伦', 'limit': 20, 'offset': 0}) as Map;
    _expectNoError(result);
    final albums = result['albums'];
    final playlists = result['playlists'];
    expect(albums is List ? albums.isEmpty : (albums as Map).isEmpty, isTrue);
    expect(playlists is List ? playlists.isEmpty : (playlists as Map).isEmpty, isTrue);
  });

  test('T4#17 search artists carry UP row shape with albumCount 0', () async {
    final result = await rt.invoke('search', {'query': '周杰伦', 'limit': 20, 'offset': 0}) as Map;
    _expectNoError(result);
    final artists = (result['artists'] as List).cast<Map>();
    expect(artists.isNotEmpty, isTrue);
    final first = artists.first;
    for (final key in ['id', 'name', 'coverUrl', 'description', 'albumCount']) {
      expect(first.containsKey(key), isTrue, reason: 'missing $key');
    }
    expect(first['id'], '1745584728');
    expect(first['name'], '周杰伦');
    expect(first['albumCount'], 0);
  });

  test('T4#18 artistSongs aggregates two pages into 100 rows at limit=100', () async {
    _bulkArcMode = true;
    try {
      final result = await rt.invoke('artistSongs', {'id': '888', 'limit': 100, 'offset': 0});
      final rows = result is List ? result : <dynamic>[];
      expect(rows.length, 100);
      expect((rows.first as Map)['id'], 'BVbulk1_0');
      expect((rows.last as Map)['id'], 'BVbulk2_49');
    } finally {
      _bulkArcMode = false;
    }
  });

  test('T4#19 -412 maps to 429 throttle (T5: -352 moved to transient)', () async {
    // T5 §3.2 翻转了 -352 的归类：它是匿名风控而不是身份失效，归 401 会让客户端
    // 提示"检查用户名密码"，且 401 会让宿主停止重试。现归 transient(70)，
    // 由 T5#27 断言。
    _forcedError('*', -352);
    Map? a;
    try {
      a = await rt.invoke('lyrics', {'id': 'BV1GJ411x7h7'}) as Map?;
    } finally {
      _forcedErrors.remove('*');
    }
    expect(a != null && a.containsKey('error'), isTrue);
    expect(a!['error']['code'], 70);
    expect(a['error']['httpStatus'], isNull);

    _forcedError('*', -412);
    Map? b;
    try {
      b = await rt.invoke('lyrics', {'id': 'BV1GJ411x7h7'}) as Map?;
    } finally {
      _forcedErrors.remove('*');
    }
    expect(b != null && b.containsKey('error'), isTrue);
    expect(b!['error']['httpStatus'], 429);
  });

  test('cover fix: playlist without own cover falls back to first video cover', () async {
    _favFoldersNoCover = true;
    try {
      await login();
      final lists = _list(await rt.invoke('playlists', {'limit': 20, 'offset': 0}));
      expect(lists.length, 2);
      // fav_resources first media pic = //i0.hdslb.com/bfs/archive/a.jpg -> https
      expect((lists.first as Map)['coverUrl'],
             'https://i0.hdslb.com/bfs/archive/a.jpg');
      expect((lists.last as Map)['coverUrl'],
             'https://i0.hdslb.com/bfs/archive/a.jpg');
    } finally {
      _favFoldersNoCover = false;
    }
  });

  // ---- T5 / T01: pagination, duration, model filtering ----

  test('T5#21 search(limit=100) is clamped to 35 rows, ids 1..35', () async {
    // T8/D3: this test used to assert 100 rows on 6-field synthetic rows and
    // certify a limit the wire cannot serve. Real wire rows 408 at 45 live
    // (evidence/t8/R13_search_live_fine.log), so the contract is now "the clamp
    // happens and the rows are the first 35", not "100 arrives".
    _paged('search', (pn, ps) => _videoRows((pn - 1) * ps + 1, ps), total: 250, pastEnd: PastEnd.keepsTotal);
    final result = await rt.invoke('search', {'query': 'paging', 'limit': 100, 'offset': 0}) as Map;
    _expectNoError(result);
    final songs = result['songs'] as List;
    expect(songs.length, 35);
    expect((songs.first as Map)['id'], 'BVpg1');
    expect((songs.last as Map)['id'], 'BVpg35');
    expect(result['truncated'], isTrue);
  });

  test('T5#22 search(limit=100, offset=100) is rows 101..135, no overlap', () async {
    _paged('search', (pn, ps) => _videoRows((pn - 1) * ps + 1, ps), total: 250, pastEnd: PastEnd.keepsTotal);
    final first = await rt.invoke('search', {'query': 'paging', 'limit': 100, 'offset': 0}) as Map;
    final second = await rt.invoke('search', {'query': 'paging', 'limit': 100, 'offset': 100}) as Map;
    final firstIds = (first['songs'] as List).map((e) => (e as Map)['id']).toList();
    final secondIds = (second['songs'] as List).map((e) => (e as Map)['id']).toList();
    expect(secondIds.length, 35);
    expect(secondIds.first, 'BVpg101');
    expect(secondIds.last, 'BVpg135');
    expect(secondIds.toSet().intersection(firstIds.toSet()), isEmpty);
    // 旧代码 offset=100/limit=100 会把页号算成 3 且只回 50 行；现在 35 是
    // 明确的夹取结果，而不是算错页的副作用。
    expect(second['truncated'], isTrue);
  });

  test('T5#23 comments follow host offset arithmetic on short pages', () async {
    // 远端 ps=20 实际每页只回 15 条（折叠/过滤），总数 60。
    _paged('reply', (pn, ps) {
      final from = (pn - 1) * 15 + 1;
      if (from > 60) return <Map<String, dynamic>>[];
      final count = (from + 15 > 61) ? 61 - from : 15;
      return _commentRows(from, count);
    }, total: 60, pastEnd: PastEnd.errorCode);

    final a = await rt.invoke('comments', {'id': 'BV1GJ411x7h7', 'limit': 20, 'offset': 15}) as Map;
    final aRows = _list(a['latest']);
    expect(aRows.length, 20);
    expect((aRows.first as Map)['content'], '评论 16');

    final b = await rt.invoke('comments', {'id': 'BV1GJ411x7h7', 'limit': 20, 'offset': 35}) as Map;
    final bRows = _list(b['latest']);
    expect(bRows.length, 20);
    expect((bRows.first as Map)['content'], '评论 36');
    final bContents = bRows.map((e) => (e as Map)['content']).toList();
    for (var n = 21; n <= 35; n++) {
      expect(bContents.contains('评论 $n'), isFalse, reason: '第 $n 条被重复返回');
    }

    // 宿主真实形态：offset += 上一页实际收到的条数，4 轮不许重复、不许缺条。
    final seen = <String>[];
    var offset = 0;
    for (var round = 0; round < 4; round++) {
      final page = await rt.invoke('comments', {
        'id': 'BV1GJ411x7h7', 'limit': 20, 'offset': offset,
      }) as Map;
      final rows = _list(page['latest']);
      for (final row in rows) {
        seen.add((row as Map)['content'] as String);
      }
      if (rows.isEmpty) break;
      offset += rows.length;
    }
    expect(seen.length, seen.toSet().length, reason: '出现重复评论');
    for (var n = 1; n <= 60; n++) {
      expect(seen.contains('评论 $n'), isTrue, reason: '第 $n 条永久丢失');
    }
  });

  test('T5#24 playlists slices list-all locally: 150 folders -> 100/50/0', () async {
    // 真机实测 list-all 忽略 pn/ps 返回全量，所以 150 个夹子一次全来。
    _paged('list_all', (pn, ps) => _folderRows(1, 150), total: 150, pastEnd: PastEnd.notPaged);
    await login();
    final first = _list(await rt.invoke('playlists', {'limit': 100, 'offset': 0}));
    final second = _list(await rt.invoke('playlists', {'limit': 100, 'offset': 100}));
    final third = _list(await rt.invoke('playlists', {'limit': 100, 'offset': 200}));
    expect(first.length, 100);
    expect(second.length, 50);
    expect(third.length, 0);
    expect((first.first as Map)['id'], '900001');
    expect((first.last as Map)['id'], '900100');
    expect((second.first as Map)['id'], '900101');
    expect((second.last as Map)['id'], '900150');
  });

  test('T5#25a short page mid-offset returns 20 rows starting at global 16', () async {
    // ps=40 实测只回 38（失效稿件被过滤）；用 15 行/页把偏差放大。
    _paged('fav_resource', (pn, ps) {
      final from = (pn - 1) * 15 + 1;
      if (from > 90) return <Map<String, dynamic>>[];
      final count = (from + 15 > 91) ? 91 - from : 15;
      return _videoRows(from, count, prefix: 'BVshort');
    }, total: 90, pastEnd: PastEnd.zeroedCount);
    final rows = await rt.invoke('playlistSongs', {
      'id': '72000000', 'limit': 20, 'offset': 15,
    });
    final list = _rows(rows);
    expect(list.length, 20);
    expect((list.first as Map)['id'], 'BVshort16');
    expect((list.last as Map)['id'], 'BVshort35');
  });

  test('T5#25b a short page in the middle does not truncate the listing', () async {
    // 150 条，第 2 页只有 37 条（ps=40），其余满页。
    _paged('fav_resource', (pn, ps) {
      const sizes = <int>[40, 37, 40, 33];
      if (pn > sizes.length) return <Map<String, dynamic>>[];
      var from = 1;
      for (var i = 0; i < pn - 1; i++) {
        from += sizes[i];
      }
      return _videoRows(from, sizes[pn - 1], prefix: 'BVmid');
    }, total: 150, pastEnd: PastEnd.zeroedCount);
    await login();
    final rows = await rt.invoke('favorites', {'limit': 100, 'offset': 0});
    final list = _rows(rows);
    expect(list.length, 100);
    final ids = list.map((e) => (e as Map)['id']).toList();
    expect(ids.first, 'BVmid1');
    expect(ids.last, 'BVmid100');
    expect(ids.toSet().length, 100, reason: '出现重复行');
  });

  test('T5#26 parse_duration accumulates HH:MM:SS segments', () async {
    _paged('popular', (pn, ps) => <Map<String, dynamic>>[
      {'bvid': 'BVdur00001', 'title': '长视频', 'author': 'UP', 'mid': 1,
       'pic': '//i0.hdslb.com/bfs/hot/d1.jpg', 'duration': '1:02:03'},
      {'bvid': 'BVdur00002', 'title': '短视频', 'author': 'UP', 'mid': 1,
       'pic': '//i0.hdslb.com/bfs/hot/d2.jpg', 'duration': '6:30'},
      {'bvid': 'BVdur00003', 'title': '秒数', 'author': 'UP', 'mid': 1,
       'pic': '//i0.hdslb.com/bfs/hot/d3.jpg', 'duration': '213'},
      {'bvid': 'BVdur00004', 'title': '超长', 'author': 'UP', 'mid': 1,
       'pic': '//i0.hdslb.com/bfs/hot/d4.jpg', 'duration': '12:34:56'},
      {'bvid': 'BVdur00005', 'title': '空时长', 'author': 'UP', 'mid': 1,
       'pic': '//i0.hdslb.com/bfs/hot/d5.jpg', 'duration': ''},
      {'bvid': 'BVdur00006', 'title': '越界秒', 'author': 'UP', 'mid': 1,
       'pic': '//i0.hdslb.com/bfs/hot/d6.jpg', 'duration': '9:99'},
    ], pastEnd: PastEnd.notPaged);
    final home = await rt.invoke('homeFeed') as Map;
    _expectNoError(home);
    final songs = (home['featuredSongs'] as List).cast<Map>();
    expect(songs.length, 6);
    final byId = <String, int>{
      for (final s in songs) s['id'] as String: s['durationMs'] as int,
    };
    expect(byId['BVdur00001'], 3723000, reason: '旧代码返回 60000');
    expect(byId['BVdur00002'], 390000);
    expect(byId['BVdur00003'], 213000);
    expect(byId['BVdur00004'], 45296000, reason: '旧代码返回 720000');
    expect(byId['BVdur00005'], 0);
    expect(byId['BVdur00006'], 639000);
  });

  test('T5#26b rows without bvid are dropped, never emitted as id=""', () async {
    _paged('popular', (pn, ps) => <Map<String, dynamic>>[
      {'bvid': 'BVkeep0001', 'title': '有效', 'author': 'UP', 'mid': 1,
       'pic': '//i0.hdslb.com/bfs/hot/k.jpg', 'duration': '3:00'},
      {'title': '无 bvid', 'author': 'UP', 'mid': 1, 'duration': '3:00'},
      {'bvid': '', 'title': '空 bvid', 'author': 'UP', 'mid': 1, 'duration': '3:00'},
    ], pastEnd: PastEnd.notPaged);
    final home = await rt.invoke('homeFeed') as Map;
    _expectNoError(home);
    final songs = (home['featuredSongs'] as List).cast<Map>();
    expect(songs.length, 1);
    expect(songs.first['id'], 'BVkeep0001');
  });

  // ---- T5 / T02: transport + error model ----

  test('T5#27 -400 -> 400 (not 401), -412 -> 429, -352 -> 70 with no status', () async {
    _forcedError('*', -400);
    Map? param;
    try {
      param = await rt.invoke('song', {'id': 'BV1GJ411x7h7'}) as Map?;
    } finally {
      _forcedErrors.remove('*');
    }
    expect(param!['error']['httpStatus'], 400, reason: '旧代码把 -400 报成 401');
    expect(param['error']['code'], isNull);

    _forcedError('*', -412);
    Map? limited;
    try {
      limited = await rt.invoke('song', {'id': 'BV1GJ411x7h7'}) as Map?;
    } finally {
      _forcedErrors.remove('*');
    }
    expect(limited!['error']['httpStatus'], 429);

    _forcedError('*', -352);
    Map? risk;
    try {
      risk = await rt.invoke('song', {'id': 'BV1GJ411x7h7'}) as Map?;
    } finally {
      _forcedErrors.remove('*');
    }
    expect(risk!['error']['code'], 70);
    expect(risk['error']['httpStatus'], isNull,
        reason: 'httpStatus 必须留空：70 落在 400..599 之外才不会被宿主当成状态码');
  });

  test('T5#27b unsupported op -> code 501, not an auth failure', () async {
    final result = await rt.invoke('noSuchOp') as Map;
    final error = result['error'] as Map;
    expect(error['code'], 501);
    // 宿主规则：httpStatus 缺省时 400..599 的 code 会被当作状态码。
    expect(error['httpStatus'], isNull);
    expect(error['reason'], isNot(contains('SESSDATA')));
  });

  test('T5#28 wbi signs with a SECONDS wts and a 32-char salt', () async {
    _requestUrls.clear();
    await rt.invoke('search', {'query': '周杰伦', 'limit': 20, 'offset': 0});
    final signed = _requestUrls.firstWhere(
      (u) => u.contains('/x/web-interface/wbi/search/type'),
      orElse: () => fail('search did not sign its request'),
    );
    final uri = Uri.parse(signed);
    final wts = int.parse(uri.queryParameters['wts']!);
    final nowSeconds = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    // 秒级时间戳：与当前秒相差应在几分钟内。毫秒级会差 1000 倍。
    expect((wts - nowSeconds).abs(), lessThan(300),
        reason: 'wts 必须是秒，旧代码发的是毫秒');
    expect(uri.queryParameters['w_rid'], isNotNull);
    expect(uri.queryParameters['w_rid']!.length, 32);
  });

  test('T5#29 a rejected signature refreshes the salt exactly once', () async {
    // 第 1 次签名请求返回 -403（salt 过期），刷新后第 2 次成功。
    var calls = 0;
    _paged('search', (pn, ps) {
      calls++;
      return _videoRows(1, 2);
    }, pastEnd: PastEnd.keepsTotal);
    // 用 forcedError 模拟首次 -403：它作用于 kind=search 的所有请求。
    final before = _callsOf('search');
    _forcedError('search', -403);
    final failed = await rt.invoke('search', {'query': 'x', 'limit': 2, 'offset': 0}) as Map;
    expect(failed.containsKey('error'), isTrue);
    // 一次刷新 + 一次重试 = 2 次 search 请求（不含 nav）。
    expect(_callsOf('search') - before, 2);
    expect(calls, 0, reason: '两次都被 forcedError 拦下，未走到数据页');
  });

  test('T5#30 a failed favorite write is never replayed', () async {
    await login();
    _forcedError('fav_deal', -412);
    _resetCalls();
    final result = await rt.invoke('setFavorite', {'id': 'BV1GJ411x7h7', 'favorite': true}) as Map;
    expect(result.containsKey('error'), isTrue);
    expect(_callsOf('fav_deal'), 1, reason: '写请求不得自动重放');
  });

  test('T5#31 a 4-hop redirect chain stops at 3 and reports transient', () async {
    await login();
    _redirect('view', 4);
    final result = await rt.invoke('song', {'id': 'BV1GJ411x7h7'}) as Map;
    expect(result.containsKey('error'), isTrue);
    expect(result['error']['code'], 70, reason: '重定向超限是 transient');
  });

  test('T5#32 a cross-host redirect drops the session cookie', () async {
    await login();
    // 两跳：api.bilibili.com -> www.bilibili.com。后者在白名单内，所以第二跳
    // 真的会被发出——只有这样，"第二跳没有 Cookie"才证明是插件剥离的。
    _crossHostRedirect = true;
    try {
      _resetCalls();
      final result = await rt.invoke('song', {'id': 'BV1GJ411x7h7'});
      _expectNoError(result);

      final sameHost = _cookieFor('api.bilibili.com/x/web-interface/view?bvid=hop2');
      expect(sameHost, isNotNull, reason: '同域重定向必须保留 Cookie');
      expect(sameHost, contains('SESSDATA'));

      // 第二跳必须真的被发出：先确认请求记录里出现了跨主机的那一条。
      expect(
        _requestUrls.any((u) => u.contains('www.bilibili.com')),
        isTrue,
        reason: '第二跳必须真的被发出，否则"没有 Cookie"只是"没发请求"',
      );
      // 剥离得比"空串"更彻底：Cookie 头整个不出现。
      expect(_cookieFor('www.bilibili.com'), isNull,
          reason: '跨主机重定向必须剥离 Cookie，否则 SESSDATA 泄露给别的主机');
    } finally {
      _crossHostRedirect = false;
    }
  });

  test('T5#33 song(bvid:cid) resolves that part; plain bvid keeps the old id', () async {
    final plain = await rt.invoke('song', {'id': 'BV1GJ411x7h7'}) as Map;
    _expectNoError(plain);
    expect(plain['id'], 'BV1GJ411x7h7', reason: '纯 bvid 必须保持旧 id，旧缓存才命中');

    _multiPart = true;
    try {
      final second = await rt.invoke('song', {'id': 'BVmulti00001:2002'}) as Map;
      _expectNoError(second);
      expect(second['id'], 'BVmulti00001:2002');
      expect(second['title'], '第二部分');
      expect(second['durationMs'], 500000);
      final extra = second['extra'] as Map;
      expect(extra['cid'], '2002');
      expect(extra['parts'], 3);
      expect(extra['part'], 2);
    } finally {
      _multiPart = false;
    }
  });

  test('T5#34 stream(bvid:cid) requests that cid and never the first part', () async {
    _multiPart = true;
    try {
      _requestUrls.clear();
      final result = await rt.invoke('stream', {
        'id': 'BVmulti00001:2002', 'quality': 'high',
      }) as Map;
      _expectNoError(result);
      final playurl = _requestUrls.firstWhere(
        (u) => u.contains('/x/player/playurl'),
        orElse: () => fail('stream did not call playurl'),
      );
      expect(playurl, contains('cid=2002'));
      expect(playurl, isNot(contains('cid=1001')));
      expect(playurl, contains('bvid=BVmulti00001'));
    } finally {
      _multiPart = false;
    }
  });

  test('T5#35 lyrics(bvid:cid) reads that part, not the first one', () async {
    _multiPart = true;
    try {
      _requestUrls.clear();
      final result = await rt.invoke('lyrics', {'id': 'BVmulti00001:2002'}) as List;
      final player = _requestUrls.firstWhere(
        (u) => u.contains('/x/player/wbi/v2'),
        orElse: () => fail('lyrics did not call the player endpoint'),
      );
      expect(player, contains('cid=2002'));
      expect(player, isNot(contains('cid=1001')));
      expect(result, isNotEmpty);
      expect((result.first as Map)['lines'], isA<List>());
    } finally {
      _multiPart = false;
    }
  });

  test('T5#36 albumSongs returns one row per part, each with its own cid', () async {
    _multiPart = true;
    try {
      final rows = _list(await rt.invoke('albumSongs', {
        'id': 'BVmulti00001', 'limit': 100, 'offset': 0,
      }));
      expect(rows.length, 3);
      expect(rows.map((e) => (e as Map)['id']).toList(),
          ['BVmulti00001:1001', 'BVmulti00001:2002', 'BVmulti00001:3003']);
      expect((rows[1] as Map)['title'], 'P2 第二部分');
      expect((rows[1] as Map)['durationMs'], 500000);
      final album = await rt.invoke('album', {'id': 'BVmulti00001'}) as Map;
      expect(album['id'], 'BVmulti00001');
      expect(album['songCount'], 3);
    } finally {
      _multiPart = false;
    }
  });

  test('T5#36b a plain bvid still resolves the same track as before', () async {
    // 旧缓存键是纯 bvid：这条保证 bvid:cid 的引入没有打断它。
    final song = await rt.invoke('song', {'id': 'BV1GJ411x7h7'}) as Map;
    _expectNoError(song);
    expect(song['id'], 'BV1GJ411x7h7');
    final lyrics = await rt.invoke('lyrics', {'id': 'BV1GJ411x7h7'}) as List;
    expect(lyrics, isNotEmpty);
  });

  // ---- T5 / T06: cover budget ----

  test('T5#44 cover backfill is budgeted and cached across opens', () async {
    // 40 个夹子，list-all 不带 cover，每个都需要一次 ps=1 回填。
    _paged('list_all', (pn, ps) => _folderRows(1, 40), total: 40, pastEnd: PastEnd.notPaged);
    _paged('fav_resource', (pn, ps) => <Map<String, dynamic>>[
      {'bvid': 'BVcover0001', 'title': '封面来源',
       'pic': '//i0.hdslb.com/bfs/archive/cover.jpg', 'duration': '3:00',
       'author': 'UP', 'mid': 1},
    ], pastEnd: PastEnd.zeroedCount);
    await login();

    // 冷启动：只返回前 20 个夹子时最多 20 次回填。
    final cold = _list(await rt.invoke('playlists', {'limit': 20, 'offset': 0}));
    expect(cold.length, 20);
    expect(_callsOf('fav_resource'), lessThanOrEqualTo(20),
        reason: '单次调用最多 20 次封面请求');

    // 热启动：同一批夹子第二次打开不应再发请求（TTL 6h 内命中缓存）。
    _resetCalls();
    final warm = _list(await rt.invoke('playlists', {'limit': 20, 'offset': 0}));
    expect(warm.length, 20);
    expect(_callsOf('fav_resource'), 0, reason: '热启动必须全部命中封面缓存');
    expect((warm.first as Map)['coverUrl'],
        'https://i0.hdslb.com/bfs/archive/cover.jpg');
  });

  test('T5#44b an empty folder is cached as empty, not retried every open', () async {
    _paged('list_all', (pn, ps) => _folderRows(1, 2), total: 2, pastEnd: PastEnd.notPaged);
    // 空夹：medias 为空数组。
    _paged('fav_resource', (pn, ps) => <Map<String, dynamic>>[], pastEnd: PastEnd.zeroedCount);
    await login();

    final first = _list(await rt.invoke('playlists', {'limit': 20, 'offset': 0}));
    expect(first.length, 2);
    expect(_callsOf('fav_resource'), 2);
    expect((first.first as Map)['coverUrl'], isNull);

    _resetCalls();
    final second = _list(await rt.invoke('playlists', {'limit': 20, 'offset': 0}));
    expect(second.length, 2);
    expect(_callsOf('fav_resource'), 0, reason: '空夹不应每次打开都重试');
  });

  // ===========================================================================
  // T6 — trust boundary / capability reachability / silent failure
  // ===========================================================================

  /// The cookie the plugin persisted, read back from its own storage file.
  String? storedCookie() {
    final file = File('${dir.path}/storage.json');
    if (!file.existsSync()) return null;
    final map = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final value = map['session_cookie'];
    return value is String ? value : null;
  }

  // ---- T01: transport trust boundary ----

  test('T6#01 a cross-host redirect cannot rewrite the session cookie', () async {
    const login = 'SESSDATA=fake; bili_jct=csrf123';
    await login2(login);
    expect(storedCookie(), contains('SESSDATA=fake'));

    _crossHostRedirect = true;
    // The off-site answer offers a replacement session.
    _offsiteSetCookie = 'SESSDATA=STOLEN_FROM_REDIRECT; Path=/; Domain=.bilibili.com';
    try {
      final result = await rt.invoke('song', {'id': 'BV1GJ411x7h7'});
      _expectNoError(result);
      // The request really left the origin, so "unchanged" is meaningful.
      expect(_requestUrls.any((u) => u.contains('www.bilibili.com')), isTrue,
          reason: '第二跳必须真的发出，否则"没被改写"只是"没发请求"');
      expect(storedCookie(), login,
          reason: '跨主机 30x 与它之后的响应都不得写会话');
      expect(storedCookie(), isNot(contains('STOLEN')));
    } finally {
      _crossHostRedirect = false;
      _offsiteSetCookie = null;
    }
  });

  test('T6#02 a same-host 30x merges into the cookie the request carried', () async {
    const login = 'SESSDATA=fake; bili_jct=csrf123';
    await login2(login);
    // Two hops, both same-host; every hop sets a new field.
    _sameHostRedirects = true;
    _redirect('view', 2);
    _sameHostRedirectSetCookie = 'buvid3=FROM_REDIRECT; Path=/';
    try {
      final result = await rt.invoke('song', {'id': 'BV1GJ411x7h7'});
      _expectNoError(result);
      final after = storedCookie();
      expect(after, contains('buvid3=FROM_REDIRECT'),
          reason: '同主机 30x 的 Set-Cookie 必须并入');
      expect(after, contains('SESSDATA=fake'),
          reason: 'merge base 是本次请求携带的 cookie，既有登录态不能被丢掉');
    } finally {
      _sameHostRedirectSetCookie = null;
      _sameHostRedirects = false;
    }
  });

  test('T6#03 -412 produces exactly one search request and no extra nav', () async {
    _forcedError('search', -412);
    _resetCalls();
    final result = await rt.invoke('search', {'query': 'x', 'limit': 2, 'offset': 0}) as Map;
    expect(result.containsKey('error'), isTrue);
    expect(result['error']['httpStatus'], 429);
    // 旧代码：pcall 捕获后无条件 invalidate + 重试 → searchCalls=2、navCalls=2。
    expect(_callsOf('search'), 1, reason: '限流不重试：重试即加码');
    expect(_callsOf('nav'), 1, reason: '只有首次签名取 salt，不得因限流再取一次');
  });

  test('T6#04 a transient signature failure still refreshes the salt once', () async {
    // nav 第一次回坏 JSON → fetch_salt 抛 transient → 刷新并重试一次 → 第二次成功。
    _malformedOnce('nav');
    _resetCalls();
    final result = await rt.invoke('search', {'query': 'x', 'limit': 2, 'offset': 0}) as Map;
    _expectNoError(result);
    // 一次失败 + 一次重试 = 2 次 nav；重试后签名成功，search 只发 1 次。
    expect(_callsOf('nav'), 2, reason: 'transient 必须刷新 salt 重试一次');
    expect(_callsOf('search'), 1, reason: '重试成功后只发一次业务请求');
  });

  test('T6#05 positive HTTP codes are classified, not lumped into transient', () async {
    for (final entry in const [[403, 403], [404, 404], [400, 400], [412, 429]]) {
      _httpError('view', entry[0]);
      Map? result;
      try {
        result = await rt.invoke('song', {'id': 'BV1GJ411x7h7'}) as Map?;
      } finally {
        _httpStatus.remove('view');
      }
      expect(result != null && result.containsKey('error'), isTrue,
          reason: 'HTTP ${entry[0]} 应报错');
      expect(result!['error']['httpStatus'], entry[1],
          reason: 'HTTP ${entry[0]} 应映射成 ${entry[1]}');
    }
  });

  // ---- T02: capability id consumability ----

  test('T6#06 playlistSongs(charts[0].id) returns the chart, not a fav request', () async {
    _resetCalls();
    final charts = _list(await rt.invoke('charts'));
    expect(charts.length, 1);
    final id = (charts.first as Map)['id'] as String;
    expect(id, startsWith('chart:'), reason: 'id 必须带命名空间，否则和 media_id 混淆');
    final rows = _list(await rt.invoke('playlistSongs', {'id': id, 'limit': 100, 'offset': 0}));
    expect(rows.length, 1);
    // T7/T00: the ranking fixture now carries the `cid` the real endpoint always
    // sends, so this row's identity is `bvid:cid` — the exact shape that made
    // setFavorite/comments answer 400 before T7/T01. Asserting the plain bvid
    // here is what let that defect live through 73 tests.
    expect((rows.first as Map)['id'], 'BV1rank001:43796138001');
    expect((rows.first as Map)['albumId'], 'BV1rank001');
    expect(_callsOf('fav_resource'), 0, reason: '榜单 id 绝不能打到收藏夹接口（旧代码 400）');
  });

  test('T6#07 charts() then playlistSongs() is one ranking request', () async {
    _resetCalls();
    final charts = _list(await rt.invoke('charts'));
    expect(_callsOf('ranking'), 1);
    await rt.invoke('playlistSongs', {
      'id': (charts.first as Map)['id'], 'limit': 100, 'offset': 0,
    });
    expect(_callsOf('ranking'), 1, reason: '共用一次响应，面板打开不得打两次 ranking');
  });

  test('T6#08 a numeric media_id still takes the favourite branch', () async {
    await login();
    _resetCalls();
    final rows = _list(await rt.invoke('playlistSongs', {'id': '72000000', 'limit': 20, 'offset': 0}));
    expect(rows.length, 2);
    expect(_callsOf('fav_resource'), greaterThan(0), reason: '数字 id 必须仍走收藏夹');
    expect(_callsOf('ranking'), 0);
  });

  test('T6#09 playlist rows carry writable and owner; default folder is favorites', () async {
    await login();
    final lists = _list(await rt.invoke('playlists', {'limit': 20, 'offset': 0}));
    expect(lists.length, 2);
    for (final row in lists.cast<Map>()) {
      expect(row['writable'], isTrue, reason: 'list-all 返回的就是本人创建的夹子');
      expect(row['owner'], '12345');
    }
    expect((lists.first as Map)['isFavorites'], isTrue);
    expect((lists.last as Map)['isFavorites'], isFalse);
  });

  test('T6#10 host bucket simulation: created is non-empty, personal resolves', () async {
    await login();
    final lists = _list(await rt.invoke('playlists', {'limit': 20, 'offset': 0}));
    // platform_catalog.dart:181-197 的判定，逐字重写一遍。
    const accountId = '12345';
    Map? personal;
    for (final row in lists.cast<Map>()) {
      if (row['isFavorites'] == true &&
          (row['writable'] == true || row['owner'] == accountId)) {
        personal = row;
        break;
      }
    }
    expect(personal, isNotNull, reason: 'personal 必须能解析出默认夹');
    final created = lists
        .cast<Map>()
        .where((row) => row['writable'] == true && row['id'] != personal!['id'])
        .toList();
    final subscribed = lists
        .cast<Map>()
        .where((row) => row['writable'] != true && row['id'] != personal!['id'])
        .toList();
    expect(created.length, 1, reason: '旧代码 created=0，弹窗列表为空');
    expect(subscribed.length, 0, reason: '旧代码 subscribed=3，全部塌进订阅桶');
    // 弹窗只列 liked + created（playlist_picker_dialog.dart:266）。
    expect(1 + created.length, 2, reason: '弹窗里应有两个可点的真实目标');
  });

  // ---- T02b: playlist write path ----

  test('T6#09b addToPlaylist posts csrf and the target aid, exactly once', () async {
    await login();
    _resetCalls();
    final result = await rt.invoke('addToPlaylist', {
      'playlist': '2',
      'songs': ['BV1GJ411x7h7'],
    });
    expect(result, isTrue);
    expect(_callsOf('fav_deal'), 1, reason: '写请求不得重放');
    final post = _requestUrls.where((u) => u.contains('/fav/resource/deal')).toList();
    expect(post.length, 1);
    // POST body 里的字段由 handler 收到；这里用请求头里的 cookie 确认带上了会话。
    expect(_cookieFor('/fav/resource/deal'), contains('bili_jct=csrf123'));
  });

  test('T6#09c addToPlaylist refuses 21 songs without sending a request', () async {
    await login();
    _resetCalls();
    final songs = List.generate(21, (i) => 'BV1GJ411x7h$i');
    final result = await rt.invoke('addToPlaylist', {'playlist': '2', 'songs': songs}) as Map;
    expect(result.containsKey('error'), isTrue);
    expect(result['error']['httpStatus'], 400, reason: '超出预算直接 param，不静默截断');
    expect(_callsOf('fav_deal'), 0);
    expect(_callsOf('view'), 0, reason: '闸门要在发请求之前');
  });

  test('T6#09d createPlaylist returns an id playlistSongs can consume', () async {
    await login();
    _resetCalls();
    final created = await rt.invoke('createPlaylist', {'name': '新建歌单', 'isPublic': true}) as Map;
    _expectNoError(created);
    expect(created['id'], '4700000000');
    expect(created['writable'], isTrue);
    expect(created['owner'], '12345');
    expect(_callsOf('folder_add'), 1, reason: '写请求不得重放');
    // 返回的 id 必须能被 playlistSongs 直接吃掉（宿主就是这么用的）。
    _paged('fav_resource', (pn, ps) => _videoRows(1, 2), pastEnd: PastEnd.zeroedCount);
    final rows = _list(await rt.invoke('playlistSongs', {
      'id': created['id'], 'limit': 20, 'offset': 0,
    }));
    expect(rows.length, 2);
  });

  test('T6#09e picker simulation: list -> add, and create -> add', () async {
    await login();
    final lists = _list(await rt.invoke('playlists', {'limit': 20, 'offset': 0}));
    final personal = lists.cast<Map>().firstWhere((r) => r['isFavorites'] == true);
    final created = lists
        .cast<Map>()
        .where((r) => r['writable'] == true && r['id'] != personal['id'])
        .toList();
    // 分支一：有夹子 → 列出 → 加成功。
    expect(created.isNotEmpty, isTrue);
    _resetCalls();
    final added = await rt.invoke('addToPlaylist', {
      'playlist': created.first['id'], 'songs': ['BV1GJ411x7h7'],
    });
    expect(added, isTrue);
    // 分支二：新建 → 加成功。
    final fresh = await rt.invoke('createPlaylist', {'name': '第二个', 'isPublic': false}) as Map;
    _expectNoError(fresh);
    final added2 = await rt.invoke('addToPlaylist', {
      'playlist': fresh['id'], 'songs': ['BV1GJ411x7h7'],
    });
    expect(added2, isTrue);
    expect(_callsOf('fav_deal'), 2);
  });

  test('T6#09f addToPlaylist on a chart id is a param error, not a bad write', () async {
    await login();
    _resetCalls();
    final result = await rt.invoke('addToPlaylist', {
      'playlist': 'chart:0', 'songs': ['BV1GJ411x7h7'],
    }) as Map;
    expect(result.containsKey('error'), isTrue);
    expect(result['error']['httpStatus'], 400);
    expect(_callsOf('fav_deal'), 0, reason: '榜单不是可写收藏夹，不能在发请求后才发现');
  });

  test('T6#09h createPlaylist invalidates the cached folder listing', () async {
    await login();
    _paged('list_all', (pn, ps) => _folderRows(1, 2), total: 2, pastEnd: PastEnd.notPaged);
    // 先读一次，让 cursor / 封面缓存建立起来。
    final before = _list(await rt.invoke('playlists', {'limit': 20, 'offset': 0}));
    expect(before.length, 2);
    // 建一个夹子：返回的 id 必须出现在下一次列表里，所以列表缓存必须被清掉。
    _paged('list_all', (pn, ps) => _folderRows(1, 3), total: 3, pastEnd: PastEnd.notPaged);
    final created = await rt.invoke('createPlaylist', {'name': '新的', 'isPublic': false}) as Map;
    _expectNoError(created);
    final after = _list(await rt.invoke('playlists', {'limit': 20, 'offset': 0}));
    expect(after.length, 3, reason: '新建后列表必须重新取，不能回放旧的全量');
  });

  test('T6#09i addToPlaylist deduplicates repeated bvids into one aid', () async {
    await login();
    _resetCalls();
    final result = await rt.invoke('addToPlaylist', {
      'playlist': '2',
      'songs': ['BV1GJ411x7h7', 'BV1GJ411x7h7'],
    });
    expect(result, isTrue);
    // 两个相同 bvid 只解析一次 aid：view 只发 1 次。
    expect(_callsOf('view'), 1, reason: '同一次调用内按 bvid 去重');
    expect(_callsOf('fav_deal'), 1);
  });

  test('T6#09g removeFromPlaylist stays unsupported (position vs aid mismatch)', () async {
    final result = await rt.invoke('removeFromPlaylist', {
      'playlist': '2', 'indexes': [0],
    }) as Map;
    expect(result.containsKey('error'), isTrue);
    expect(result['error']['code'], 501, reason: '索引→aid 映射不可靠，宁可不实现');
  });

  // ---- T03: failures must not be silent ----

  test('T6#11 comments(offset=1300) reaches the window instead of returning 0 rows', () async {
    _paged('reply', (pn, ps) => _commentRows((pn - 1) * ps + 1, ps), total: 5000, pastEnd: PastEnd.errorCode);
    final result = await rt.invoke('comments', {
      'id': 'BV1GJ411x7h7', 'limit': 20, 'offset': 1300,
    }) as Map;
    _expectNoError(result);
    final latest = result['latest'] as List;
    expect(latest.length, 20, reason: '旧 MAX_PAGES=64 在这里返回 0 行');
    // rpid = 500000 + n，所以第 1301 条是 501301。
    expect((latest.first as Map)['id'], '501301');
    expect(latest.first['content'], '评论 1301');
  });

  test('T6#12 comments(offset=3000, limit=100) returns 100 rows from 3001', () async {
    _paged('reply', (pn, ps) => _commentRows((pn - 1) * ps + 1, ps), total: 9000, pastEnd: PastEnd.errorCode);
    final result = await rt.invoke('comments', {
      'id': 'BV1GJ411x7h7', 'limit': 100, 'offset': 3000,
    }) as Map;
    _expectNoError(result);
    final latest = result['latest'] as List;
    expect(latest.length, 100);
    expect(latest.first['content'], '评论 3001');
  });

  test('T6#13 artistSongs degrades to an empty page when the endpoint is blocked', () async {
    _forcedError('space_arc', -403);
    final rows = await rt.invoke('artistSongs', {'id': '888', 'limit': 100, 'offset': 0});
    expect(rows is List ? rows.isEmpty : (rows as Map).isEmpty, isTrue,
        reason: '接口被封锁时返回空页，不抛错（否则整页退化成 error 卡）');
    // artist 仍要能给出名字/头像。
    final artist = await rt.invoke('artist', {'id': '888'}) as Map;
    _expectNoError(artist);
    expect(artist['name'], '音乐收藏家');
    expect(artist['coverUrl'], isNotNull);
  });

  test('T6#14 artistSongs still throws on a transient failure', () async {
    _httpError('space_arc', 500);
    Map? result;
    try {
      result = await rt.invoke('artistSongs', {'id': '888', 'limit': 100, 'offset': 0}) as Map?;
    } finally {
      _httpStatus.remove('space_arc');
    }
    expect(result != null && result.containsKey('error'), isTrue,
        reason: '网络故障不得被吞成"这个 UP 没有投稿"');
    expect(result!['error']['code'], 70);
  });

  test('T6#14b comments keeps the reported total when the walk truncates', () async {
    // 接口报了 9000 条，但只给了少量行：total 不得被已读条数覆盖。
    _paged('reply', (pn, ps) => _commentRows((pn - 1) * ps + 1, ps), total: 9000, pastEnd: PastEnd.errorCode);
    final result = await rt.invoke('comments', {
      'id': 'BV1GJ411x7h7', 'limit': 20, 'offset': 0,
    }) as Map;
    _expectNoError(result);
    expect(result['total'], 9000, reason: '接口报的 total 是权威值');
    expect(result['hasMore'], isTrue);
  });

  // ---- T04: multi-part entry point ----

  test('T6#15 the browse shelf carries music-zone rows, single-P included', () async {
    // 20 条热门，全部音乐区；其中第 1、3、7 条是多 P，其余单 P。
    // T8/T03: `videos` 是判定依据（真站每行都带，T7 已验 24/24 与 pages 一致），
    // 所以 fixture 必须像真站一样把它写出来，否则测的是"缺字段时怎么猜"。
    //
    // T12 语义变更：单 P 行**也是**专辑候选（一个 1 首歌的专辑，`songCount=1`
    // 是真实值）。旧断言 `albums.length == 3` 保护的是"只收多 P"，
    // 而那正是把音乐架饿死的原因。现在 20 条热门全上架，`view` 仍只发 3 次。
    //
    // T15：这条断言钉的是 `albums()`（浏览页的容器货架），不是 `homeFeed`
    // （首页的新发行推荐）—— 两者自 T15 起是**两套候选集**，见 T15#11。
    _multiPartHot = {'BVhot00001', 'BVhot00003', 'BVhot00007'};
    _paged('popular', (pn, ps) => List.generate(20, (i) {
      final n = i + 1;
      final bvid = 'BVhot${n.toString().padLeft(5, '0')}';
      return <String, dynamic>{
        'bvid': bvid,
        'title': '热门 $n',
        'pic': '//i0.hdslb.com/bfs/hot/$n.jpg',
        'duration': '3:00',
        'author': 'UP$n',
        'mid': 100 + n,
        'videos': _multiPartHot.contains(bvid) ? 3 : 1,
        'pid_v2': 1003,
      };
    }), pastEnd: PastEnd.notPaged);
    // 榜单钉成空，候选只来自热门，才能把「20 条全上架」数清楚。
    _paged('ranking', (pn, ps) => <Map<String, dynamic>>[], pastEnd: PastEnd.notPaged);
    _resetCalls();
    final albums = _list(await rt.invoke('albums', {'limit': 40, 'offset': 0})).cast<Map>();
    // T8/D5: 只有 3 条多 P，就只发 3 次 view —— 单 P 行不探测。
    expect(_callsOf('view'), 3, reason: '只对 videos>1 的行发 view；单 P 行零请求');
    expect(albums.length, 20, reason: '音乐区单 P 与多 P 都上架');
    expect(albums.map((a) => a['id']).toList(),
        List.generate(20, (i) => 'BVhot${(i + 1).toString().padLeft(5, '0')}'),
        reason: '热门层保持 popular 原序');
    for (final row in albums) {
      expect(row.containsKey('songCount'), isTrue);
      expect(row['songCount'] as int, greaterThanOrEqualTo(1));
    }
    final single = albums.firstWhere((a) => a['id'] == 'BVhot00002');
    expect(single['songCount'], 1, reason: '单 P 专辑的 songCount 是真实值 1，不是占位');
    final multi = albums.firstWhere((a) => a['id'] == 'BVhot00003');
    expect(multi['songCount'], 3, reason: '多 P 行由 view 的 pages 补全');
  });

  test('T6#16 albums() has one wide cache; homeFeed has its own', () async {
    // T10 曾让两个入口共用一份 wide 缓存，因为那时它们读同一组候选。
    // T15 把它们拆开：`albums()` 是「找多 P 容器」（popular + 榜单），
    // `homeFeed.albums` 是「推荐现在能听的」（六词新鲜源）。两套候选集不该
    // 共用一个槽，否则后到的那次会读到另一条的货架。
    //
    // 本条钉的是「各自重复调用都免费」，以及「互不写对方的槽」。
    _paged('popular', (pn, ps) => _singlePartHot(20), pastEnd: PastEnd.notPaged);
    _paged('ranking', (pn, ps) => _multiPartRank(2, videos: 1),
        pastEnd: PastEnd.notPaged);
    seedFreshWords();
    _resetCalls();
    final first = _list(await rt.invoke('albums', {'limit': 40, 'offset': 0}));
    expect(first, isNotEmpty);
    final popularAfterFirst = _callsOf('popular');
    final rankingAfterFirst = _callsOf('ranking');
    final viewAfterFirst = _callsOf('view');
    final again = _list(await rt.invoke('albums', {'limit': 40, 'offset': 0}));
    expect(_callsOf('popular') - popularAfterFirst, 0, reason: 'albums() 第二次命中 wide');
    expect(_callsOf('ranking') - rankingAfterFirst, 0);
    expect(_callsOf('view') - viewAfterFirst, 0);
    expect(again.length, first.length);

    // 首页货架不得写进 albums() 的槽，也不得读它的内容。
    final searchBefore = _callsOf('search');
    final feed = await rt.invoke('homeFeed') as Map;
    _expectNoError(feed);
    expect(_callsOf('search') - searchBefore, 10, reason: '首页读十词，albums() 一条都不读');
    expect(_callsOf('ranking') - rankingAfterFirst, 0,
        reason: '首页不读榜单；albums() 的 wide 已在 TTL 内也不该被它重取');
    final homeAlbums = _list(feed['albums']);
    expect(homeAlbums.map((e) => (e as Map)['id']).toList(),
        isNot(first.map((e) => (e as Map)['id']).toList()),
        reason: '两套候选集内容不同 —— 若相同说明其中一个读了另一个的槽');

    // Both are repeatable for free.
    final viewAfterFeed = _callsOf('view');
    final searchAfterFeed = _callsOf('search');
    final feed2 = await rt.invoke('homeFeed') as Map;
    expect(_list(feed2['albums']).length, homeAlbums.length,
        reason: '第二次 homeFeed 必须命中同一份缓存');
    expect(_callsOf('search') - searchAfterFeed, 0,
        reason: '首页货架自己有 20 分钟缓存，十词不得重发');
    final shelf2 = _list(await rt.invoke('albums', {'limit': 40, 'offset': 0}));
    expect(shelf2.length, first.length, reason: '第二次 albums 必须命中同一份缓存');
    expect(_callsOf('view'), viewAfterFeed, reason: '两次复查都不得新增 view');
  });

  test('T6#17 albumSongs gives every part its own cid, title and duration', () async {
    _multiPart = true;
    try {
      final rows = _list(await rt.invoke('albumSongs', {
        'id': 'BVmulti00001', 'limit': 100, 'offset': 0,
      }));
      expect(rows.length, 3);
      final cids = rows.cast<Map>().map((r) => (r['id'] as String).split(':').last).toList();
      expect(cids, ['1001', '2002', '3003']);
      expect(rows.cast<Map>().map((r) => r['title']).toList(),
          ['P1 第一部分', 'P2 第二部分', 'P3 第三部分']);
      expect(rows.cast<Map>().map((r) => r['durationMs']).toList(),
          [400000, 500000, 600000]);
    } finally {
      _multiPart = false;
    }
  });

  test('T6#18 song(unknown cid) is a 404 with no second request', () async {
    _multiPart = true;
    try {
      _resetCalls();
      final result = await rt.invoke('song', {'id': 'BVmulti00001:9999'}) as Map;
      expect(result.containsKey('error'), isTrue);
      expect(result['error']['httpStatus'], 404,
          reason: '不存在的 P 不能返回 P1 的内容配 9999 的 id');
      expect(_callsOf('view'), 1, reason: 'pages 已在手，本地判定，不发二次请求');
    } finally {
      _multiPart = false;
    }
  });

  // ---- manifest / capability consistency ----

  test('T6#20 every declared capability has a real op, and vice versa', () async {
    final manifest = jsonDecode(File('$_srcRoot/manifest.json').readAsStringSync()) as Map;
    final declared = (manifest['capabilities'] as List).cast<String>().toSet();
    // 每个 capability 在宿主侧对应的 op（music_gateway.dart + platform_catalog.dart）。
    const required = <String, String>{
      'search': 'search',
      'playlists': 'playlists',
      'favorites': 'favorites',
      'lyrics': 'lyrics',
      'homeFeed': 'homeFeed',
      'charts': 'charts',
      'recommendations': 'recommendations',
      'comments': 'comments',
      'album': 'album',
      'albumSongs': 'albumSongs',
      'browseAlbums': 'albums',
    };
    for (final capability in declared) {
      final op = required[capability];
      expect(op, isNotNull, reason: '未登记的 capability: $capability');
      final result = await rt.invoke(op!);
      final isError = result is Map && result.containsKey('error');
      if (isError) {
        expect(result['error']['code'], isNot(501),
            reason: '声明了 $capability 但 $op 没有实现 → 宿主会走进必败路径');
      }
    }
    // 反向：声明了 browseAlbums 就必须真有 albums op（否则 Future.wait 整体抛）。
    if (declared.contains('browseAlbums')) {
      final result = await rt.invoke('albums', {'limit': 40, 'offset': 0});
      expect(result is Map && result.containsKey('error'), isFalse,
          reason: 'browseAlbums 已声明，albums 必须可用');
    }
  });

  test('T6#21 test manifest and src/manifest.json agree on capabilities', () async {
    final src = jsonDecode(File('$_srcRoot/manifest.json').readAsStringSync()) as Map;
    final srcCaps = (src['capabilities'] as List).cast<String>().toSet();
    final testCaps = _manifest.capabilities.toSet();
    expect(testCaps, srcCaps, reason: 'D12：测试内嵌 manifest 曾停在 v0.1.0 且缺 album/*');
    expect(src['version'], _manifest.version);
  });

  // ---- T06: lyrics three-state (E12 verdict: keep 70) ----

  test('T6#19 lyrics with no subtitle and no lrclib hit stays retryable', () async {
    // E12 (evidence/t6/E12_puremusic_matrix.md)：2.0.210 会把空答复落盘成
    // 121 B 空壳，且该空壳没有 savedAt，2.0.300 的 24h TTL 也救不回来。
    // 所以"两个源都没有"必须报 70，绝不能返回空表。
    _paged('player', (pn, ps) => <Map<String, dynamic>>[], pastEnd: PastEnd.notPaged);
    // player 返回空字幕列表；lrclib 返回空命中。
    _paged('lrclib', (pn, ps) => <Map<String, dynamic>>[], pastEnd: PastEnd.notPaged);
    Map? result;
    try {
      result = await rt.invoke('lyrics', {'id': 'BV1GJ411x7h7'}) as Map?;
    } finally {
      _pages.remove('player');
      _pages.remove('lrclib');
    }
    expect(result != null && result.containsKey('error'), isTrue,
        reason: '不能返回空表（会被落盘成纯音乐）');
    expect(result!['error']['code'], 70);
    expect(result['error']['httpStatus'], isNull);
  });

  test('T6#19b lyrics network failure is also 70, with no leaked detail', () async {
    _httpError('view', 500);
    Map? result;
    try {
      result = await rt.invoke('lyrics', {'id': 'BV1GJ411x7h7'}) as Map?;
    } finally {
      _httpStatus.remove('view');
    }
    expect(result != null && result.containsKey('error'), isTrue);
    expect(result!['error']['code'], 70);
    final reason = result['error']['reason'] as String? ?? '';
    // 错误响应不得含 URL 查询串、Cookie、响应正文。
    expect(reason, isNot(contains('SESSDATA')));
    expect(reason, isNot(contains('http')));
    expect(reason, isNot(contains('bvid=')));
  });

  // =========================================================================
  // T7 — identity parsing / per-family budget / fixture fidelity
  // =========================================================================

  // ---- T00: fixture fidelity ----

  test('T7#01 ranking/popular fixtures carry the cid, videos and aid the wire has', () {
    for (final name in const ['ranking', 'popular']) {
      final body = jsonDecode(_fixture(name)) as Map<String, dynamic>;
      final rows = (body['data'] as Map)['list'] as List;
      expect(rows, isNotEmpty, reason: '$name fixture 不能为空');
      for (final row in rows.cast<Map>()) {
        expect(row.containsKey('cid'), isTrue,
            reason: '$name 行缺 cid — 真站 100/100 都有（evidence/t7/G0_capture_fields.log）');
        expect(row.containsKey('videos'), isTrue,
            reason: '$name 行缺 videos — 多 P 判定要靠它，零请求');
        expect(row.containsKey('aid'), isTrue, reason: '$name 行缺 aid');
        expect((row['cid'] as num), greaterThan(0));
        expect((row['videos'] as num), greaterThanOrEqualTo(1));
      }
    }
  });

  test('T7#02 the rebuilt ranking fixture makes chart ids carry a colon', () async {
    final rows = _list(await rt.invoke('playlistSongs', {
      'id': 'chart:0', 'limit': 100, 'offset': 0,
    }));
    expect(rows.length, 1);
    final id = (rows.first as Map)['id'] as String;
    expect(id, contains(':'),
        reason: 'fixture 带 cid 后榜单 id 必须是 bvid:cid（旧 fixture 下不含，D1 因此隐身）');
    expect(id, 'BV1rank001:43796138001');
  });

  test('T7#04 the rebuilt fixtures change real behaviour, not just bytes', () async {
    // A fixture that only adds fields nothing reads would pass T7#01 and still
    // hide the next D1. This asserts the new `cid` actually reaches the id.
    final chart = _list(await rt.invoke('playlistSongs', {
      'id': 'chart:0', 'limit': 100, 'offset': 0,
    }));
    final feed = _list(((await rt.invoke('homeFeed')) as Map)['featuredSongs']);
    expect((chart.first as Map)['id'], contains(':'));
    expect((feed.first as Map)['id'], contains(':'),
        reason: 'homeFeed.featured 也读 popular fixture，同样要带 cid');
    // search rows really have no cid on the wire (0/20), so they must stay plain.
    final songs = ((await rt.invoke('search', {
      'query': '周杰伦', 'limit': 20, 'offset': 0,
    })) as Map)['songs'] as List;
    expect((songs.first as Map)['id'], 'BV1GJ411x7h7');
    expect((songs.first as Map)['id'], isNot(contains(':')));
  });

  // ---- T01: identity parsing ----

  test('T7#05 setFavorite(bvid:cid) sends the plain bvid, never a %3A', () async {
    await login();
    _resetCalls();
    final result = await rt.invoke('setFavorite', {
      'id': 'BVmulti00001:2002', 'favorite': true,
    });
    expect(result, isTrue, reason: '旧代码把 bvid:cid 整个塞进 view?bvid=，回答 400');
    final viewUrls = _requestUrls.where((u) => u.contains('/x/web-interface/view'));
    expect(viewUrls, isNotEmpty);
    for (final url in viewUrls) {
      expect(url, isNot(contains('%3A')), reason: '未解析的冒号被 url_encode 成 %3A');
      expect(url, contains('bvid=BVmulti00001'));
    }
  });

  test('T7#06 comments(bvid:cid) resolves the video and pages normally', () async {
    _paged('reply', (pn, ps) => _commentRows((pn - 1) * ps + 1, ps), total: 100, pastEnd: PastEnd.errorCode);
    final comments = await rt.invoke('comments', {
      'id': 'BV1GJ411x7h7:1001', 'limit': 20, 'offset': 0,
    }) as Map;
    _expectNoError(comments);
    expect((comments['latest'] as List).length, 20);
    expect(comments['total'], 100, reason: '旧代码在这里 400，total 根本不存在');
    for (final url in _requestUrls.where((u) => u.contains('/x/web-interface/view'))) {
      expect(url, isNot(contains('%3A')));
    }
  });

  test('T7#07 one bvid:cid id is accepted by all six song paths', () async {
    await login();
    const id = 'BV1GJ411x7h7:1001';

    final song = await rt.invoke('song', {'id': id}) as Map;
    _expectNoError(song);
    expect(song['id'], id);

    final streamResult = await rt.invoke('stream', {'id': id, 'quality': 'high'}) as Map;
    _expectNoError(streamResult);

    final lyricsResult = await rt.invoke('lyrics', {'id': id}) as List;
    expect(lyricsResult, isNotEmpty);

    final albumSongs = await rt.invoke('albumSongs', {
      'id': 'BV1GJ411x7h7', 'limit': 100, 'offset': 0,
    }) as List;
    expect(albumSongs, isNotEmpty);

    final added = await rt.invoke('addToPlaylist', {
      'playlist': '2', 'songs': [id],
    });
    expect(added, isTrue);

    final fav = await rt.invoke('setFavorite', {'id': id, 'favorite': true});
    expect(fav, isTrue);

    final comments = await rt.invoke('comments', {'id': id, 'limit': 20, 'offset': 0}) as Map;
    _expectNoError(comments);
  });

  test('T7#08 a plain bvid still behaves exactly as before on both write paths', () async {
    await login();
    _resetCalls();
    final fav = await rt.invoke('setFavorite', {
      'id': 'BV1GJ411x7h7', 'favorite': true,
    });
    expect(fav, isTrue);
    final comments = await rt.invoke('comments', {
      'id': 'BV1GJ411x7h7', 'limit': 20, 'offset': 0,
    }) as Map;
    _expectNoError(comments);
    for (final url in _requestUrls.where((u) => u.contains('/x/web-interface/view'))) {
      expect(url, contains('bvid=BV1GJ411x7h7'));
    }
  });

  test('T7#08b a malformed song id is a param error, not a 400 from the wire', () async {
    await login();
    _resetCalls();
    final result = await rt.invoke('setFavorite', {'id': 'not-a-bvid', 'favorite': true});
    expect(result is Map && result.containsKey('error'), isTrue);
    // `param` carries status 400 and no application code (errors.lua TABLE).
    expect((result as Map)['error']['httpStatus'], 400);
    expect(_callsOf('view'), 0, reason: '本地就能判定非法，不该发出去');
  });

  // ---- T02: per-family budget + visible truncation ----

  test('T7#10 a deep folder window is never a silent short page', () async {
    // 2000 首、ps=40。offset=1200 需要 31 页；旧代码用满 32 次请求后返回 80 行，
    // 宿主按 rows.length < limit 判 hasMore=false，用户永远看不到第 1301 首之后。
    _paged('fav_resource', (pn, ps) => _videoRows((pn - 1) * ps + 1, ps, prefix: 'BVdeep'),
        total: 2000, pastEnd: PastEnd.zeroedCount);
    await login();
    final result = await rt.invoke('playlistSongs', {
      'id': '72000000', 'limit': 100, 'offset': 1200,
    });
    if (result is List) {
      // 允许"恰好 limit 行"，但绝不允许短页冒充末页。
      expect(result.length, 100,
          reason: '旧代码在这里返回 80 行，宿主据此判 hasMore=false');
    } else {
      expect((result as Map)['error']['code'], 70, reason: '撞预算必须报可重试，不能短页');
      expect(result['error']['httpStatus'], isNull);
    }
  });

  test('T7#11 a folder offset past the budget is an error, never zero rows', () async {
    _paged('fav_resource', (pn, ps) => _videoRows((pn - 1) * ps + 1, ps, prefix: 'BVdeep'),
        total: 2000, pastEnd: PastEnd.zeroedCount);
    await login();
    final result = await rt.invoke('playlistSongs', {
      'id': '72000000', 'limit': 100, 'offset': 1600,
    });
    // 旧代码返回 0 行 → 宿主读成"到底了"。空列表和"读不到"必须可区分。
    expect(result is Map && result.containsKey('error'), isTrue,
        reason: '旧代码在这里返回 0 行，宿主据此判末页');
    expect((result as Map)['error']['code'], 70);
  });

  test('T7#12 artistSongs(offset=800) is a retryable error, not a 408', () async {
    // 签名族：每页 50，offset=800 需要第 17 页；实测 14 次成功、17 页即 408
    // （evidence/t7/R2_artist_budget.log）。旧代码用明文预算 32，直接把 VM 打挂。
    _paged('space_arc', (pn, ps) => _bulkVlist(pn), total: 4000, pastEnd: PastEnd.errorCode);
    final result = await rt.invoke('artistSongs', {
      'id': '888', 'limit': 100, 'offset': 800,
    });
    expect(result is Map && result.containsKey('error'), isTrue,
        reason: '要么返回 100 行，要么明确可重试；不能 408');
    expect((result as Map)['error']['code'], 70);
    expect(result['error']['httpStatus'], isNull);
    expect(_callsOf('space_arc'), lessThanOrEqualTo(12),
        reason: '签名族预算 12，实测 14 次即接近上限');
  });

  test('T7#12b artistSongs(offset=400) still answers inside the signed budget', () async {
    // T8/D8: 这条原名写 `offset=600`，断言用的却是 400 —— 名字在说谎。测试名
    // 里的数字现在就是断言里的数字。
    // 预算降到 12 不能让正常的浅翻页变成截断：offset=400 只需 9 页就能定位窗口，
    // 所以它必须真的返回行；offset=600 要 13 页，超出预算，必须报可重试
    // （那是 T7#12 的断言）。
    _paged('space_arc', (pn, ps) => _bulkVlist(pn), total: 4000, pastEnd: PastEnd.errorCode);
    final shallow = await rt.invoke('artistSongs', {
      'id': '888', 'limit': 100, 'offset': 400,
    }) as List;
    expect(shallow.length, 100);
    expect((shallow.first as Map)['id'], 'BVbulk9_0');
    expect(_callsOf('space_arc'), lessThanOrEqualTo(12));
  });

  test('T7#13 comment seek still costs one request per call', () async {
    _paged('reply', (pn, ps) => _commentRows((pn - 1) * ps + 1, ps), total: 9000, pastEnd: PastEnd.errorCode);
    _resetCalls();
    final comments = await rt.invoke('comments', {
      'id': 'BV1GJ411x7h7', 'limit': 20, 'offset': 1300,
    }) as Map;
    expect((comments['latest'] as List).length, 20);
    expect(_callsOf('reply'), 1, reason: '跳页后深 offset 仍是 1 次请求');
  });

  test('T7#13b a full page is never turned into an error by the budget', () async {
    // 截断但已经凑满 limit 时是完整页：客户端拿到了它要的东西，报错反而是退步。
    _paged('fav_resource', (pn, ps) => _videoRows((pn - 1) * ps + 1, ps, prefix: 'BVedge'),
        total: 2000, pastEnd: PastEnd.zeroedCount);
    await login();
    final rows = await rt.invoke('playlistSongs', {
      'id': '72000000', 'limit': 40, 'offset': 40,
    }) as List;
    expect(rows.length, 40);
    expect((rows.first as Map)['id'], 'BVedge41');
  });

  // ---- T8/T00: cursor trustworthiness ----
  //
  // The live folder is 88 songs in pages of 38/40/8, and page 4 answers
  // `medias: []` with `info.media_count: 0` (evidence/t8/R1_out_of_range.log).
  // Reading limit=100 therefore always probes page 4, and the old code wrote
  // that zero into the cursor: the second call on the same key returned nothing
  // without sending a request. Every case below is red on the pre-T8 src.

  /// 88 rows over pages of 38/40/8, page 4 and beyond empty with a zeroed count.
  _PageFn poisonedFolder() => (pn, ps) {
        const sizes = <int>[38, 40, 8];
        if (pn < 1 || pn > 3) return <Map<String, dynamic>>[];
        final start = pn == 1 ? 1 : (pn == 2 ? 39 : 79);
        return _videoRows(start, sizes[pn - 1], prefix: 'BVpoison');
      };

  test('T8#01 the same cursor key answers 86 rows twice', () async {
    _paged('fav_resource', poisonedFolder(), total: 88, pastEnd: PastEnd.zeroedCount);
    await login();
    final first = await rt.invoke('playlistSongs', {'id': '72000000', 'limit': 100, 'offset': 0});
    expect(_list(first).length, 86, reason: '第一次读到全部 86 行');

    final second = await rt.invoke('playlistSongs', {'id': '72000000', 'limit': 100, 'offset': 0});
    expect(_list(second).length, 86,
        reason: '越界页的 media_count=0 不得写进游标（旧代码这里返回空表）');
  });

  test('T8#02 a deep window still reads after the end was probed', () async {
    _paged('fav_resource', poisonedFolder(), total: 88, pastEnd: PastEnd.zeroedCount);
    await login();
    await rt.invoke('playlistSongs', {'id': '72000000', 'limit': 100, 'offset': 0});
    final tail = await rt.invoke('playlistSongs', {'id': '72000000', 'limit': 100, 'offset': 80});
    final rows = _list(tail);
    expect(rows.length, 6, reason: 'offset=80 仍能读到第 81–86 行');
    expect((rows.first as Map)['id'], 'BVpoison81');
  });

  test('T8#03 a small folder is immune to the same probe', () async {
    // 12 行但报 14：page 2 越界时把 count 清零，旧代码第三次调用变空。
    _paged('fav_resource', (pn, ps) {
      if (pn > 1) return <Map<String, dynamic>>[];
      return _videoRows(1, 12, prefix: 'BVsmall');
    }, total: 14, pastEnd: PastEnd.zeroedCount);
    await login();
    for (var round = 1; round <= 3; round++) {
      final rows = await rt.invoke('playlistSongs', {'id': '72000000', 'limit': 100, 'offset': 0});
      expect(_list(rows).length, 12, reason: '第 $round 次调用必须仍是 12 行');
    }
  });

  test('T8#05 opening a folder does not poison favorites', () async {
    // 真机现场（evidence/t8/R7_live_poison_open_folder.log）：用户点开的正是
    // 默认收藏夹，所以 playlistSongs 与 favorites 共用 `fav:<media_id>` 这一
    // 条游标——收藏夹被探到越界后，「我喜欢」跟着变空。
    _paged('fav_resource', poisonedFolder(), total: 88, pastEnd: PastEnd.zeroedCount);
    // list_all 的第一行就是默认收藏夹，id 与上面 playlistSongs 用的一致。
    _paged('list_all', (pn, ps) => <Map<String, dynamic>>[
          <String, dynamic>{'id': 72000000, 'title': '默认收藏夹', 'media_count': 88},
          <String, dynamic>{'id': 72219751, 'title': '稍后再看', 'media_count': 5},
        ], total: 2, pastEnd: PastEnd.notPaged);
    await login();
    await rt.invoke('playlistSongs', {'id': '72000000', 'limit': 100, 'offset': 0});
    final favorites = await rt.invoke('favorites', {'limit': 100, 'offset': 0});
    expect(_list(favorites).length, 86,
        reason: '「我喜欢」与收藏夹共用游标，不得被越界探测清零');
  });

  // ---- T9/T02: 评论双桶（latest=时间序，hot=热度且只取首页） ----

  test('T9#12 hot and latest carry the same comment shape', () async {
    _paged('reply', (pn, ps) => _commentRows((pn - 1) * ps + 1, ps),
        total: 100, pastEnd: PastEnd.errorCode);
    _paged('reply_hot', (pn, ps) => _commentRows(9000 + pn, ps),
        total: 20, pastEnd: PastEnd.errorCode);
    final page = await rt.invoke('comments',
        {'id': 'BV1GJ411x7h7', 'limit': 20, 'offset': 0}) as Map;
    _expectNoError(page);
    final hot = _list(page['hot']);
    final latest = _list(page['latest']);
    expect(hot, isNotEmpty);
    expect(latest, isNotEmpty);
    final hotKeys = (hot.first as Map).keys.toSet();
    expect((latest.first as Map).keys.toSet(), hotKeys,
        reason: '两个桶必须用同一份 models.comment');
    for (final key in <String>['id', 'content', 'author', 'time', 'likedCount']) {
      expect(hotKeys.contains(key), isTrue, reason: 'hot 缺字段 $key');
    }
  });

  test('T9#13 latest comes from sort=0 and hot from sort=1', () async {
    // fixture 必须能让两个桶区分开，否则一个没改 sort 的插件也能全绿：
    // 宿主按 id 去重，两桶同源时只是两个区块内容相同。
    _paged('reply', (pn, ps) => _commentRows((pn - 1) * ps + 1, ps),
        total: 100, pastEnd: PastEnd.errorCode);
    _paged('reply_hot', (pn, ps) => _commentRows(9000 + pn, ps),
        total: 20, pastEnd: PastEnd.errorCode);
    _resetCalls();
    final page = await rt.invoke('comments',
        {'id': 'BV1GJ411x7h7', 'limit': 20, 'offset': 0}) as Map;
    expect(_callsOf('reply_hot'), 1, reason: 'hot 必须真的发出去（sort=1）');
    expect(_callsOf('reply'), 1, reason: 'latest 走 sort=0 的走 walker');
    final hotIds = _list(page['hot']).map((e) => (e as Map)['id']).toSet();
    final latestIds = _list(page['latest']).map((e) => (e as Map)['id']).toSet();
    expect(hotIds.intersection(latestIds), isEmpty,
        reason: '两桶内容必须可区分，否则测不出 sort 用错');
  });

  test('T9#14 latest is time-ordered while hot is like-ordered', () async {
    _paged('reply', (pn, ps) => _commentRows((pn - 1) * ps + 1, ps),
        total: 100, pastEnd: PastEnd.errorCode);
    _paged('reply_hot', (pn, ps) {
      // 热评：点赞很高但时间更早。
      return _commentRows(9000 + pn, ps).map((row) {
        row['like'] = 99999;
        row['ctime'] = 1500000000;
        return row;
      }).toList();
    }, total: 20, pastEnd: PastEnd.errorCode);
    final page = await rt.invoke('comments',
        {'id': 'BV1GJ411x7h7', 'limit': 20, 'offset': 0}) as Map;
    final latestFirst = _list(page['latest']).first as Map;
    final hotFirst = _list(page['hot']).first as Map;
    expect(latestFirst['time'] as int, greaterThanOrEqualTo(hotFirst['time'] as int),
        reason: 'latest 是新→旧，hot 是点赞序（时间可以更早）');
  });

  test('T9#15 a failed hot bucket never breaks latest, and is retried', () async {
    _paged('reply', (pn, ps) => _commentRows((pn - 1) * ps + 1, ps),
        total: 100, pastEnd: PastEnd.errorCode);
    _forcedError('reply_hot', -412);
    final first = await rt.invoke('comments',
        {'id': 'BV1GJ411x7h7', 'limit': 20, 'offset': 0}) as Map;
    _expectNoError(first);
    expect(_list(first['latest']).length, 20, reason: 'hot 失败不影响 latest');
    expect(_list(first['hot']), isEmpty, reason: 'hot 失败留空');
    // 失败结果不得写成长期空缓存：下一次 offset=0 仍要重新请求。
    _forcedErrors.remove('reply_hot');
    _resetCalls();
    final second = await rt.invoke('comments',
        {'id': 'BV1GJ411x7h7', 'limit': 20, 'offset': 0}) as Map;
    expect(_callsOf('reply_hot'), 1, reason: '失败态不得被缓存锁死');
    expect(_list(second['latest']).length, 20);
  });

  test('T9#16 hot is fetched on the first page only', () async {
    _paged('reply', (pn, ps) => _commentRows((pn - 1) * ps + 1, ps),
        total: 9000, pastEnd: PastEnd.errorCode);
    _paged('reply_hot', (pn, ps) => _commentRows(9000 + pn, ps),
        total: 20, pastEnd: PastEnd.errorCode);
    _resetCalls();
    final first = await rt.invoke('comments',
        {'id': 'BV1GJ411x7h7', 'limit': 20, 'offset': 0}) as Map;
    expect(_callsOf('reply_hot'), lessThanOrEqualTo(1));
    expect(_list(first['hot']), isNotEmpty);
    for (final offset in <int>[20, 40]) {
      _resetCalls();
      final page = await rt.invoke('comments',
          {'id': 'BV1GJ411x7h7', 'limit': 20, 'offset': offset}) as Map;
      expect(_callsOf('reply_hot'), 0,
          reason: 'offset=$offset 不得再为同一份热评付一次请求');
      expect(_list(page['hot']), isEmpty, reason: 'offset>0 直接 hot={}');
      expect(_list(page['latest']).length, 20);
    }
  });

  test('T9#17 total/hasMore only describe the latest bucket', () async {
    _paged('reply', (pn, ps) => _commentRows((pn - 1) * ps + 1, ps),
        total: 60, pastEnd: PastEnd.errorCode);
    // hot 桶故意给一个不相干的 count，不得影响 total/hasMore。
    _paged('reply_hot', (pn, ps) => _commentRows(9000 + pn, ps),
        total: 999999, pastEnd: PastEnd.errorCode);
    final page = await rt.invoke('comments',
        {'id': 'BV1GJ411x7h7', 'limit': 20, 'offset': 40}) as Map;
    expect(page['total'], 60, reason: 'total 只来自 latest 的 page.count');
    expect(page['hasMore'], isFalse, reason: 'offset=40 + 20 行已到 60');
  });

  // ---- T9/T03: total 只采信"非空页 + 非零计数" ----

  test('T9#18 a non-empty page with no count does not latch the cursor', () async {
    // 真站形态：行照给，但 page 里没有 count/acount。旧代码把 0 写成 total，
    // 之后 skip >= 0 恒真，offset=20 起永远返回空表（evidence/t9/R3_comments_latch.log）。
    _paged('reply', (pn, ps) => _commentRows((pn - 1) * ps + 1, ps),
        pastEnd: PastEnd.errorCode);
    _omitCount.add('reply');
    var offset = 0;
    for (var round = 0; round < 3; round++) {
      final page = await rt.invoke('comments',
          {'id': 'BV1GJ411x7h7', 'limit': 20, 'offset': offset}) as Map;
      _expectNoError(page);
      final rows = _list(page['latest']);
      expect(rows.length, 20, reason: 'offset=$offset 必须是 20 行');
      expect((rows.first as Map)['content'], '评论 ${offset + 1}');
      expect(page['total'], anyOf(isNull, 0), reason: '接口没报 count 时留空');
      offset += rows.length;
    }
  });

  test('T9#19 a non-empty page reporting count=0 does not latch the cursor', () async {
    _paged('reply', (pn, ps) => _commentRows((pn - 1) * ps + 1, ps),
        pastEnd: PastEnd.errorCode);
    _countOverrides['reply'] = 0;
    var offset = 0;
    for (var round = 0; round < 3; round++) {
      final page = await rt.invoke('comments',
          {'id': 'BV1GJ411x7h7', 'limit': 20, 'offset': offset}) as Map;
      final rows = _list(page['latest']);
      expect(rows.length, 20, reason: 'offset=$offset 必须是 20 行');
      expect(page['total'], anyOf(isNull, 0));
      offset += rows.length;
    }
  });

  test('T9#21 an out-of-range page still never invents a total', () async {
    _paged('reply', (pn, ps) {
      if (pn > 3) return <Map<String, dynamic>>[];
      return _commentRows((pn - 1) * ps + 1, ps);
    }, pastEnd: PastEnd.emptyNoCount);
    final page = await rt.invoke('comments',
        {'id': 'BV1GJ411x7h7', 'limit': 20, 'offset': 1000}) as Map;
    expect(_list(page['latest']), isEmpty);
    expect(page['total'], anyOf(isNull, 0));
  });

  test('T9#27 the page-length contract is load-bearing (30-row clamp turns it red)',
      () async {
    // 行为测试替代原计划的 C13 文本门：门不该检查注释怎么写，而该检查
    // 宿主最终拿到了什么。这里用 30 行夹取等价物直接演示同一场景变红。
    _multiPart = true;
    _multiPartParts = 150;
    const clamp = 30; // 旧 ALBUM_SONG_CEILING 的等价物
    final ids = <String>[];
    var offset = 0;
    for (var hop = 0; hop < 6; hop++) {
      final rows = _list(await rt.invoke('albumSongs',
          {'id': 'BVmulti00001', 'limit': 100, 'offset': offset}));
      final page = rows.take(clamp).toList();
      ids.addAll(page.map((e) => (e as Map)['id'] as String));
      if (page.length < 100) break; // 宿主判 hasMore=false
      offset += page.length;
    }
    expect(ids.length, lessThan(150),
        reason: '夹取 30 行时宿主读不到全部 P —— 这正是本轮要消除的行为');
    expect(ids.length, 30, reason: '宿主只走一跳就停');
  });

  test('T8#06 comments never report the request offset as the total', () async {
    // 真站形态（evidence/t8/R9_past_end_offline.log）：60 条之后是空页，且
    // `page.count` 从不出现。旧代码把 `skip + #replies` 当 total，于是
    // offset=1000 回答 total=1000。
    _paged('reply', (pn, ps) {
      if (pn > 3) return <Map<String, dynamic>>[];
      return _commentRows((pn - 1) * ps + 1, ps);
    }, pastEnd: PastEnd.emptyNoCount);
    final result = await rt.invoke('comments', {
      'id': 'BV1GJ411x7h7', 'limit': 20, 'offset': 1000,
    }) as Map;
    _expectNoError(result);
    expect(_list(result['latest']), isEmpty, reason: '1000 之后确实没有评论');
    expect(result['total'], isNot(1000),
        reason: '旧代码把请求偏移当总数返回');
    expect(result['total'], anyOf(isNull, 0),
        reason: '接口没报 count 时必须留空，让宿主读成"未知"');
  });

  test('T8#07 a real upstream total still closes hasMore at the right offset', () async {
    _paged('reply', (pn, ps) => _commentRows((pn - 1) * ps + 1, ps),
        total: 60, pastEnd: PastEnd.errorCode);
    final page = await rt.invoke('comments', {
      'id': 'BV1GJ411x7h7', 'limit': 20, 'offset': 40,
    }) as Map;
    _expectNoError(page);
    expect(page['total'], 60, reason: '上游报的 60 是权威值');
    expect(page['hasMore'], isFalse, reason: 'offset=40 读完已到 60');
  });

  test('T8#09 fixture pastEnd is load-bearing: keepsTotal makes T8#01 red', () async {
    // 把 fav_resource 的末端行为临时改成"越界页仍报真实总数"，同一场景必须
    // 不再复现中毒——否则说明这个开关根本没接进行为里。
    _paged('fav_resource', poisonedFolder(), total: 88, pastEnd: PastEnd.keepsTotal);
    await login();
    final first = await rt.invoke('playlistSongs', {'id': '72000000', 'limit': 100, 'offset': 0});
    expect(_list(first).length, 86);
    // keepsTotal 下越界页不会给 0，因此即使按旧代码的写法游标也不会被清零。
    final second = await rt.invoke('playlistSongs', {'id': '72000000', 'limit': 100, 'offset': 0});
    expect(_list(second).length, 86);
    // 断言 fixture 真的发出了清零/非清零两种形状：_envelope 对 empty 页的
    // media_count 由 pastEnd 决定，这里直接验证那条分支被走到过。
    expect(_pastEnds['fav_resource'], PastEnd.keepsTotal);
  });

  // ---- T8/T02: search budget on rows the wire actually sends ----

  test('T8#13 search(limit=100) clamps to 35 instead of a 408', () async {
    // 真站行形状：66 字段 + 带 <em> 的长标题，且**两个桶都有行** —— 真机
    // `search` 同时映射视频与 UP 主，把 UP 桶当空的离线测量会高估上限
    // （R12 得 50，R13 真机得 40，45 即 408）。
    _paged('search', (pn, ps) => _wireSearchRows((pn - 1) * ps + 1, ps),
        total: 250, pastEnd: PastEnd.keepsTotal);
    _paged('search_user', (pn, ps) => _wireArtistRows((pn - 1) * ps + 1, ps),
        total: 250, pastEnd: PastEnd.keepsTotal);
    final result = await rt.invoke('search', {'query': '周杰伦', 'limit': 100, 'offset': 0}) as Map;
    _expectNoError(result);
    final songs = _list(result['songs']);
    expect(songs.length, 35, reason: '夹到 35 行，不返回 408');
    expect(result['truncated'], isTrue, reason: '必须标记这次被夹取');
    expect(result['requestedLimit'], 100);
    expect(result['limit'], 35);
    expect(_list(result['artists']).length, 35, reason: 'UP 桶同样受夹取');
  });

  test('T8#14 search(limit=35) is unchanged and not marked truncated', () async {
    _paged('search', (pn, ps) => _wireSearchRows((pn - 1) * ps + 1, ps),
        total: 250, pastEnd: PastEnd.keepsTotal);
    _paged('search_user', (pn, ps) => _wireArtistRows((pn - 1) * ps + 1, ps),
        total: 250, pastEnd: PastEnd.keepsTotal);
    final result = await rt.invoke('search', {'query': '周杰伦', 'limit': 35, 'offset': 0}) as Map;
    _expectNoError(result);
    expect(_list(result['songs']).length, 35, reason: '35 是可用上限，不得回归');
    expect(result['truncated'], isFalse);
  });

  test('T8#15 the default host call (limit=30) stays cheap on wire rows', () async {
    // 宿主默认 limit=30（lua_music_gateway.dart:328），必须在真站行上稳过。
    _paged('search', (pn, ps) => _wireSearchRows((pn - 1) * ps + 1, ps),
        total: 250, pastEnd: PastEnd.keepsTotal);
    _paged('search_user', (pn, ps) => _wireArtistRows((pn - 1) * ps + 1, ps),
        total: 250, pastEnd: PastEnd.keepsTotal);
    final result = await rt.invoke('search', {'query': '周杰伦', 'limit': 30, 'offset': 0}) as Map;
    _expectNoError(result);
    expect(_list(result['songs']).length, 30);
    expect(result['truncated'], isFalse);
    // 真站行必须映射出可用的歌曲字段，否则"夹到 35"只是省了指令。
    final first = _list(result['songs']).first as Map;
    expect(first['id'], 'BVwire00001');
    expect((first['title'] as String).contains('<em'), isFalse,
        reason: '高亮标签必须被清掉，不能显示成用户可见文本');
  });

  // ---- T8/T03: homeFeed album discovery costs nothing to classify ----

  test('T8#16 the browse shelf spends view requests only on multi-part rows', () async {
    // 20 条热门里 5 条多 P：旧代码固定 8 次 view（且可能一条专辑都没换到），
    // 新代码只发 5 次。R3 实测旧行为是 10 请求里 8 次 view、albums 恒空。
    //
    // T12：单 P 行现在也上架，所以这里断言的是**view 次数**而不是架长。
    // 架长由 T6#15 钉（20 条全上架）；本条的职责是「单 P 行一个请求都不发」。
    //
    // T15：首页货架（六词新鲜源）根本不发 view —— 搜索行没有 `videos`，
    // 也没有「多 P 才要补详情」这回事。view 只属于 `albums()`，所以本条
    // 断言对象改成 albums()。
    _multiPartHot = {'BVhot00002', 'BVhot00005', 'BVhot00009',
                     'BVhot00013', 'BVhot00017'};
    _paged('popular', (pn, ps) => List.generate(20, (i) {
      final n = i + 1;
      final bvid = 'BVhot${n.toString().padLeft(5, '0')}';
      return <String, dynamic>{
        'bvid': bvid,
        'title': '热门 $n',
        'pic': '//i0.hdslb.com/bfs/hot/$n.jpg',
        'duration': '3:00',
        'author': 'UP$n',
        'mid': 100 + n,
        'videos': _multiPartHot.contains(bvid) ? 4 : 1,
        'pid_v2': 1003,
      };
    }), pastEnd: PastEnd.notPaged);
    // 榜单钉空：候选全部来自热门，view 次数才只由热门的 5 条多 P 决定。
    _paged('ranking', (pn, ps) => <Map<String, dynamic>>[], pastEnd: PastEnd.notPaged);
    _resetCalls();
    final albums = _list(await rt.invoke('albums', {'limit': 40, 'offset': 0}));
    expect(_callsOf('view'), 5,
        reason: '每次 view 都必须由一个 videos>1 的行触发');
    expect(albums.length, 20,
        reason: '音乐区 20 行全上架，其中 15 条单 P 零请求');
    expect(_callsOf('popular'), 1, reason: 'popular 只请求一次，两个桶共用');
    expect(_callsOf('ranking'), 1, reason: '多出来的这一次只属于榜单族');
  });

  test('T8#17 an all-single-part browse shelf costs zero view requests', () async {
    // R3 的真机结论就是"8 次 view 换 0 专辑"。全单 P 时新代码必须 0 次。
    // T12：架不再为空 —— 单 P 也是专辑。本条钉的是「零 view」，架长由
    // T6#15/T10#04 钉。T15：断言对象改为 albums()（首页货架不发 view）。
    _multiPartHot = <String>{};
    _paged('popular', (pn, ps) => _singlePartHot(20), pastEnd: PastEnd.notPaged);
    _paged('ranking', (pn, ps) => _multiPartRank(1, videos: 1),
        pastEnd: PastEnd.notPaged);
    _resetCalls();
    final albums = _list(await rt.invoke('albums', {'limit': 40, 'offset': 0}));
    expect(_callsOf('view'), 0, reason: '两个来源都没有多 P 行，就不该有任何 view 探测');
    expect(albums.length, 21,
        reason: '热门 20 + 榜单 1，全部单 P 也全部上架');
  });

  test('T8#18 albums() reads the chart rows, not the mapped song rows', () async {
    // T03 的第二半：`chart_rows` 返回的是已映射的 song 形状，里面没有 videos，
    // 所以第一版 albums() 在真机恒空（G8: albums(18) {} newRequests=1）。
    // 现在候选集直接读缓存的**原始行**。
    _multiPartHot = <String>{};
    _paged('popular', (pn, ps) => List.generate(20, (i) {
      final n = i + 1;
      return <String, dynamic>{
        'bvid': 'BVhot${n.toString().padLeft(5, '0')}',
        'title': '热门 $n',
        'pic': '//i0.hdslb.com/bfs/hot/$n.jpg',
        'duration': '3:00',
        'author': 'UP$n',
        'mid': 100 + n,
        'videos': 1,
        'pid_v2': 1003,
      };
    }), pastEnd: PastEnd.notPaged);
    // 榜单 fixture 只有 1 行（真站抓包的 1 条）；把它标成多 P 才能证明
    // albums() 读的是原始行（映射后的 song 行没有 videos 字段）。
    // 同时补 `pid_v2`：真机 ranking/v2 每行都带它，缺字段会被当成非音乐区。
    final ranking = _fixture('ranking');
    final parsed = jsonDecode(ranking) as Map<String, dynamic>;
    final rows = ((parsed['data'] as Map)['list'] as List).cast<Map>();
    expect(rows, isNotEmpty, reason: 'ranking fixture 不能为空');
    for (final row in rows) {
      row['videos'] = 3;
      row['pid_v2'] = 1003;
    }
    _rankingOverride = jsonEncode(parsed);
    _resetCalls();
    // `view` 必须同意行里的说法（videos=3），否则 songCount 会被 pages 覆盖成 1。
    _multiPartHot = <String>{for (final row in rows) row['bvid'] as String};
    // T12：单 P 热门行也上架，所以 limit 必须大于热门行数才能看见榜单那一行。
    final shelf = _list(await rt.invoke('albums', {'limit': 40, 'offset': 0}));
    expect(shelf.length, 21, reason: '热门 20 + 榜单 1');
    final chartIds = <String>{for (final row in rows) row['bvid'] as String};
    final fromChart =
        shelf.cast<Map>().where((a) => chartIds.contains('${a['id']}')).toList();
    expect(fromChart.length, 1, reason: '榜单行是多 P，必须出现在专辑架上');
    expect(fromChart.first['songCount'], greaterThan(1));
    // T15：首页货架自 T15 起另有来源（六词新鲜源），它不读榜单、不读热门、
    // 不发 view。原来这里断言的是"两个入口共用 wide 缓存"，那条语义已经作废
    // （见 T6#16），所以改成断言**拆开**这件事本身。
    //
    // popular 已在上一段被 albums() 读过，20 分钟缓存仍在，所以这里允许
    // 0 次（命中缓存）或 1 次（未命中）；关键是它不再被首页的货架路径驱动。
    final popularBefore = _callsOf('popular');
    _resetCalls();
    final feed = await rt.invoke('homeFeed') as Map;
    _expectNoError(feed);
    expect(_callsOf('ranking'), 0, reason: '首页不再读榜单');
    expect(_callsOf('popular'), 0,
        reason: 'popular 已在 TTL 内（上面 albums() 读过），首页不得重取');
    expect(popularBefore, greaterThan(0), reason: '前置条件：上面确实读过 popular');
    expect(_callsOf('view'), 0, reason: '首页货架不补 view');
    expect(_callsOf('search'), 10, reason: '首页读十词');
    expect(_list(feed['albums']).map((e) => (e as Map)['id']).toList(),
        isNot(shelf.map((e) => (e as Map)['id']).toList()),
        reason: 'albums() 与 homeFeed 是两套候选集，内容不得相同');
  });

  // ---- T9/T00+T01: 页长契约与合集完整可达 ----
  //
  // 宿主只有一条判据：hasMore = list.length >= limit（lua_music_gateway.dart:200），
  // 它的下一个 offset 是 offset + items.length（music_models.dart:250）。
  // 所以插件必须：只要还有剩余行，单页就返回整整 limit 行；短页 = 没有下一页。

  test('T8#19 albumSongs returns a full page instead of clamping to 30', () async {
    // 旧断言保护的是 D1 本身（"夹到 30 行"）。30 行 + limit=100 让宿主在
    // 第一页就判 hasMore=false，第 31 个 P 起永久不可达（evidence/t9/R20_album_host_hasmore_live.log）。
    // 现在：单页返回 min(limit, 剩余)，宿主自己翻页。
    _multiPart = true;
    _multiPartParts = 40;
    final rows = _list(await rt.invoke('albumSongs',
        {'id': 'BVmulti00001', 'limit': 100, 'offset': 0}));
    expect(rows.length, 40, reason: '40 P 的合集必须一次给全 40 行');
    expect((rows.first as Map)['id'], 'BVmulti00001:1001',
        reason: '页长改动不得改变行身份或顺序');
    expect((rows.last as Map)['id'], 'BVmulti00001:43000',
        reason: '必须是第 40 个 P，不能跳行');
  });

  test('T8#20 albumSongs(limit=30) is unchanged', () async {
    _multiPart = true;
    final rows = _list(await rt.invoke('albumSongs',
        {'id': 'BVmulti00001', 'limit': 30, 'offset': 0}));
    expect(rows.length, 3, reason: '三 P 视频给 3 行，夹取不影响小专辑');
  });

  test('T8#21 albumSongs(offset=30) continues from the 31st part, no overlap', () async {
    // 夹取消失后这条断言的前提（"offset 越过夹取"）不存在了，改成语义本身：
    // 第二页从第 31 个 P 起，与第一页无重叠。
    _multiPart = true;
    _multiPartParts = 40;
    final first = _list(await rt.invoke('albumSongs',
        {'id': 'BVmulti00001', 'limit': 30, 'offset': 0}));
    final second = _list(await rt.invoke('albumSongs',
        {'id': 'BVmulti00001', 'limit': 100, 'offset': 30}));
    expect(first.length, 30, reason: 'limit=30 的首页必须是满页');
    expect(second.length, 10, reason: '40 P 里第 31–40 个');
    expect((second.first as Map)['id'], 'BVmulti00001:34000');
    final firstIds = first.map((e) => (e as Map)['id']).toSet();
    for (final row in second) {
      expect(firstIds.contains((row as Map)['id']), isFalse,
          reason: '第二页不得重复第一页的行');
    }
  });

  test('T9#01 albumSongs(limit=100) on a 63-part video returns all 63 rows', () async {
    // 剩余不足 limit：返回 remaining 行，宿主自然得到 hasMore=false（真末页）。
    _multiPart = true;
    _multiPartParts = 63;
    final rows = _list(await rt.invoke('albumSongs',
        {'id': 'BVmulti00001', 'limit': 100, 'offset': 0}));
    expect(rows.length, 63);
    expect(rows.length >= 100, isFalse, reason: '宿主读作 hasMore=false');
  });

  test('T9#01b a part with an empty cid is filtered before slicing, not after',
      () async {
    // 第 40 个 P 的 cid 为空（映射时丢弃）。插件必须先在"可映射行空间"里
    // 过滤，再切片；否则页长变短（宿主判末页）且 offset 与下标错位
    // （宿主 nextOffset = offset + items.length）。
    _multiPart = true;
    _multiPartParts = 63;
    _emptyCidAt = 40;
    final all = _list(await rt.invoke('albumSongs',
        {'id': 'BVmulti00001', 'limit': 100, 'offset': 0}));
    expect(all.length, 62, reason: '63 个 P 里丢掉 1 个坏行 = 62 行');
    expect(all.map((e) => (e as Map)['id']).contains('BVmulti00001:43000'), isFalse,
        reason: '空 cid 的行不得出现');
    // 窗口横跨坏行：offset=30、limit=30 必须仍是 30 行满页（继续向后取）。
    final window = _list(await rt.invoke('albumSongs',
        {'id': 'BVmulti00001', 'limit': 30, 'offset': 30}));
    expect(window.length, 30, reason: '短页会让第 61–62 个 P 永久不可达');
    final firstIds = all.map((e) => (e as Map)['id']).toSet();
    for (final row in window) {
      expect(firstIds.contains((row as Map)['id']), isTrue,
          reason: '窗口里的行必须来自同一批可映射行');
    }
  });

  test('T9#02 host all() reaches every part of a 150-part video', () async {
    _multiPart = true;
    _multiPartParts = 150;
    final ids = <String>[];
    var offset = 0;
    for (var hop = 0; hop < 6; hop++) {
      final rows = _list(await rt.invoke('albumSongs',
          {'id': 'BVmulti00001', 'limit': 100, 'offset': offset}));
      ids.addAll(rows.map((e) => (e as Map)['id'] as String));
      if (rows.length < 100 || rows.isEmpty) break;
      offset += rows.length;
    }
    expect(ids.length, 150, reason: '100 + 50 两跳读完');
    expect(ids.toSet().length, 150, reason: '不得重复');
  });

  test('T9#03 host all() reaches every part of a 300-part video', () async {
    _multiPart = true;
    _multiPartParts = 300;
    final ids = <String>[];
    var offset = 0;
    final hops = <int>[];
    for (var hop = 0; hop < 8; hop++) {
      final rows = _list(await rt.invoke('albumSongs',
          {'id': 'BVmulti00001', 'limit': 100, 'offset': offset}));
      hops.add(rows.length);
      ids.addAll(rows.map((e) => (e as Map)['id'] as String));
      if (rows.length < 100 || rows.isEmpty) break;
      offset += rows.length;
    }
    expect(hops, [100, 100, 100, 0], reason: '100/100/100/0 四跳');
    expect(ids.length, 300);
    expect(ids.toSet().length, 300, reason: '不得重复、不得缺项');
  });

  test('T9#05 albumSongs(limit=30) is a full page and asks for more', () async {
    // 小 limit 调用方（若有）：满页 30 行 → 宿主判 hasMore=true。
    _multiPart = true;
    _multiPartParts = 40;
    final rows = _list(await rt.invoke('albumSongs',
        {'id': 'BVmulti00001', 'limit': 30, 'offset': 0}));
    expect(rows.length, 30);
    expect(rows.length >= 30, isTrue, reason: '满页 = 还有下一页');
  });

  test('T9#07 every limit step returns min(limit, remaining)', () async {
    _multiPart = true;
    _multiPartParts = 40;
    for (final limit in <int>[1, 30, 39, 40, 45, 100]) {
      final rows = _list(await rt.invoke('albumSongs',
          {'id': 'BVmulti00001', 'limit': limit, 'offset': 0}));
      final expected = limit < 40 ? limit : 40;
      expect(rows.length, expected, reason: 'limit=$limit 单页必须是 min(limit, 40)');
    }
  });

  test('T9#08 a 160-part video answers a full 100-row page', () async {
    _multiPart = true;
    _multiPartParts = 160;
    final rows = _list(await rt.invoke('albumSongs',
        {'id': 'BVmulti00001', 'limit': 100, 'offset': 0}));
    expect(rows.length, 100, reason: 'hoist 后 160 行的输入不再 408');
  });

  test('T9#09 300/800/1200-part videos each answer a full page', () async {
    for (final parts in <int>[300, 800, 1200]) {
      _multiPart = true;
      _multiPartParts = parts;
      final rows = _list(await rt.invoke('albumSongs',
          {'id': 'BVmulti00001', 'limit': 100, 'offset': 0}));
      expect(rows.length, 100, reason: '$parts P 的每次调用都稳定返回 100 行');
    }
  });

  test('T9#10 a single-part video keeps clean_title(title) as its row title', () async {
    final rows = _list(await rt.invoke('albumSongs',
        {'id': 'BV1GJ411x7h7', 'limit': 100, 'offset': 0}));
    expect(rows.length, 1);
    expect((rows.first as Map)['title'], '【测试】稻香');
  });

  test('T9#11 multi-part titles stay P<n> <part>', () async {
    _multiPart = true;
    final rows = _list(await rt.invoke('albumSongs',
        {'id': 'BVmulti00001', 'limit': 100, 'offset': 0}));
    expect(rows.map((e) => (e as Map)['title']).toList(),
        ['P1 第一部分', 'P2 第二部分', 'P3 第三部分']);
  });

  // ---- T10: 首页专辑来源与降级缓存 ----
  //
  // 缺陷：`homeFeed.albums` 只读热门，而真机热门 20/20 全是单 P
  // （evidence/t8/R18_popular_videos.log），于是「为你推荐的新发行」是一个
  // 永远不显示的区块；多 P 候选全在榜单里（evidence/t9/R27_homefeed_chart_raw.log）。
  //
  // 408 的成因不是榜单行数，是**映射时机**：`chart_rows` 把 100 行映射成 song
  // 形状（R25 408），`chart_raw` 只读原始行（R27 6 请求正常）。所以修法只能是
  // chart_raw，且降级必须窄到「榜单这一条请求」。


  test('T10#01 albums() takes music-zone popular rows plus the music chart',
      () async {
    // 热门全单 P 且全音乐区；榜单有 2 个多 P。
    // T12：单 P 也上架，所以热门那 20 行也进候选，顺序是「popular 层在前」。
    // T15：这条钉的是 albums()（容器货架），首页货架的断言在 T15 家族。
    _multiPartHot = {'BVrank00001', 'BVrank00002'};
    _paged('popular', (pn, ps) => _singlePartHot(20), pastEnd: PastEnd.notPaged);
    _paged('ranking', (pn, ps) => _multiPartRank(2), pastEnd: PastEnd.notPaged);

    final albums = _list(await rt.invoke('albums', {'limit': 40, 'offset': 0})).cast<Map>();
    expect(albums.map((a) => a['id']).toList(), <String>[
      ...List.generate(20, (i) => 'BVhot${(i + 1).toString().padLeft(5, '0')}'),
      'BVrank00001',
      'BVrank00002',
    ], reason: '分层顺序：popular 音乐区行在前（保持原序），榜单行在后');
    for (final album in albums.where((a) => '${a['id']}'.startsWith('BVrank'))) {
      expect(album['songCount'], 3, reason: 'view 必须同意行里的 videos');
    }
    expect(_callsOf('view'), 2, reason: '只有榜单那 2 条多 P 需要 view');
  });

  test('T10#01b a non-music popular row never reaches the browse shelf', () async {
    // 反例一：热门里有音乐区单 P 行，也有非音乐区行。只有前者能上架。
    // `pid_v2 = 0` 是真机真实取值（国产动画 / 综艺），不是缺字段。
    _multiPartHot = <String>{};
    _paged('popular', (pn, ps) => <Map<String, dynamic>>[
          {..._singlePartHot(1).first as Map<String, dynamic>, 'bvid': 'BVmusic0001', 'pid_v2': 1003},
          {..._singlePartHot(1).first as Map<String, dynamic>, 'bvid': 'BVgame00001', 'pid_v2': 1008},
          {..._singlePartHot(1).first as Map<String, dynamic>, 'bvid': 'BVzero00001', 'pid_v2': 0},
        ], pastEnd: PastEnd.notPaged);
    _paged('ranking', (pn, ps) => <Map<String, dynamic>>[], pastEnd: PastEnd.notPaged);
    expect(_list(await rt.invoke('albums', {'limit': 40, 'offset': 0}))
            .map((a) => (a as Map)['id']).toList(),
        ['BVmusic0001'],
        reason: 'pid_v2=1008 与 pid_v2=0 都不是音乐区，必须拒掉');
  });

  test('T10#01c a music-zone multi-part row is accepted, a non-music one is not',
      () async {
    // 反例二：同一层里放两条多 P —— 音乐区的收、非音乐区的拒。
    _multiPartHot = {'BVmusicM001', 'BVgameM0001'};
    _paged('popular', (pn, ps) => <Map<String, dynamic>>[], pastEnd: PastEnd.notPaged);
    _paged('ranking', (pn, ps) => <Map<String, dynamic>>[
          {..._multiPartRank(1).first as Map<String, dynamic>, 'bvid': 'BVmusicM001', 'pid_v2': 1003},
          {..._multiPartRank(1).first as Map<String, dynamic>, 'bvid': 'BVgameM0001', 'pid_v2': 1008},
        ], pastEnd: PastEnd.notPaged);
    expect(_list(await rt.invoke('albums', {'limit': 40, 'offset': 0}))
            .map((a) => (a as Map)['id']).toList(),
        ['BVmusicM001'],
        reason: '音乐区多 P 收，非音乐区多 P 拒 —— 旧代码只按 videos>1 收，两个都会进');
    expect(_callsOf('view'), 1, reason: '被拒的行不该产生 view');
  });

  test('T10#03 a bvid present in both browse sources yields one album and one view',
      () async {
    // 同一个多 P 视频同时出现在热门和榜单：按 bvid 去重，view 只发一次。
    _multiPartHot = {'BVhot00003'};
    _paged('popular', (pn, ps) => <Map<String, dynamic>>[
          {
            'bvid': 'BVhot00001', 'title': '热门 1', 'pic': '//i0.hdslb.com/bfs/hot/1.jpg',
            'duration': '3:00', 'author': 'UP1', 'mid': 101, 'videos': 1,
            'pid_v2': 1003,
          },
          {
            'bvid': 'BVhot00003', 'title': '热门 3', 'pic': '//i0.hdslb.com/bfs/hot/3.jpg',
            'duration': '3:00', 'author': 'UP3', 'mid': 103, 'videos': 3,
            'pid_v2': 1003,
          },
        ], pastEnd: PastEnd.notPaged);
    _paged('ranking', (pn, ps) => <Map<String, dynamic>>[
          {
            'bvid': 'BVhot00003', 'title': '榜单 3', 'pic': '//i0.hdslb.com/bfs/rank/3.jpg',
            'duration': '3:00', 'owner': {'mid': 103, 'name': 'UP3'}, 'videos': 3,
            'pid_v2': 1003,
          },
        ], pastEnd: PastEnd.notPaged);

    final albums = _list(await rt.invoke('albums', {'limit': 40, 'offset': 0})).cast<Map>();
    expect(albums.map((a) => a['id']).toList(), ['BVhot00001', 'BVhot00003'],
        reason: '去重后两个 bvid，popular 层在前');
    expect(albums.first['songCount'], 1, reason: '单 P 行 songCount 是真实值');
    expect(albums.last['songCount'], 3, reason: '多 P 行由 view 补全');
    expect(_callsOf('view'), 1, reason: '去重后只发一次 view');
  });

  test('T10#04 two all-single-part browse sources still form a shelf with zero view',
      () async {
    // T12 语义变更的核心：旧断言是「两源全单 P → 空架」，那是被 `videos > 1`
    // 饿出来的。单 P 是真实专辑（1 首歌），架必须非空，且零 view。
    _multiPartHot = <String>{};
    _paged('popular', (pn, ps) => _singlePartHot(20), pastEnd: PastEnd.notPaged);
    _paged('ranking', (pn, ps) => _multiPartRank(2, videos: 1),
        pastEnd: PastEnd.notPaged);
    final albums = _list(await rt.invoke('albums', {'limit': 40, 'offset': 0})).cast<Map>();
    expect(albums.length, 22, reason: '热门 20 + 榜单 2，全部单 P 也全部上架');
    expect(albums.every((a) => a['songCount'] == 1), isTrue,
        reason: '全单 P 时每行 songCount 必须是 1');
    expect(_callsOf('view'), 0, reason: '两个来源都没有多 P 行，零请求');
  });

  test('T10#04b a popular page with zero music rows still forms a browse shelf',
      () async {
    // R5 的真机形态：20 行全非音乐区（含 2 行 pid_v2=0）。架子必须由榜单
    // 单独撑起来，不能因为 popular 没有音乐行就变空。
    _multiPartHot = <String>{};
    _paged('popular', (pn, ps) => <Map<String, dynamic>>[
          ..._singlePartHot(18, pidV2: 1008),
          ..._singlePartHot(2, pidV2: 0),
        ], pastEnd: PastEnd.notPaged);
    _paged('ranking', (pn, ps) => _multiPartRank(3, videos: 1),
        pastEnd: PastEnd.notPaged);
    final albums = _list(await rt.invoke('albums', {'limit': 40, 'offset': 0})).cast<Map>();
    expect(albums.map((a) => a['id']).toList(),
        ['BVrank00001', 'BVrank00002', 'BVrank00003'],
        reason: 'popular 无音乐行 → 候选退化为纯榜单，架子仍成形');
    expect(_callsOf('view'), 0);
  });

  test('T10#05 a chart failure surfaces from albums() instead of an empty page',
      () async {
    // T15 前这条叫「榜单失败时降级到热门」：当时 homeFeed 读榜单，所以必须
    // 有降级路径。现在榜单只被 albums() 读，而 albums() 是显式浏览操作，
    // 失败就属于调用方（同一结论由 T10#12 从错误形状侧钉住）。
    // 本条改为钉「popular 部分照常返回，但榜单失败照样上抛」。
    _multiPartHot = {'BVhot00003'};
    _paged('popular', (pn, ps) => <Map<String, dynamic>>[
          ..._singlePartHot(2),
          {..._singlePartHot(1).first as Map<String, dynamic>, 'bvid': 'BVhot00003', 'videos': 3},
        ], pastEnd: PastEnd.notPaged);
    _forcedError('ranking', -412);
    final result = await rt.invoke('albums', {'limit': 40, 'offset': 0});
    expect(result is Map && result.containsKey('error'), isTrue,
        reason: 'albums() 不吞榜单失败；降级只属于 homeFeed 的六词源');
  });

  test('T10#06 a failed browse chart is retried on the next albums() call', () async {
    _multiPartHot = {'BVrank00001'};
    _paged('popular', (pn, ps) => _singlePartHot(20), pastEnd: PastEnd.notPaged);
    _paged('ranking', (pn, ps) => _multiPartRank(1), pastEnd: PastEnd.notPaged);
    _forcedError('ranking', -412);
    final first = await rt.invoke('albums', {'limit': 40, 'offset': 0});
    expect(first is Map && first.containsKey('error'), isTrue,
        reason: 'albums() 不降级，第一次就是错误');
    final before = _callsOf('ranking');
    _forcedErrors.remove('ranking');
    final second = _list(await rt.invoke('albums', {'limit': 40, 'offset': 0}));
    expect(_callsOf('ranking') - before, 1, reason: '失败结果不得占住缓存，必须重试榜单');
    expect(second.map((e) => (e as Map)['id']).toList(), <String>[
      ...List.generate(20, (i) => 'BVhot${(i + 1).toString().padLeft(5, '0')}'),
      'BVrank00001',
    ], reason: '重试成功后榜单行补进第二层');
  });

  test('T10#07 a failed browse chart never occupies the wide cache', () async {
    _multiPartHot = {'BVrank00001'};
    _paged('popular', (pn, ps) => _singlePartHot(20), pastEnd: PastEnd.notPaged);
    _paged('ranking', (pn, ps) => _multiPartRank(1), pastEnd: PastEnd.notPaged);
    _forcedError('ranking', -412);
    await rt.invoke('albums', {'limit': 40, 'offset': 0});
    _forcedErrors.remove('ranking');
    final before = _callsOf('ranking');
    final shelf = _list(await rt.invoke('albums', {'limit': 40, 'offset': 0}));
    expect(_callsOf('ranking') - before, 1,
        reason: '若失败结果占了 wide，这里会零请求返回热门集');
    expect(shelf.map((e) => (e as Map)['id']).toList(), <String>[
      ...List.generate(20, (i) => 'BVhot${(i + 1).toString().padLeft(5, '0')}'),
      'BVrank00001',
    ], reason: '重试后榜单行必须在架尾出现');
  });

  test('T10#08 repeated albums() calls cost no new request', () async {
    _multiPartHot = {'BVrank00001'};
    _paged('popular', (pn, ps) => _singlePartHot(20), pastEnd: PastEnd.notPaged);
    _paged('ranking', (pn, ps) => _multiPartRank(1), pastEnd: PastEnd.notPaged);
    final first = _list(await rt.invoke('albums', {'limit': 40, 'offset': 0}));
    final popularBefore = _callsOf('popular');
    final rankingBefore = _callsOf('ranking');
    final viewBefore = _callsOf('view');
    final shelf = _list(await rt.invoke('albums', {'limit': 40, 'offset': 0}));
    expect(_callsOf('popular') - popularBefore, 0);
    expect(_callsOf('ranking') - rankingBefore, 0);
    expect(_callsOf('view') - viewBefore, 0);
    expect(shelf.map((e) => (e as Map)['id']).toList(),
        first.map((e) => (e as Map)['id']).toList(),
        reason: 'albums() 复用自己的 wide 槽');
  });

  test('T10#09 homeFeed does not reuse the browse shelf cache', () async {
    // T15 把这层语义反转了：两个入口现在是两套候选集，所以 albums() 之后
    // 的 homeFeed 必须**自己**读六词，而不是命中 wide。
    _multiPartHot = {'BVrank00001'};
    _paged('popular', (pn, ps) => _singlePartHot(20), pastEnd: PastEnd.notPaged);
    _paged('ranking', (pn, ps) => _multiPartRank(1), pastEnd: PastEnd.notPaged);
    final shelf = _list(await rt.invoke('albums', {'limit': 40, 'offset': 0}));
    expect(shelf, isNotEmpty);
    final searchBefore = _callsOf('search');
    final feed = await rt.invoke('homeFeed') as Map;
    _expectNoError(feed);
    expect(_callsOf('search') - searchBefore, 10,
        reason: '首页自己读十词，不复用 albums() 的结果');
    expect(_list(feed['albums']).map((e) => (e as Map)['id']).toList(),
        isNot(shelf.map((e) => (e as Map)['id']).toList()),
        reason: '两套候选集内容不同');
  });

  test('T10#10 a 100-row all-multi-part chart stays inside ALBUM_LIMIT', () async {
    // 最坏输入：榜单 100 行全多 P。硬上限是 16 次 view（尝试数），不是成功数。
    // T12：热门 20 行（单 P）不需要 view，先全部上架；榜单层在第 17 条多 P
    // 处停手。所以架长 = 20 + 16，view = 16。T15：断言对象是 albums()。
    final rows = _multiPartRank(100);
    _multiPartHot = {for (final row in rows) row['bvid'] as String};
    _paged('popular', (pn, ps) => _singlePartHot(20), pastEnd: PastEnd.notPaged);
    _paged('ranking', (pn, ps) => rows, pastEnd: PastEnd.notPaged);
    final albums = _list(await rt.invoke('albums', {'limit': 40, 'offset': 0})).cast<Map>();
    expect(albums.length, 20 + 16,
        reason: '20 条单 P 热门 + 16 条到顶的多 P 榜单');
    expect(_callsOf('view'), 16,
        reason: 'ALBUM_LIMIT 限制的是尝试数，一次失败不得让它越过 16');
    expect(albums.where((a) => '${a['id']}'.startsWith('BVrank')).length, 16,
        reason: '榜单层只放进 16 条');
  });

  test('T10#11 one failing view keeps the rest of the browse shelf', () async {
    _multiPartHot = {'BVrank00001', 'BVrank00002'};
    _paged('popular', (pn, ps) => _singlePartHot(20), pastEnd: PastEnd.notPaged);
    _paged('ranking', (pn, ps) => _multiPartRank(2), pastEnd: PastEnd.notPaged);
    _viewErrorBvids.add('BVrank00001');
    final albums = _list(await rt.invoke('albums', {'limit': 40, 'offset': 0})).cast<Map>();
    expect(albums.map((a) => a['id']).toList(), <String>[
      ...List.generate(20, (i) => 'BVhot${(i + 1).toString().padLeft(5, '0')}'),
      'BVrank00001',
      'BVrank00002',
    ], reason: '一条 view 失败不得清空整架');
    final failed = albums.firstWhere((a) => a['id'] == 'BVrank00001');
    expect(failed['songCount'], 3,
        reason: '失败行回退到 feed 行的 videos，而不是 0 或空');
  });

  test('T10#12 albums() still surfaces a ranking failure instead of degrading',
      () async {
    _paged('popular', (pn, ps) => _singlePartHot(20), pastEnd: PastEnd.notPaged);
    _forcedError('ranking', -412);
    final result = await rt.invoke('albums', {'limit': 40, 'offset': 0});
    expect(result is Map && result.containsKey('error'), isTrue,
        reason: 'albums() 是显式浏览操作，榜单失败必须照旧上抛');
    final error = (result as Map)['error'] as Map;
    expect(error['httpStatus'], 429, reason: '-412 归为限流');
  });

  // ---- T15: 首页「为你推荐的新发行」换源 ----
  //
  // 缺陷：`homeFeed.albums` 曾是「音乐榜」的同义词。实测 rid=3 的 97 行
  // `pubdate` 中位 603 天、<24h 为 0/97（evidence/t15/probe_base_age.log），
  // 而 `popular` 音乐区 0/20 —— 所以要修的不是排序，是源。
  //
  // 新源 `search?order=pubdate` 的实测性质（evidence/t15/probe_search_window.log）：
  // 翻页有效（p1∩p2=0/30）、`page_size` 上限 50、行内**没有** `videos`/`pid_v2`。

  test('T16#01 the shelf is 8 asmr + 6 long + 2 short in a fixed pattern',
      () async {
    // 用户 2026-11-24 的比例：ASMR 拿一半，长内容次之，短内容最少。
    // 断言的是**位置**，不只是计数 —— 计数能对上而顺序难看是很容易的事。
    seedFreshWords();
    final feed = await rt.invoke('homeFeed') as Map;
    _expectNoError(feed);
    final albums = _list(feed['albums']).cast<Map>();
    expect(albums.length, 16, reason: '固定 16 格');
    final ids = [for (final a in albums) '${a['id']}'];
    final asmr = ids.where((id) => id.startsWith('BVA')).length;
    final longs = ids.where((id) => id.startsWith('BVL')).length;
    final shorts = ids.where((id) => id.startsWith('BVS')).length;
    expect(asmr, 8, reason: 'ASMR 占一半，实际 $asmr / 16');
    expect(longs, 6, reason: '长内容 6 格，实际 $longs');
    expect(shorts, 2, reason: '短内容 2 格，实际 $shorts');
    // 模式 asmr,asmr,long,asmr,long,asmr,long,short ×2
    const pattern = ['A', 'A', 'L', 'A', 'L', 'A', 'L', 'S'];
    for (var slot = 0; slot < 16; slot++) {
      final want = pattern[slot % 8];
      final got = ids[slot].startsWith('BVA')
          ? 'A'
          : ids[slot].startsWith('BVL')
              ? 'L'
              : 'S';
      expect(got, want, reason: '第 ${slot + 1} 格应为 $want，实际 $got（${ids[slot]}）');
    }
  });

  test('T16#02 every shelf album id is a bare bvid', () async {
    // T13#03 锁 `albumId == bvid`：带 `:cid` 会让专辑入口失效。
    seedFreshWords();
    final feed = await rt.invoke('homeFeed') as Map;
    _expectNoError(feed);
    final albums = _list(feed['albums']).cast<Map>();
    expect(albums.every((a) => !'${a['id']}'.contains(':')), isTrue,
        reason: 'id 必须是纯 bvid，不得带分 P 后缀');
    expect(albums.every((a) => '${a['id']}'.startsWith('BV')), isTrue);
  });

  test('T16#03 the second line names the channel, not the wire zone',
      () async {
    seedFreshWords();
    final feed = await rt.invoke('homeFeed') as Map;
    _expectNoError(feed);
    final albums = _list(feed['albums']).cast<Map>();
    for (final album in albums) {
      final artists = _list(album['artists']).cast<Map>();
      expect(artists.length, 1, reason: '卡片第二行只有一个标签');
      final name = '${artists.first['name']}';
      expect(name.contains(' · '), isTrue,
          reason: '标识必须是「分区 · 时长」，实际是 "$name"');
    }
    final labels = [
      for (final a in albums) '${(_list(a['artists']).first as Map)['name']}'
    ];
    // ASMR 通道的行写**选中它的那个词**，与线上分区无关。种子 fixture 的
    // ASMR 行标题是「<词> n」，三个词分别是 ASMR / 助眠 / 白噪音，所以标签
    // 也必须是这三个之一 —— 既不是 `日常`（线上分区），也不是扁平的 `ASMR`
    // （那会把 助眠/白噪音 掩盖掉，见 T17#01）。
    const asmrLabels = {'ASMR', '助眠', '白噪音', '哄睡', '环境音', '睡眠'};
    final asmrSlots = [0, 1, 3, 5, 8, 9, 11, 13];
    for (final slot in asmrSlots) {
      final head = labels[slot].split(' · ').first;
      expect(asmrLabels.contains(head), isTrue,
          reason: '第 ${slot + 1} 格是 ASMR 槽，标签必须是具体的 ASMR 词，实际 "${labels[slot]}"');
      expect(labels[slot], endsWith(' · 40:00'),
          reason: '第 ${slot + 1} 格的时长照常印出来，实际 "${labels[slot]}"');
    }
    final otherSlots = [2, 4, 6, 7, 10, 12, 14, 15];
    for (final slot in otherSlots) {
      final head = labels[slot].split(' · ').first;
      expect(asmrLabels.contains(head), isFalse,
          reason: '第 ${slot + 1} 格不是 ASMR 槽，实际 "${labels[slot]}"');
    }
    expect(labels.any((l) => l.startsWith('日常')), isFalse,
        reason: '这一架上不该出现「日常 · …」：$labels');
    // ASMR 槽之间不该全是同一个词 —— 三个词各占一席才说明标签是逐行判的。
    final asmrHeads = {for (final slot in asmrSlots) labels[slot].split(' · ').first};
    expect(asmrHeads.length, 3,
        reason: 'ASMR 槽应当同时出现 ASMR / 助眠 / 白噪音 三种标签，实际 $asmrHeads');
    // 长通道保留真实分区名，短通道也是。
    expect(labels.any((l) => l == '人文历史 · 55:00'), isTrue,
        reason: '长内容仍要显示自己的分区名与时长：$labels');
    expect(labels.any((l) => l == '翻唱 · 3:00'), isTrue,
        reason: '秒级时长必须是 m:ss，不是 180s：$labels');
  });

  test('T16#04 校园学习 (208) never reaches the shelf', () async {
    // 用户明确要求去掉校园学习。208 出白名单后，任何词返回它都必须被丢掉 ——
    // 包括长通道的词。这条是 T16 的验收核心之一。
    for (final word in const [
      'ASMR', '助眠', '白噪音',
      '有声书', '文学朗读', '听书', '讲座',
      '鬼畜', '歌切', '纯音乐',
    ]) {
      _keyworded(word, (pn, ps) => List.generate(20, (i) => _freshRow(
            'BVschool${word.hashCode.abs() % 1000}'
            '${(i + 1).toString().padLeft(3, '0')}',
            word: word, typeid: 208, typename: '校园学习',
            duration: '50:00', play: 1000 - i,
          )));
    }
    _paged('popular', (pn, ps) => _singlePartHot(3), pastEnd: PastEnd.notPaged);
    _paged('ranking', (pn, ps) => <Map<String, dynamic>>[], pastEnd: PastEnd.notPaged);
    final feed = await rt.invoke('homeFeed') as Map;
    _expectNoError(feed);
    final albums = _list(feed['albums']).cast<Map>();
    expect(albums.any((a) => '${a['id']}'.startsWith('BVschool')), isFalse,
        reason: '208 一条都不能上架');
    expect(albums, isNotEmpty, reason: '全被过滤时退回旧候选集，不能是空架');
  });

  test('T16#05 the ten-word real capture still answers (budget gate)', () async {
    // 十词 ps=30 的真站行：300 行 / 465,598 B，加 popular 33,182 B 后
    // 498,780 B，是 T15 出货版（313,859 B）的 1.59x、换源前（206,027 B）的
    // 2.42x。解码量涨了这么多仍未 408，唯一原因是过滤发生在**映射之前**
    // （T9/R25 的墙量的是被映射的行数，而这里只映射 16 行）。
    //
    // 这条红了就说明墙回来了：处理办法是减词或退回 ps=20，不是调预算。
    seedRealisticFreshWords();
    _paged('popular', (pn, ps) => _singlePartHot(20), pastEnd: PastEnd.notPaged);
    final feed = await rt.invoke('homeFeed') as Map;
    _expectNoError(feed);
    final albums = _list(feed['albums']).cast<Map>();
    expect(albums.length, 16,
        reason: '真站行也必须产出 16 格 —— 408 会在这里变成 {error}');
    expect(_list(feed['featuredSongs']).length, 20, reason: 'popular 桶照常');
    for (final album in albums) {
      final label = '${(_list(album['artists']).first as Map)['name']}';
      expect(label.isNotEmpty, isTrue);
      expect(label.contains(' · ') || RegExp(r'^[\u4e00-\u9fa5A-Za-z]+$').hasMatch(label),
          isTrue,
          reason: '要么「分区 · 时长」，要么只有分区（超 24h 时），实际 "$label"');
    }
  });

  test('T16#06 a tid-21 row without an ASMR token never reaches the shelf',
      () async {
    // 21 日常 是最大的干扰源。ASMR 通道放它进来有两个条件，必须分别证明：
    //
    //   (a) 词本身是 ASMR 词 —— 长/短词搜到的 21 行一律不收
    //   (b) 行的标题或标签自报 asmr/助眠/白噪音 —— ASMR 词搜到的 21 行也要
    //       有标记才收
    //
    // 三个前缀各测一个方向。`BVnaked` 是**唯一能测到 (b) 的那一条**：它来自
    // ASMR 词（所以 (a) 过）、落在 21（所以 known 过），只有标记能拦住它。
    // 第一版只写了 BVplain 与 BVtoken，负向控制 N1（去掉标记门）时全绿 ——
    // 因为 BVplain 是被 (a) 拦的，不是被 (b) 拦的。缺口补在这里。
    for (final word in const ['有声书', '文学朗读', '听书', '讲座']) {
      _keyworded(word, (pn, ps) => List.generate(20, (i) => _freshRow(
            'BVplain${word.hashCode.abs() % 1000}'
            '${(i + 1).toString().padLeft(3, '0')}',
            word: word, typeid: 21, typename: '日常', duration: '40:00',
            title: '${word}vlog ${i + 1}',
          )));
    }
    for (final word in const ['ASMR', '助眠', '白噪音']) {
      _keyworded(word, (pn, ps) => List.generate(20, (i) => _freshRow(
            'BVtoken${word.hashCode.abs() % 1000}'
            '${(i + 1).toString().padLeft(3, '0')}',
            word: word, typeid: 21, typename: '日常', duration: '40:00',
          )));
    }
    // ASMR 词、tid 21、标题里**故意不含**任何标记词（默认标题会带 keyword，
    // 所以必须显式覆盖）。
    _keyworded('ASMR', (pn, ps) => <Map<String, dynamic>>[
          ...List.generate(10, (i) => _freshRow(
                'BVnaked${(i + 1).toString().padLeft(3, '0')}',
                word: 'ASMR', typeid: 21, typename: '日常', duration: '40:00',
                play: 900 - i, title: '随手拍的置物架 ${i + 1}',
              )),
          ...List.generate(20, (i) => _freshRow(
                'BVtoken${'ASMR'.hashCode.abs() % 1000}'
                '${(i + 1).toString().padLeft(3, '0')}',
                word: 'ASMR', typeid: 21, typename: '日常', duration: '40:00',
              )),
        ]);
    for (final word in const ['鬼畜', '歌切', '纯音乐']) {
      _keyworded(word, (pn, ps) => <Map<String, dynamic>>[]);
    }
    final feed = await rt.invoke('homeFeed') as Map;
    _expectNoError(feed);
    final albums = _list(feed['albums']).cast<Map>();
    expect(albums.any((a) => '${a['id']}'.startsWith('BVplain')), isFalse,
        reason: '长词的 21 行：词不是 ASMR 词，一条都不能上架');
    expect(albums.any((a) => '${a['id']}'.startsWith('BVnaked')), isFalse,
        reason: 'ASMR 词的 21 行但没有标记 —— 只有标记门能拦住它，'
            '它出现说明标记门失效了');
    expect(albums.any((a) => '${a['id']}'.startsWith('BVtoken')), isTrue,
        reason: 'ASMR 词的 21 行带标记，必须上架');
  });

  test('T16#07 an ASMR word\'s row in a real zone lands in the ASMR channel',
      () async {
    // 实测的跨界样本：助眠 → 228 人文历史 x2、130 音乐综合 x1
    // （evidence/t16/probe_final_vocab.log）。它们自报助眠，所以是 ASMR 内容，
    // 不该拿一个 ASMR 词去填长/短格。
    for (final word in const ['ASMR', '白噪音']) {
      _keyworded(word, (pn, ps) => <Map<String, dynamic>>[]);
    }
    _keyworded('助眠', (pn, ps) => List.generate(8, (i) => _freshRow(
          'BVcross${(i + 1).toString().padLeft(3, '0')}',
          word: '助眠', typeid: 228, typename: '人文历史', duration: '55:00',
          title: '【助眠】睡前朗读 ${i + 1}',
        )));
    for (final word in const ['有声书', '文学朗读', '听书', '讲座']) {
      _keyworded(word, (pn, ps) => <Map<String, dynamic>>[]);
    }
    for (final word in const ['鬼畜', '歌切', '纯音乐']) {
      _keyworded(word, (pn, ps) => <Map<String, dynamic>>[]);
    }
    final feed = await rt.invoke('homeFeed') as Map;
    _expectNoError(feed);
    final albums = _list(feed['albums']).cast<Map>();
    expect(albums.length, 8, reason: '只有 8 条候选，不得重复填充');
    expect(albums.first['id'], startsWith('BVcross'));
    // ASMR 通道的行写选它的那个词（这里标题是「【助眠】…」），不是线上分区
    // 228/人文历史。线上分区在真机上会和长通道的行撞标签（evidence/t16/
    // R1_live_channels.log 里 音乐综合 同时属于 ASMR 与短通道），卡片又是宿主
    // 留给插件的唯一通道信号，所以它必须写 ASMR 系的名字而不是分区名。
    final label = '${(_list(albums.first['artists']).first as Map)['name']}';
    expect(label, '助眠 · 55:00',
        reason: 'ASMR 通道的行要写选中它的词，实际 "$label"');
    expect(label.contains('人文历史'), isFalse,
        reason: '线上分区不得出现在 ASMR 槽的标签里，实际 "$label"');
  });

  test('T16#08 a missing ASMR pool degrades to long, not to 鬼畜', () async {
    // 三通道的降级顺序是 asmr → long → short。ASMR 全死时，8 个 asmr 格必须
    // 用长内容补，不能拿鬼畜去填 —— 权重顺序是有语义的。
    for (final word in const ['ASMR', '助眠', '白噪音']) {
      _keyworded(word, (pn, ps) => <Map<String, dynamic>>[]);
    }
    for (final word in const ['有声书', '文学朗读', '听书', '讲座']) {
      _keyworded(word, (pn, ps) => List.generate(20, (i) => _freshRow(
            'BVL${word.hashCode.abs() % 1000}'
            '${(i + 1).toString().padLeft(3, '0')}',
            word: word, typeid: 228, typename: '人文历史', duration: '55:00',
            play: 100 - i,
          )));
    }
    for (final word in const ['鬼畜', '歌切', '纯音乐']) {
      _keyworded(word, (pn, ps) => List.generate(20, (i) => _freshRow(
            'BVS${word.hashCode.abs() % 1000}'
            '${(i + 1).toString().padLeft(3, '0')}',
            word: word, typeid: 31, typename: '翻唱', duration: '3:00',
            play: 100 - i,
          )));
    }
    final feed = await rt.invoke('homeFeed') as Map;
    _expectNoError(feed);
    final albums = _list(feed['albums']).cast<Map>();
    expect(albums.length, 16, reason: '16 格必须填满');
    final ids = [for (final a in albums) '${a['id']}'];
    expect(ids.map((id) => id.startsWith('BVS')).where((x) => x).length, 2,
        reason: '只有 2 个 short 槽，ASMR 死了不得让鬼畜占满');
    expect(ids.toSet().length, 16, reason: '不得循环补同一条');
  });

  test('T16#09 inside a channel the highest play+like*10 comes first', () async {
    // fixture 形状：第 n 条的 play=(20-n)*10、like=(n-1)*15。
    //   n=1  -> play=190, like=0   -> 总分 190    <- 单看 play 是第 1
    //   n=20 -> play=0,   like=285 -> 总分 2850   <- 单看 like/总分是第 1
    // 两个公式的顺序**相反**，所以这条断言能区分它们（N4 就是靠它变红的）。
    seedFreshWords();
    final feed = await rt.invoke('homeFeed') as Map;
    _expectNoError(feed);
    final albums = _list(feed['albums']).cast<Map>();
    expect(albums.first['id'], endsWith('020'),
        reason: 'ASMR 通道第一条必须是 play+like*10 最高的那条，实际 ${albums.first['id']}');
    // 长通道第一个位置是第 3 格。
    expect(albums[2]['id'], endsWith('020'),
        reason: '长通道第一格同理，实际 ${albums[2]['id']}');
    expect(albums.any((a) => '${a['id']}'.endsWith('001')), isFalse,
        reason: 'play 最高但总分最低的行不得上架 —— 它出现说明公式退化成单 play');
  });

  test('T16#10 one dead word keeps the other nine and does not cache',
      () async {
    seedFreshWords();
    _keywordError('讲座', -412);
    final first = await rt.invoke('homeFeed') as Map;
    _expectNoError(first);
    final albums = _list(first['albums']).cast<Map>();
    expect(albums.length, 16, reason: '一个词失败，其余九个词仍要填满架子');
    expect(albums.any((a) => '${a['id']}'.contains('讲座')), isFalse);
    _keywordErrors.remove('讲座');
    final searchBefore = _callsOf('search');
    final second = await rt.invoke('homeFeed') as Map;
    _expectNoError(second);
    expect(_callsOf('search') - searchBefore, greaterThan(0),
        reason: '降级结果不得占住 20 分钟货架缓存，必须重试');
    expect(_list(second['albums']).length, 16);
  });

  test('T16#11 all ten words dead falls back to popular, shelf stays non-empty',
      () async {
    seedFreshWords();
    for (final word in const [
      'ASMR', '助眠', '白噪音',
      '有声书', '文学朗读', '听书', '讲座',
      '鬼畜', '歌切', '纯音乐',
    ]) {
      _keywordError(word, -412);
    }
    _paged('popular', (pn, ps) => _singlePartHot(4), pastEnd: PastEnd.notPaged);
    _paged('ranking', (pn, ps) => <Map<String, dynamic>>[], pastEnd: PastEnd.notPaged);
    final feed = await rt.invoke('homeFeed') as Map;
    _expectNoError(feed);
    final albums = _list(feed['albums']).cast<Map>();
    expect(albums, isNotEmpty, reason: '十词全挂时必须退回旧候选集，不得抛错也不得空架');
    expect(albums.map((a) => a['id']).toList(),
        ['BVhot00001', 'BVhot00002', 'BVhot00003', 'BVhot00004']);
  });

  test('T16#12 a duration past 24h drops the time and keeps the zone', () async {
    // 7/120 实测行超过 24h，最长 14018:40 = 841120s（9.7 天），全是连载小说/
    // 直播回放（evidence/t15/T00-duration-anomaly.log）。它们照样上架，只是
    // 不印时长。
    //
    // 注意 B 站 duration 的格式：`MM:SS`，分钟可以超过 60。所以 `233:38` 是
    // 3.9 HOURS，不是 233 小时 —— 判超限必须按累加后的秒数，不能按冒号前的
    // 数字猜。
    //
    // 其余词都被钉成空页，这样两条 fixture 行必然占据长通道的第 1、2 位
    // （否则它们会被同通道 20 条 55 分钟行按热度挤出 6 格）。
    for (final word in const ['ASMR', '助眠', '白噪音', '鬼畜', '歌切', '纯音乐']) {
      _keyworded(word, (pn, ps) => <Map<String, dynamic>>[]);
    }
    for (final word in const ['文学朗读', '听书', '讲座']) {
      _keyworded(word, (pn, ps) => <Map<String, dynamic>>[]);
    }
    _keyworded('有声书', (pn, ps) => <Map<String, dynamic>>[
          _freshRow('BVlong00001', word: '有声书', typeid: 228,
              typename: '人文历史', duration: '14018:40', play: 500),
          _freshRow('BVlong00002', word: '有声书', typeid: 195,
              typename: '动态漫.广播剧', duration: '55:00', play: 400),
        ]);
    final feed = await rt.invoke('homeFeed') as Map;
    _expectNoError(feed);
    final albums = _list(feed['albums']).cast<Map>();
    final giant = albums.firstWhere((a) => a['id'] == 'BVlong00001');
    final label = '${(_list(giant['artists']).first as Map)['name']}';
    expect(label, '人文历史',
        reason: '超 24h 只显示分区名，不显示 233.6h —— 实际 "$label"');
    final normal = albums.firstWhere((a) => a['id'] == 'BVlong00002');
    expect('${(_list(normal['artists']).first as Map)['name']}',
        '动态漫.广播剧 · 55:00',
        reason: '正常长内容仍要显示时长');
    expect(233 * 60 + 38, 14018, reason: '233:38 = 3.9 小时，低于 24h 上限');
    expect(14018 * 60 + 40, 841120, reason: '14018:40 = 9.7 天，超上限');
  });

  test('T16#13 the home shelf reads ten words once and never the chart',
      () async {
    // 这是换源的核心断言：首页货架的请求构成必须变。
    seedFreshWords();
    _paged('ranking', (pn, ps) => _multiPartRank(3), pastEnd: PastEnd.notPaged);
    _resetCalls();
    final feed = await rt.invoke('homeFeed') as Map;
    _expectNoError(feed);
    expect(_callsOf('search'), 10, reason: '十词各一页');
    expect(_callsOf('ranking'), 0, reason: '首页不再读榜单 —— 它正是"不新"的来源');
    expect(_callsOf('view'), 0, reason: '搜索行没有 videos，不需要补详情');
    expect(_callsOf('popular'), 1, reason: 'popular 仍要读，featuredSongs 来自它');
    expect(_list(feed['featuredSongs']), isNotEmpty, reason: '首页歌曲不受换源影响');
  });

  test('T16#14 a second homeFeed is free inside the 20-minute TTL', () async {
    seedFreshWords();
    final first = await rt.invoke('homeFeed') as Map;
    _expectNoError(first);
    final searchBefore = _callsOf('search');
    final second = await rt.invoke('homeFeed') as Map;
    _expectNoError(second);
    expect(_callsOf('search') - searchBefore, 0,
        reason: 'TTL 内不得重发十词');
    expect(_list(second['albums']).length, _list(first['albums']).length);
  });

  test('T16#15 one bvid never occupies two slots, even across channels',
      () async {
    // 平台层：`fresh_channel_of` 可以让同一条行同时够两个通道的条件 ——
    // ASMR 词搜到的「助眠」朗读稿落在 228，按 want+标记 是 asmr；长词搜到
    // 的同一 bvid 落在 228，按 typeid 是 long。两个通道各有各的 `seen`，
    // 于是**同一条视频被上架两次、两个不同标签**。真机上真的出现过：
    // `ASMR · 39:52` 与 `人文历史 · 39:52` 是同一个 bvid
    // （截图留在本地，读数与说明见 evidence/t16/INDEX.md 的
    // 「一次被真机抓到的缺陷」一节）。
    //
    // 通道按 asmr → long → short 构建，高权重通道先认领，所以这里期望
    // 那条跨界稿以 ASMR 出现且只出现一次。
    _keyworded('助眠', (pn, ps) => <Map<String, dynamic>>[
          _freshRow('BVboth00001', word: '助眠', typeid: 228,
              typename: '人文历史', duration: '39:52', play: 500,
              title: '【助眠】睡前朗读 全一章'),
        ]);
    for (final word in const ['ASMR', '白噪音']) {
      _keyworded(word, (pn, ps) => <Map<String, dynamic>>[]);
    }
    // 长词搜到同一个 bvid。
    _keyworded('有声书', (pn, ps) => <Map<String, dynamic>>[
          _freshRow('BVboth00001', word: '有声书', typeid: 228,
              typename: '人文历史', duration: '39:52', play: 500,
              title: '【助眠】睡前朗读 全一章'),
        ]);
    for (final word in const ['文学朗读', '听书', '讲座', '鬼畜', '歌切', '纯音乐']) {
      _keyworded(word, (pn, ps) => <Map<String, dynamic>>[]);
    }
    final feed = await rt.invoke('homeFeed') as Map;
    _expectNoError(feed);
    final albums = _list(feed['albums']).cast<Map>();
    final ids = [for (final a in albums) '${a['id']}'];
    expect(ids.where((id) => id == 'BVboth00001').length, 1,
        reason: '同一个 bvid 只能占一格，实际 $ids');
    final label = '${(_list(albums.first['artists']).first as Map)['name']}';
    expect(label, '助眠 · 39:52',
        reason: '先认领的是高权重的 ASMR 通道，且标签写标题里的 ASMR 词，实际 "$label"');
  });

  test('T16#15b the same bvid under two words of one channel lands once',
      () async {
    // 十词之间会重叠（实测 10 词 300 条去重后 long 31 / asmr 52 / short 51）。
    // 去重是**整架一次**的，不是每通道一次：跨通道的重复也必须合并，见 T16#15。
    for (final word in const ['ASMR', '助眠', '白噪音']) {
      _keyworded(word, (pn, ps) => List.generate(20, (i) => _freshRow(
            'BVsame00001', word: word, typeid: 21, typename: '日常',
            duration: '30:00', play: 100 - i,
          )));
    }
    for (final word in const [
      '有声书', '文学朗读', '听书', '讲座', '鬼畜', '歌切', '纯音乐',
    ]) {
      _keyworded(word, (pn, ps) => <Map<String, dynamic>>[]);
    }
    final feed = await rt.invoke('homeFeed') as Map;
    _expectNoError(feed);
    final albums = _list(feed['albums']).cast<Map>();
    expect(albums.length, 1, reason: '同一个 bvid 在三个 ASMR 词里出现，只上架一次');
    expect(albums.first['id'], 'BVsame00001');
  });

  test('T16#16 the shelf never spends a view request', () async {
    // 搜索行没有 `videos`（0/20 实测），所以 songCount 写 1 是真话；
    // 逐条 view 会让首页多 16 个请求换不到信息（T14 §2.3 已证 +2.85 倍延迟）。
    seedFreshWords();
    _resetCalls();
    final feed = await rt.invoke('homeFeed') as Map;
    _expectNoError(feed);
    expect(_callsOf('view'), 0);
    expect(_list(feed['albums']).every((a) => (a as Map)['songCount'] == 1), isTrue,
        reason: '单条投稿的 songCount 就是 1');
  });

  // ---- T17 (v0.6.1): ASMR 标签写具体词，不写扁平的 `ASMR` ----
  //
  // v0.6.0 为了让 ASMR 通道与短通道的 `音乐综合` 区分开，把所有 asmr 通道的行
  // 一律写成 `ASMR`。区分问题解决了，但把线上本来就有的信息扔了：三个词加上
  // `tag` 字段已经能分出 助眠 / 白噪音 / 哄睡 / 环境音，卡片写
  // 「白噪音 · 20:11」比「ASMR · 20:11」有用（用户 2026-11-24 提出）。
  //
  // 判据是**位置**不是优先级：标题里最早出现的那个词胜出，标题一个都没有时
  // 才由 tag 字段决定。实测 61 行里 36 行标题带词、25 行只有 tag
  // （evidence/t17/label_tokens.log）。

  test('T17#01 the ASMR shelf names the word, not the umbrella', () async {
    // 三个 ASMR 词各给一条，标签必须各不相同 —— 扁平 `ASMR` 会让三条一样。
    for (final word in const ['ASMR', '助眠', '白噪音']) {
      _keyworded(word, (pn, ps) => <Map<String, dynamic>>[
            _freshRow('BVA${word.hashCode.abs() % 1000}'.padRight(12, '0'),
                word: word, typeid: 21, typename: '日常', duration: '20:11',
                title: '【$word】睡眠环境音', play: 100),
          ]);
    }
    for (final word in const [
      '有声书', '文学朗读', '听书', '讲座', '鬼畜', '歌切', '纯音乐',
    ]) {
      _keyworded(word, (pn, ps) => <Map<String, dynamic>>[]);
    }
    final feed = await rt.invoke('homeFeed') as Map;
    _expectNoError(feed);
    final labels = [
      for (final a in _list(feed['albums']).cast<Map>())
        '${(_list(a['artists']).first as Map)['name']}'
    ];
    expect(labels.toSet(), {'ASMR · 20:11', '助眠 · 20:11', '白噪音 · 20:11'},
        reason: '三条 ASMR 行的标签必须是各自的词（顺序由热度与 bvid 决定，'
            '所以比集合不比顺序），实际 $labels');
  });

  test('T17#02 the earliest token in the title wins over priority order',
      () async {
    // 「助眠」在前、「白噪音」在后：位置判据要选 助眠。按固定优先级（把
    // 白噪音排在 助眠 前面）会选 白噪音，两种规则在这里给出不同答案。
    _keyworded('助眠', (pn, ps) => <Map<String, dynamic>>[
          _freshRow('BVAorder00001', word: '助眠', typeid: 21, typename: '日常',
              duration: '30:00', title: '助眠向白噪音 雨声一小时', play: 100),
        ]);
    for (final word in const ['ASMR', '白噪音']) {
      _keyworded(word, (pn, ps) => <Map<String, dynamic>>[]);
    }
    for (final word in const [
      '有声书', '文学朗读', '听书', '讲座', '鬼畜', '歌切', '纯音乐',
    ]) {
      _keyworded(word, (pn, ps) => <Map<String, dynamic>>[]);
    }
    final feed = await rt.invoke('homeFeed') as Map;
    _expectNoError(feed);
    final album = _list(feed['albums']).cast<Map>().first;
    expect('${(_list(album['artists']).first as Map)['name']}', '助眠 · 30:00',
        reason: '标题里 助眠 在前，标签就该是 助眠');
  });

  test('T17#03 a filename-style row falls back to its tag, not to ASMR',
      () async {
    // 真机上一批行的标题是纯文件名/人名（「心跳声」「好看呆呆芦荟胶」），标题
    // 里一个词都没有，只有 `tag` 字段写 `助眠`。扁平 `ASMR` 会把它们埋掉。
    _keyworded('助眠', (pn, ps) => <Map<String, dynamic>>[
          _freshRow('BVAtag0000001', word: '助眠', typeid: 21, typename: '日常',
              duration: '5:54', title: '心跳声',
              tag: '助眠,放松,耳机', play: 100),
        ]);
    for (final word in const ['ASMR', '白噪音']) {
      _keyworded(word, (pn, ps) => <Map<String, dynamic>>[]);
    }
    for (final word in const [
      '有声书', '文学朗读', '听书', '讲座', '鬼畜', '歌切', '纯音乐',
    ]) {
      _keyworded(word, (pn, ps) => <Map<String, dynamic>>[]);
    }
    final feed = await rt.invoke('homeFeed') as Map;
    _expectNoError(feed);
    final album = _list(feed['albums']).cast<Map>().first;
    expect('${(_list(album['artists']).first as Map)['name']}', '助眠 · 5:54',
        reason: '标题无词时由 tag 决定，而不是退回扁平 ASMR');
  });

  test('T17#04 the ASMR label never leaks a wire zone name', () async {
    // 线上分区是 音乐综合 / 人文历史 时，标签仍必须是 ASMR 系的名字 —— 否则
    // 会和短/长通道自己的 `音乐综合`、`人文历史` 撞标签，那正是 v0.6.0 要修的
    // 问题（evidence/t16/R1_live_channels.log）。
    const cases = <List<Object>>[
      ['BVAlive00000001', 130, '音乐综合', '白噪音 · 8:52'],
      ['BVAlive00000002', 228, '人文历史', '助眠 · 12:16'],
      ['BVAlive00000003', 21, '日常', '哄睡 · 1:00:00'],
    ];
    _keyworded('助眠', (pn, ps) => <Map<String, dynamic>>[
          for (final c in cases)
            _freshRow(c[0] as String, word: '助眠', typeid: c[1] as int,
                typename: c[2] as String, duration: '8:52',
                title: '${c[3]}'.split(' · ').first + ' 素材',
                play: 100),
        ]);
    for (final word in const ['ASMR', '白噪音']) {
      _keyworded(word, (pn, ps) => <Map<String, dynamic>>[]);
    }
    for (final word in const [
      '有声书', '文学朗读', '听书', '讲座', '鬼畜', '歌切', '纯音乐',
    ]) {
      _keyworded(word, (pn, ps) => <Map<String, dynamic>>[]);
    }
    final feed = await rt.invoke('homeFeed') as Map;
    _expectNoError(feed);
    final labels = [
      for (final a in _list(feed['albums']).cast<Map>())
        '${(_list(a['artists']).first as Map)['name']}'
    ];
    expect(labels, isNotEmpty);
    for (final label in labels) {
      for (final zone in const ['音乐综合', '人文历史', '日常']) {
        expect(label.contains(zone), isFalse,
            reason: 'ASMR 槽的标签不得出现线上分区「$zone」，实际 "$label"');
      }
    }
  });

  test('T11#01 artistSongs(limit=100) answers on the REAL two-page response',
      () async {
    // 宿主的 UP 主页固定 limit=100（platform_catalog.dart:285-287）。v0.4.2 在
    // 这条调用上 408，而 T4#18 用的是 `_bulkVlist` 的 6 字段短行 —— 覆盖缺口。
    // 这里用的是 evidence/t11 落盘的真机原样 body：38 字段/行、标题最长 60 字节、
    // 含 `&` 实体。
    _realArcMode = true;
    try {
      final result = await rt.invoke('artistSongs', {'id': '7000003', 'limit': 100, 'offset': 0});
      expect(result is List, isTrue, reason: '不得是 {error} 或空表：$result');
      final rows = result as List;
      expect(rows.length, 100, reason: '两页各 50 行必须都映射出来');
      expect((rows.first as Map)['id'], 'BV1LFyVzdEjV');
      expect((rows.last as Map)['id'], 'BV197421f76g');
      // 标题必须是清洗后的：无 '<'，且含 '&' 的真标题原样保留 '&'（不是实体）。
      final titles = [for (final r in rows) '${(r as Map)['title']}'];
      expect(titles.every((t) => !t.contains('<')), isTrue);
      expect(titles.any((t) => t.contains('&')), isTrue,
          reason: '真机标题里就有 &，它不该被丢掉或被转义');
      // 时长与作者必须来自行本身。
      expect((rows.first as Map)['durationMs'], 442000);
      final artists = (rows.first as Map)['artists'] as List;
      expect((artists.first as Map)['name'], 'uploader_07x');
    } finally {
      _realArcMode = false;
    }
  });

  test('T11#02 the 51st..188th uploads stay reachable on the real response',
      () async {
    // 第 3/4 页是 50+38 行、第 5 页空。宿主的 all() 靠 hasMore 逐页走，
    // 所以 offset=100 必须给出剩下的 88 行，且与首页不重叠。
    _realArcMode = true;
    try {
      final first = await rt.invoke('artistSongs', {'id': '7000003', 'limit': 100, 'offset': 0}) as List;
      final rest = await rt.invoke('artistSongs', {'id': '7000003', 'limit': 100, 'offset': 100}) as List;
      expect(rest.length, 88);
      final headIds = first.map((r) => (r as Map)['id']).toSet();
      expect(rest.any((r) => headIds.contains((r as Map)['id'])), isFalse,
          reason: '两页不得重叠');
      // past-end：第 5 页空 -> 空页（Lua 空表到 Dart 是 {}），不是错误。
      final past = await rt.invoke('artistSongs', {'id': '7000003', 'limit': 100, 'offset': 188});
      expect(past is List ? past.isEmpty : (past as Map).isEmpty, isTrue);
      // 而且空页不得毒化游标：再问一次首页仍要给出 100 行。
      final again = await rt.invoke('artistSongs', {'id': '7000003', 'limit': 100, 'offset': 0}) as List;
      expect(again.length, 100);
    } finally {
      _realArcMode = false;
    }
  });

  test('T11#03 clean_title keeps markup and entity semantics', () async {
    // 快路径是纯优化，语义必须逐字不变：带标记的仍要剥标签 + 解实体。
    _paged('space_arc', (pn, ps) => <Map<String, dynamic>>[
      if (pn == 1) ...<Map<String, dynamic>>[
        {
          'bvid': 'BV1clean0001',
          'title': '<em class="keyword">周杰伦</em> &amp; 方文山 &#39;经典&#39;',
          'author': 'UP&amp;co',
          'mid': 888,
          'pic': '//i0.hdslb.com/bfs/a.jpg',
          'length': '3:00',
        },
        {
          'bvid': 'BV1clean0002',
          'title': '纯文本 & 符号 无标记',
          'author': 'UP',
          'mid': 888,
          'pic': '//i0.hdslb.com/bfs/b.jpg',
          'length': '4:00',
        },
      ],
    ], total: 2, pastEnd: PastEnd.keepsTotal);
    final rows = await rt.invoke('artistSongs', {'id': '888', 'limit': 10, 'offset': 0}) as List;
    expect(rows.length, 2);
    expect((rows[0] as Map)['title'], "周杰伦 & 方文山 '经典'");
    expect((rows[1] as Map)['title'], '纯文本 & 符号 无标记');
    // 作者名也走同一条路径，同样要解实体。
    expect(((rows[0] as Map)['artists'] as List).first['name'], 'UP&co');
  });

  // ---- T13: 多 P 可见性（albumName 带 `· N P`） ----
  //
  // 缺陷不是"选不到 P2"，是"看不出这里能选 P2"：`models.song` 给所有视频同一个
  // 泛名 `B站视频`，而 `desktop_now_playing.dart:532` 的专辑名是唯一不依赖列表
  // 的入口。T13/D3 把规则钉成 `视频标题 · N P`，N 分别取自 row.videos（列表行、
  // view 顶层 videos）或 #pages（album_songs），search 与收藏夹行没有 videos
  // （实测 0/20 与 0/19）所以不加后缀（D4）。

  List<Map<String, dynamic>> _hotRowsForT13() => <Map<String, dynamic>>[
        <String, dynamic>{
          'bvid': 'BV1t13multi',
          'title': '热门 3',
          'pic': '//i0.hdslb.com/bfs/hot/m3.jpg',
          'duration': '3:00',
          'author': 'UP3',
          'mid': 103,
          'videos': 3,
          'pid_v2': 1003,
        },
        <String, dynamic>{
          'bvid': 'BV1t13single',
          'title': '热门 2',
          'pic': '//i0.hdslb.com/bfs/hot/s2.jpg',
          'duration': '3:00',
          'author': 'UP2',
          'mid': 102,
          'videos': 1,
          'pid_v2': 1003,
        },
      ];

  test('T13#01 a multi-part list row names its album "标题 · 3 P"', () async {
    _paged('popular', (pn, ps) => _hotRowsForT13(), pastEnd: PastEnd.notPaged);
    _paged('ranking', (pn, ps) => <Map<String, dynamic>>[], pastEnd: PastEnd.notPaged);
    final feed = await rt.invoke('homeFeed') as Map;
    _expectNoError(feed);
    final songs = _list(feed['featuredSongs']).cast<Map>();
    final multi = songs.firstWhere((s) => s['id'] == 'BV1t13multi');
    expect(multi['albumName'], '热门 3 · 3 P',
        reason: 'N 取该行的 videos，标题与后缀用同一个分隔符');
    expect(multi['albumId'], 'BV1t13multi', reason: 'D2：albumId 仍是 bvid，可点');
  });

  test('T13#02 a single-part list row keeps the plain title, no suffix', () async {
    _paged('popular', (pn, ps) => _hotRowsForT13(), pastEnd: PastEnd.notPaged);
    _paged('ranking', (pn, ps) => <Map<String, dynamic>>[], pastEnd: PastEnd.notPaged);
    final feed = await rt.invoke('homeFeed') as Map;
    _expectNoError(feed);
    final single = _list(feed['featuredSongs'])
        .cast<Map>()
        .firstWhere((s) => s['id'] == 'BV1t13single');
    // **这条期望值在本轮改过**：原 D3 是"统一加后缀"，` · 1 P` 也要有。用户在
    // 真机看过宽屏专辑列之后改成"只给多 P 加"——单 P 加 ` · 1 P` 只让专辑列
    // 与标题列更像重复的一行字，而 1 P 的视频本来就没有 P 可选，后缀帮不上忙。
    // 所以现在单 P 行与"没有 videos"的行显示相同：都是纯标题。
    expect(single['albumName'], '热门 2',
        reason: '单 P 不加后缀（用户确认的 D3 修订）');
    expect(single['albumId'], 'BV1t13single', reason: '仍可点进专辑页');
  });

  test('T13#03 a search row leaves the album name blank for song() to fill', () async {
    // S1（T14）改写了这条规则。原来要求 `albumName == title`，理由是"没有 N
    // 就别写后缀"。但宿主的队列合并是
    //   album: entry.album.isEmpty ? updated.album : entry.album
    // （music_platform_state.dart:635）：一旦把纯标题写进队列条目，之后
    // `song()` 返回的「标题 · N P」永远进不来，播放页就看不到有几 P。
    //
    // 所以 search / 收藏夹这两类**没有 videos 的行**改成留空，等播放时由
    // `song()` 补上带后缀的称呼。空串不是"没有专辑"，是"还没问到"。
    final result = await rt.invoke('search', {'query': '周杰伦', 'limit': 20, 'offset': 0}) as Map;
    _expectNoError(result);
    final songs = _list(result['songs']).cast<Map>();
    expect(songs, isNotEmpty);
    for (final song in songs) {
      expect(song['albumName'], '',
          reason: 'search 行留空，好让播放时的 song() 覆盖');
      expect(song['albumId'], song['id'],
          reason: 'albumId 仍是 bvid，专辑页入口不受影响');
      expect('${song['albumId']}'.isNotEmpty, isTrue);
    }
  });

  test('T13#03b playing a search row upgrades the album name to "标题 · N P"',
      () async {
    // 上一条的**目的**：留空之后，播放时 song() 必须真的给出带后缀的称呼。
    // 没有这条，留空就只是把信息删掉了。
    _multiPart = true;
    try {
      final song = await rt.invoke('song', {'id': 'BVmulti00001'}) as Map;
      _expectNoError(song);
      expect(song['albumName'], '三 P 视频 · 3 P');
    } finally {
      _multiPart = false;
    }
  });

  test('T13#04 a favourites row leaves the album name blank too', () async {
    // fav_resources.json 的 `_note`：0/19 既无 videos 也无顶层 cid，与 search
    // 同族，处理必须一致。S1。
    await login();
    final songs = _list(await rt.invoke('playlistSongs',
        {'id': '72000000', 'limit': 20, 'offset': 0}));
    expect(songs, isNotEmpty);
    for (final song in songs.cast<Map>()) {
      expect(song['albumName'], '');
    }
  });

  test('T13#04b rows that DO carry videos still name the album immediately',
      () async {
    // 留空只针对"不知道 N"的行。热门/榜单行有 videos，必须当场写名字——
    // 否则这一轮的改动会顺手把 T13 的整个可见性目标退回去。
    _paged('popular', (pn, ps) => _hotRowsForT13(), pastEnd: PastEnd.notPaged);
    _paged('ranking', (pn, ps) => <Map<String, dynamic>>[], pastEnd: PastEnd.notPaged);
    final feed = await rt.invoke('homeFeed') as Map;
    _expectNoError(feed);
    final rows = _list(feed['featuredSongs']).cast<Map>();
    expect(rows, isNotEmpty);
    for (final row in rows) {
      expect('${row['albumName']}'.isNotEmpty, isTrue,
          reason: '有 videos 的行不该留空');
    }
  });

  test('T13#05 albumSongs names every part with the video\'s total part count', () async {
    _multiPart = true;
    try {
      final rows = _list(await rt.invoke('albumSongs',
          {'id': 'BVmulti00001', 'limit': 100, 'offset': 0})).cast<Map>();
      expect(rows.length, 3);
      for (final row in rows) {
        expect(row['albumName'], '三 P 视频 · 3 P',
            reason: '同一个专辑名，N 是这支视频的总 P 数');
      }
      // 标题仍是分 P 名：D3 要求标题与专辑名不同，否则列表两列同字。
      expect(rows.map((r) => r['title']).toList(),
          ['P1 第一部分', 'P2 第二部分', 'P3 第三部分']);
    } finally {
      _multiPart = false;
    }
  });

  test('T13#05b a bad part does not shrink the album name\'s part count', () async {
    // `albumName` 描述的是"这支视频有几 P"，不是"这里能播几 P"。第 2 个 P 的
    // cid 为空时它会被过滤掉（无法播放），但总数仍是 3。
    // 这是 N3 的靶子：把 N 改成 #mappable 就会说"2 P"，说小了。
    _multiPart = true;
    _emptyCidAt = 2;
    try {
      final rows = _list(await rt.invoke('albumSongs',
          {'id': 'BVmulti00001', 'limit': 100, 'offset': 0})).cast<Map>();
      expect(rows.length, 2, reason: 'cid 为空的 P 播不了，不进行空间');
      for (final row in rows) {
        expect(row['albumName'], '三 P 视频 · 3 P',
            reason: '总数取 #pages=3，不随丢掉的坏 P 缩小');
      }
    } finally {
      _emptyCidAt = 0;
      _multiPart = false;
    }
  });

  test('T13#06 song(bvid:cid) names the album after the whole video', () async {
    _multiPart = true;
    try {
      final song = await rt.invoke('song', {'id': 'BVmulti00001:2002'}) as Map;
      _expectNoError(song);
      expect(song['title'], '第二部分', reason: '标题仍是这一 P 的');
      expect(song['albumName'], '三 P 视频 · 3 P', reason: '专辑名是整支视频的');
    } finally {
      _multiPart = false;
    }
  });

  test('T13#07 song(plain bvid) names the album from view.pages', () async {
    _multiPart = true;
    try {
      final song = await rt.invoke('song', {'id': 'BVmulti00001'}) as Map;
      _expectNoError(song);
      expect(song['albumName'], '三 P 视频 · 3 P',
          reason: 'view 的 #pages 就是 N，零额外请求');
      final extra = song['extra'] as Map;
      expect(extra['parts'], 3);
    } finally {
      _multiPart = false;
    }
  });

  test('T13#08 no row falls back to the generic "B站视频" name', () async {
    _paged('popular', (pn, ps) => _hotRowsForT13(), pastEnd: PastEnd.notPaged);
    _paged('ranking', (pn, ps) => <Map<String, dynamic>>[], pastEnd: PastEnd.notPaged);
    final feed = await rt.invoke('homeFeed') as Map;
    _expectNoError(feed);
    final search = await rt.invoke('search', {'query': '周杰伦', 'limit': 20, 'offset': 0}) as Map;
    _expectNoError(search);
    final seen = <Map>[
      ..._list(feed['featuredSongs']).cast<Map>(),
      ..._list(search['songs']).cast<Map>(),
    ];
    expect(seen, isNotEmpty);
    for (final row in seen) {
      expect(row['albumName'], isNot('B站视频'),
          reason: '${row['title']} 落回了泛名，正在播放页的入口又会看不出是什么');
    }
    // 「非空」只对有 `videos` 的行成立（S1）：search / 收藏夹行留空是**有意**
    // 的，好让播放时 song() 补成带后缀的称呼。这里分组断言，避免把两条相反
    // 的规则写成一个含糊的循环。
    final named = _list(feed['featuredSongs']).cast<Map>();
    expect(named, isNotEmpty);
    for (final row in named) {
      expect(row['albumName'], isNotEmpty,
          reason: '有 videos 的行必须当场写出名字');
    }
  });

  test('T13#11 a long title is clipped so the " · N P" suffix survives', () async {
    // 宿主按末尾省略号截断（player_controls_bar.dart:131、
    // desktop_now_playing.dart:532）。60 列的标题会把 ` · N P` 整段吃掉，
    // 专辑行又变回"看不出有几 P"——真机 `BV1q4FTeBEMj`（标题 60 列）就是这样。
    // 修法：`util.fit_label` 先量后缀，剩余列数才给标题。
    const long = '【无损音质】周杰伦歌曲精选100首 歌词版纯享 地表最高音质 每一首都是顶级文案 中国流行音乐开拓者JAY';
    _paged('popular', (pn, ps) => <Map<String, dynamic>>[
          <String, dynamic>{
            'bvid': 'BV1t13long',
            'title': long,
            'pic': '//i0.hdslb.com/bfs/hot/long.jpg',
            'duration': '3:00',
            'author': 'UP',
            'mid': 101,
            'videos': 100,
            'pid_v2': 1003,
          },
        ], pastEnd: PastEnd.notPaged);
    _paged('ranking', (pn, ps) => <Map<String, dynamic>>[], pastEnd: PastEnd.notPaged);
    final feed = await rt.invoke('homeFeed') as Map;
    _expectNoError(feed);
    final row = _list(feed['featuredSongs']).cast<Map>().first;
    final name = '${row['albumName']}';
    expect(name, endsWith(' · 100 P'), reason: '后缀必须完整保留');
    expect(name.endsWith('…'), isFalse, reason: '省略号在标题里，不在结尾');
    expect(name, startsWith('【无损音质】'), reason: '标题前缀保留（裁尾不裁头）');
    expect(name.contains('… · 100 P'), isTrue,
        reason: '裁掉的标题以省略号收尾，后缀紧跟其后');
    // 整串预算 32 列（`models.ALBUM_LABEL_COLUMNS`），后缀 ` · 100 P` 占 8 列，
    // 省略号占 1 列，剩下的才给标题。全角标题 2 列/字 → 11 个字 + 省略号 = 23 列，
    // 加后缀共 31 列，仍在 32 之内。断言按**字符**数（本运行时 string.len 就是
    // 字符数，实测见 evidence/t13/CLIP_PROBE.log）。
    final cut = name.substring(0, name.indexOf('…'));
    expect(cut.length, lessThanOrEqualTo(11),
        reason: '全角标题按 2 列/字算，预算扣掉后缀与省略号后最多 11 个字');
    expect(cut.length, greaterThanOrEqualTo(6),
        reason: '不能裁到只剩一两个字，否则标题没有信息量');
    // 逐字钉住。**这条曾经钉的是 `【无损音质】周杰伦歌曲精… · 100 P`（12 字），
    // 而那正是 `fit_label` 越界 1 列的产物**——探针实测 outCols=33 > budget=32
    // （`FIT_LABEL_PROBE.log`）。断言把 bug 当成正确答案钉了下来，是这一轮
    // 修 `fit_label` 时才发现的。现在的值是扣掉省略号那一列之后的。
    expect(name, '【无损音质】周杰伦歌曲… · 100 P',
        reason: '逐字钉住，避免"看起来对"的裁剪');
    // 标题列不受影响：用户要读全。
    expect(row['title'], long, reason: '只裁 albumName，title 保持原文');
  });

  test('T13#12 album_songs clips the same way as a list row', () async {
    // 两条构造点必须用同一个列数，否则同一支视频从列表进和从专辑页进
    // 会得到不同的专辑名（D5 的核心要求）。
    _multiPart = true;
    _multiPartParts = 2;
    try {
      final rows = _list(await rt.invoke('albumSongs',
          {'id': 'BVmulti00001', 'limit': 100, 'offset': 0})).cast<Map>();
      expect(rows, isNotEmpty);
      // fixture 的标题"三 P 视频"只有 8 列，不触发裁剪，但形状必须一致。
      for (final row in rows) {
        expect(row['albumName'], '三 P 视频 · 2 P');
      }
    } finally {
      _multiPart = false;
      _multiPartParts = 3;
    }
  });

  test('T13#13 the suffix width is charged against the title budget', () async {
    // `util.fit_label` 先量后缀再决定标题能占几列。同样 53 字的标题，
    // ` · 100 P`（8 列）与 ` · 2 P`（5 列）留给标题的宽度差 3 列，所以裁出来
    // 的标题长度必须不同。固定裁标题再拼后缀的实现会让两者相等——这正是
    // 上一版在真机上仍被宿主省略号吃掉后缀的原因。
    const long = '【无损音质】周杰伦歌曲精选100首 歌词版纯享 地表最高音质 每一首都是顶级文案 中国流行音乐开拓者JAY';
    int suffixOf(String name) => name.lastIndexOf(' · ');
    // 同一页里放两行，避免第二次 homeFeed 命中 wide 缓存而拿到上一轮的结果
    // （缓存是 6 h、按 bvid 无关的整架缓存，不是这次要测的东西）。
    _paged('popular', (pn, ps) => <Map<String, dynamic>>[
          <String, dynamic>{
            'bvid': 'BV1t13bud100',
            'title': long,
            'pic': '//i0.hdslb.com/bfs/hot/b100.jpg',
            'duration': '3:00',
            'author': 'UP',
            'mid': 101,
            'videos': 100,
            'pid_v2': 1003,
          },
          <String, dynamic>{
            'bvid': 'BV1t13bud002',
            'title': long,
            'pic': '//i0.hdslb.com/bfs/hot/b002.jpg',
            'duration': '3:00',
            'author': 'UP',
            'mid': 102,
            'videos': 2,
            'pid_v2': 1003,
          },
        ], pastEnd: PastEnd.notPaged);
    _paged('ranking', (pn, ps) => <Map<String, dynamic>>[], pastEnd: PastEnd.notPaged);
    final feed = await rt.invoke('homeFeed') as Map;
    _expectNoError(feed);
    final songs = _list(feed['featuredSongs']).cast<Map>();
    final names = <int, String>{
      for (final row in songs)
        (row['albumId'] == 'BV1t13bud100' ? 100 : 2): '${row['albumName']}',
    };
    expect(names[100], endsWith(' · 100 P'));
    expect(names[2], endsWith(' · 2 P'));
    final title100 = names[100]!.substring(0, suffixOf(names[100]!));
    final title2 = names[2]!.substring(0, suffixOf(names[2]!));
    expect(title100.length, lessThan(title2.length),
        reason: '100 P 的后缀更宽，留给标题的列数必须更少');
    expect(title2.length - title100.length, greaterThanOrEqualTo(1),
        reason: '3 列差距至少要体现为 1 个全角字');
    // 两条都还能看见 P 数，也就是这个修复的目的。
    expect(names[100]!.contains('P'), isTrue);
    expect(names[2]!.contains('P'), isTrue);
  });

  test('T13#14 the fitted album name never exceeds its column budget', () async {
    // T13#11/#13 钉的是"后缀活下来"和"后缀宽度参与预算"，都没有钉**上限**。
    // 缺的正是这一条：`fit_label` 曾经把 room 整份交给 `clip`，而 `clip` 会先
    // 填满 room 列再追加省略号，于是整串超出预算 1 列（探针实测 outCols=33 vs
    // budget=32）。宿主按列宽省略，超出 1 列就是后缀被吃掉。
    //
    // 这里用 `util.columns` 的语义在 Dart 侧独立重算列宽（全角 2 / 半角 1），
    // 不复用插件里的判断——那样才是真的独立校验，而不是把同一个 bug 抄两遍。
    int cols(String text) {
      var total = 0;
      for (final rune in text.runes) {
        final wide = (rune >= 0x1100 && rune <= 0x115F) ||
            (rune >= 0x2E80 && rune <= 0xA4CF) ||
            (rune >= 0xAC00 && rune <= 0xD7A3) ||
            (rune >= 0xF900 && rune <= 0xFAFF) ||
            (rune >= 0xFE30 && rune <= 0xFE6F) ||
            (rune >= 0xFF00 && rune <= 0xFF60) ||
            (rune >= 0xFFE0 && rune <= 0xFFE6) ||
            (rune >= 0x1F300 && rune <= 0x1FAFF);
        total += wide ? 2 : 1;
      }
      return total;
    }

    const long = '【无损音质】周杰伦歌曲精选100首 歌词版纯享 地表最高音质 每一首都是顶级文案 中国流行音乐开拓者JAY';
    const mixed = 'GTA6 性能要求高吗？哪台主机表现好？解锁 30 帧后能跑多少帧？';
    // 100 P 是最宽的后缀（8 列），1 P 最窄；两种标题宽度都要守住同一条上限。
    // **全部塞进同一次 homeFeed**：专辑架有 6 h 缓存，多调几次拿到的是同一份
    // 结果（第一次写这条断言就踩了，第二次调用读到的是上一轮的 ` · 100 P`）。
    final cases = <Map<String, dynamic>>[];
    var caseId = 0;
    for (final parts in <int>[100, 2, 1]) {
      for (final title in <String>[long, mixed]) {
        caseId += 1;
        cases.add(<String, dynamic>{
          'bvid': 'BV1t13bd${caseId.toString().padLeft(4, '0')}',
          'title': title,
          'pic': '//i0.hdslb.com/bfs/hot/b$caseId.jpg',
          'duration': '3:00',
          'author': 'UP',
          'mid': 100 + caseId,
          'videos': parts,
          'pid_v2': 1003,
          // parts == 1 没有后缀（D3 修订），此时要求"整串 = 纯标题"，
          // 也就是标题**完全不被裁**。这条与 100 P/2 P 一起守同一条上限。
          '_want': parts > 1 ? ' · $parts P' : '',
          '_plain': parts <= 1,
        });
      }
    }
    _paged('popular', (pn, ps) => cases, pastEnd: PastEnd.notPaged);
    _paged('ranking', (pn, ps) => <Map<String, dynamic>>[], pastEnd: PastEnd.notPaged);
    final feed = await rt.invoke('homeFeed') as Map;
    _expectNoError(feed);
    final rows = _list(feed['featuredSongs']).cast<Map>();
    expect(rows.length, cases.length, reason: '六条都要出现在架子上');
    for (final want in cases) {
      final row = rows.firstWhere((r) => r['albumId'] == want['bvid'],
          orElse: () => <String, dynamic>{});
      expect(row, isNotEmpty, reason: '${want['bvid']} 必须出现在架子上');
      final name = '${row['albumName']}';
      if (want['_plain'] == true) {
        // 单 P：不带后缀，也不裁——没有后缀要保护，裁了只会白丢标题。
        expect(name, want['title'], reason: '单 P 的专辑名就是完整标题');
        continue;
      }
      expect(cols(name), lessThanOrEqualTo(32),
          reason: '${want['bvid']} 的专辑名 $cols(name) 列，'
              '超过 models.ALBUM_LABEL_COLUMNS=32 就会被宿主吃掉后缀：$name');
      expect(name, endsWith('${want['_want']}'), reason: '后缀必须完整：$name');
    }
  });

  test('T13#10 search still spends zero view requests', () async {
    // 后缀完全由行内字段推出，不得为了拿 N 去发 view——search 的解码上限
    // （40 行/桶，50 行即 408）没有任何余量给逐行探测。
    _resetCalls();
    await rt.invoke('search', {'query': '周杰伦', 'limit': 20, 'offset': 0});
    expect(_callsOf('view'), 0, reason: 'search 的 N 不可得，就地不加后缀');
  });
}
