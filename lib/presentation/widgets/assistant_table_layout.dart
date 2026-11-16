import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

/// Keep GFM parsing, including escaped pipes and reference links. The marker is
/// rendered after the entire document's inline parsing finishes.
class AssistantTableSyntax extends md.TableSyntax {
  const AssistantTableSyntax();

  @override
  md.Node? parse(md.BlockParser parser) {
    final table = super.parse(parser);
    if (table is! md.Element) return table;
    return md.Element('section', table.children)
      ..attributes['assistant-table'] = 'true';
  }
}

class AssistantTableBuilder extends MarkdownElementBuilder {
  AssistantTableBuilder({
    required this.styleSheet,
    required this.onTapLink,
    required this.imageBuilder,
  });

  final MarkdownStyleSheet styleSheet;
  final MarkdownTapLinkCallback onTapLink;
  final MarkdownImageBuilder imageBuilder;
  final _tables = <md.Element, List<md.Element>>{};

  @override
  void visitElementBefore(md.Element element) {
    if (element.attributes['assistant-table'] != 'true') return;
    _tables[element] = _rows(element).toList();
    // The custom widget owns these cells. Do not visit tr/td through the stock
    // renderer without its enclosing table state.
    element.children!.clear();
  }

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final rows = _tables.remove(element);
    if (rows == null) return null;
    return _AssistantTable(
      rows: rows.map((row) => row.children!.cast<md.Element>()).toList(),
      styleSheet: styleSheet,
      onTapLink: onTapLink,
      imageBuilder: imageBuilder,
    );
  }

  static Iterable<md.Element> _rows(md.Element element) sync* {
    if (element.tag == 'tr') {
      yield element;
    } else {
      for (final child in element.children?.whereType<md.Element>() ??
          const <md.Element>[]) {
        yield* _rows(child);
      }
    }
  }
}

class _AssistantTable extends StatefulWidget {
  const _AssistantTable({
    required this.rows,
    required this.styleSheet,
    required this.onTapLink,
    required this.imageBuilder,
  });

  final List<List<md.Element>> rows;
  final MarkdownStyleSheet styleSheet;
  final MarkdownTapLinkCallback onTapLink;
  final MarkdownImageBuilder imageBuilder;

  @override
  State<_AssistantTable> createState() => _AssistantTableState();
}

