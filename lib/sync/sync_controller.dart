import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:crypto/crypto.dart';

import '../local_store.dart';
import '../diary_service.dart';
import 'sync_state.dart';
import 'sync_merger.dart';
import 'sync_transport.dart';

abstract interface class SyncVault {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SystemSyncVault implements SyncVault {
  const SystemSyncVault();
  static const storage = FlutterSecureStorage();
  @override
  Future<String?> read(String key) => storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => storage.delete(key: key);
}

typedef TransportFactory =
    SyncTransport Function(String account, String password);
typedef CloudProfile = ({String id, String name});

class MergePreview {
  MergePreview(
    this.base,
    this.documents,
    this.seen,
    this.devices,
    this.binding,
    this.expected,
    this.epoch,
    this.recoveryPath,
  );
  final SyncState base;
  final List<Map<String, dynamic>> documents;
  final Map<String, String> seen, devices;
  final Map<String, dynamic> binding;
  final String expected, recoveryPath;
  final int epoch;
  SyncState get merged => SyncMerger.merge(base, documents);
  int count(String c) => merged.records[c]!.values
      .where((rows) => rows.any((r) => !r.deleted))
      .length;
}

class SyncController extends ChangeNotifier implements SyncHooks {
  SyncController(
    this.store, {
    SyncVault? vault,
    TransportFactory? transportFactory,
  }) : vault = vault ?? const SystemSyncVault(),
       _factory = transportFactory {
    _epoch = store.profileEpoch;
    store.syncHooks = this;
    store.addListener(_storeChanged);
    _idle = Timer.periodic(const Duration(seconds: 120), (_) {
      if (_foreground) unawaited(synchronize());
    });
    scheduleMicrotask(() => synchronize());
  }
  final LocalStore store;
  final SyncVault vault;
  final TransportFactory? _factory;
  final Map<String, RequestBudget> _budgets = {};
  Timer? _idle, _debounce, _retry;
  SyncTransport? _transport, _setup;
  Future<void>? _running;
  late int _epoch;
  int _generation = 0, _failures = 0;
  bool _closed = false, _foreground = true, _again = false, _authFailed = false;
  bool _serverLimited = false;
  DateTime? _lastProgressUpload, _lastPull, _notBefore;
  String? error;
  bool resumePending = false;
  String _account = '', _deviceName = '';
  String? _setupPassword;
  bool get busy => _running != null;
  SyncState get state => store.syncState;
  bool get bound => state.binding != null;
  String _key(String token) =>
      'zhenguojian.sync.${store.deviceId}.${store.profile.id}.$token';
  String get _secretKey =>
      _key(state.binding?['credentialId'] as String? ?? 'legacy');
  bool _valid(int generation) =>
      !_closed && generation == _generation && !store.locked;
  void _check(int generation) {
    if (!_valid(generation)) throw const SyncFailure('cancelled', '当前用户或连接已变更');
  }

  void _notify() {
    if (!_closed) notifyListeners();
  }

  SyncTransport _make(String account, String password) {
    if (_factory != null) return _factory(account, password);
    final hash = sha256
        .convert(utf8.encode(account.trim().toLowerCase()))
        .toString();
    final budget = _budgets.putIfAbsent(
      hash,
      () => RequestBudget(
        file: File('${store.files.root.path}.sync-budget/$hash.json'),
      ),
    );
    return WebDavTransport(
      account: account,
      password: password,
      budget: budget,
    );
  }

  void _storeChanged() {
    if (_epoch == store.profileEpoch) {
      _notify();
      return;
    }
    _epoch = store.profileEpoch;
    _cancel();
    scheduleMicrotask(() => synchronize());
  }

  void _cancel() {
    _generation++;
    _transport?.close();
    _transport = null;
    _setup?.close();
    _setup = null;
    _setupPassword = null;
    _debounce?.cancel();
    _retry?.cancel();
    _running = null;
    _again = false;
    _authFailed = false;
    _lastPull = null;
    _lastProgressUpload = null;
    _notBefore = null;
    _serverLimited = false;
    _failures = 0;
    error = null;
    resumePending = false;
    _notify();
  }

  void cancelSetup() {
    if (_setup == null) return;
    _cancel();
    scheduleMicrotask(() => synchronize());
  }

