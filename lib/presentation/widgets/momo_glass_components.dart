import 'dart:ui';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../app/momo_theme.dart';
import 'momo_floating_dock.dart';
import 'momo_press_scale.dart';

/// Capsule actions retain native focus, keyboard and screen-reader behavior.
/// Height is a minimum: wrapped labels and accessibility text can grow.
class MomoCapsuleButton extends StatefulWidget {
  const MomoCapsuleButton({
    required this.onPressed,
    required this.label,
    this.icon,
    this.isPrimary = true,
    this.isLoading = false,
    this.height = 48,
    this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
    super.key,
  });

  final VoidCallback? onPressed;
  final String label;
  final Widget? icon;
  final bool isPrimary;
  final bool isLoading;
  final double height;
  final EdgeInsetsGeometry padding;

  @override
  State<MomoCapsuleButton> createState() => _MomoCapsuleButtonState();
}

class _MomoCapsuleButtonState extends State<MomoCapsuleButton> {
  final _states = WidgetStatesController();
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    _states.addListener(_updatePressed);
  }

  void _updatePressed() {
    final pressed = _states.value.contains(WidgetState.pressed);
    if (pressed == _pressed) return;
    // Native buttons may update disabled/pressed state while rebuilding.
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(
            () => _pressed = _states.value.contains(WidgetState.pressed),
          );
        }
      });
    } else {
      setState(() => _pressed = pressed);
    }
  }

  @override
  void dispose() {
    _states.removeListener(_updatePressed);
    _states.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onPressed != null && !widget.isLoading;
    final theme = Theme.of(context);
    final buttonTheme =
        widget.isPrimary
            ? theme.filledButtonTheme.style
            : theme.outlinedButtonTheme.style;
    final loadingForeground = buttonTheme?.foregroundColor?.resolve({});
    final loadingBackground = buttonTheme?.backgroundColor?.resolve({});
    final child = Semantics(
      liveRegion: widget.isLoading,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (widget.isLoading) ...[
            SizedBox.square(
              dimension: 18,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: loadingForeground,
              ),
            ),
            const SizedBox(width: 8),
          ] else if (widget.icon != null) ...[
            widget.icon!,
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Text(
              widget.isLoading ? '处理中…' : widget.label,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
    final style = ButtonStyle(
      backgroundColor:
          widget.isLoading && loadingBackground != null
              ? WidgetStatePropertyAll(loadingBackground)
              : null,
      foregroundColor:
          widget.isLoading && loadingForeground != null
              ? WidgetStatePropertyAll(loadingForeground)
              : null,
      minimumSize: WidgetStatePropertyAll(Size(48, widget.height)),
      padding: WidgetStatePropertyAll(widget.padding),
      textStyle: WidgetStatePropertyAll(
        theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
      ),
    );
    final button =
        widget.isPrimary
            ? FilledButton(
              statesController: _states,
              style: style,
              onPressed: enabled ? widget.onPressed : null,
              child: child,
            )
            : OutlinedButton(
              statesController: _states,
              style: style,
              onPressed: enabled ? widget.onPressed : null,
              child: child,
            );
    return MomoPressScale(
      pressed: enabled && _pressed,
      child: button,
    );
  }
}

/// Ordinary content uses a light solid material; only floating layers blur.
class MomoGlassCard extends StatefulWidget {
  const MomoGlassCard({
    required this.child,
    this.onTap,
    this.padding = const EdgeInsets.all(16),
    this.margin,
    this.borderRadius = 18,
    this.palette,
    this.color,
    this.frosted = false,
    super.key,
  });

  final Widget child;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final double borderRadius;
  final MomoPalette? palette;
  final Color? color;
  final bool frosted;

  @override
  State<MomoGlassCard> createState() => _MomoGlassCardState();
}

class _MomoGlassCardState extends State<MomoGlassCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final highContrast = MediaQuery.highContrastOf(context) || MediaQuery.accessibleNavigationOf(context);
    final radius = BorderRadius.circular(widget.borderRadius);
    final surface =
        widget.color ??
        (theme.brightness == Brightness.light
            ? widget.palette?.surface
            : null) ??
        scheme.surface;
    final background =
        widget.frosted && !highContrast
            ? (theme.brightness == Brightness.dark
                ? scheme.onSurface.withValues(alpha: 0.08)
                : surface.withValues(alpha: 0.82))
            : surface;
    final border = scheme.onSurface.withValues(
      alpha: highContrast ? 0.5 : 0.08,
    );
    Widget content = Card(
      color: background,
      surfaceTintColor: Colors.transparent,
      margin: EdgeInsets.zero,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: radius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.onTap,
        onHighlightChanged:
            widget.onTap == null
                ? null
                : (pressed) {
                  setState(() => _pressed = pressed);
                },
        child: Padding(padding: widget.padding, child: widget.child),
      ),
    );
    if (widget.frosted && !highContrast) {
      content = ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
          child: content,
        ),
      );
    }
    return Padding(
      padding: widget.margin ?? const EdgeInsets.symmetric(vertical: 6),
      child: MomoPressScale(
        pressed: _pressed,
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: radius,
            border: Border.all(color: border, width: 0.5),
          ),
          // Paint the fine border above the material, outside its clip.
          child: Padding(padding: const EdgeInsets.all(0.5), child: content),
        ),
      ),
    );
  }
}

