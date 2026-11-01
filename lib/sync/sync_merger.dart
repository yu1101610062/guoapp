import 'dart:convert';

import '../models.dart';
import '../playback_preferences.dart';
import 'sync_state.dart';

class SyncMerger {
  static List<SyncRecord> compact(
    String category,
    Iterable<SyncRecord> input, {
    SyncVersion? clear,
  }) {
    final rows = input.toList()
      ..sort((a, b) {
        final v = b.version.compareTo(a.version);
        // A malformed duplicate version must still converge deterministically.
        return v != 0
            ? v
            : jsonEncode(b.toJson()).compareTo(jsonEncode(a.toJson()));
      });
    if (category != 'history') return rows.take(1).toList();
    final deletion = rows.where((r) => r.deleted).firstOrNull;
    final barrier = deletion == null
        ? clear
        : clear == null || deletion.version.compareTo(clear) > 0
        ? deletion.version
        : clear;
    final sessions = <String>{};
    final positions = rows
        .where(
          (r) =>
              !r.deleted &&
              (barrier == null || r.version.compareTo(barrier) > 0) &&
              sessions.add('${r.version.device}/${r.session}'),
        )
        .take(3);
    return [?deletion, ...positions];
  }

  static void validateCategory(Map<String, dynamic> doc) {
    if (doc['protocol'] != 1 ||
        doc['recordVersion'] != 1 ||
        !syncCategories.contains(doc['category'])) {
      throw const FormatException('同步协议版本不支持');
    }
    final c = doc['category'] as String;
    final rows = doc['records'] as List;
    if (rows.length > 100000) throw const FormatException('同步记录过多');
    if (doc['clear'] != null) SyncVersion.fromJson(doc['clear']);
    for (final raw in rows) {
      final r = SyncRecord.fromJson(raw);
      if (r.deleted) continue;
      final data = r.data!;
      if (c == 'preferences') {
        if (!syncedPreferences.contains(r.key) ||
            data.keys.length != 1 ||
            !data.containsKey('value')) {
          throw const FormatException('播放偏好无效');
        }
        PlaybackPreferences.fromJson({r.key: data['value']});
      } else {
        final drama = c == 'history' ? jsonMap(data['drama']) : data;
        if (syncDramaKey(drama) != r.key) {
          throw const FormatException('站源身份不一致');
        }
        final identity = jsonDecode(r.key) as List;
        if (drama['id'] != '${identity[0]}:${identity[1]}') {
          throw const FormatException('剧集 ID 必须包含站源');
        }
        Drama.fromJson(drama);
        if (c == 'history') {
          final watch = WatchEntry.fromJson(data);
          if (watch.episode < 1 ||
              !watch.position.isFinite ||
              watch.position < 0 ||
              !watch.duration.isFinite ||
              watch.duration < 0 ||
              (watch.duration > 0 && watch.position > watch.duration + 5) ||
              DateTime.tryParse(data['updatedAt'].toString()) == null) {
            throw const FormatException('观看位置无效');
          }
        }
      }
    }
  }

  /// Validate the entire batch before touching state. Never infer deletions.
  static SyncState merge(
    SyncState local,
    Iterable<Map<String, dynamic>> documents,
  ) {
    final docs = documents.toList();
    for (final doc in docs) {
      validateCategory(doc);
    }
    final next = local.copy();
    for (final doc in docs) {
      final c = doc['category'] as String;
      if (c == 'history' && doc['clear'] != null) {
        final v = SyncVersion.fromJson(doc['clear']);
        if (next.clearHistory == null || v.compareTo(next.clearHistory!) > 0) {
          next.clearHistory = v;
        }
        next.observe(v);
      }
      for (final raw in doc['records'] as List) {
        final r = SyncRecord.fromJson(raw);
        next.observe(r.version);
        (next.records[c]![r.key] ??= []).add(r);
      }
    }
    for (final c in syncCategories) {
      for (final key in next.records[c]!.keys.toList()) {
        next.records[c]![key] = compact(
          c,
          next.records[c]![key]!,
          clear: next.clearHistory,
        );
      }
    }
    return next;
  }

  static List<SyncRecord> positions(SyncState state, String key) => compact(
    'history',
    state.records['history']![key] ?? [],
    clear: state.clearHistory,
  ).where((r) => !r.deleted).toList();
}
