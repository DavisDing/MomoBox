import 'package:flutter/material.dart';

/// Shows the newest transient feedback and removes an older message first.
///
/// Keeping this behavior in one presentation-layer helper prevents a stale
/// SnackBar from masking the result of a newer user action. If the widget is
/// no longer attached to a ScaffoldMessenger, the feedback is safely ignored.
ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? showAppSnackBar(
  BuildContext context,
  SnackBar snackBar,
) {
  final messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return null;
  messenger.hideCurrentSnackBar();
  return messenger.showSnackBar(snackBar);
}
