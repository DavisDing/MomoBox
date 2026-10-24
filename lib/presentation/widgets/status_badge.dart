import '../../app/momo_typography.dart';
import 'package:flutter/material.dart';

import '../../domain/inventory/expiry_rules.dart';

class StatusBadge extends StatelessWidget {
  const StatusBadge({required this.status, required this.days, super.key});

  final ExpiryStatus status;
  final int? days;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = scheme.brightness == Brightness.dark;
    final highContrast = MediaQuery.highContrastOf(context);
    final (label, color) = switch (status) {
      ExpiryStatus.safe => ('效期充足', isDark ? Colors.green.shade300 : Colors.green.shade800),
      ExpiryStatus.expiring => (days == 0 ? '今日到期' : '$days 天内到期', isDark ? Colors.orange.shade300 : Colors.orange.shade900),
      ExpiryStatus.expired => ('已过期', scheme.error),
      ExpiryStatus.noExpiry => ('未设置效期', scheme.onSurfaceVariant),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: ShapeDecoration(
        color: highContrast ? scheme.surface : color.withValues(alpha: 0.1),
        shape: StadiumBorder(
          side: BorderSide(color: color.withValues(alpha: highContrast ? 1 : 0.2), width: 0.5),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: MomoTextSize.caption),
      ),
    );
  }
}