class _AssistantTableState extends State<_AssistantTable> {
  final _scrollController = ScrollController();
  static const _padding = 8.0;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  Widget _cell(List<md.Node> nodes, {bool heading = false, String? align}) {
    final sheet = widget.styleSheet;
    final style = heading ? sheet.tableHead! : sheet.tableBody!;
    return _ParsedTableCell(
      nodes: nodes,
      styleSheet: sheet.copyWith(
        p: style,
        a: sheet.a?.copyWith(fontSize: style.fontSize),
        textAlign: switch (align) {
          'right' => WrapAlignment.end,
          'center' => WrapAlignment.center,
          _ => WrapAlignment.start,
        },
      ),
      onTapLink: widget.onTapLink,
      imageBuilder: widget.imageBuilder,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.rows.isEmpty || widget.rows.first.isEmpty) {
      return const SizedBox.shrink();
    }
    final colors = Theme.of(context).colorScheme;
    final count = widget.rows.first.length;
    final scaler = widget.styleSheet.textScaler ??
        MediaQuery.textScalerOf(context);
    final fontSize = widget.styleSheet.tableBody!.fontSize!;
    final scale = scaler.scale(fontSize) / fontSize;
    final preferred = List<double>.filled(count, 0);
    for (var row = 0; row < widget.rows.length; row++) {
      for (var column = 0; column < count; column++) {
        final painter = TextPainter(
          text: TextSpan(
            text: widget.rows[row][column].textContent,
            style: row == 0
                ? widget.styleSheet.tableHead
                : widget.styleSheet.tableBody,
          ),
          textScaler: scaler,
          textDirection: Directionality.of(context),
        )..layout();
        preferred[column] = math.max(
          preferred[column],
          math.min(260 * scale, painter.width + _padding * 2),
        );
        painter.dispose();
      }
    }
    final minimum = [
      for (final width in preferred)
        math.min(width, scaler.scale(fontSize) * 3 + _padding * 2),
    ];
    // Reserve room for up to three readable characters per column, then give
    // extra width to the columns that need it. Never reduce the user's font.
    return LayoutBuilder(builder: (context, constraints) {
      final minimumTotal = minimum.fold<double>(0, (sum, width) => sum + width);
      final preferredTotal = preferred.fold<double>(0, (sum, width) => sum + width);
      final available = constraints.maxWidth;
      final crowded = available.isFinite && minimumTotal > available;
      if (crowded && count >= 2 && count <= 6 && widget.rows.length > 1) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var row = 1; row < widget.rows.length; row++)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  border: row == widget.rows.length - 1
                      ? null
                      : Border(bottom: BorderSide(color: colors.outlineVariant)),
                ),
                child: _cell([
                  for (var column = 0; column < count; column++) ...[
                    if (column > 0) md.Element.empty('br'),
                    if (widget.rows.first[column].textContent.trim().isNotEmpty) ...[
                      md.Element('strong', [
                        ...?widget.rows.first[column].children,
                      ]),
                      md.Text('：'),
                    ],
                    ...?widget.rows[row][column].children,
                  ],
                ]),
              ),
          ],
        );
      }
      final target = crowded || !available.isFinite ? preferredTotal : available;
      final widths = [
        for (var column = 0; column < count; column++)
          preferredTotal <= target
              ? preferred[column] + (target - preferredTotal) / count
              : minimum[column] + (target - minimumTotal) *
                  (preferred[column] - minimum[column]) /
                  (preferredTotal - minimumTotal),
      ];
      final table = ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: Table(
          columnWidths: {
            for (var column = 0; column < count; column++)
              column: FixedColumnWidth(widths[column]),
          },
          defaultVerticalAlignment: TableCellVerticalAlignment.top,
          border: TableBorder(
            horizontalInside: BorderSide(
              color: colors.outlineVariant.withValues(alpha: .6),
            ),
          ),
          children: [
            for (var row = 0; row < widget.rows.length; row++)
              TableRow(
                decoration: row == 0
                    ? BoxDecoration(
                        color: colors.surfaceContainerHighest.withValues(alpha: .6),
                      )
                    : null,
                children: [
                  for (final cell in widget.rows[row])
                    Padding(
                      padding: const EdgeInsets.all(_padding),
                      child: _cell(
                        [...?cell.children],
                        heading: row == 0,
                        align: cell.attributes['align'],
                      ),
                    ),
                ],
              ),
          ],
        ),
      );
      if (!crowded) return table;
      return Scrollbar(
        controller: _scrollController,
        child: SingleChildScrollView(
          controller: _scrollController,
          scrollDirection: Axis.horizontal,
          child: SizedBox(width: target, child: table),
        ),
      );
    });
  }
}

/// Use the same Markdown builder for parsed cells, preserving selection, safe
/// links, emphasis and image guards without reparsing or flattening their text.
class _ParsedTableCell extends StatefulWidget {
  const _ParsedTableCell({
    required this.nodes,
    required this.styleSheet,
    required this.onTapLink,
    required this.imageBuilder,
  });

  final List<md.Node> nodes;
  final MarkdownStyleSheet styleSheet;
  final MarkdownTapLinkCallback onTapLink;
  final MarkdownImageBuilder imageBuilder;

  @override
  State<_ParsedTableCell> createState() => _ParsedTableCellState();
}

class _ParsedTableCellState extends State<_ParsedTableCell>
    implements MarkdownBuilderDelegate {
  final _links = <TapGestureRecognizer>[];

  void _disposeLinks() {
    for (final link in _links) {
      link.dispose();
    }
    _links.clear();
  }

  @override
  void dispose() {
    _disposeLinks();
    super.dispose();
  }

  @override
  GestureRecognizer createLink(String text, String? href, String title) {
    final link = TapGestureRecognizer()
      ..onTap = () => widget.onTapLink(text, href, title);
    _links.add(link);
    return link;
  }

  @override
  TextSpan formatText(MarkdownStyleSheet styleSheet, String code) =>
      TextSpan(style: styleSheet.code, text: code);

  @override
  Widget build(BuildContext context) {
    _disposeLinks();
    final children = MarkdownBuilder(
      delegate: this,
      selectable: true,
      styleSheet: widget.styleSheet,
      imageDirectory: null,
      imageBuilder: widget.imageBuilder,
      checkboxBuilder: null,
      bulletBuilder: null,
      builders: const {},
      paddingBuilders: const {},
      listItemCrossAxisAlignment: MarkdownListItemCrossAxisAlignment.start,
      softLineBreak: true,
      contextMenuBuilder: (context, editableTextState) =>
          AdaptiveTextSelectionToolbar.editableText(
            editableTextState: editableTextState,
          ),
    ).build([md.Element('p', [...widget.nodes])]);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }
}
