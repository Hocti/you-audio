package com.example.flutter_app

import com.ryanheise.audioservice.AudioServiceActivity

// audio_service requires the host Activity to extend AudioServiceActivity so the
// background service binds to the correct FlutterEngine. Using a plain
// FlutterActivity makes AudioService.init() throw a PlatformException.
class MainActivity: AudioServiceActivity()
