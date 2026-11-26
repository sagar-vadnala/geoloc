import 'package:material_ui/material_ui.dart';

import '../../../../core/theme.dart';

/// A stop in a pickup-to-drop-off list: a marker (filled for pickup, hollow
/// for drop-off) joined by a line to the stop below it.
class StopLine extends StatelessWidget {
  const StopLine({
    super.key,
    required this.label,
    required this.title,
    this.subtitle,
    this.filled = true,
    this.showConnector = false,
    this.dimmed = false,
  });

  final String label;
  final String title;
  final String? subtitle;
  final bool filled;
  final bool showConnector;

  /// Already done, shown for context only.
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final status = StatusColors.of(context);
    final color = dimmed ? status.muted : theme.colorScheme.primary;
    final text = theme.textTheme;

    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: 22,
            child: Column(
              children: [
                const SizedBox(height: 4),
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: filled ? color : null,
                    border: Border.all(color: color, width: 2),
                  ),
                ),
                if (showConnector)
                  Expanded(
                    child: Container(
                      width: 2,
                      margin: const EdgeInsets.symmetric(vertical: 4),
                      color: status.line,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: showConnector ? 14 : 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: text.bodySmall),
                  Text(
                    title,
                    style: text.titleMedium?.copyWith(
                      color: dimmed ? status.muted : null,
                    ),
                  ),
                  if (subtitle != null && subtitle!.isNotEmpty)
                    Text(
                      subtitle!,
                      style: text.bodyMedium?.copyWith(color: status.muted),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
