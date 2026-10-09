package com.example.lyrics_app

import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.media.MediaMetadata
import android.media.session.MediaController
import android.media.session.MediaSessionManager
import android.media.session.PlaybackState
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val MEDIA_CHANNEL = "lyriko/android_media_session"
        private const val OVERLAY_CHANNEL = "lyriko/native_overlay"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MEDIA_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isNotificationAccessEnabled" -> {
                        result.success(isNotificationAccessEnabled())
                    }

                    "openNotificationAccessSettings" -> {
                        openNotificationAccessSettings()
                        result.success(true)
                    }

                    "getSessions" -> {
                        try {
                            result.success(getActiveMediaSessions())
                        } catch (error: SecurityException) {
                            result.error(
                                "NOTIFICATION_ACCESS_REQUIRED",
                                "Notification access is required to read active media sessions.",
                                null,
                            )
                        } catch (error: Exception) {
                            result.error(
                                "MEDIA_SESSION_ERROR",
                                error.message ?: error.javaClass.simpleName,
                                null,
                            )
                        }
                    }

                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, OVERLAY_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isOverlayPermissionGranted" -> {
                        result.success(Settings.canDrawOverlays(this))
                    }

                    "requestOverlayPermission" -> {
                        openOverlayPermissionSettings()
                        result.success(null)
                    }

                    "showOverlay" -> {
                        if (!Settings.canDrawOverlays(this)) {
                            result.success(false)
                            return@setMethodCallHandler
                        }

                        val stateJson = call.argument<String>("stateJson") ?: "{}"
                        startOverlayService(
                            NativeLyricsOverlayService.ACTION_SHOW,
                            stateJson = stateJson,
                        )
                        result.success(true)
                    }

                    "updateOverlay" -> {
                        val stateJson = call.argument<String>("stateJson") ?: "{}"
                        startOverlayService(
                            NativeLyricsOverlayService.ACTION_UPDATE,
                            stateJson = stateJson,
                        )
                        result.success(null)
                    }

                    "setOverlayBackground" -> {
                        val percent = call.argument<Number>("percent")?.toDouble() ?: 20.0
                        startOverlayService(
                            NativeLyricsOverlayService.ACTION_BACKGROUND,
                            backgroundPercent = percent,
                        )
                        result.success(null)
                    }

                    "closeOverlay" -> {
                        val intent = Intent(this, NativeLyricsOverlayService::class.java).apply {
                            action = NativeLyricsOverlayService.ACTION_CLOSE
                        }
                        startService(intent)
                        result.success(null)
                    }

                    else -> result.notImplemented()
                }
            }
    }

    private fun startOverlayService(
        action: String,
        stateJson: String? = null,
        backgroundPercent: Double? = null,
    ) {
        val intent = Intent(this, NativeLyricsOverlayService::class.java).apply {
            this.action = action
            stateJson?.let {
                putExtra(NativeLyricsOverlayService.EXTRA_STATE_JSON, it)
            }
            backgroundPercent?.let {
                putExtra(NativeLyricsOverlayService.EXTRA_BACKGROUND_PERCENT, it)
            }
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            action == NativeLyricsOverlayService.ACTION_SHOW
        ) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    private fun openOverlayPermissionSettings() {
        val intent = Intent(
            Settings.ACTION_MANAGE_OVERLAY_PERMISSION,
            Uri.parse("package:$packageName"),
        )
        startActivity(intent)
    }

    private fun notificationListenerComponent(): ComponentName {
        return ComponentName(this, LyrikoNotificationListener::class.java)
    }

    private fun isNotificationAccessEnabled(): Boolean {
        val notificationManager =
            getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        return notificationManager.isNotificationListenerAccessGranted(
            notificationListenerComponent(),
        )
    }

    private fun openNotificationAccessSettings() {
        val intent = Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS)
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        startActivity(intent)
    }

    private fun getActiveMediaSessions(): List<Map<String, Any?>> {
        if (!isNotificationAccessEnabled()) {
            throw SecurityException("Notification listener access is not enabled.")
        }

        val mediaSessionManager =
            getSystemService(Context.MEDIA_SESSION_SERVICE) as MediaSessionManager

        val controllers = mediaSessionManager.getActiveSessions(
            notificationListenerComponent(),
        )

        return controllers.map { controller -> sessionToMap(controller) }
    }

    private fun sessionToMap(controller: MediaController): Map<String, Any?> {
        val metadata = controller.metadata
        val state = controller.playbackState

        val rawPositionMs = state?.position ?: 0L
        val lastUpdateElapsedMs = state?.lastPositionUpdateTime ?: 0L
        val playbackSpeed = state?.playbackSpeed ?: 0.0f
        val stateCode = state?.state ?: PlaybackState.STATE_NONE

        val nowElapsedMs = SystemClock.elapsedRealtime()
        val elapsedSinceUpdateMs = if (lastUpdateElapsedMs > 0L) {
            (nowElapsedMs - lastUpdateElapsedMs).coerceAtLeast(0L)
        } else {
            0L
        }

        val isAdvancing = when (stateCode) {
            PlaybackState.STATE_PLAYING,
            PlaybackState.STATE_FAST_FORWARDING,
            PlaybackState.STATE_REWINDING -> true
            else -> false
        }

        val estimatedPositionMs = if (isAdvancing && lastUpdateElapsedMs > 0L) {
            (rawPositionMs + elapsedSinceUpdateMs * playbackSpeed).toLong()
                .coerceAtLeast(0L)
        } else {
            rawPositionMs.coerceAtLeast(0L)
        }

        return linkedMapOf(
            "packageName" to controller.packageName,
            "title" to metadata?.getString(MediaMetadata.METADATA_KEY_TITLE),
            "artist" to metadata?.getString(MediaMetadata.METADATA_KEY_ARTIST),
            "albumArtist" to metadata?.getString(MediaMetadata.METADATA_KEY_ALBUM_ARTIST),
            "album" to metadata?.getString(MediaMetadata.METADATA_KEY_ALBUM),
            "durationMs" to metadata?.getLong(MediaMetadata.METADATA_KEY_DURATION),
            "state" to playbackStateName(stateCode),
            "stateCode" to stateCode,
            "rawPositionMs" to rawPositionMs,
            "estimatedPositionMs" to estimatedPositionMs,
            "lastPositionUpdateElapsedMs" to lastUpdateElapsedMs,
            "elapsedSinceUpdateMs" to elapsedSinceUpdateMs,
            "playbackSpeed" to playbackSpeed.toDouble(),
            "actions" to (state?.actions ?: 0L),
        )
    }

    private fun playbackStateName(state: Int): String {
        return when (state) {
            PlaybackState.STATE_NONE -> "NONE"
            PlaybackState.STATE_STOPPED -> "STOPPED"
            PlaybackState.STATE_PAUSED -> "PAUSED"
            PlaybackState.STATE_PLAYING -> "PLAYING"
            PlaybackState.STATE_FAST_FORWARDING -> "FAST_FORWARDING"
            PlaybackState.STATE_REWINDING -> "REWINDING"
            PlaybackState.STATE_BUFFERING -> "BUFFERING"
            PlaybackState.STATE_ERROR -> "ERROR"
            PlaybackState.STATE_CONNECTING -> "CONNECTING"
            PlaybackState.STATE_SKIPPING_TO_PREVIOUS -> "SKIPPING_TO_PREVIOUS"
            PlaybackState.STATE_SKIPPING_TO_NEXT -> "SKIPPING_TO_NEXT"
            PlaybackState.STATE_SKIPPING_TO_QUEUE_ITEM -> "SKIPPING_TO_QUEUE_ITEM"
            else -> "UNKNOWN($state)"
        }
    }
}
