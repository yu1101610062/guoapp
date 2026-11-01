import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/sync/sync_controller.dart';
import 'package:duanju_app/sync/sync_transport.dart';
import 'package:duanju_app/playback_preferences.dart';
import 'support/fakes.dart';

class MemoryVault implements SyncVault {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class Cloud {
  final files = <String, List<int>>{};
  final dirs = <String>{};
  int writes = 0, requests = 0;
  bool auth = true, losePutResponse = false, corrupt = false;
  bool automaticBudgetExhausted = false;
  int automaticBudgetRejections = 0;
  Duration? rate;
  Completer<void>? hold;
  String? holdPath;
  String? blockCategory;
  bool incomplete = false;
}

class MemoryDav extends SyncTransport {
  MemoryDav(this.cloud);
  final Cloud cloud;
  bool closed = false;
  Future<void> check(String path) async {
    cloud.requests++;
    if (cloud.hold != null && cloud.holdPath == path) await cloud.hold!.future;
    if (closed) throw const SyncFailure('cancelled', 'closed');
    if (!cloud.auth) throw const SyncFailure('auth', 'revoked');
    if (!manual && cloud.automaticBudgetExhausted) {
      cloud.automaticBudgetRejections++;
      throw const SyncFailure(
        'budget',
        'automatic quota used',
        retryAfter: Duration(minutes: 30),
      );
    }
    if (cloud.rate != null) {
      throw SyncFailure('rate', 'limited', retryAfter: cloud.rate);
    }
  }

  @override
  Future<void> mkdir(String path) async {
    await check(path);
    cloud.dirs.add(path);
  }

  @override
  Future<List<DavEntry>> list(String path) async {
    await check(path);
    if (cloud.incomplete) throw const SyncFailure('listing', 'partial listing');
    if (!cloud.dirs.contains(path)) {
      throw const SyncFailure('missing', 'missing directory');
    }
    bool direct(String p) =>
        p.startsWith('$path/') && !p.substring(path.length + 1).contains('/');
    return [
      for (final p in cloud.dirs.where(direct)) DavEntry(p, directory: true),
      for (final p in cloud.files.keys.where(direct)) DavEntry(p),
    ];
  }

  @override
  Future<List<int>> get(String path) async {
    await check(path);
    if (cloud.blockCategory != null &&
        path.contains('/${cloud.blockCategory}/')) {
      throw const SyncFailure('network', 'offline');
    }
    final data = cloud.files[path];
    if (data == null) throw const SyncFailure('missing', 'missing file');
    if (cloud.corrupt && path.endsWith('.gz')) return [0, ...data];
    return List.of(data);
  }

  @override
  Future<void> put(String path, List<int> bytes) async {
    await check(path);
    if (cloud.files.containsKey(path) &&
        contentHash(cloud.files[path]!) != contentHash(bytes)) {
      throw StateError('immutable file overwritten');
    }
    cloud.files[path] = List.of(bytes);
    cloud.writes++;
    if (cloud.losePutResponse && path.endsWith('.gz')) {
      throw const SyncFailure('timeout', 'response lost');
    }
  }

  @override
  Future<void> delete(String path) async {
    await check(path);
    cloud.files.remove(path);
  }

