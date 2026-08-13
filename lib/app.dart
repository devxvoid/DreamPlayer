import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'screens/player_screen.dart';
import 'screens/settings_screen.dart';
import 'services/open_intent.dart';
import 'theme/app_theme.dart';

/// Used by the "Open with" intent handler to navigate without a BuildContext.
final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

/// Route observer so screens (e.g. Home) can refresh when a pushed route above
/// them pops back (file browser → Home, player → Home, "Open with" → Home).
final RouteObserver<ModalRoute<void>> appRouteObserver =
    RouteObserver<ModalRoute<void>>();

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
      navigatorObservers: [appRouteObserver],
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

  /// Bumped whenever the Library tab is (re)selected so the Home screen can
  /// reload its "Continue watching" list even though IndexedStack keeps it
  /// alive (playing from the file browser/WebDAV never pushes through Home).
  final ValueNotifier<int> _homeRefreshTick = ValueNotifier(0);

  @override
  void dispose() {
    _homeRefreshTick.dispose();
    super.dispose();
  }

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
          children: [
            HomeScreen(refreshTick: _homeRefreshTick),
            const SettingsScreen(),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (index) {
          setState(() {
            _selectedIndex = index;
          });
          if (index == 0) _homeRefreshTick.value++;
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