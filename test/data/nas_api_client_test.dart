import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:momo_box/data/nas/nas_api_client.dart';
import 'package:momo_box/data/nas/nas_api_error.dart';

void main() {
  group('requestJson keeps credentials inside configured API boundary', () {
    for (final path in [
      'https://other.example/api/v1/me',
      'http://nas.example/proxy/api/v1/me',
      'https://nas.example:8443/proxy/api/v1/me',
      'https://user@nas.example/proxy/api/v1/me',
      'https://nas.example/other/api/v1/me',
      '../me',
      '../../me',
      '%2e%2e/me',
      'me#fragment',
    ]) {
      test('rejects $path before sending bearer', () async {
        var requests = 0;
        final api = NasApiClient(
          'https://nas.example/proxy',
          client: MockClient((_) async {
            requests++;
            return http.Response('{}', 200);
          }),
        );
        addTearDown(api.close);
        api.setAccessToken('private-token');
        await expectLater(
          api.requestJson(method: 'GET', path: path),
          throwsA(isA<NasApiError>().having(
            (error) => error.kind,
            'kind',
            NasApiErrorKind.invalidBaseUrl,
          )),
        );
        expect(requests, 0);
        expect(api.accessToken, 'private-token');
      });
    }

    test('relative feature requests keep prefix, bearer and query parameters', () async {
      final requests = <http.Request>[];
      final api = NasApiClient(
        'https://nas.example/proxy/api/v1/',
        client: MockClient((request) async {
          requests.add(request);
          return http.Response('{"items":[]}', 200);
        }),
      );
      addTearDown(api.close);
      api.setAccessToken('current');
      final response = await api.requestJson(
        method: 'GET',
        path: '/families?offset=0',
        queryParameters: {'limit': '10'},
      );
      expect(response['items'], isEmpty);
      expect(requests, hasLength(1));
      expect(requests.single.url.path, '/proxy/api/v1/families');
      expect(requests.single.url.queryParameters, {'offset': '0', 'limit': '10'});
      expect(requests.single.headers['Authorization'], 'Bearer current');
    });
  });
}