  @override
  void changed({bool progress = false, bool urgent = false}) {
    if (_closed ||
        !bound ||
        !state.automatic ||
        state.needsReview ||
        _authFailed) {
      return;
    }
    if (progress && !urgent) {
      // Do not reset this timer every five seconds while playback is running.
      if (_debounce?.isActive ?? false) return;
      final elapsed = _lastProgressUpload == null
          ? 0
          : DateTime.now().difference(_lastProgressUpload!).inSeconds;
      _debounce = Timer(
        Duration(seconds: max(1, 60 - elapsed)),
        () => synchronize(),
      );
    } else {
      _debounce?.cancel();
      _debounce = Timer(Duration(seconds: urgent ? 1 : 5), () => synchronize());
    }
  }

  void foreground(bool value) {
    _foreground = value;
    if (value) {
      unawaited(synchronize());
    } else {
      changed(urgent: true);
    }
  }

  @override
  Future<void> beforeResume() async {
    if (!bound || state.needsReview || !state.automatic) return;
    if (_lastPull != null &&
        DateTime.now().difference(_lastPull!).inSeconds <= 30) {
      return;
    }
    resumePending = false;
    try {
      await synchronize().timeout(const Duration(seconds: 3));
    } on TimeoutException {
      resumePending = true;
    }
    if (error != null) resumePending = true;
    _notify();
  }

  /// Setup requests are manual-budgeted and never persist the password in JSON.
  Future<List<CloudProfile>> connect(
    String account,
    String password,
    String deviceName,
  ) async {
    if (account.trim().isEmpty ||
        password.isEmpty ||
        deviceName.trim().isEmpty ||
        deviceName.length > 80) {
      throw const SyncFailure('input', '请填写账号、应用密码和设备名称（最多 80 字）');
    }
    _cancel();
    final generation = _generation;
    final dav = _make(account.trim(), password)..manual = true;
    _setup = dav;
    _account = account.trim();
    _deviceName = deviceName.trim();
    try {
      for (final path in [
        'ZhenguojianSync',
        syncRoot,
        '$syncRoot/profiles',
        '$syncRoot/tests',
      ]) {
        _check(generation);
        await dav.mkdir(path);
      }
      final path = '$syncRoot/tests/${newSyncId()}.bin';
      final bytes = utf8.encode(newSyncId());
      try {
        _check(generation);
        await dav.put(path, bytes);
        _check(generation);
        if (contentHash(await dav.get(path)) != contentHash(bytes)) {
          throw const SyncFailure('corrupt', '读回测试失败');
        }
      } finally {
        _check(generation);
        await dav.delete(path);
      }
      _check(generation);
      final profiles = <CloudProfile>[];
      for (final entry in await dav.list('$syncRoot/profiles')) {
        _check(generation);
        final id = entry.path.split('/').last;
        if (!entry.directory || !RegExp(r'^[a-f0-9]{32}$').hasMatch(id)) {
          continue;
        }
        final doc = jsonMap(
          jsonDecode(utf8.decode(await dav.get('${entry.path}/profile.json'))),
        );
        if (doc['protocol'] != 1 || doc['id'] != id || doc['name'] is! String) {
          throw const SyncFailure('protocol', '云端资料版本不支持');
        }
        profiles.add((id: id, name: doc['name'] as String));
      }
      _check(generation);
      _setupPassword = password;
      error = null;
      return profiles;
    } catch (_) {
      if (_valid(generation)) {
        dav.close();
        _setup = null;
      }
      rethrow;
    }
  }

