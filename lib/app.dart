import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'screens/player_screen.dart';
import 'screens/settings_screen.dart';
import 'services/open_intent.dart';
import 'theme/app_theme.dart';

/// Used by the "Open with" intent handler to navigate without a BuildContext.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

class DreamPlayerApp extends StatefulWidget {
  const DreamPlayerApp({super.key});

  @override
  State<DreamPlayerApp> createState() => _DreamPlayerAppState();
}

class _DreamPlayerAppState extends State<DreamPlayerApp> {
  @override
  void initState() {
    super.initState();
    _listenForIntents();
  }

  Future<void> _listenForIntents() async {
    final service = OpenIntentService.instance;
    service.intents.listen((intent) {
      final navigator = appNavigatorKey.currentState;
      if (navigator == null) return;
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => PlayerScreen(video: intent.toVideoItem()),
        ),
      );
    });
    // Fetches the intent that launched the app (if any).
    await service.init();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'DreamPlayer',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark(),
      navigatorKey: appNavigatorKey,
      builder: (context, child) {
        final mediaQuery = MediaQuery.of(context);
        final clampedTextScaler = mediaQuery.textScaler.clamp(
          minScaleFactor: 1.0,
          maxScaleFactor: 1.3,
        );
        return MediaQuery(
          data: mediaQuery.copyWith(textScaler: clampedTextScaler),
          child: child!,
        );
      },
      home: const RootShell(),
    );
  }
}

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _selectedIndex = 0;

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    // Android edge-to-edge reports `padding.top == 0` (transparent status
    // bar), so SliverAppBar/AppBar won't push content below the status bar.
    // Map the real status-bar inset (`viewPadding`) into `padding` for the
    // library/settings tabs so they never clash with the status bar.
    final padded = mediaQuery.copyWith(
      padding: mediaQuery.padding.copyWith(
        top: mediaQuery.viewPadding.top,
      ),
    );
    return Scaffold(
      body: MediaQuery(
        data: padded,
        child: IndexedStack(
          index: _selectedIndex,
          children: const [
            HomeScreen(),
            SettingsScreen(),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          setState(() {
            _selectedIndex = index;
          });
        },
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.video_library_outlined),
            selectedIcon: Icon(Icons.video_library),
            label: 'Library',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}