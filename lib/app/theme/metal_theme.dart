import 'package:flutter/material.dart';

/// A dark, brushed-steel look shared by the home screen and the full-screen lyrics pages.
/// Deliberately not used by the small overlay widget, which stays as it already is.
class MetalTheme {
  MetalTheme._();

  static const Color base = Color(0xFF16171B); // near-black page background
  static const Color surfaceDark = Color(0xFF232529); // card gradient, dark end
  static const Color surfaceLight = Color(
    0xFF3C3F45,
  ); // card gradient, light end
  static const Color edgeHighlight = Color(
    0xFF5A5E66,
  ); // thin brushed-edge border
  static const Color steel = Color(
    0xFF9AA4B2,
  ); // primary accent — icons, active states
  static const Color steelBright = Color(
    0xFFC7D0DC,
  ); // brighter accent — highlights
  static const Color textPrimary = Color(0xFFF2F3F5);
  static const Color textSecondary = Color(0xFFAEB3BC);
  static const Color textMuted = Color(0xFF74787F);

  static const LinearGradient backgroundGradient = LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: [Color(0xFF1C1D21), Color(0xFF101114)],
  );

  static const LinearGradient cardGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [surfaceLight, surfaceDark],
  );

  static const LinearGradient cardGradientDisabled = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF2A2C30), Color(0xFF1C1D20)],
  );

  static ThemeData themeData() {
    final base = ThemeData(brightness: Brightness.dark, useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: MetalTheme.base,
      colorScheme: base.colorScheme.copyWith(
        primary: steel,
        secondary: steelBright,
        surface: surfaceDark,
        onPrimary: const Color(0xFF101114),
        onSurface: textPrimary,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: MetalTheme.base,
        foregroundColor: textPrimary,
        elevation: 0,
      ),
      textTheme: base.textTheme.apply(
        bodyColor: textPrimary,
        displayColor: textPrimary,
      ),
      iconTheme: const IconThemeData(color: steel),
      dividerColor: const Color(0xFF2E3036),
    );
  }
}

/// A brushed-metal panel — gradient fill, a thin highlight edge, and a soft drop shadow — the
/// shared building block for every card-shaped section on the home screen and full-screen
/// lyrics pages, replacing the flat default Material [Card].
class MetalCard extends StatelessWidget {
  const MetalCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        gradient: MetalTheme.cardGradient,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: MetalTheme.edgeHighlight, width: 0.6),
        boxShadow: const [
          BoxShadow(
            color: Colors.black45,
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Padding(padding: padding, child: child),
      ),
    );
  }
}

/// A brushed-metal button matching [MetalCard]'s look — used for the overlay show/hide toggle
/// in place of the default flat [ElevatedButton].
class MetalButton extends StatelessWidget {
  const MetalButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null;
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onPressed,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            gradient: enabled
                ? MetalTheme.cardGradient
                : MetalTheme.cardGradientDisabled,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: MetalTheme.edgeHighlight, width: 0.6),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (icon != null) ...[
                Icon(
                  icon,
                  size: 18,
                  color: enabled
                      ? MetalTheme.steelBright
                      : MetalTheme.textMuted,
                ),
                const SizedBox(width: 8),
              ],
              Text(
                label,
                style: TextStyle(
                  color: enabled
                      ? MetalTheme.textPrimary
                      : MetalTheme.textMuted,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
