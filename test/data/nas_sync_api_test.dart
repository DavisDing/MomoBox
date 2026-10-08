import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:momo_box/data/nas/nas_api_error.dart';
import 'package:momo_box/data/nas/nas_sync_api.dart';

http.Response _versions({int schema = 1, int protocol = 1}) => http.Response(
      jsonEncode({'schema_version': schema, 'sync_protocol_version': protocol}),
      200,
    );

Matcher _error(NasApiErrorKind kind) => isA<NasApiError>().having(
      (error) => error.kind,
      'kind',
      kind,
    );

void main() {
  group('capabilities transport contract', () {
    for (final base in ['https://nas.example/proxy', 'https://nas.example/proxy/api/v1/']) {
      test('GET preserves configured API prefix: $base', () async {
        final requests = <http.Request>[];
        final api = NasSyncApi(
          base,
          accessToken: ' token ',
          client: MockClient((request) async {
            requests.add(request);
            return _versions(schema: 1, protocol: 2);
          }),
        );
        addTearDown(api.close);

        final versions = await api.capabilities();
        expect(versions.schemaVersion, 1);
        // Compatibility policy belongs to the engine, not this transport.
        expect(versions.syncProtocolVersion, 2);
        expect(requests, hasLength(1));
        expect(requests.single.method, 'GET');
        expect(requests.single.url.toString(), 'https://nas.example/proxy/api/v1/capabilities');
        expect(requests.single.headers['Authorization'], 'Bearer token');
        expect(requests.single.headers['Accept'], 'application/json');
        expect(requests.single.body, isEmpty);
      });
    }

    final malformed = <String, String>{
      'empty body': '',
      'invalid JSON': '{',
      'non-object': '[]',
      'null root': 'null',
      'missing schema': '{"sync_protocol_version":1}',
      'missing protocol': '{"schema_version":1}',
      'null version': '{"schema_version":null,"sync_protocol_version":1}',
      'string version': '{"schema_version":1,"sync_protocol_version":"1"}',
      'fractional version': '{"schema_version":1.5,"sync_protocol_version":1}',
      'boolean version': '{"schema_version":true,"sync_protocol_version":1}',
      'nested version': '{"schema_version":1,"sync_protocol_version":{"version":1}}',
    };
    for (final entry in malformed.entries) {
      test('malformed capabilities fail closed: ${entry.key}', () async {
        var requests = 0;
        final api = NasSyncApi(
          'https://nas.example',
          accessToken: 'token',
          client: MockClient((_) async {
            requests++;
            return http.Response(entry.value, 200);
          }),
        );
        addTearDown(api.close);
        await expectLater(api.capabilities(), throwsA(_error(NasApiErrorKind.invalidResponse)));
        expect(requests, 1);
      });
    }

    test('401 refresh retries GET once with the returned token', () async {
      final requests = <http.Request>[];
      var refreshes = 0;
      final api = NasSyncApi(
        'https://nas.example',
        accessToken: 'old',
        refreshHandler: () async {
          refreshes++;
          return 'fresh';
        },
        client: MockClient((request) async {
          requests.add(request);
          return requests.length == 1 ? http.Response('{}', 401) : _versions();
        }),
      );
      addTearDown(api.close);
      expect((await api.capabilities()).syncProtocolVersion, 1);
      expect(refreshes, 1);
      expect(requests, hasLength(2));
      expect(requests.map((request) => request.method), ['GET', 'GET']);
      expect(requests[1].url, requests[0].url);
      expect(requests[0].headers['Authorization'], 'Bearer old');
      expect(requests[1].headers['Authorization'], 'Bearer fresh');
    });

    test('a second 401 does not loop refresh', () async {
      var requests = 0;
      var refreshes = 0;
      final api = NasSyncApi(
        'https://nas.example',
        accessToken: 'old',
        refreshHandler: () async {
          refreshes++;
          return 'fresh';
        },
        client: MockClient((_) async {
          requests++;
          return http.Response('{}', 401);
        }),
      );
      addTearDown(api.close);
      await expectLater(api.capabilities(), throwsA(_error(NasApiErrorKind.unauthorized)));
      expect(requests, 2);
      expect(refreshes, 1);
    });
  });

  group('capabilities session boundary', () {
    test('invalid session prevents network and refresh', () async {
      var requests = 0;
      var refreshes = 0;
      final api = NasSyncApi(
        'https://nas.example',
        accessToken: 'cached',
        isSessionCurrent: () => false,
        refreshHandler: () async {
          refreshes++;
          return 'fresh';
        },
        client: MockClient((_) async {
          requests++;
          return _versions();
        }),
      );
      addTearDown(api.close);
      await expectLater(api.capabilities(), throwsA(_error(NasApiErrorKind.unauthorized)));
      expect(requests, 0);
      expect(refreshes, 0);
    });

    for (final change in ['session', 'clear token', 'close', 'provider']) {
      test('$change while awaiting a successful response rejects it', () async {
        var current = true;
        String? token = 'current';
        final entered = Completer<void>();
        final release = Completer<http.Response>();
        var requests = 0;
        final api = NasSyncApi(
          'https://nas.example',
          accessToken: 'cached',
          accessTokenProvider: change == 'provider' ? () => token : null,
          isSessionCurrent: () => current,
          client: MockClient((_) async {
            requests++;
            entered.complete();
            return release.future;
          }),
        );
        addTearDown(api.close);
        final assertion = expectLater(
          api.capabilities(),
          throwsA(_error(NasApiErrorKind.unauthorized)),
        );
        await entered.future;
        if (change == 'session') current = false;
        if (change == 'clear token') api.setAccessToken(null);
        if (change == 'close') api.close();
        if (change == 'provider') token = null;
        release.complete(_versions());
        await assertion;
        await expectLater(api.capabilities(), throwsA(_error(NasApiErrorKind.unauthorized)));
        expect(requests, 1);
      });
    }

    for (final change in ['session', 'clear token', 'close', 'provider']) {
      test('$change during refresh cannot restore a token or send a retry', () async {
        var current = true;
        String? token = 'current';
        final entered = Completer<void>();
        final release = Completer<String?>();
        var requests = 0;
        final api = NasSyncApi(
          'https://nas.example',
          accessToken: 'cached',
          accessTokenProvider: change == 'provider' ? () => token : null,
          isSessionCurrent: () => current,
          refreshHandler: () {
            entered.complete();
            return release.future;
          },
          client: MockClient((_) async {
            requests++;
            return http.Response('{}', 401);
          }),
        );
        addTearDown(api.close);
        final assertion = expectLater(
          api.capabilities(),
          throwsA(_error(NasApiErrorKind.unauthorized)),
        );
        await entered.future;
        if (change == 'session') current = false;
        if (change == 'clear token') api.setAccessToken(null);
        if (change == 'close') api.close();
        if (change == 'provider') token = null;
        release.complete('late-refresh-token');
        await assertion;
        await expectLater(api.capabilities(), throwsA(_error(NasApiErrorKind.unauthorized)));
        expect(requests, 1);
      });
    }

    test('a replacement token does not make an old response current again', () async {
      final entered = Completer<void>();
      final release = Completer<http.Response>();
      final requests = <http.Request>[];
      final api = NasSyncApi(
        'https://nas.example',
        accessToken: 'old-account',
        client: MockClient((request) async {
          requests.add(request);
          if (requests.length == 1) {
            entered.complete();
            return release.future;
          }
          return _versions();
        }),
      );
      addTearDown(api.close);
      final assertion = expectLater(
        api.capabilities(),
        throwsA(_error(NasApiErrorKind.unauthorized)),
      );
      await entered.future;
      api.setAccessToken(null);
      api.setAccessToken('new-account');
      release.complete(_versions());
      await assertion;
      expect((await api.capabilities()).schemaVersion, 1);
      expect(requests, hasLength(2));
      expect(requests.last.headers['Authorization'], 'Bearer new-account');
    });

    test('null provider never falls back to a cached token', () async {
      var requests = 0;
      final api = NasSyncApi(
        'https://nas.example',
        accessToken: 'cached',
        accessTokenProvider: () => null,
        client: MockClient((_) async {
          requests++;
          return _versions();
        }),
      );
      addTearDown(api.close);
      await expectLater(api.capabilities(), throwsA(_error(NasApiErrorKind.unauthorized)));
      expect(requests, 0);
    });
  });
}
