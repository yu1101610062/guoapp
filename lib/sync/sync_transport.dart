import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:xml/xml.dart';

import 'sync_state.dart';

const syncRoot = 'ZhenguojianSync/v1';
const jianguoyunEndpoint = 'https://dav.jianguoyun.com/dav/';

class SyncFailure implements Exception {
  const SyncFailure(this.kind, this.message, {this.retryAfter});
  final String kind, message;
  final Duration? retryAfter;
  @override
  String toString() => message;
}

class DavEntry {
  const DavEntry(this.path, {this.directory = false});
  final String path;
  final bool directory;
}

abstract class SyncTransport {
  bool manual = false;
  int? serverOffset;
  Future<List<DavEntry>> list(String path);
  Future<List<int>> get(String path);
  Future<void> put(String path, List<int> bytes);
  Future<void> mkdir(String path);
  Future<void> delete(String path);
  void close();
}

/// A persisted, account-wide rolling budget, shared by all profiles in a client.
class RequestBudget {
  RequestBudget({this.file, DateTime Function()? now})
    : now = now ?? DateTime.now;
  final File? file;
  final DateTime Function() now;
  final List<int> _requests = [];
  Future<void> _queue = Future.value();
  bool _loaded = false;
  int _blockedUntil = 0;
  Future<void> _persist() async {
    if (file == null) return;
    await file!.parent.create(recursive: true);
    final temp = File('${file!.path}.tmp');
    await temp.writeAsString(
      jsonEncode({'requests': _requests, 'blockedUntil': _blockedUntil}),
      flush: true,
    );
    await temp.rename(file!.path);
  }

  Future<void> defer(Duration duration) {
    final job = _queue.catchError((Object _) {}).then((_) async {
      final until = now().add(duration).millisecondsSinceEpoch;
      if (until > _blockedUntil) _blockedUntil = until;
      await _persist();
    });
    _queue = job;
    return job;
  }

  Future<void> take({required bool manual}) {
    final job = _queue.catchError((Object _) {}).then((_) async {
      if (!_loaded) {
        if (file != null && await file!.exists()) {
          try {
            final saved = jsonDecode(await file!.readAsString());
            _requests.addAll(
              (saved is List ? saved : saved['requests'] as List).cast<int>(),
            );
            if (saved is Map) {
              _blockedUntil = saved['blockedUntil'] as int? ?? 0;
            }
          } catch (_) {
            throw const SyncFailure('budget', '请求预算文件损坏，请稍后检查本地存储');
          }
        }
        _loaded = true;
      }
      final time = now().millisecondsSinceEpoch;
      if (time < _blockedUntil) {
        throw SyncFailure(
          'rate',
          '坚果云限流等待中，稍后自动继续',
          retryAfter: Duration(milliseconds: _blockedUntil - time),
        );
      }
      _requests.removeWhere(
        (t) => t <= time - const Duration(minutes: 30).inMilliseconds,
      );
      if (_requests.length >= (manual ? 100 : 80)) {
        final delay =
            (_requests.first +
                    const Duration(minutes: 30).inMilliseconds -
                    time)
                .clamp(1000, 1800000);
        throw SyncFailure(
          'budget',
          '已达到本客户端请求预算，稍后自动继续',
          retryAfter: Duration(milliseconds: delay),
        );
      }
      _requests.add(time);
      // Persist before I/O. All profiles sharing an account use this budget.
      await _persist();
    });
    _queue = job;
    return job;
  }
}

class WebDavTransport extends SyncTransport {
  WebDavTransport({
    required String account,
    required String password,
    required this.budget,
    HttpClient? client,
    Uri? testEndpoint,
  }) : _authorization =
           'Basic ${base64Encode(utf8.encode('$account:$password'))}',
       _client = client ?? HttpClient(),
       _base = testEndpoint ?? Uri.parse(jianguoyunEndpoint) {
    if (_base.toString() != jianguoyunEndpoint &&
        !['127.0.0.1', 'localhost', '::1'].contains(_base.host)) {
      throw ArgumentError('Only the official HTTPS endpoint is allowed');
    }
    _client.connectionTimeout = const Duration(seconds: 12);
  }
  final String _authorization;
  final HttpClient _client;
  final Uri _base;
  final RequestBudget budget;
  static const maxBytes = 16 * 1024 * 1024;

  Uri _uri(String path) {
    if (path.split('/').any((s) => s == '..' || s == '.') ||
        path.startsWith('/')) {
      throw const FormatException('云端路径无效');
    }
    return _base.resolve(path.split('/').map(Uri.encodeComponent).join('/'));
  }

