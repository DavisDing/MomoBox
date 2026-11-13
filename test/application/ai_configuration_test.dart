import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/domain/models/nas_ai_model.dart';
void main(){
 test('NAS model list contains only IDs and default selection; duplicate IDs are removed',(){
  final models=NasAiModel.parse([{'id':'family-fast','default':true,'api_key':'ignored'},{'id':'family-fast'},{'id':'family-smart'}]);
  expect(models.map((model)=>model.id),['family-fast','family-smart']);
  expect(models.first.isDefault,isTrue);
 });
 test('invalid NAS model catalog is rejected',(){
  for(final raw in [null,{},[{'id':''}],[{'id':1}]]) {
   expect(()=>NasAiModel.parse(raw),throwsFormatException);
  }
 });
}
