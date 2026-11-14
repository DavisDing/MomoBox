import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../app/momo_typography.dart';
import '../../domain/models/ai_action.dart';

/// Formats only the displayed reply. Stored messages and action parsing retain
/// their original content and continue through the separate confirmation flow.
class AssistantMessageBody extends StatelessWidget {
  const AssistantMessageBody({super.key, required this.content});

  final String content;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final textScaler = MediaQuery.textScalerOf(context);
    final body = TextStyle(
      color: colors.onSurface,
      fontSize: MomoTextSize.title,
      height: 1.5,
    );
    final tableText = body.copyWith(fontSize: MomoTextSize.body);
    return MarkdownBody(
      data: AiInventoryAction.displayText(content),
      selectable: true,
      softLineBreak: true,
      fitContent: false,
      styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
        p: body,
        h1: body.copyWith(
          fontSize: MomoTextSize.page,
          fontWeight: FontWeight.w600,
        ),
        h2: body.copyWith(
          fontSize: MomoTextSize.section,
          fontWeight: FontWeight.w600,
        ),
        h3: body.copyWith(fontWeight: FontWeight.w600),
        h4: body.copyWith(fontWeight: FontWeight.w600),
        h5: tableText.copyWith(fontWeight: FontWeight.w600),
        h6: tableText.copyWith(fontWeight: FontWeight.w600),
        a: body.copyWith(
          color: colors.primary,
          decoration: TextDecoration.underline,
        ),
        listBullet: body,
        blockquote: body.copyWith(color: colors.onSurfaceVariant),
        blockSpacing: 10,
        listIndent: textScaler.scale(28),
        blockquotePadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 8,
        ),
        blockquoteDecoration: BoxDecoration(
          color: colors.surfaceContainerHighest.withValues(alpha: .5),
          border: Border(
            left: BorderSide(color: colors.outlineVariant, width: 3),
          ),
        ),
        code: tableText.copyWith(
          fontFamily: 'monospace',
          backgroundColor: colors.surfaceContainerHighest,
        ),
        codeblockPadding: const EdgeInsets.all(12),
        codeblockDecoration: BoxDecoration(
          color: colors.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(10),
        ),
        tableHead: tableText.copyWith(fontWeight: FontWeight.w600),
        tableBody: tableText,
        // Fixed, scaled cells wrap long text while the whole table scrolls
        // horizontally. It must not widen the conversation on a narrow phone.
        tableColumnWidth: FixedColumnWidth(
          148 *
              (textScaler.scale(MomoTextSize.body) / MomoTextSize.body).clamp(
                1.0,
                double.infinity,
              ),
        ),
        tableCellsPadding: const EdgeInsets.all(10),
        tableBorder: TableBorder.all(color: colors.outlineVariant),
        tableHeadCellsDecoration: BoxDecoration(
          color: colors.surfaceContainerHighest,
        ),
        textScaler: textScaler,
      ),
      onTapLink: (_, href, _) => _openLink(context, href),
      // Replies are untrusted. Do not fetch tracking images or read device
      // files while rendering; a deliberate tap opens a web image externally.
      imageBuilder:
          (uri, title, alt) => TextButton.icon(
            onPressed:
                _webUri(uri.toString()) == null
                    ? null
                    : () => _openLink(context, uri.toString()),
            icon: const Icon(Icons.image_outlined, size: 18),
            label: Text(alt?.trim().isNotEmpty == true ? '查看图片：$alt' : '查看图片'),
          ),
    );
  }

  static Uri? _webUri(String? href) {
    final uri = href == null ? null : Uri.tryParse(href);
    return uri != null &&
            (uri.scheme == 'https' || uri.scheme == 'http') &&
            uri.host.isNotEmpty &&
            uri.userInfo.isEmpty
        ? uri
        : null;
  }

  static Future<void> _openLink(BuildContext context, String? href) async {
    final uri = _webUri(href);
    var message = '仅支持打开 HTTP 或 HTTPS 网页链接。';
    if (uri != null) {
      try {
        if (await launchUrl(uri, mode: LaunchMode.externalApplication)) return;
      } catch (_) {
        // Native launch failures should not replace or discard the reply.
      }
      message = '无法打开链接，请检查设备是否有可用浏览器。';
    }
    if (context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(message)));
    }
  }
}
