import 'package:flutter/material.dart';

import '../../domain/models/inventory_models.dart';

enum MatchChoice { merge, create, cancel }

class MatchDecision {
  const MatchDecision(this.choice, {this.candidate});
  final MatchChoice choice;
  final ProductMatchCandidate? candidate;
}

Future<MatchDecision> showProductMatchConfirmation(
  BuildContext context,
  List<ProductMatchCandidate> matches, {
  String? draftName,
}) async {
  var selectedIndex = 0;
  final decision = await showDialog<MatchDecision>(
    context: context,
    barrierDismissible: false,
    builder:
        (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) {
            final selected = matches[selectedIndex];
            return AlertDialog(
              title: const Text('发现相似商品'),
              content: SizedBox(
                width: 420,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        draftName == null
                            ? '请选择如何处理本次入库：'
                            : '请选择如何入库「$draftName」。',
                      ),
                      const SizedBox(height: 10),
                      RadioGroup<int>(
                        groupValue: selectedIndex,
                        onChanged: (value) {
                          if (value != null) {
                            setDialogState(() => selectedIndex = value);
                          }
                        },
                        child: Column(
                          children: [
                            for (var index = 0; index < matches.length; index++)
                              RadioListTile<int>(
                                value: index,
                                contentPadding: EdgeInsets.zero,
                                title: Text(matches[index].name),
                                subtitle: Text(
                                  _matchDescription(matches[index]),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '当前选择：${selected.name}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      const SizedBox(height: 12),
                      const Text('合并只会为已有商品新增一个独立批次；不会静默修改原商品信息。'),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed:
                      () => Navigator.pop(
                        dialogContext,
                        const MatchDecision(MatchChoice.cancel),
                      ),
                  child: const Text('取消'),
                ),
                TextButton(
                  onPressed:
                      () => Navigator.pop(
                        dialogContext,
                        const MatchDecision(MatchChoice.create),
                      ),
                  child: const Text('新建独立商品'),
                ),
                FilledButton(
                  onPressed:
                      () => Navigator.pop(
                        dialogContext,
                        MatchDecision(MatchChoice.merge, candidate: selected),
                      ),
                  child: const Text('合并到已有商品'),
                ),
              ],
            );
          },
        ),
  );
  return decision ?? const MatchDecision(MatchChoice.cancel);
}

String _matchDescription(ProductMatchCandidate candidate) => [
  candidate.category,
  candidate.brand,
  candidate.specification,
  candidate.barcode,
].whereType<String>().where((value) => value.trim().isNotEmpty).join(' · ');
