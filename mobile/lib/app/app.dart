import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../features/settings/providers/theme_provider.dart';
import 'router.dart';
import 'theme/app_theme.dart';

class TelomyApp extends ConsumerWidget {
  const TelomyApp({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp.router(
    title: 'Telomy',
    debugShowCheckedModeBanner: false,
    theme: AppTheme.build(Brightness.light),
    darkTheme: AppTheme.build(Brightness.dark),
    themeMode: ref.watch(themeProvider),
    routerConfig: ref.watch(routerProvider),
  );
}