  Future<MergePreview> preview({CloudProfile? profile, String? newName}) async {
    final dav = _setup;
    if (dav == null) throw const SyncFailure('setup', '请先测试连接');
    final generation = _generation;
    final epoch = _epoch;
    if (profile == null) {
      if (newName == null || newName.trim().isEmpty || newName.length > 80) {
        throw const SyncFailure('input', '请填写云端资料名称（最多 80 字）');
      }
      profile = (id: newSyncId(), name: newName.trim());
      final root = '$syncRoot/profiles/${profile.id}';
      for (final path in [root, '$root/heads', '$root/devices']) {
        _check(generation);
        await dav.mkdir(path);
      }
      final bytes = utf8.encode(
        jsonEncode({'protocol': 1, 'id': profile.id, 'name': profile.name}),
      );
      await _verifiedPut(dav, '$root/profile.json', bytes, generation);
    }
    _check(generation);
    final recovery = await store.saveSyncRecovery();
    _check(generation);
    final original = state;
    var base = original.copy();
    // First merge uses cloud preferences and cloud removals, irrespective of
    // the local installation time. Existing watch times remain meaningful.
    for (final c in ['favorites', 'preferences']) {
      for (final key in base.records[c]!.keys.toList()) {
        base.records[c]![key] = base.records[c]![key]!
            .map(
              (r) => SyncRecord(
                key: key,
                version: SyncVersion(0, 0, store.deviceId),
                time: r.time,
                data: r.data,
              ),
            )
            .toList();
      }
    }
    base.seen.clear();
    base.devices.clear();
    final binding = <String, dynamic>{
      'account': _account,
      'deviceName': _deviceName,
      'profileId': profile.id,
      'profileName': profile.name,
      'files': <String, String>{},
      'credentialId': newSyncId(),
    };
    final pulled = await _pull(dav, binding, base, generation);
    for (final doc in pulled.docs.where(
      (d) => d['category'] == 'preferences',
    )) {
      for (final row in doc['records'] as List) {
        base.records['preferences']!.remove(SyncRecord.fromJson(row).key);
      }
    }
    _check(generation);
    return MergePreview(
      base,
      pulled.docs,
      pulled.seen,
      pulled.devices,
      binding,
      jsonEncode(original.toJson()),
      epoch,
      recovery,
    );
  }

  Future<void> confirm(MergePreview preview) async {
    final generation = _generation;
    _check(generation);
    if (_epoch != preview.epoch || _setup == null) {
      throw const SyncFailure('cancelled', '用户已变更，请重新连接');
    }
    await vault.write(
      _key(preview.binding['credentialId'] as String),
      _setupPassword!,
    );
    _check(generation);
    await store.mergeSync(
      preview.documents,
      epoch: preview.epoch,
      base: preview.base,
      expected: preview.expected,
      update: (next) {
        next.binding = preview.binding;
        next.needsReview = false;
        next.automatic = true;
        next.seen.addAll(preview.seen);
        next.devices.addAll(preview.devices);
        for (final c in syncCategories) {
          next.revision[c] = next.revision[c]! + 1;
        }
      },
    );
    _check(generation);
    _setup?.close();
    _setup = null;
    _setupPassword = null;
    await synchronize(manual: true);
  }

  Future<void> setAutomatic(bool value) async {
    if (value && state.needsReview) {
      throw const SyncFailure('review', '恢复备份后需要重新连接并预览合并');
    }
    await store.updateSync((s) => s.automatic = value, epoch: _epoch);
    if (!value) {
      _debounce?.cancel();
      _retry?.cancel();
    } else {
      unawaited(synchronize());
    }
  }

  Future<void> disconnect() async {
    final key = _secretKey;
    _cancel();
    await store.updateSync((s) {
      s.binding = null;
      s.seen.clear();
      s.devices.clear();
    }, epoch: _epoch);
    await vault.delete(key);
  }

  Future<void> synchronize({bool manual = false}) {
    if (_closed ||
        _setup != null ||
        store.locked ||
        !bound ||
        state.needsReview ||
        (!manual && (!state.automatic || _authFailed)) ||
        (_notBefore != null &&
            (!manual || _serverLimited) &&
            DateTime.now().isBefore(_notBefore!))) {
      return Future.value();
    }
    if (_running != null) {
      _again = true;
      return _running!;
    }
    final generation = _generation;
    final epoch = _epoch;
    final future = _run(generation, epoch, manual);
    _running = future;
    _notify();
    return future;
  }

