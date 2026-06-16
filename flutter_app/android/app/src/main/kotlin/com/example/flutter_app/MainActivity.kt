package com.example.flutter_app

import android.content.Intent
import android.os.Bundle
import android.util.Log
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// audio_service requires the host Activity to extend AudioServiceActivity so the
// background service binds to the correct FlutterEngine. Using a plain
// FlutterActivity makes AudioService.init() throw a PlatformException.
//
// We also bridge OS "share" intents (ACTION_SEND text/plain) into Dart over a
// MethodChannel so a shared YouTube link can start a background download or open
// the channel page. See lib/services/share_handler.dart.
class MainActivity : AudioServiceActivity() {
    private val channelName = "app/share"
    private var methodChannel: MethodChannel? = null

    // Text shared at cold start, handed to Dart once via getInitialShare.
    private var initialShared: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        initialShared = extractSharedText(intent)
        Log.d("SHARE", "onCreate action=${intent?.action} type=${intent?.type} shared=$initialShared")
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger, channelName
        )
        methodChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialShare" -> {
                    Log.d("SHARE", "getInitialShare -> $initialShared")
                    result.success(initialShared)
                    initialShared = null
                }
                "moveToBackground" -> {
                    moveTaskToBack(true)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    // launchMode=singleTop means an in-flight share reuses this activity and
    // arrives here instead of through onCreate.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val text = extractSharedText(intent)
        Log.d("SHARE", "onNewIntent action=${intent.action} type=${intent.type} text=$text channel=${methodChannel != null}")
        if (text != null) {
            methodChannel?.invokeMethod("onShare", text)
        }
    }

    private fun extractSharedText(intent: Intent?): String? {
        if (intent == null) return null
        if (intent.action == Intent.ACTION_SEND && intent.type == "text/plain") {
            return intent.getStringExtra(Intent.EXTRA_TEXT)
        }
        return null
    }
}
