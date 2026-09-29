import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

class ThemeController extends Notifier<ThemeMode> {
  @override
  ThemeMode build() => ThemeMode.system;
  void setMode(ThemeMode value) => state = value;
}

final themeProvider = NotifierProvider<ThemeController, ThemeMode>(
  ThemeController.new,
);
