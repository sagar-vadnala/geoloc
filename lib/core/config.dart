import 'package:flutter/foundation.dart';

/// Base URL of the mock API.
///
/// Override at build/run time, e.g. for a physical device on the same Wi-Fi:
/// `flutter run --dart-define=API_BASE_URL=http://192.168.1.20:3000`
///
/// Defaults: Android emulator reaches the host machine at 10.0.2.2, the iOS
/// simulator shares the host's localhost.
String get apiBaseUrl {
  const fromEnv = String.fromEnvironment('API_BASE_URL');
  if (fromEnv.isNotEmpty) return fromEnv;
  return defaultTargetPlatform == TargetPlatform.android
      ? 'http://10.0.2.2:3000'
      : 'http://localhost:3000';
}
