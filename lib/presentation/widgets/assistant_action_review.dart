import 'package:flutter/material.dart';

import 'momo_components.dart';
import 'momo_mobile_layout.dart';

/// Opening a review never executes the proposal. Receipts become readable
/// status instead of a faded, disabled action that looks available to retry.
class AssistantActionEntry extends StatelessWidget {
  const AssistantActionEntry({
    required this.receipt,
    required this.onPressed,
    this.label = '查看并确认操作',
    super.key,
  });

  final String? receipt;
  final VoidCallback? onPressed;
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = receipt;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: status == null
          ? MomoCapsuleButton(
              onPressed: onPressed,
              label: label,
              icon: const Icon(Icons.fact_check_outlined, size: 18),
              isPrimary: false,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            )
          : Semantics(
              liveRegion: true,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    status == '已执行' || status == '已打开页面'
                        ? Icons.check_circle_outline_rounded
                        : Icons.info_outline_rounded,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      status,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

class AssistantActionReviewDialog extends StatelessWidget {
  const AssistantActionReviewDialog({
    required this.kind,
    required this.description,
    super.key,
  });

  final String kind;
  final String description;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final destructive = kind == 'discard' || kind.endsWith('_delete');
    final (title, icon) = switch (kind) {
      'product_update' => ('确认修改物品资料', Icons.edit_outlined),
      'device_control' => ('确认控制设备', Icons.devices_outlined),
      'consume_many' => ('确认记录消耗', Icons.inventory_2_outlined),
      _ => ('确认操作', destructive
          ? Icons.delete_outline_rounded : Icons.fact_check_outlined),
    };
    final cancel = MomoCapsuleButton(
      label: '取消',
      isPrimary: false,
      onPressed: () => Navigator.pop(context, false),
    );
    final confirm = Theme(
      data: destructive ? theme.copyWith(
        filledButtonTheme: FilledButtonThemeData(
          style: (theme.filledButtonTheme.style ?? const ButtonStyle()).copyWith(
            backgroundColor: WidgetStatePropertyAll(colors.error),
            foregroundColor: WidgetStatePropertyAll(colors.onError),
          ),
        ),
      ) : theme,
      child: MomoCapsuleButton(
        label: '确认执行',
        onPressed: () => Navigator.pop(context, true),
      ),
    );
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      backgroundColor: colors.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        // Let the whole review grow and scroll, including its actions. A long
        // title or Dynamic Type must never push confirmation off the viewport.
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: destructive
                          ? colors.errorContainer
                          : colors.surfaceContainerLow,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      icon,
                      size: 20,
                      color: destructive ? colors.onErrorContainer : colors.primary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Semantics(
                      header: true,
                      child: Text(title, style: theme.textTheme.headlineSmall),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerLow,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: SelectableText(
                  description,
                  style: theme.textTheme.bodyMedium?.copyWith(height: 1.6),
                ),
              ),
              const SizedBox(height: 20),
              LayoutBuilder(builder: (context, constraints) {
                if (MomoMobileLayout.stack(context, constraints.maxWidth, minimum: 300)) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [confirm, const SizedBox(height: 10), cancel],
                  );
                }
                return Row(children: [
                  Expanded(child: cancel),
                  const SizedBox(width: 12),
                  Expanded(child: confirm),
                ]);
              }),
            ],
          ),
        ),
      ),
    );
  }
}

class AssistantPurchaseReviewDialog extends StatefulWidget {
  const AssistantPurchaseReviewDialog({required this.items, super.key});

  final List<String> items;

  @override
  State<AssistantPurchaseReviewDialog> createState() => _AssistantPurchaseReviewDialogState();
}

class _AssistantPurchaseReviewDialogState extends State<AssistantPurchaseReviewDialog> {
  late final _selected = {for (var index = 0; index < widget.items.length; index++) index};

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('加入采购清单'),
    scrollable: true,
    content: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < widget.items.length; index++)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: Text(widget.items[index]),
            value: _selected.contains(index),
            onChanged: (value) => setState(() {
              if (value == true) {
                _selected.add(index);
              } else {
                _selected.remove(index);
              }
            }),
          ),
      ],
    ),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
      FilledButton(
        onPressed: _selected.isEmpty ? null : () => Navigator.pop(context, Set<int>.of(_selected)),
        child: const Text('确认加入'),
      ),
    ],
  );
}