  Future<({int status, List<int> bytes})> _request(
    String method,
    String path, {
    List<int>? body,
    Map<String, String> headers = const {},
    Set<int> accept = const {200, 201, 204, 207},
  }) async {
    await budget.take(manual: manual);
    try {
      return await (() async {
        final request = await _client.openUrl(method, _uri(path));
        request.followRedirects =
            false; // Never forward a password to a redirect.
        request.headers.set(HttpHeaders.authorizationHeader, _authorization);
        request.headers.set(HttpHeaders.userAgentHeader, 'ZhenguojianSync/1');
        headers.forEach(request.headers.set);
        if (body != null) {
          request.contentLength = body.length;
          request.add(body);
        }
        final response = await request.close();
        final date = response.headers.value(HttpHeaders.dateHeader);
        if (date != null) {
          try {
            serverOffset =
                HttpDate.parse(date).millisecondsSinceEpoch -
                DateTime.now().millisecondsSinceEpoch;
          } catch (_) {}
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > maxBytes) {
            throw const SyncFailure('corrupt', '云端文件过大');
          }
          bytes.addAll(chunk);
        }
        final status = response.statusCode;
        if (status == 401 || status == 403) {
          throw const SyncFailure('auth', '应用密码无效或权限不足，请更新应用密码');
        }
        if (status == 429 || status == 503) {
          final raw = response.headers.value('retry-after');
          var seconds = int.tryParse(raw ?? '') ?? 60;
          if (raw != null && int.tryParse(raw) == null) {
            try {
              seconds = HttpDate.parse(
                raw,
              ).difference(DateTime.now()).inSeconds;
            } catch (_) {}
          }
          final delay = Duration(seconds: seconds.clamp(1, 86400));
          await budget.defer(delay);
          throw SyncFailure('rate', '坚果云暂时限流，等待后重试', retryAfter: delay);
        }
        if (!accept.contains(status)) {
          throw SyncFailure(
            status == 404 ? 'missing' : 'http',
            '云端请求失败（HTTP $status）',
          );
        }
        return (status: status, bytes: bytes);
      })().timeout(const Duration(seconds: 20));
    } on SyncFailure {
      rethrow;
    } on TimeoutException {
      throw const SyncFailure('timeout', '连接超时，待上传数据已保留');
    } on IOException {
      throw const SyncFailure('network', '网络不可用，待上传数据已保留');
    }
  }

  @override
  Future<List<DavEntry>> list(String path) async {
    final response = await _request(
      'PROPFIND',
      '$path/',
      headers: {'Depth': '1', 'Content-Type': 'application/xml'},
      body: utf8.encode(
        '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>',
      ),
      accept: {207},
    );
    try {
      final doc = XmlDocument.parse(utf8.decode(response.bytes));
      if (doc.rootElement.name.local != 'multistatus') {
        throw const FormatException();
      }
      final responses = doc
          .findAllElements('response', namespace: 'DAV:')
          .toList();
      if (responses.isEmpty || responses.length >= 750) {
        throw const FormatException();
      }
      final result = <DavEntry>[];
      final parent = _uri('$path/');
      var hasSelf = false;
      for (final node in responses) {
        final hrefs = node.findAllElements('href', namespace: 'DAV:').toList();
        if (hrefs.length != 1) throw const FormatException();
        final uri = parent.resolve(hrefs.single.innerText);
        if (uri.origin != _base.origin || !uri.path.startsWith(_base.path)) {
          throw const FormatException();
        }
        final decoded = Uri.decodeComponent(
          uri.path.substring(_base.path.length),
        ).replaceFirst(RegExp(r'/$'), '');
        final statuses = node
            .findAllElements('status', namespace: 'DAV:')
            .map((e) => e.innerText)
            .toList();
        if (statuses.isEmpty ||
            statuses.any((s) => !RegExp(r'HTTP/\S+ 200(?: |$)').hasMatch(s))) {
          throw const FormatException();
        }
        if (decoded == path) {
          hasSelf = true;
          continue;
        }
        if (!decoded.startsWith('$path/') ||
            decoded.substring(path.length + 1).contains('/') ||
            decoded.endsWith('/..')) {
          throw const FormatException();
        }
        result.add(
          DavEntry(
            decoded,
            directory: node
                .findAllElements('collection', namespace: 'DAV:')
                .isNotEmpty,
          ),
        );
      }
      if (!hasSelf) throw const FormatException();
      return result;
    } catch (_) {
      throw const SyncFailure('listing', '云端目录读取不完整，本批数据未应用');
    }
  }

  @override
  Future<List<int>> get(String path) async =>
      (await _request('GET', path, accept: {200})).bytes;
  @override
  Future<void> put(String path, List<int> bytes) async {
    await _request(
      'PUT',
      path,
      body: bytes,
      headers: {
        'Content-Type': 'application/octet-stream',
        'If-None-Match': '*',
      },
      accept: {200, 201, 204, 412},
    );
  }

  @override
  Future<void> mkdir(String path) async {
    await _request('MKCOL', '$path/', accept: {200, 201, 204, 405});
  }

  @override
  Future<void> delete(String path) async {
    await _request('DELETE', path, accept: {200, 204, 404});
  }

  @override
  void close() => _client.close(force: true);
}

List<int> encodeSnapshot(Map<String, dynamic> doc) =>
    gzip.encode(utf8.encode(jsonEncode(doc)));
String contentHash(List<int> bytes) => sha256.convert(bytes).toString();
Map<String, dynamic> decodeSnapshot(List<int> bytes, String expectedHash) {
  if (bytes.length > WebDavTransport.maxBytes ||
      contentHash(bytes) != expectedHash) {
    throw const SyncFailure('corrupt', '云端文件校验失败，本批数据未应用');
  }
  // Bound inflation as well as compressed network bytes (zip bombs).
  final sink = _BoundedSink();
  final decoder = gzip.decoder.startChunkedConversion(sink);
  try {
    for (var i = 0; i < bytes.length; i += 4096) {
      decoder.add(bytes.sublist(i, (i + 4096).clamp(0, bytes.length)));
    }
    decoder.close();
    return jsonMap(jsonDecode(utf8.decode(sink.bytes)));
  } catch (_) {
    throw const SyncFailure('corrupt', '云端文件损坏，本批数据未应用');
  }
}

class _BoundedSink implements Sink<List<int>> {
  final bytes = <int>[];
  @override
  void add(List<int> data) {
    if (bytes.length + data.length > WebDavTransport.maxBytes) {
      throw const FormatException('snapshot too large');
    }
    bytes.addAll(data);
  }

  @override
  void close() {}
}
