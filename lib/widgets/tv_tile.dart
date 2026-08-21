import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../utils/tv_helper.dart';

/// A [ListTile] with the app's TV focus treatment: blue border + primary glow
/// + slight scale when focused, and select/enter/space/gameButtonA activation
/// via [Focus.onKeyEvent] (media-center keys don't activate an InkWell).
///
/// On phones/tablets (`isTvMode == false`) this renders a plain [ListTile] so
/// touch behaviour is unchanged.
class TvTile extends StatelessWidget {
  const TvTile({
    super.key,
    this.leading,
    this.title,
    this.subtitle,
    this.trailing,
    this.dense,
    this.enabled = true,
    this.onTap,
  });

  final Widget? leading;
  final Widget? title;
  final Widget? subtitle;
  final Widget? trailing;
  final bool? dense;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    if (!isTvMode(context)) {
      return ListTile(
        leading: leading,
        title: title,
        subtitle: subtitle,
        trailing: trailing,
        dense: dense,
        enabled: enabled,
        onTap: enabled ? onTap : null,
      );
    }
    return Focus(
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent || event is KeyRepeatEvent) {
          final key = event.logicalKey;
          if (enabled &&
              onTap != null &&
              (key == LogicalKeyboardKey.select ||
                  key == LogicalKeyboardKey.enter ||
                  key == LogicalKeyboardKey.numpadEnter ||
                  key == LogicalKeyboardKey.space ||
                  key == LogicalKeyboardKey.gameButtonA)) {
            onTap!();
            return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: Builder(
        builder: (context) {
          final focused = Focus.of(context).hasFocus;
          final primary = Theme.of(context).colorScheme.primary;
          return AnimatedScale(
            scale: focused ? 1.05 : 1.0,
            duration: const Duration(milliseconds: 150),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: focused
                    ? primary.withValues(alpha: 0.3)
                    : Colors.transparent,
                border: Border.all(
                  color: focused ? primary : Colors.transparent,
                  width: 3,
                ),
                boxShadow: focused
                    ? [
                        BoxShadow(
                          color: primary.withValues(alpha: 0.4),
                          blurRadius: 12,
                          spreadRadius: 2,
                        ),
                      ]
                    : null,
              ),
              child: ListTile(
                leading: leading,
                title: title,
                subtitle: subtitle,
                trailing: trailing,
                dense: dense,
                enabled: enabled,
                onTap: enabled ? onTap : null,
              ),
            ),
          );
        },
      ),
    );
  }
}
