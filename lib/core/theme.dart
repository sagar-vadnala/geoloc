import 'package:material_ui/material_ui.dart';

/// Colours that carry meaning (sync state) rather than decoration.
@immutable
class StatusColors extends ThemeExtension<StatusColors> {
  const StatusColors({
    required this.synced,
    required this.pending,
    required this.failed,
    required this.muted,
    required this.line,
  });

  final Color synced;
  final Color pending;
  final Color failed;
  final Color muted;
  final Color line;

  static StatusColors of(BuildContext context) =>
      Theme.of(context).extension<StatusColors>()!;

  @override
  StatusColors copyWith({
    Color? synced,
    Color? pending,
    Color? failed,
    Color? muted,
    Color? line,
  }) {
    return StatusColors(
      synced: synced ?? this.synced,
      pending: pending ?? this.pending,
      failed: failed ?? this.failed,
      muted: muted ?? this.muted,
      line: line ?? this.line,
    );
  }

  @override
  StatusColors lerp(StatusColors? other, double t) {
    if (other == null) return this;
    return StatusColors(
      synced: Color.lerp(synced, other.synced, t)!,
      pending: Color.lerp(pending, other.pending, t)!,
      failed: Color.lerp(failed, other.failed, t)!,
      muted: Color.lerp(muted, other.muted, t)!,
      line: Color.lerp(line, other.line, t)!,
    );
  }
}

abstract final class AppTheme {
  static const _font = 'IBM Plex Sans';
  static const _cobalt = Color(0xFF2B55D6);

  static ThemeData light() => _build(
    brightness: Brightness.light,
    canvas: const Color(0xFFF2F4F7),
    surface: Colors.white,
    ink: const Color(0xFF17202B),
    primary: _cobalt,
    status: const StatusColors(
      synced: Color(0xFF1D8A57),
      pending: Color(0xFFB26B00),
      failed: Color(0xFFC43D33),
      muted: Color(0xFF5E6B7A),
      line: Color(0xFFDDE2E8),
    ),
  );

  static ThemeData dark() => _build(
    brightness: Brightness.dark,
    canvas: const Color(0xFF141A21),
    surface: const Color(0xFF1C232C),
    ink: const Color(0xFFE6EAEF),
    primary: const Color(0xFF7D9CF5),
    status: const StatusColors(
      synced: Color(0xFF4CC38A),
      pending: Color(0xFFE5A23A),
      failed: Color(0xFFF2766B),
      muted: Color(0xFF94A0AE),
      line: Color(0xFF2C3540),
    ),
  );

  static ThemeData _build({
    required Brightness brightness,
    required Color canvas,
    required Color surface,
    required Color ink,
    required Color primary,
    required StatusColors status,
  }) {
    final scheme =
        ColorScheme.fromSeed(
          seedColor: primary,
          brightness: brightness,
        ).copyWith(
          primary: primary,
          onPrimary: brightness == Brightness.light ? Colors.white : canvas,
          surface: surface,
          onSurface: ink,
          onSurfaceVariant: status.muted,
          outline: status.line,
          outlineVariant: status.line,
          error: status.failed,
        );

    final base = ThemeData(
      brightness: brightness,
      colorScheme: scheme,
      fontFamily: _font,
      scaffoldBackgroundColor: canvas,
    );

    final text = base.textTheme.apply(bodyColor: ink, displayColor: ink);

    return base.copyWith(
      extensions: [status],
      textTheme: text.copyWith(
        headlineMedium: text.headlineMedium?.copyWith(
          fontSize: 28,
          fontWeight: FontWeight.w600,
          height: 1.15,
          letterSpacing: -0.4,
        ),
        titleMedium: text.titleMedium?.copyWith(
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: text.bodyLarge?.copyWith(fontSize: 16, height: 1.45),
        bodyMedium: text.bodyMedium?.copyWith(fontSize: 14, height: 1.4),
        bodySmall: text.bodySmall?.copyWith(fontSize: 13, color: status.muted),
      ),
      dividerTheme: DividerThemeData(color: status.line, space: 1),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
          textStyle: const TextStyle(
            fontFamily: _font,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          textStyle: const TextStyle(
            fontFamily: _font,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