  @override
  void close() {
    closed = true;
  }
}

void main() {
  late Cloud cloud;
  SyncController make(LocalStore store) {
    final c = SyncController(
      store,
      vault: MemoryVault(),
      transportFactory: (_, _) => MemoryDav(cloud),
    );
    addTearDown(c.dispose);
    return c;
  }

  Future<void> bind(SyncController c, {CloudProfile? profile}) async {
    await c.connect('account@example.test', 'app-password-test', 'device');
    await c.confirm(await c.preview(profile: profile, newName: '测试资料'));
    expect(c.error, isNull);
  }

  CloudProfile profile(SyncController c) =>
      (id: c.state.binding!['profileId'] as String, name: '测试资料');
  setUp(() => cloud = Cloud());
  test(
    'two clients sync both ways, offline deletes converge and remote merge produces no echo',
    () async {
      final sa = await openStore(), sb = await openStore();
      final a = make(sa), b = make(sb);
      final hongguo = drama('42'), other = drama('42', source: 'guipian');
      await sa.toggleFavorite(hongguo);
      await bind(a);
      await sb.toggleFavorite(other);
      await bind(b, profile: profile(a));
      await a.synchronize(manual: true);
      expect(sa.favorites.map((d) => d.id).toSet(), {hongguo.id, other.id});
      expect(sb.favorites.map((d) => d.id).toSet(), {hongguo.id, other.id});
      await sa.saveWatch(watching(hongguo, episode: 4, position: 23));
      await sa.setPlaybackPreferences(
        const PlaybackPreferences(speed: 1.5, quality: 720, autoAdvance: false),
      );
      await a.synchronize(manual: true);
      await b.synchronize(manual: true);
      expect(sb.watched(hongguo.id)!.position, 23);
      expect(sb.playbackPreferences.speed, 1.5);
      expect(sb.playbackPreferences.autoAdvance, isFalse);
      final writes = cloud.writes;
      await b.synchronize(manual: true);
      await a.synchronize(manual: true);
      expect(cloud.writes, writes);
      final offline = sb.syncState;
      await sa.removeFavorites({hongguo.id});
      await sa.clearHistory();
      await a.synchronize(manual: true);
      // An old device repeats its unchanged snapshot after a long offline period.
      await sa.mergeSync([
        offline.categoryJson('favorites'),
        offline.categoryJson('history'),
      ], epoch: sa.profileEpoch);
      await b.synchronize(manual: true);
      expect(sa.isFavorite(hongguo.id), isFalse);
      expect(sb.isFavorite(hongguo.id), isFalse);
      expect(sb.watched(hongguo.id), isNull);
      expect(a.state.pending, 0);
      expect(b.state.pending, 0);
      expect(cloud.files.keys.any((p) => p.contains('/tests/')), isFalse);
      expect(
        jsonEncode(await sa.files.dump()),
        isNot(contains('app-password-test')),
      );
    },
  );
  test(
    'lost PUT responses are resolved by readback without fresh operations',
    () async {
      final store = await openStore(), c = make(await openStore());
      // Use a separate local store to keep the explicit mutation on the bound client.
      await bind(c);
      cloud.losePutResponse = true;
      await c.store.toggleFavorite(drama('lost'));
      final version = c
          .store
          .syncState
          .records['favorites']!
          .values
          .single
          .single
          .version
          .toJson();
      await c.synchronize(manual: true);
      expect(c.error, isNull);
      expect(c.state.pending, 0);
      expect(
        c.store.syncState.records['favorites']!.values.single.single.version
            .toJson(),
        version,
      );
      expect(store.favorites, isEmpty);
    },
  );
  test(
    'auth failure stops automatic retry, rate limiting preserves dirty state',
    () async {
      final c = make(await openStore());
      await bind(c);
      await c.store.toggleFavorite(drama('pending'));
      cloud.auth = false;
      await c.synchronize(manual: true);
      expect(c.error, 'revoked');
      expect(c.state.pending, greaterThan(0));
      final requests = cloud.requests;
      await c.synchronize();
      expect(cloud.requests, requests);
      cloud.auth = true;
      cloud.rate = const Duration(minutes: 2);
      await c.synchronize(manual: true);
      expect(c.error, 'limited');
      final limited = cloud.requests;
      await c.synchronize(manual: true);
      expect(cloud.requests, limited);
      expect(c.state.pending, greaterThan(0));
    },
  );
  test(
    'manual sync can use reserved quota during automatic budget backoff',
    () async {
      final c = make(await openStore());
      await bind(c);
      await c.store.toggleFavorite(drama('manual-reserve'));
      cloud.automaticBudgetExhausted = true;
      await c.synchronize();
      expect(c.error, 'automatic quota used');
      final requests = cloud.requests;
      await c.synchronize();
      expect(cloud.requests, requests);
      await c.synchronize(manual: true);
      expect(cloud.requests, greaterThan(requests));
      expect(c.error, isNull);
      expect(c.state.pending, 0);
      expect(cloud.automaticBudgetRejections, 2); // GC uses automatic quota.
    },
  );
  test(
    'corrupt or incomplete remote batch applies nothing, including valid earlier categories',
    () async {
      final a = make(await openStore()), b = make(await openStore());
      await bind(a);
      await bind(b, profile: profile(a));
      await a.store.toggleFavorite(drama('new'));
      await a.store.saveWatch(watching(drama('new')));
      await a.synchronize(manual: true);
      cloud.blockCategory = 'history';
      final before = jsonEncode(b.state.toJson());
      await b.synchronize(manual: true);
      expect(b.store.favorites, isEmpty);
      expect(jsonEncode(b.state.toJson()), before);
      // New controller gets the persisted binding/secret in the next test; here
      // force a fresh manual connection, which also clears the previous backoff.
      cloud.blockCategory = null;
      cloud.corrupt = true;
      await b.connect('account@example.test', 'pass', 'b');
      await expectLater(
        b.preview(profile: profile(a)),
        throwsA(isA<SyncFailure>()),
      );
      expect(b.store.favorites, isEmpty);
      cloud.corrupt = false;
      cloud.incomplete = true;
      await expectLater(
        b.preview(profile: profile(a)),
        throwsA(isA<SyncFailure>()),
      );
    },
  );
  test(
    'switching profile cancels in-flight results and does not change new user data',
    () async {
      final store = await openStore();
      await store.saveProfile(
        id: 'default',
        name: '管理员',
        sources: [],
        download: true,
        pin: 'test-pin-123',
      );
      await store.saveProfile(
        name: '测试用户',
        sources: ['hongguo'],
        download: false,
      );
      await store.switchProfile(store.profiles.firstWhere((p) => !p.admin).id);
      final c = make(store);
      await bind(c);
      final root = '$syncRoot/profiles/${profile(c).id}/heads';
      cloud.holdPath = root;
      cloud.hold = Completer<void>();
      final running = c.synchronize(manual: true);
      await pumpEventQueue();
      await store.switchProfile('default', pin: 'test-pin-123');
      cloud.hold!.complete();
      await running;
      expect(store.profile.id, 'default');
      expect(store.favorites, isEmpty);
      expect(store.syncState.binding, isNull);
      expect(c.error, isNull);
    },
  );
  test(
    'preview cloud preferences win and changed local preview must be reviewed again',
    () async {
      final a = make(await openStore()), b = make(await openStore());
      await a.store.setPlaybackPreferences(
        const PlaybackPreferences(speed: 1.5),
      );
      await bind(a);
      await b.store.setPlaybackPreferences(const PlaybackPreferences(speed: 2));
      await b.connect('a@b.test', 'pass', 'b');
      final preview = await b.preview(profile: profile(a));
      expect(
        preview.merged.records['preferences']!['speed']!.single.data!['value'],
        1.5,
      );
      await b.store.toggleFavorite(drama('changed-during-preview'));
      await expectLater(b.confirm(preview), throwsStateError);
      expect(b.state.binding, isNull);
    },
  );
}
