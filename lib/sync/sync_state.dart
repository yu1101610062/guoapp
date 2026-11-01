import 'dart:convert';
import 'dart:math';

const syncCategories = ['favorites', 'history', 'preferences'];
const syncedPreferences = ['speed', 'quality', 'autoAdvance', 'danmaku'];

String newSyncId() {
  final random = Random.secure();
  return List.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

Map<String, dynamic> jsonMap(Object? value) =>
    Map<String, dynamic>.from(value as Map);

/// An HLC orders operations, not uploads. Retrying never advances this clock.
class SyncVersion implements Comparable<SyncVersion> {
  const SyncVersion(this.wall, this.logical, this.device);
  final int wall, logical;
  final String device;
  factory SyncVersion.fromJson(Object? value) {
    final v = value as List;
    if (v.length != 3 ||
        v[0] is! int ||
        v[1] is! int ||
        v[2] is! String ||
        (v[0] as int) < 0 ||
        (v[1] as int) < 0) {
      throw const FormatException('版本无效');
    }
    return SyncVersion(v[0], v[1], v[2]);
  }
  List<Object> toJson() => [wall, logical, device];
  @override
  int compareTo(SyncVersion other) {
    final w = wall.compareTo(other.wall);
    if (w != 0) return w;
    final l = logical.compareTo(other.logical);
    return l != 0 ? l : device.compareTo(other.device);
  }
}

class SyncRecord {
  const SyncRecord({
    required this.key,
    required this.version,
    required this.time,
    this.data,
    this.session = '',
    this.uncertain = false,
  });
  final String key, session;
  final SyncVersion version;
  final int time;
  final Map<String, dynamic>? data;
  final bool uncertain;
  bool get deleted => data == null;
  Map<String, dynamic> toJson() => {
    'key': key,
    'version': version.toJson(),
    'time': time,
    'data': data,
    'session': session,
    'uncertain': uncertain,
  };
  factory SyncRecord.fromJson(Object? value) {
    final v = jsonMap(value);
    if (v['key'] is! String ||
        (v['key'] as String).isEmpty ||
        v['time'] is! int) {
      throw const FormatException('记录无效');
    }
    return SyncRecord(
      key: v['key'],
      version: SyncVersion.fromJson(v['version']),
      time: v['time'],
      data: v['data'] == null ? null : jsonMap(v['data']),
      session: v['session'] as String? ?? '',
      uncertain: v['uncertain'] == true,
    );
  }
}

/// Profile-specific state. Credentials and installation identity live elsewhere.
class SyncState {
  SyncState();
  final Map<String, Map<String, List<SyncRecord>>> records = {
    for (final c in syncCategories) c: {},
  };
  final Map<String, int> revision = {for (final c in syncCategories) c: 0};
  final Map<String, int> uploaded = {for (final c in syncCategories) c: 0};
  final Map<String, String> seen = {};
  final Map<String, String> devices = {};
  SyncVersion? clock;
  SyncVersion? clearHistory;
  Map<String, dynamic>? binding;
  int sequence = 0;
  int? lastSuccess;
  bool needsReview = false;
  bool automatic = true;
  bool clockUncertain = false;
  int clockOffset = 0;
  int get pending => syncCategories
      .where((c) => revision[c]! > uploaded[c]!)
      .fold(0, (n, c) => n + revision[c]! - uploaded[c]!);
  Set<String> get dirty =>
      syncCategories.where((c) => revision[c]! > uploaded[c]!).toSet();
  SyncState copy() => SyncState.fromJson(toJson());
  SyncVersion tick(String device, {int? now}) {
    final physical =
        (now ?? DateTime.now().millisecondsSinceEpoch) + clockOffset;
    final wall = max(physical, clock?.wall ?? 0);
    clock = SyncVersion(
      wall,
      wall == clock?.wall ? clock!.logical + 1 : 0,
      device,
    );
    return clock!;
  }

  void observe(SyncVersion v) {
    if (clock == null || v.compareTo(clock!) > 0) clock = v;
  }

  void put(
    String category,
    String key,
    Map<String, dynamic>? data,
    String device, {
    String session = '',
    int? time,
  }) {
    final record = SyncRecord(
      key: key,
      version: tick(device),
      time: time ?? DateTime.now().millisecondsSinceEpoch,
      data: data,
      session: session,
      uncertain: clockUncertain,
    );
    final old = records[category]![key] ?? [];
    records[category]![key] = category == 'history'
        ? [...old, record]
        : [record];
    revision[category] = revision[category]! + 1;
  }

  Map<String, dynamic> categoryJson(String c) => {
    'protocol': 1,
    'recordVersion': 1,
    'category': c,
    'clear': c == 'history' ? clearHistory?.toJson() : null,
    'records': [
      for (final key in records[c]!.keys.toList()..sort())
        for (final r in records[c]![key]!) r.toJson(),
    ],
  };
  Map<String, dynamic> toJson() => {
    'protocol': 1,
    'categories': {for (final c in syncCategories) c: categoryJson(c)},
    'revision': revision,
    'uploaded': uploaded,
    'clock': clock?.toJson(),
    'seen': seen,
    'devices': devices,
    'binding': binding,
    'sequence': sequence,
    'lastSuccess': lastSuccess,
    'needsReview': needsReview,
    'automatic': automatic,
    'clockOffset': clockOffset,
    'clockUncertain': clockUncertain,
  };
  factory SyncState.fromJson(Object? value) {
    final v = jsonMap(value);
    if (v['protocol'] != 1) throw const FormatException('同步协议版本不支持');
    final state = SyncState();
    for (final c in syncCategories) {
      final cat = jsonMap((v['categories'] as Map)[c]);
      for (final raw in cat['records'] as List) {
        final r = SyncRecord.fromJson(raw);
        (state.records[c]![r.key] ??= []).add(r);
      }
      if (c == 'history' && cat['clear'] != null) {
        state.clearHistory = SyncVersion.fromJson(cat['clear']);
      }
      state.revision[c] = (v['revision'] as Map)[c] as int;
      state.uploaded[c] = (v['uploaded'] as Map)[c] as int;
    }
    state.clock = v['clock'] == null ? null : SyncVersion.fromJson(v['clock']);
    state.binding = v['binding'] == null ? null : jsonMap(v['binding']);
    state.seen.addAll(Map<String, String>.from(v['seen'] as Map? ?? {}));
    state.devices.addAll(Map<String, String>.from(v['devices'] as Map? ?? {}));
    state.sequence = v['sequence'] as int? ?? 0;
    state.lastSuccess = v['lastSuccess'] as int?;
    state.needsReview = v['needsReview'] == true;
    state.automatic = v['automatic'] != false;
    state.clockOffset = v['clockOffset'] as int? ?? 0;
    state.clockUncertain = v['clockUncertain'] == true;
    return state;
  }
}

String syncDramaKey(Map<String, dynamic> drama) {
  final source = drama['source'] as String? ?? '';
  final id = drama['sourceId'] as String? ?? '';
  final full = drama['id'] as String? ?? '';
  if (source.isEmpty || (id.isEmpty && full.isEmpty)) {
    throw const FormatException('站源身份缺失');
  }
  final sourceId = id.isNotEmpty
      ? id
      : full.startsWith('$source:')
      ? full.substring(source.length + 1)
      : full;
  return jsonEncode([source, sourceId]);
}

/// No controller dependency in persistence or the player (also useful in tests).
abstract interface class SyncHooks {
  void changed({bool progress = false, bool urgent = false});
  Future<void> beforeResume();
}
