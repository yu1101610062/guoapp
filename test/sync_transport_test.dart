import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:duanju_app/sync/sync_transport.dart';

void main() {
  test(
    'real HTTP PUT GET DELETE, namespace-aware PROPFIND and clock offset',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final files = <String, List<int>>{};
      final methods = <String>[];
      server.listen((request) async {
        expect(
          request.headers.value('authorization'),
          'Basic ${base64Encode(utf8.encode('user:app-pass'))}',
        );
        methods.add(request.method);
        request.response.headers.set(
          'date',
          HttpDate.format(DateTime.now().add(const Duration(minutes: 10))),
        );
        switch (request.method) {
          case 'PUT':
            files[request.uri.path] = await request.fold<List<int>>(
              [],
              (all, b) => all..addAll(b),
            );
            request.response.statusCode = 201;
          case 'GET':
            request.response.add(files[request.uri.path]!);
          case 'DELETE':
            files.remove(request.uri.path);
            request.response.statusCode = 204;
          case 'PROPFIND':
            expect(request.headers.value('depth'), '1');
            request.response.statusCode = 207;
            request.response.write(
              '''<?xml version="1.0"?><x:multistatus xmlns:x="DAV:">
<x:response><x:href>/dav/folder/</x:href><x:propstat><x:prop><x:resourcetype><x:collection/></x:resourcetype></x:prop><x:status>HTTP/1.1 200 OK</x:status></x:propstat></x:response>
<x:response><x:href>/dav/folder/a.bin</x:href><x:propstat><x:prop><x:resourcetype/></x:prop><x:status>HTTP/1.1 200 OK</x:status></x:propstat></x:response>
</x:multistatus>''',
            );
          default:
            request.response.statusCode = 201;
        }
        await request.response.close();
      });
      final dav = WebDavTransport(
        account: 'user',
        password: 'app-pass',
        budget: RequestBudget(),
        testEndpoint: Uri.parse('http://127.0.0.1:${server.port}/dav/'),
      );
      addTearDown(dav.close);
      await dav.mkdir('folder');
      await dav.put('folder/a.bin', [1, 2, 3]);
      expect(await dav.get('folder/a.bin'), [1, 2, 3]);
      expect((await dav.list('folder')).single.path, 'folder/a.bin');
      expect(dav.serverOffset!, greaterThan(590000));
      await dav.delete('folder/a.bin');
      expect(files, isEmpty);
      expect(methods, ['MKCOL', 'PUT', 'GET', 'PROPFIND', 'DELETE']);
    },
  );
  test(
    'HTTP auth, Retry-After, redirects and incomplete listings fail closed',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var status = 401;
      var body = '';
      server.listen((r) async {
        r.response.statusCode = status;
        r.response.headers.set('retry-after', '93');
        r.response.headers.set(
          'location',
          'https://example.invalid/password-leak',
        );
        r.response.write(body);
        await r.response.close();
      });
      var clock = DateTime.now();
      final dav = WebDavTransport(
        account: 'u',
        password: 'p',
        budget: RequestBudget(now: () => clock),
        testEndpoint: Uri.parse('http://127.0.0.1:${server.port}/dav/'),
      );
      addTearDown(dav.close);
      await expectLater(
        dav.get('x'),
        throwsA(isA<SyncFailure>().having((e) => e.kind, 'kind', 'auth')),
      );
      status = 429;
      await expectLater(
        dav.get('x'),
        throwsA(
          isA<SyncFailure>().having(
            (e) => e.retryAfter,
            'delay',
            const Duration(seconds: 93),
          ),
        ),
      );
      clock = clock.add(const Duration(seconds: 94));
      status = 302;
      await expectLater(
        dav.get('x'),
        throwsA(isA<SyncFailure>().having((e) => e.kind, 'kind', 'http')),
      );
      status = 207;
      body = '<d:multistatus xmlns:d="DAV:"></d:multistatus>';
      await expectLater(
        dav.list('x'),
        throwsA(isA<SyncFailure>().having((e) => e.kind, 'kind', 'listing')),
      );
    },
  );
  test(
    'rolling account budget reserves manual quota and survives reload',
    () async {
      final dir = Directory.systemTemp.createTempSync('sync-budget-');
      addTearDown(() => dir.delete(recursive: true));
      var now = DateTime(2026, 1, 1);
      final file = File('${dir.path}/budget.json');
      final b = RequestBudget(file: file, now: () => now);
      for (var i = 0; i < 80; i++) {
        await b.take(manual: false);
      }
      await expectLater(b.take(manual: false), throwsA(isA<SyncFailure>()));
      final restarted = RequestBudget(file: file, now: () => now);
      for (var i = 0; i < 20; i++) {
        await restarted.take(manual: true);
      }
      await expectLater(
        restarted.take(manual: true),
        throwsA(isA<SyncFailure>()),
      );
      now = now.add(const Duration(minutes: 30));
      await restarted.take(manual: false);
      await restarted.defer(const Duration(minutes: 5));
      final cooling = RequestBudget(file: file, now: () => now);
      await expectLater(
        cooling.take(manual: true),
        throwsA(isA<SyncFailure>().having((e) => e.kind, 'kind', 'rate')),
      );
      now = now.add(const Duration(minutes: 5));
      await cooling.take(manual: true);
    },
  );
  test(
    'gzip checksums reject corruption and bounded inflation rejects oversized files',
    () {
      final data = encodeSnapshot({'protocol': 1, 'test': 'ok'});
      expect(decodeSnapshot(data, contentHash(data))['test'], 'ok');
      expect(
        () => decodeSnapshot([...data, 0], contentHash(data)),
        throwsA(isA<SyncFailure>()),
      );
      final bomb = gzip.encode(List.filled(WebDavTransport.maxBytes + 1, 65));
      expect(
        () => decodeSnapshot(bomb, contentHash(bomb)),
        throwsA(isA<SyncFailure>()),
      );
    },
  );
}
