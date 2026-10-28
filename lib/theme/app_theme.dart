import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

/// 页面与控件共用 Miuix token；媒体取景、二维码和课件画布有各自的背景。
MiuixThemeData appMiuixTheme(Brightness brightness) {
  final theme = MiuixThemeData.of(brightness);
  return theme.copyWith(
    // 分组页面用 surface 作底，卡片保留 surfaceContainer，形成稳定层级。
    colors: theme.colors.copy(
      background: theme.colors.surface,
      onSecondaryContainer: theme.colors.onSurfaceVariantSummary,
    ),
  );
}

/// 保留 Material 控件的输入、焦点、返回值和无障碍语义，统一其视觉外观。
ThemeData appMaterialTheme({
  required Brightness brightness,
  required PageTransitionsTheme pageTransitions,
}) {
  final miuix = appMiuixTheme(brightness);
  final c = miuix.colors;
  final t = miuix.textStyles;
  const controlShape = MiuixSquircleBorder(cornerRadius: 16);
  const buttonShape = _MiuixControlBorder();
  const dialogShape = MiuixSquircleBorder(cornerRadius: 32);
  final inputShape = OutlineInputBorder(
    borderRadius: BorderRadius.circular(16),
    borderSide: BorderSide.none,
  );
  TextStyle typography(TextStyle style) =>
      style.copyWith(color: c.onBackground, letterSpacing: 0);
  final text = ThemeData(brightness: brightness).textTheme.merge(
    TextTheme(
      displayLarge: typography(t.title1),
      displayMedium: typography(t.title1),
      displaySmall: typography(t.title2),
      headlineLarge: typography(t.title1),
      headlineMedium: typography(t.title2),
      headlineSmall: typography(t.title3),
      titleLarge: typography(t.title4),
      titleMedium: typography(t.headline1),
      titleSmall: typography(t.subtitle),
      bodyLarge: typography(t.main),
      bodyMedium: typography(t.main),
      bodySmall: typography(t.body2),
      labelLarge: typography(t.button),
      labelMedium: typography(t.footnote1),
      labelSmall: typography(t.footnote2),
    ),
  );
  final scheme = ColorScheme(
    brightness: brightness,
    primary: c.primary,
    onPrimary: c.onPrimary,
    primaryContainer: c.tertiaryContainer,
    onPrimaryContainer: c.onTertiaryContainer,
    secondary: c.primary,
    onSecondary: c.onPrimary,
    secondaryContainer: c.secondaryVariant,
    onSecondaryContainer: c.onSecondaryVariant,
    tertiary: c.primaryVariant,
    onTertiary: c.onPrimary,
    error: c.error,
    onError: c.onError,
    errorContainer: c.errorContainer,
    onErrorContainer: c.onErrorContainer,
    surface: c.surfaceContainer,
    onSurface: c.onSurfaceContainer,
    onSurfaceVariant: c.onSurfaceVariantSummary,
    surfaceContainerLowest: c.background,
    surfaceContainerLow: c.surfaceContainer,
    surfaceContainer: c.surfaceContainer,
    surfaceContainerHigh: c.secondaryVariant,
    surfaceContainerHighest: c.surfaceContainerHighest,
    outline: c.outline,
    outlineVariant: c.dividerLine,
    shadow: Colors.black,
    scrim: Colors.black,
    surfaceTint: Colors.transparent,
  );
  final filled = FilledButton.styleFrom(
    backgroundColor: c.primary,
    foregroundColor: c.onPrimary,
    disabledBackgroundColor: c.disabledPrimaryButton,
    disabledForegroundColor: c.disabledOnPrimaryButton,
    minimumSize: const Size(48, 48),
    padding: MiuixButtonDefaults.insideMargin,
    textStyle: text.labelLarge,
    shape: buttonShape,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: c.background,
    canvasColor: c.background,
    disabledColor: c.disabledOnSurface,
    dividerColor: c.dividerLine,
    textTheme: text,
    primaryTextTheme: text.apply(
      bodyColor: c.onPrimary,
      displayColor: c.onPrimary,
    ),
    iconTheme: IconThemeData(color: c.onSurfaceContainer, size: 24),
    pageTransitionsTheme: pageTransitions,
    cardTheme: CardThemeData(
      margin: EdgeInsets.zero,
      color: c.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: controlShape,
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: c.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: dialogShape,
      titleTextStyle: text.titleLarge!.copyWith(
        color: c.onSurfaceContainer,
        fontWeight: FontWeight.w600,
      ),
      contentTextStyle: text.bodyMedium!.copyWith(color: c.onSurfaceContainer),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
    ),
    filledButtonTheme: FilledButtonThemeData(style: filled),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: filled.copyWith(
        elevation: const WidgetStatePropertyAll(0),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: c.primary,
        disabledForegroundColor: c.disabledOnSurface,
        side: BorderSide(color: c.outline),
        minimumSize: const Size(48, 48),
        padding: MiuixButtonDefaults.insideMargin,
        textStyle: text.labelLarge,
        shape: buttonShape,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: c.primary,
        disabledForegroundColor: c.disabledOnSurface,
        minimumSize: const Size(48, 48),
        textStyle: text.labelLarge,
        shape: buttonShape,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.secondaryVariant,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      hintStyle: text.bodyMedium!.copyWith(color: c.onSurfaceVariantSummary),
      labelStyle: text.bodyMedium!.copyWith(color: c.onSurfaceVariantSummary),
      errorStyle: text.labelMedium!.copyWith(color: c.error),
      border: inputShape,
      enabledBorder: inputShape,
      disabledBorder: inputShape,
      focusedBorder: inputShape.copyWith(
        borderSide: BorderSide(
          color: c.primary,
          width: MiuixTextFieldDefaults.borderWidth,
        ),
      ),
      errorBorder: inputShape.copyWith(borderSide: BorderSide(color: c.error)),
      focusedErrorBorder: inputShape.copyWith(
        borderSide: BorderSide(
          color: c.error,
          width: MiuixTextFieldDefaults.borderWidth,
        ),
      ),
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      textColor: c.onSurface,
      iconColor: c.onSurfaceVariantSummary,
      titleTextStyle: text.bodyLarge!.copyWith(color: c.onSurfaceContainer),
      subtitleTextStyle: text.bodySmall!.copyWith(
        color: c.onSurfaceVariantSummary,
      ),
    ),
    expansionTileTheme: ExpansionTileThemeData(
      iconColor: c.primary,
      collapsedIconColor: c.onSurfaceVariantSummary,
      textColor: c.onSurface,
      collapsedTextColor: c.onSurface,
      shape: const Border(),
      collapsedShape: const Border(),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: c.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(32)),
      ),
      clipBehavior: Clip.antiAlias,
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.surfaceContainer,
      surfaceTintColor: Colors.transparent,
      shape: controlShape,
      textStyle: text.bodyMedium!.copyWith(color: c.onSurfaceContainer),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: c.onSurfaceContainer,
      contentTextStyle: text.bodySmall!.copyWith(color: c.surfaceContainer),
      shape: controlShape,
      elevation: 0,
    ),
    checkboxTheme: CheckboxThemeData(
      shape: const CircleBorder(),
      side: BorderSide.none,
      checkColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.disabled)
            ? c.disabledOnPrimary
            : c.onPrimary,
      ),
      fillColor: WidgetStateProperty.resolveWith((states) {
        final selected = states.contains(WidgetState.selected);
        if (states.contains(WidgetState.disabled)) {
          return selected ? c.disabledPrimary : c.disabledSecondary;
        }
        return selected ? c.primary : c.secondary;
      }),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: c.primary),
    dividerTheme: DividerThemeData(color: c.dividerLine, thickness: 0.5),
  );
}

/// flutter_miuix 的 Squircle 是 ShapeBorder，ButtonStyle 需要 OutlinedBorder。
/// 复用库的实际路径与绘制，不再维护另一套按钮圆角公式。
class _MiuixControlBorder extends OutlinedBorder {
  const _MiuixControlBorder({super.side, this.radius = 16});

  final double radius;
  MiuixSquircleBorder get _shape =>
      MiuixSquircleBorder(cornerRadius: radius, side: side);

  @override
  EdgeInsetsGeometry get dimensions => _shape.dimensions;
  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      _shape.getOuterPath(rect, textDirection: textDirection);
  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      MiuixSquircleBorder(
        cornerRadius: (radius - side.width).clamp(0, radius),
      ).getOuterPath(rect.deflate(side.width), textDirection: textDirection);
  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) =>
      _shape.paint(canvas, rect, textDirection: textDirection);
  @override
  _MiuixControlBorder copyWith({BorderSide? side}) =>
      _MiuixControlBorder(side: side ?? this.side, radius: radius);
  @override
  ShapeBorder scale(double t) =>
      _MiuixControlBorder(side: side.scale(t), radius: radius * t);
}