  Future<void> _run(int generation, int epoch, bool manual) async {
    try {
      final binding = state.binding!;
      final password = await vault.read(_secretKey);
      _check(generation);
      if (password == null) throw const SyncFailure('auth', '请重新输入坚果云应用密码');
      final dav = _make(binding['account'] as String, password)
        ..manual = manual;
      _transport = dav;
      final pulled = await _pull(dav, binding, state, generation);
      _check(generation);
      await store.mergeSync(
        pulled.docs,
        epoch: epoch,
        update: (next) {
          next.seen.addAll(pulled.seen);
          next.devices.addAll(pulled.devices);
          if (dav.serverOffset case final offset?) {
            next.clockOffset = offset;
            next.clockUncertain = offset.abs() > 300000;
          }
        },
      );
      _check(generation);
      _lastPull = DateTime.now();
      resumePending = false;
      if (state.dirty.isNotEmpty) await _upload(dav, generation, epoch);
      _check(generation);
      await store.updateSync(
        (s) => s.lastSuccess = DateTime.now().millisecondsSinceEpoch,
        epoch: epoch,
      );
      error = null;
      _failures = 0;
      _authFailed = false;
      _notBefore = null;
      _serverLimited = false;
    } catch (failure) {
      if (!_valid(generation)) return;
      final f = failure is SyncFailure
          ? failure
          : const SyncFailure('data', '同步数据处理失败，数据已保留，请检查存储空间或重新连接');
      error = f.message;
      _authFailed = f.kind == 'auth';
      _serverLimited = f.kind == 'rate';
      DiaryService.add('[Sync] 阶段:同步 错误类别:${f.kind} 待上传:${state.pending}');
      if (!_authFailed) {
        final delay =
            f.retryAfter ??
            Duration(
              seconds: min(900, 10 * pow(2, min(_failures++, 7)).toInt()),
            );
        _notBefore = DateTime.now().add(delay);
        _retry?.cancel();
        if (state.automatic) {
          _retry = Timer(delay, () => synchronize());
        }
      }
    } finally {
      if (_valid(generation)) {
        _transport?.close();
        _transport = null;
        _running = null;
        _notify();
        final again = _again;
        _again = false;
        if (again && error == null) changed();
      }
    }
  }

  Future<
    ({
      List<Map<String, dynamic>> docs,
      Map<String, String> seen,
      Map<String, String> devices,
    })
  >
  _pull(
    SyncTransport dav,
    Map<String, dynamic> binding,
    SyncState local,
    int generation,
  ) async {
    final root = '$syncRoot/profiles/${binding['profileId']}';
    final latest = <String, ({String path, int seq, String hash})>{};
    _check(generation);
    for (final entry in await dav.list('$root/heads')) {
      if (entry.directory) continue;
      final match = _filename.firstMatch(entry.path.split('/').last);
      if (match == null) throw const SyncFailure('protocol', '云端目录包含未知版本文件');
      final device = match[1]!;
      final seq = int.parse(match[2]!);
      if (!latest.containsKey(device) || latest[device]!.seq < seq) {
        latest[device] = (path: entry.path, seq: seq, hash: match[3]!);
      }
    }
    final docs = <Map<String, dynamic>>[];
    final seen = <String, String>{}, devices = <String, String>{};
    for (final entry in latest.entries) {
      _check(generation);
      if (local.seen[entry.key] == entry.value.path) continue;
      final head = decodeSnapshot(
        await dav.get(entry.value.path),
        entry.value.hash,
      );
      _validateHead(head, root, entry.key);
      devices[entry.key] = head['name'] as String;
      final files = jsonMap(head['files']);
      for (final c in syncCategories) {
        _check(generation);
        final path = files[c] as String;
        // Cache category paths independently; a new head may only change history.
        final cacheKey = '${entry.key}/$c';
        if (local.seen[cacheKey] != path) {
          final match = _filename.firstMatch(path.split('/').last)!;
          final doc = decodeSnapshot(await dav.get(path), match[3]!);
          if (doc['category'] != c) {
            throw const SyncFailure('corrupt', '快照类别不一致');
          }
          SyncMerger.validateCategory(doc);
          docs.add(doc);
          seen[cacheKey] = path;
        }
      }
      seen[entry.key] = entry.value.path;
    }
    return (docs: docs, seen: seen, devices: devices);
  }

  static final _filename = RegExp(
    r'^([a-f0-9]{32})_([0-9]{1,18})_([a-f0-9]{64})\.json\.gz$',
  );
  void _validateHead(Map<String, dynamic> head, String root, String device) {
    if (head['protocol'] != 1 ||
        head['device'] != device ||
        head['name'] is! String ||
        (head['name'] as String).length > 80) {
      throw const SyncFailure('protocol', '云端设备清单版本不支持');
    }
    final files = jsonMap(head['files']);
    for (final c in syncCategories) {
      final path = files[c];
      final prefix = '$root/devices/$device/$c/';
      if (path is! String ||
          !path.startsWith(prefix) ||
          !_filename.hasMatch(path.substring(prefix.length)) ||
          _filename.firstMatch(path.substring(prefix.length))![1] != device) {
        throw const SyncFailure('corrupt', '云端设备清单路径无效');
      }
    }
  }

