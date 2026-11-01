import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:duanju_app/local_files.dart';
import 'package:duanju_app/sync/sync_state.dart';
import 'package:duanju_app/sync/sync_merger.dart';
import 'support/fakes.dart';

class InterruptedFiles extends LocalFiles {
  InterruptedFiles(super.root);
  bool interrupt = false;
  @override
  Future<void> persist(File file, String content) async {
    if (interrupt && file.path.endsWith('sync.json.tmp')) {
      throw const FileSystemException('simulated power loss');
    }
    await super.persist(file, content);
  }
}

void main() {
  test(
    'journal replay commits local data and pending operation together after interruption',
    () async {
      final files = InterruptedFiles(temporaryFiles().root);
      final store = await openStore({}, null, files);
      files.interrupt = true;
      final show = drama('journal');
      await expectLater(store.toggleFavorite(show), throwsStateError);
      expect(await files.transactionPending, isTrue);
      files.interrupt = false;
      final recovered = await restartStore(store);
      expect(recovered.favorites.single.id, show.id);
      expect(
        recovered
            .syncState
            .records['favorites']![syncDramaKey(show.toJson())]!
            .single
            .deleted,
        isFalse,
      );
      expect(recovered.syncState.pending, greaterThan(0));
      expect(await files.transactionPending, isFalse);
      final again = await restartStore(recovered);
      expect(
        jsonEncode(again.syncState.toJson()),
        jsonEncode(recovered.syncState.toJson()),
      );
    },
  );
  test(
    'remote apply does not dirty state and source visibility is not deletion',
    () async {
      final a = await openStore(), b = await openStore();
      final show = drama('42', source: 'guipian');
      await a.toggleFavorite(show);
      final pending = b.syncState.pending;
      await b.mergeSync([
        a.syncState.categoryJson('favorites'),
      ], epoch: b.profileEpoch);
      expect(b.syncState.pending, pending);
      expect(b.favorites.single.id, show.id);
      await b.setSourceEnabled('guipian', false);
      expect(b.favorites, isEmpty);
      await b.setSourceEnabled('guipian', true);
      expect(b.favorites.single.id, show.id);
    },
  );
  test('history display cap does not delete synchronized records', () async {
    final a = await openStore();
    for (var i = 0; i < 305; i++) {
      await a.saveWatch(watching(drama('$i')));
    }
    expect(a.history, hasLength(300));
    expect(a.syncState.records['history'], hasLength(305));
    expect(
      a.syncState.records['history']!.values
          .expand((r) => r)
          .any((r) => r.deleted),
      isFalse,
    );
    await a.clearHistory();
    expect(a.history, isEmpty);
    for (final key in a.syncState.records['history']!.keys) {
      expect(SyncMerger.positions(a.syncState, key), isEmpty);
    }
  });
  test(
    'backup excludes binding and identity, restore pauses existing binding',
    () async {
      final store = await openStore();
      final device = store.deviceId;
      await store.updateSync(
        (s) => s.binding = {
          'account': 'private@example.test',
          'profileId': 'a' * 32,
        },
        epoch: store.profileEpoch,
      );
      final backup = await store.exportBackup();
      expect(backup, isNot(contains('private@example.test')));
      expect(backup, isNot(contains(device)));
      await store.importBackup(backup);
      expect(store.syncState.needsReview, isTrue);
      expect(store.syncState.automatic, isFalse);
      expect(store.syncState.binding!['profileId'], 'a' * 32);
      expect(store.deviceId, device);
      final newInstall = await openStore();
      await newInstall.importBackup(backup);
      expect(newInstall.deviceId, isNot(device));
      expect(newInstall.syncState.binding, isNull);
    },
  );
  test('metadata updates are not user operations', () async {
    final store = await openStore();
    await store.toggleFavorite(drama('m'));
    await store.saveWatch(watching(drama('m')));
    final pending = store.syncState.pending;
    await store.refreshDrama(drama('m', title: '新标题', episodes: 100));
    expect(store.syncState.pending, pending);
  });
  test(
    'merge recovery can restore records and pauses automatic sync',
    () async {
      final store = await openStore();
      final show = drama('restore');
      await store.toggleFavorite(show);
      await store.saveWatch(watching(show, position: 25));
      await store.saveSyncRecovery();
      final names = await store.syncRecoveries();
      expect(names, hasLength(1));
      await store.removeFavorites({show.id});
      await store.clearHistory();
      await store.restoreSyncRecovery(names.single);
      expect(store.favorites.single.id, show.id);
      expect(store.watched(show.id)!.position, 25);
      expect(store.syncState.needsReview, isTrue);
      expect(store.syncState.automatic, isFalse);
    },
  );
}
