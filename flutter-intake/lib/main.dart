import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'pages/intake_page.dart';
import 'theme/app_theme.dart';

void main() {
  runApp(const ProviderScope(child: ZeroTouchApp()));
}

class ZeroTouchApp extends StatelessWidget {
  const ZeroTouchApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ZeroTouch — Identity Lifecycle',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.system,
      home: const IntakePage(),
    );
  }
}
