import 'package:flutter/material.dart';

/// Semantic color tokens for Open Bench so future themes swap cleanly without widget edits.
class CircuitColors extends ThemeExtension<CircuitColors> {
  final Color canvasBackground;
  final Color panelSurface;
  final Color panelBorder;
  final Color gridMinor;
  final Color gridMajor;
  final Color accentAmber;
  final Color accentAmberDim;
  final Color wireDefault;
  final Color wireSelected;
  final Color componentStroke;
  final Color pinHighlight;
  final Color scopeCh1;
  final Color scopeCh2;
  final Color scopeCh3;
  final Color scopeCh4;
  final Color dangerRed;

  const CircuitColors({
    required this.canvasBackground,
    required this.panelSurface,
    required this.panelBorder,
    required this.gridMinor,
    required this.gridMajor,
    required this.accentAmber,
    required this.accentAmberDim,
    required this.wireDefault,
    required this.wireSelected,
    required this.componentStroke,
    required this.pinHighlight,
    required this.scopeCh1,
    required this.scopeCh2,
    required this.scopeCh3,
    required this.scopeCh4,
    required this.dangerRed,
  });

  static const darkAmber = CircuitColors(
    canvasBackground: Color(0xFF12100E),
    panelSurface: Color(0xFF1C1814),
    panelBorder: Color(0xFF332B22),
    gridMinor: Color(0xFF211C16),
    gridMajor: Color(0xFF332B22),
    accentAmber: Color(0xFFFFB300),
    accentAmberDim: Color(0xFF8C6200),
    wireDefault: Color(0xFFD7CCC8),
    wireSelected: Color(0xFFFFCA28),
    componentStroke: Color(0xFFF5E6D3),
    pinHighlight: Color(0xFFFFB300),
    scopeCh1: Color(0xFFFFB300),
    scopeCh2: Color(0xFF26C6DA),
    scopeCh3: Color(0xFF66BB6A),
    scopeCh4: Color(0xFFCE93D8),
    dangerRed: Color(0xFFEF5350),
  );

  static const lightBench = CircuitColors(
    canvasBackground: Color(0xFFF7F4EE),
    panelSurface: Color(0xFFECE6DA),
    panelBorder: Color(0xFFCFC6B4),
    gridMinor: Color(0xFFE7E1D4),
    gridMajor: Color(0xFFD5CCB9),
    accentAmber: Color(0xFFD97706),
    accentAmberDim: Color(0xFFB45309),
    wireDefault: Color(0xFF4E473E),
    wireSelected: Color(0xFFB45309),
    componentStroke: Color(0xFF231F1A),
    pinHighlight: Color(0xFFD97706),
    scopeCh1: Color(0xFFD97706),
    scopeCh2: Color(0xFF00838F),
    scopeCh3: Color(0xFF2E7D32),
    scopeCh4: Color(0xFF7B1FA2),
    dangerRed: Color(0xFFC62828),
  );

  @override
  CircuitColors copyWith({
    Color? canvasBackground,
    Color? panelSurface,
    Color? panelBorder,
    Color? gridMinor,
    Color? gridMajor,
    Color? accentAmber,
    Color? accentAmberDim,
    Color? wireDefault,
    Color? wireSelected,
    Color? componentStroke,
    Color? pinHighlight,
    Color? scopeCh1,
    Color? scopeCh2,
    Color? scopeCh3,
    Color? scopeCh4,
    Color? dangerRed,
  }) {
    return CircuitColors(
      canvasBackground: canvasBackground ?? this.canvasBackground,
      panelSurface: panelSurface ?? this.panelSurface,
      panelBorder: panelBorder ?? this.panelBorder,
      gridMinor: gridMinor ?? this.gridMinor,
      gridMajor: gridMajor ?? this.gridMajor,
      accentAmber: accentAmber ?? this.accentAmber,
      accentAmberDim: accentAmberDim ?? this.accentAmberDim,
      wireDefault: wireDefault ?? this.wireDefault,
      wireSelected: wireSelected ?? this.wireSelected,
      componentStroke: componentStroke ?? this.componentStroke,
      pinHighlight: pinHighlight ?? this.pinHighlight,
      scopeCh1: scopeCh1 ?? this.scopeCh1,
      scopeCh2: scopeCh2 ?? this.scopeCh2,
      scopeCh3: scopeCh3 ?? this.scopeCh3,
      scopeCh4: scopeCh4 ?? this.scopeCh4,
      dangerRed: dangerRed ?? this.dangerRed,
    );
  }

  @override
  CircuitColors lerp(ThemeExtension<CircuitColors>? other, double t) {
    if (other is! CircuitColors) return this;
    return CircuitColors(
      canvasBackground: Color.lerp(canvasBackground, other.canvasBackground, t)!,
      panelSurface: Color.lerp(panelSurface, other.panelSurface, t)!,
      panelBorder: Color.lerp(panelBorder, other.panelBorder, t)!,
      gridMinor: Color.lerp(gridMinor, other.gridMinor, t)!,
      gridMajor: Color.lerp(gridMajor, other.gridMajor, t)!,
      accentAmber: Color.lerp(accentAmber, other.accentAmber, t)!,
      accentAmberDim: Color.lerp(accentAmberDim, other.accentAmberDim, t)!,
      wireDefault: Color.lerp(wireDefault, other.wireDefault, t)!,
      wireSelected: Color.lerp(wireSelected, other.wireSelected, t)!,
      componentStroke: Color.lerp(componentStroke, other.componentStroke, t)!,
      pinHighlight: Color.lerp(pinHighlight, other.pinHighlight, t)!,
      scopeCh1: Color.lerp(scopeCh1, other.scopeCh1, t)!,
      scopeCh2: Color.lerp(scopeCh2, other.scopeCh2, t)!,
      scopeCh3: Color.lerp(scopeCh3, other.scopeCh3, t)!,
      scopeCh4: Color.lerp(scopeCh4, other.scopeCh4, t)!,
      dangerRed: Color.lerp(dangerRed, other.dangerRed, t)!,
    );
  }
}

class AppTheme {
  static ThemeData darkAmber() {
    const colors = CircuitColors.darkAmber;
    return ThemeData(
      brightness: Brightness.dark,
      useMaterial3: true,
      scaffoldBackgroundColor: colors.canvasBackground,
      colorScheme: const ColorScheme.dark(
        primary: Color(0xFFFFB300),
        secondary: Color(0xFFFF8F00),
        surface: Color(0xFF1C1814),
        error: Color(0xFFEF5350),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFF1C1814),
        foregroundColor: Color(0xFFF5E6D3),
        elevation: 0,
      ),
      extensions: const [colors],
    );
  }

  static ThemeData lightBench() {
    const colors = CircuitColors.lightBench;
    return ThemeData(
      brightness: Brightness.light,
      useMaterial3: true,
      scaffoldBackgroundColor: colors.canvasBackground,
      colorScheme: const ColorScheme.light(
        primary: Color(0xFFD97706),
        secondary: Color(0xFFB45309),
        surface: Color(0xFFECE6DA),
        error: Color(0xFFC62828),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFFECE6DA),
        foregroundColor: Color(0xFF231F1A),
        elevation: 0,
      ),
      extensions: const [colors],
    );
  }
}
