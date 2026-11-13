import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:momo_box/application/ai_fallback_executor.dart';
import 'package:momo_box/application/backend_processing_error.dart';
import 'package:momo_box/data/nas/nas_sync_api.dart';

void main() {
  test('NAS owns model credentials; mobile only sends selected alias and authorized text',() async {
    final requests=<http.Request>[];
    final api=NasSyncApi('https://nas.example',accessToken:'nas-token',client:MockClient((request) async {
      requests.add(request);
      if(request.url.path.endsWith('/capabilities')) return http.Response('{"backend_ai":true}',200);
      return http.Response(jsonEncode({'content':'OK','model':'family-smart','protocol':'chat','level':'primary','elapsed_ms':12,'usage':{}}),200);
    }));
    addTearDown(api.close);
    final executor=AiFallbackExecutor(backendResolver:() async=>api,modelReader:() async=>'family-smart');
    final response=await executor.execute(systemPrompt:'test',userPrompt:'hello');
    expect(response.model,'family-smart');
    expect(response.content,'OK');
    expect(requests.length,2);
    final payload=jsonDecode(requests.last.body) as Map;
    expect(payload['model'],'family-smart');
    expect(payload.keys,containsAll(['request_id','system_prompt','user_prompt','history','temperature','model']));
    expect(payload.containsKey('endpoint'),isFalse);
    expect(payload.containsKey('api_key'),isFalse);
    expect(payload.containsKey('tools'),isFalse);
    expect(requests.last.headers['Authorization'],'Bearer nas-token');
  });
  test('missing NAS session cannot become a direct inference call',() async {
    final executor=AiFallbackExecutor(backendResolver:() async=>null);
    await expectLater(executor.execute(systemPrompt:'test',userPrompt:'hello'),throwsA(isA<BackendProcessingSetupException>()));
  });
  test('NAS response is validated before returning a suggestion',() async {
    final api=NasSyncApi('https://nas.example',accessToken:'session',client:MockClient((request) async=>
      http.Response(request.url.path.endsWith('/capabilities')?'{"backend_ai":true}':'{"content":""}',200)));
    addTearDown(api.close);
    final executor=AiFallbackExecutor(backendResolver:() async=>api);
    await expectLater(executor.execute(systemPrompt:'test',userPrompt:'hello'),throwsFormatException);
  });
}
