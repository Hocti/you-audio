import 'package:flutter/material.dart';
import 'pages/server_setup_page.dart';
import 'services/audio_service.dart';
import 'services/download_manager.dart';
import 'services/local_library.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Initialize storage + the background audio service here (the canonical
  // audio_service pattern) rather than inside a navigated widget.
  try {
    await LocalLibrary.ensureInitialized();
    // Failed downloads from the last run, so they stay visible and retryable
    // instead of disappearing when Android kills the process.
    await DownloadManager.instance.restoreFailed();
    await AudioManager.init();
    // Restore the last-played track (paused) so the app opens where it left off.
    await AudioManager.handler.restoreLastSession();
  } catch (e, st) {
    debugPrint('Audio init failed: $e\n$st');
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'You Audio',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorSchemeSeed: Colors.deepPurple,
      ),
      home: const ServerSetupPage(),
    );
  }
}