  Future<void> _verifiedPut(
    SyncTransport dav,
    String path,
    List<int> bytes,
    int generation,
  ) async {
    _check(generation);
    try {
      await dav.put(path, bytes);
    } on SyncFailure catch (f) {
      if (!['timeout', 'network'].contains(f.kind)) rethrow;
      // PUT can succeed even when its response is lost; GET resolves that case.
    }
    _check(generation);
    if (contentHash(await dav.get(path)) != contentHash(bytes)) {
      throw const SyncFailure('corrupt', '上传读回校验失败');
    }
    _check(generation);
  }

  Future<void> _upload(SyncTransport dav, int generation, int epoch) async {
    await store.updateSync((s) => s.sequence++, epoch: epoch);
    _check(generation);
    final snapshot = state;
    final binding = snapshot.binding!;
    final root = '$syncRoot/profiles/${binding['profileId']}';
    final device = store.deviceId;
    final own = '$root/devices/$device';
    if (binding['provisioned'] != device) {
      for (final path in [own, for (final c in syncCategories) '$own/$c']) {
        _check(generation);
        await dav.mkdir(path);
      }
    }
    final files = Map<String, String>.from(binding['files'] as Map? ?? {});
    final dirty = snapshot.dirty;
    for (final c in syncCategories) {
      if (!dirty.contains(c) && files.containsKey(c)) continue;
      final bytes = encodeSnapshot(snapshot.categoryJson(c));
      final path =
          '$own/$c/${device}_${snapshot.sequence}_${contentHash(bytes)}.json.gz';
      await _verifiedPut(dav, path, bytes, generation);
      files[c] = path;
    }
    final bytes = encodeSnapshot({
      'protocol': 1,
      'device': device,
      'name': binding['deviceName'],
      'files': files,
    });
    final head =
        '$root/heads/${device}_${snapshot.sequence}_${contentHash(bytes)}.json.gz';
    await _verifiedPut(dav, head, bytes, generation);
    await store.updateSync((s) {
      for (final c in dirty) {
        s.uploaded[c] = snapshot.revision[c]!;
      }
      s.binding = {...s.binding!, 'files': files, 'provisioned': device};
      s.seen[device] = head;
      s.devices[device] = binding['deviceName'];
      for (final c in syncCategories) {
        s.seen['$device/$c'] = files[c]!;
      }
    }, epoch: epoch);
    _lastProgressUpload = DateTime.now();
    if (snapshot.sequence % 5 == 0 || dav.manual) {
      final manual = dav.manual;
      try {
        // Maintenance must not consume the quota reserved for user syncs.
        dav.manual = false;
        await _cleanup(dav, root, device, generation);
      } on SyncFailure {
        /* Publication is durable; defer GC on a limited budget. */
      } finally {
        dav.manual = manual;
      }
    }
  }

  Future<void> _cleanup(
    SyncTransport dav,
    String root,
    String device,
    int generation,
  ) async {
    List<DavEntry> own(List<DavEntry> entries) =>
        entries
            .where(
              (e) =>
                  !e.directory &&
                  _filename.firstMatch(e.path.split('/').last)?[1] == device,
            )
            .toList()
          ..sort(
            (a, b) =>
                int.parse(
                  _filename.firstMatch(b.path.split('/').last)![2]!,
                ).compareTo(
                  int.parse(_filename.firstMatch(a.path.split('/').last)![2]!),
                ),
          );
    _check(generation);
    final heads = own(await dav.list('$root/heads'));
    final keep = <String>{};
    for (final head in heads.take(3)) {
      _check(generation);
      final doc = decodeSnapshot(
        await dav.get(head.path),
        _filename.firstMatch(head.path.split('/').last)![3]!,
      );
      _validateHead(doc, root, device);
      keep.addAll(jsonMap(doc['files']).values.cast<String>());
    }
    for (final entry in heads.skip(3)) {
      _check(generation);
      await dav.delete(entry.path);
    }
    for (final c in syncCategories) {
      _check(generation);
      final files = own(await dav.list('$root/devices/$device/$c'));
      // Retain three recent versions AND every version referenced by retained heads.
      for (final entry in files.skip(3)) {
        if (keep.contains(entry.path)) continue;
        _check(generation);
        await dav.delete(entry.path);
      }
    }
  }

  @override
  void dispose() {
    _cancel();
    _closed = true;
    _idle?.cancel();
    store.removeListener(_storeChanged);
    if (identical(store.syncHooks, this)) store.syncHooks = null;
    super.dispose();
  }
}
