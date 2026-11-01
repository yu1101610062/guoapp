import 'dart:convert';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:duanju_app/sync/sync_state.dart';
import 'package:duanju_app/sync/sync_merger.dart';
import 'package:duanju_app/follow_state.dart';
import 'package:duanju_app/models.dart';
import 'support/fakes.dart';

void main() {
  final show = drama('42');
  final key = syncDramaKey(show.toJson());
  SyncRecord record(
    String device,
    int time, {
    Map<String, dynamic>? data,
    String session = '',
    String? id,
  }) => SyncRecord(
    key: id ?? key,
    version: SyncVersion(time, 0, device),
    time: time,
    data: data,
    session: session,
  );
  Map<String, dynamic> doc(String c, List<SyncRecord> rows, {int? clear}) => {
    'protocol': 1,
    'recordVersion': 1,
    'category': c,
    'records': rows.map((r) => r.toJson()).toList(),
    'clear': clear == null ? null : SyncVersion(clear, 0, 'c').toJson(),
  };
  test(
    'random reorder, duplication and grouping converge without local dirty operations',
    () {
      final docs = [
        doc('favorites', [record('a', 10, data: show.toJson())]),
        doc('favorites', [record('b', 11)]),
        doc('favorites', [record('a', 12, data: show.toJson())]),
        for (var i = 0; i < 12; i++)
          doc('history', [
            record(
              'device${i % 4}',
              100 + i,
              session: 'session${i % 4}',
              data: watching(show, position: i.toDouble()).toJson(),
            ),
          ]),
      ];
      final expected = SyncMerger.merge(SyncState(), docs);
      for (var trial = 0; trial < 50; trial++) {
        final shuffled = [...docs, ...docs]..shuffle(Random(trial));
        var state = SyncState();
        for (final item in shuffled) {
          state = SyncMerger.merge(state, [item]);
        }
        for (final c in syncCategories) {
          expect(
            jsonEncode(state.categoryJson(c)),
            jsonEncode(expected.categoryJson(c)),
          );
        }
        expect(state.pending, 0);
        expect(SyncMerger.positions(state, key), hasLength(3));
      }
    },
  );
  test('favorite removal and clear history survive old offline devices', () {
    final old = [
      doc('favorites', [record('a', 10, data: show.toJson())]),
      doc('history', [record('a', 10, data: watching(show).toJson())]),
    ];
    final deleted = SyncMerger.merge(SyncState(), [
      ...old,
      doc('favorites', [record('b', 20)]),
      doc('history', [], clear: 20),
    ]);
    final replayed = SyncMerger.merge(deleted, old);
    expect(replayed.records['favorites']![key]!.single.deleted, isTrue);
    expect(SyncMerger.positions(replayed, key), isEmpty);
    final rewatch = SyncMerger.merge(replayed, [
      doc('history', [
        record(
          'a',
          21,
          session: 'rewatch',
          data: watching(show, position: 2).toJson(),
        ),
      ]),
    ]);
    expect(SyncMerger.positions(rewatch, key).single.data!['position'], 2);
  });
  test(
    'per-title history tombstone and maximum three session alternatives',
    () {
      final state = SyncMerger.merge(SyncState(), [
        doc('history', [
          for (var i = 0; i < 9; i++)
            record('d$i', i + 1, data: watching(show).toJson()),
          record('d', 5),
        ]),
      ]);
      expect(SyncMerger.positions(state, key).map((r) => r.version.wall), [
        9,
        8,
        7,
      ]);
      final wiped = SyncMerger.merge(state, [
        doc('history', [record('x', 12)]),
      ]);
      expect(SyncMerger.positions(wiped, key), isEmpty);
    },
  );
  test(
    'same numeric ID and same title from distinct sources remain independent',
    () {
      final other = drama('42', source: 'guipian', title: show.title);
      final state = SyncMerger.merge(SyncState(), [
        doc('favorites', [
          record('a', 1, data: show.toJson()),
          record(
            'a',
            1,
            id: syncDramaKey(other.toJson()),
            data: other.toJson(),
          ),
        ]),
      ]);
      expect(state.records['favorites'], hasLength(2));
    },
  );
  test(
    'preferences merge independently and invalid batch never mutates input',
    () {
      final base = SyncState();
      final merged = SyncMerger.merge(base, [
        doc('preferences', [
          record('a', 1, id: 'speed', data: {'value': 1.5}),
          record('b', 2, id: 'quality', data: {'value': 720}),
        ]),
      ]);
      expect(merged.records['preferences'], hasLength(2));
      final before = jsonEncode(merged.toJson());
      expect(
        () => SyncMerger.merge(merged, [
          doc('favorites', [record('a', 2)]),
          {...doc('history', []), 'protocol': 2},
        ]),
        throwsFormatException,
      );
      expect(jsonEncode(merged.toJson()), before);
    },
  );
  test(
    'HLC remains monotonic on clock rollback and retries preserve operation time',
    () {
      final s = SyncState();
      final first = s.tick('a', now: 1000);
      final second = s.tick('a', now: 500);
      expect(second.compareTo(first), greaterThan(0));
      expect(second.wall, 1000);
      final docBefore = jsonEncode(s.toJson());
      expect(jsonEncode(s.copy().toJson()), docBefore);
    },
  );
  test(
    'resume follows stable episode IDs, accepts unique numbers, refuses ambiguous fallback indices',
    () {
      final watch = WatchEntry(
        drama: show,
        episode: 2,
        episodeId: 'second',
        position: 5,
        duration: 100,
        updatedAt: DateTime(2026),
      );
      final reordered = [
        Episode({'id': 'second', 'currentEpisode': 5}, 1),
        Episode({'id': 'first', 'currentEpisode': 2}, 2),
      ];
      expect(matchWatchEpisode(reordered, watch), 0);
      expect(resumeEpisodeIndex(reordered, watch), 0);
      expect(
        matchWatchEpisode([
          Episode({'id': 'missing', 'currentEpisode': 2}, 1),
        ], watch),
        0,
      );
      expect(
        matchWatchEpisode([
          Episode({'id': 'x'}, 2),
        ], watch),
        isNull,
      );
      expect(
        matchWatchEpisode([
          Episode({'currentEpisode': 2}, 1),
          Episode({'currentEpisode': 2}, 2),
        ], watch),
        isNull,
      );
      expect(matchWatchEpisode([], watch), isNull);
    },
  );
}
