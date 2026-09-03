import 'package:flutter/material.dart';

import '../../domain/inventory/expiry_rules.dart';

class StatusBadge extends StatelessWidget {
  const StatusBadge({required this.status, required this.days, super.key});

  final ExpiryStatus status;
  final int? days;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (status) {
      ExpiryStatus.safe => ('效期充足', Colors.green),
      ExpiryStatus.expiring => (days == 0 ? '今日到期' : '$days 天内到期', Colors.orange),
      ExpiryStatus.expired => ('已过期', Colors.red),
      ExpiryStatus.noExpiry => ('未设置效期', Colors.blueGrey),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 12),
      ),
    );
  }
}
