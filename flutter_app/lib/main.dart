import 'package:flutter/material.dart';
import 'pages/server_setup_page.dart';
import 'services/audio_service.dart';
import 'services/local_library.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Initialize storage + the background audio service here (the canonical
  // audio_service pattern) rather than inside a navigated widget.
  try {
    await LocalLibrary.ensureInitialized();
    await AudioManager.init();
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
      title: 'YouTube Audio',
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