/// A rounded search field with no fixed-height constraint on scaled text.
class MomoGlassSearchBar extends StatelessWidget {
  const MomoGlassSearchBar({
    required this.hintText,
    this.controller,
    this.focusNode,
    this.onChanged,
    this.onSubmitted,
    this.onTap,
    this.suffixIcon,
    this.autofocus = false,
    this.textInputAction,
    this.palette,
    super.key,
  });

  final String hintText;
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final VoidCallback? onTap;
  final Widget? suffixIcon;
  final bool autofocus;
  final TextInputAction? textInputAction;
  final MomoPalette? palette;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final shape = OutlineInputBorder(
      borderRadius: BorderRadius.circular(12),
      borderSide: BorderSide.none,
    );
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 48),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        autofocus: autofocus,
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        onTap: onTap,
        textInputAction: textInputAction,
        scrollPadding: EdgeInsets.fromLTRB(20, 20, 20, 20 + MomoDockInsets.bottomOf(context)),
        style: theme.textTheme.bodyLarge,
        decoration: InputDecoration(
          hintText: hintText,
          hintStyle: theme.textTheme.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
          prefixIcon: const Icon(Icons.search_rounded, size: 24),
          suffixIcon: suffixIcon,
          prefixIconConstraints: const BoxConstraints(
            minWidth: 44,
            minHeight: 48,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 10,
          ),
          filled: true,
          fillColor: scheme.onSurface.withValues(alpha: 0.08),
          border: shape,
          enabledBorder: shape,
          focusedBorder: shape.copyWith(
            borderSide: BorderSide(
              color: palette?.primary ?? scheme.primary,
              width: 2,
            ),
          ),
          isDense: true,
        ),
      ),
    );
  }
}

/// Native AppBar navigation/actions over a clipped translucent material.
class MomoGlassAppBar extends StatelessWidget implements PreferredSizeWidget {
  const MomoGlassAppBar({
    this.title,
    this.leading,
    this.actions,
    this.bottom,
    this.automaticallyImplyLeading = true,
    this.centerTitle,
    this.titleSpacing,
    this.toolbarHeight = kToolbarHeight,
    super.key,
  });

  /// Scaffold reads preferredSize before building the toolbar. Resolve the
  /// title at the call site so large text gets real space, including back and
  /// action buttons, instead of merely painting beyond a fixed 56dp bar.
  factory MomoGlassAppBar.adaptive(
    BuildContext context, {
    Widget? title,
    Widget? leading,
    List<Widget>? actions,
    PreferredSizeWidget? bottom,
    bool automaticallyImplyLeading = true,
    bool? centerTitle,
    double? titleSpacing,
    double toolbarHeight = kToolbarHeight,
    Key? key,
  }) {
    var height = toolbarHeight;
    if (title is Text) {
      final availableWidth = math.max(1.0,
        MediaQuery.sizeOf(context).width - MediaQuery.paddingOf(context).horizontal -
        ((leading != null || automaticallyImplyLeading) ? 56 : 0) -
        (actions?.length ?? 0) * 48 - (titleSpacing ?? 16) * 2,
      );
      final painter = TextPainter(
        text: TextSpan(
          text: title.data ?? title.textSpan?.toPlainText(),
          style: Theme.of(context).textTheme.titleLarge?.merge(title.style),
        ),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
        locale: Localizations.maybeLocaleOf(context),
      )..layout(maxWidth: availableWidth);
      height = math.max(height, painter.height.ceilToDouble() + 16);
      painter.dispose();
    }
    return MomoGlassAppBar(
      key: key,
      title: title == null ? null : DefaultTextStyle.merge(
        softWrap: true, overflow: TextOverflow.visible, child: title,
      ),
      leading: leading,
      actions: actions,
      bottom: bottom,
      automaticallyImplyLeading: automaticallyImplyLeading,
      centerTitle: centerTitle,
      titleSpacing: titleSpacing,
      toolbarHeight: height,
    );
  }

  final Widget? title;
  final Widget? leading;
  final List<Widget>? actions;
  final PreferredSizeWidget? bottom;
  final bool automaticallyImplyLeading;
  final bool? centerTitle;
  final double? titleSpacing;
  final double toolbarHeight;

  @override
  Size get preferredSize =>
      Size.fromHeight(toolbarHeight + (bottom?.preferredSize.height ?? 0));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final highContrast = MediaQuery.highContrastOf(context) || MediaQuery.accessibleNavigationOf(context);
    return AppBar(
      title: title,
      leading: leading,
      actions: actions,
      bottom: bottom,
      automaticallyImplyLeading: automaticallyImplyLeading,
      centerTitle: centerTitle,
      titleSpacing: titleSpacing,
      toolbarHeight: toolbarHeight,
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      flexibleSpace: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(
            sigmaX: highContrast ? 0 : 16,
            sigmaY: highContrast ? 0 : 16,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              // Tint glass with the page canvas so the status/toolbar area
              // does not turn into a white (or dark grey) card-shaped band.
              color: theme.scaffoldBackgroundColor.withValues(
                alpha: highContrast ? 1 : 0.85,
              ),
            ),
            child: const SizedBox.expand(),
          ),
        ),
      ),
    );
  }
}
