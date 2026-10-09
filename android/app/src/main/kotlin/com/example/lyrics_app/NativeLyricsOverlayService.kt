package com.example.lyrics_app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.IBinder
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.provider.Settings
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.WindowManager
import android.widget.FrameLayout
import android.widget.ImageButton
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.SeekBar
import android.widget.TextView
import org.json.JSONArray
import org.json.JSONObject
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

class NativeLyricsOverlayService : Service() {
    companion object {
        const val ACTION_SHOW = "com.example.lyrics_app.overlay.SHOW"
        const val ACTION_UPDATE = "com.example.lyrics_app.overlay.UPDATE"
        const val ACTION_BACKGROUND = "com.example.lyrics_app.overlay.BACKGROUND"
        const val ACTION_CLOSE = "com.example.lyrics_app.overlay.CLOSE"

        const val EXTRA_STATE_JSON = "state_json"
        const val EXTRA_BACKGROUND_PERCENT = "background_percent"

        private const val NOTIFICATION_CHANNEL_ID = "lyriko_overlay"
        private const val NOTIFICATION_ID = 4107
    }

    private lateinit var windowManager: WindowManager
    private var rootView: FrameLayout? = null
    private var params: WindowManager.LayoutParams? = null

    private var titleView: TextView? = null
    private var artistView: TextView? = null
    private var timeView: TextView? = null
    private var trackingView: TextView? = null
    private var lyricsScrollView: ScrollView? = null
    private var lyricsContainer: LinearLayout? = null
    private var backgroundSeek: SeekBar? = null
    private var backgroundValueView: TextView? = null
    private var cardBackground: GradientDrawable? = null

    private val lineViews = mutableListOf<TextView>()
    private val lines = mutableListOf<LyricLine>()
    private var activeIndex = -1
    private var lastLyricsSignature = ""
    private var backgroundPercent = 20.0

    private val tickerHandler = Handler(Looper.getMainLooper())
    private var anchorPositionMs = 0L
    private var anchorElapsedRealtimeMs = 0L
    private var playing = false
    private val ticker = object : Runnable {
        override fun run() {
            if (playing && rootView != null) {
                val elapsed = (SystemClock.elapsedRealtime() - anchorElapsedRealtimeMs)
                    .coerceAtLeast(0L)
                val position = anchorPositionMs + elapsed
                timeView?.text = formatTime(position)
                updateActiveLine(position)
            }
            tickerHandler.postDelayed(this, 100L)
        }
    }

    private var screenWidthPx = 0
    private var screenHeightPx = 0
    private var safeTopPx = 0
    private var safeBottomPx = 0

    private val minWidthPx by lazy { dp(260) }
    private val minHeightPx by lazy { dp(240) }
    private val snapDistancePx by lazy { dp(36) }

    override fun onCreate() {
        super.onCreate()
        windowManager = getSystemService(Context.WINDOW_SERVICE) as WindowManager
        refreshScreenBounds()
        createNotificationChannel()
        startForeground(NOTIFICATION_ID, buildNotification())
        tickerHandler.post(ticker)
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_SHOW -> {
                if (!Settings.canDrawOverlays(this)) {
                    stopSelf()
                    return START_NOT_STICKY
                }
                ensureOverlay()
                intent.getStringExtra(EXTRA_STATE_JSON)?.let(::applyStateJson)
            }

            ACTION_UPDATE -> {
                if (rootView == null && Settings.canDrawOverlays(this)) {
                    ensureOverlay()
                }
                intent.getStringExtra(EXTRA_STATE_JSON)?.let(::applyStateJson)
            }

            ACTION_BACKGROUND -> {
                val value = intent.getDoubleExtra(EXTRA_BACKGROUND_PERCENT, backgroundPercent)
                setBackgroundPercent(value, updateSeekBar = true)
            }

            ACTION_CLOSE -> {
                removeOverlay()
                stopSelf()
                return START_NOT_STICKY
            }
        }

        return START_STICKY
    }

    override fun onDestroy() {
        tickerHandler.removeCallbacks(ticker)
        removeOverlay()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun ensureOverlay() {
        if (rootView != null) return

        refreshScreenBounds()

        val initialWidth = min(dp(370), screenWidthPx - dp(24))
        val initialHeight = min(dp(430), screenHeightPx - safeTopPx - safeBottomPx - dp(24))

        val layoutParams = WindowManager.LayoutParams(
            max(minWidthPx, initialWidth),
            max(minHeightPx, initialHeight),
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                WindowManager.LayoutParams.TYPE_APPLICATION_OVERLAY
            } else {
                @Suppress("DEPRECATION")
                WindowManager.LayoutParams.TYPE_PHONE
            },
            WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE or
                WindowManager.LayoutParams.FLAG_LAYOUT_IN_SCREEN,
            PixelFormat.TRANSLUCENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            x = max(0, (screenWidthPx - width) / 2)
            y = max(safeTopPx, safeTopPx + dp(48))
        }

        params = layoutParams
        rootView = buildOverlayView()
        windowManager.addView(rootView, layoutParams)
    }

    private fun buildOverlayView(): FrameLayout {
        val root = FrameLayout(this).apply {
            setPadding(dp(6), dp(6), dp(6), dp(6))
        }

        cardBackground = GradientDrawable().apply {
            cornerRadius = dp(18).toFloat()
            setStroke(dp(1), Color.argb(36, 255, 255, 255))
        }
        updateCardBackground()

        val card = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            background = cardBackground
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            )
        }

        val header = buildHeader()
        card.addView(header)

        val scroll = ScrollView(this).apply {
            isFillViewport = true
            clipToPadding = false
            setPadding(dp(14), dp(6), dp(14), dp(6))
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                0,
                1f,
            )
        }

        lyricsContainer = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            setPadding(0, dp(8), 0, dp(18))
        }
        scroll.addView(
            lyricsContainer,
            FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.WRAP_CONTENT,
            ),
        )
        lyricsScrollView = scroll
        card.addView(scroll)

        card.addView(buildBottomControls())

        root.addView(card)
        root.addView(buildResizeHandle())

        return root
    }

    private fun buildHeader(): View {
        val header = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(10), dp(8), dp(6), dp(4))
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            )
        }

        val dragIndicator = TextView(this).apply {
            text = "⋮⋮"
            textSize = 18f
            setTextColor(Color.argb(140, 255, 255, 255))
            gravity = Gravity.CENTER
            setPadding(0, 0, dp(8), 0)
        }
        header.addView(dragIndicator)

        val textColumn = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f)
        }

        titleView = TextView(this).apply {
            text = "Lyriko"
            textSize = 15f
            setTextColor(Color.WHITE)
            setTypeface(typeface, Typeface.BOLD)
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
        }
        artistView = TextView(this).apply {
            text = ""
            textSize = 11f
            setTextColor(Color.argb(165, 255, 255, 255))
            maxLines = 1
            ellipsize = android.text.TextUtils.TruncateAt.END
        }
        textColumn.addView(titleView)
        textColumn.addView(artistView)
        header.addView(textColumn)

        timeView = TextView(this).apply {
            text = "0:00"
            textSize = 12f
            setTextColor(Color.argb(190, 255, 255, 255))
            setPadding(dp(8), 0, dp(8), 0)
        }
        header.addView(timeView)

        trackingView = TextView(this).apply {
            text = "MEDIA"
            textSize = 9f
            setTextColor(Color.rgb(105, 240, 174))
            setTypeface(typeface, Typeface.BOLD)
            setPadding(dp(7), dp(3), dp(7), dp(3))
            background = roundedSolid(Color.argb(28, 255, 255, 255), 99)
        }
        header.addView(trackingView)

        val close = ImageButton(this).apply {
            setImageResource(android.R.drawable.ic_menu_close_clear_cancel)
            setColorFilter(Color.argb(190, 255, 255, 255))
            setBackgroundColor(Color.TRANSPARENT)
            contentDescription = "Close overlay"
            setPadding(dp(8), dp(8), dp(8), dp(8))
            setOnClickListener {
                removeOverlay()
                stopSelf()
            }
        }
        header.addView(close, LinearLayout.LayoutParams(dp(42), dp(42)))

        attachDragBehavior(header)
        return header
    }

    private fun buildBottomControls(): View {
        val row = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER_VERTICAL
            setPadding(dp(12), 0, dp(34), dp(8))
        }

        val label = TextView(this).apply {
            text = "BACKGROUND"
            textSize = 10f
            setTextColor(Color.argb(155, 255, 255, 255))
            setTypeface(typeface, Typeface.BOLD)
        }
        row.addView(label)

        val seek = SeekBar(this).apply {
            max = 100
            progress = backgroundPercent.toInt()
            layoutParams = LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f).apply {
                marginStart = dp(8)
            }
            setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(seekBar: SeekBar?, progress: Int, fromUser: Boolean) {
                    if (fromUser) {
                        setBackgroundPercent(progress.toDouble(), updateSeekBar = false)
                    }
                }

                override fun onStartTrackingTouch(seekBar: SeekBar?) = Unit
                override fun onStopTrackingTouch(seekBar: SeekBar?) = Unit
            })
        }
        backgroundSeek = seek
        row.addView(seek)

        backgroundValueView = TextView(this).apply {
            text = "${backgroundPercent.toInt()}%"
            textSize = 11f
            gravity = Gravity.END
            setTextColor(Color.argb(190, 255, 255, 255))
            setTypeface(typeface, Typeface.BOLD)
            setPadding(dp(8), 0, 0, 0)
        }
        row.addView(backgroundValueView, LinearLayout.LayoutParams(dp(48), LinearLayout.LayoutParams.WRAP_CONTENT))

        return row
    }

    private fun buildResizeHandle(): View {
        val handle = TextView(this).apply {
            text = "↘"
            textSize = 18f
            gravity = Gravity.CENTER
            setTextColor(Color.argb(150, 255, 255, 255))
            contentDescription = "Resize overlay"
            background = roundedSolid(Color.argb(18, 255, 255, 255), 10)
        }

        val lp = FrameLayout.LayoutParams(dp(36), dp(36), Gravity.END or Gravity.BOTTOM).apply {
            rightMargin = dp(6)
            bottomMargin = dp(6)
        }
        handle.layoutParams = lp
        attachResizeBehavior(handle)
        return handle
    }

    private fun attachDragBehavior(view: View) {
        var downRawX = 0f
        var downRawY = 0f
        var startX = 0
        var startY = 0

        view.setOnTouchListener { _, event ->
            val p = params ?: return@setOnTouchListener false
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downRawX = event.rawX
                    downRawY = event.rawY
                    startX = p.x
                    startY = p.y
                    true
                }

                MotionEvent.ACTION_MOVE -> {
                    val candidateX = startX + (event.rawX - downRawX).toInt()
                    val candidateY = startY + (event.rawY - downRawY).toInt()
                    val bounded = clampPosition(candidateX, candidateY, p.width, p.height)
                    p.x = bounded.first
                    p.y = bounded.second
                    updateLayoutSafely()
                    true
                }

                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    snapToEdgeIfClose()
                    true
                }

                else -> false
            }
        }
    }

    private fun attachResizeBehavior(view: View) {
        var downRawX = 0f
        var downRawY = 0f
        var startWidth = 0
        var startHeight = 0

        view.setOnTouchListener { _, event ->
            val p = params ?: return@setOnTouchListener false
            when (event.actionMasked) {
                MotionEvent.ACTION_DOWN -> {
                    downRawX = event.rawX
                    downRawY = event.rawY
                    startWidth = p.width
                    startHeight = p.height
                    true
                }

                MotionEvent.ACTION_MOVE -> {
                    refreshScreenBounds()

                    val requestedWidth = startWidth + (event.rawX - downRawX).toInt()
                    val requestedHeight = startHeight + (event.rawY - downRawY).toInt()

                    val maxWidth = max(minWidthPx, screenWidthPx - p.x)
                    val maxHeight = max(
                        minHeightPx,
                        screenHeightPx - safeBottomPx - p.y,
                    )

                    p.width = requestedWidth.coerceIn(minWidthPx, maxWidth)
                    p.height = requestedHeight.coerceIn(minHeightPx, maxHeight)
                    updateLayoutSafely()
                    true
                }

                MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                    val bounded = clampPosition(p.x, p.y, p.width, p.height)
                    p.x = bounded.first
                    p.y = bounded.second
                    updateLayoutSafely()
                    true
                }

                else -> false
            }
        }
    }

    private fun applyStateJson(raw: String) {
        val root = try {
            JSONObject(raw)
        } catch (_: Exception) {
            return
        }

        val title = root.optString("title", "Lyriko")
        val artist = root.optString("artist", "")
        val tracking = root.optString("tracking", "MEDIA")
        val positionMs = root.optLong("positionMs", 0L).coerceAtLeast(0L)
        val isPlaying = root.optBoolean("playing", false)
        val rawLines = root.optJSONArray("lines") ?: JSONArray()

        anchorPositionMs = positionMs
        anchorElapsedRealtimeMs = SystemClock.elapsedRealtime()
        playing = isPlaying

        titleView?.text = title
        artistView?.text = artist
        artistView?.visibility = if (artist.isBlank()) View.GONE else View.VISIBLE
        timeView?.text = formatTime(positionMs)
        trackingView?.text = tracking

        val signature = buildLyricsSignature(title, artist, rawLines)
        if (signature != lastLyricsSignature) {
            lastLyricsSignature = signature
            replaceLyrics(rawLines)
        }

        updateActiveLine(positionMs)
    }

    private fun replaceLyrics(array: JSONArray) {
        lines.clear()
        lineViews.clear()
        lyricsContainer?.removeAllViews()
        activeIndex = -1

        for (i in 0 until array.length()) {
            val obj = array.optJSONObject(i) ?: continue
            val line = LyricLine(
                text = obj.optString("text", ""),
                startMs = obj.optLong("startMs", 0L),
                endMs = obj.optLong("endMs", obj.optLong("startMs", 0L)),
            )
            lines.add(line)

            val view = TextView(this).apply {
                text = line.text
                textSize = 17f
                gravity = Gravity.CENTER
                setTextColor(Color.WHITE)
                alpha = 0.22f
                setPadding(dp(4), dp(7), dp(4), dp(7))
            }
            lineViews.add(view)
            lyricsContainer?.addView(
                view,
                LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    LinearLayout.LayoutParams.WRAP_CONTENT,
                ),
            )
        }

        if (lines.isEmpty()) {
            val empty = TextView(this).apply {
                text = "Waiting for lyrics…"
                textSize = 16f
                gravity = Gravity.CENTER
                setTextColor(Color.argb(150, 255, 255, 255))
                setPadding(dp(8), dp(28), dp(8), dp(28))
            }
            lyricsContainer?.addView(empty)
        }
    }

    private fun updateActiveLine(positionMs: Long) {
        if (lines.isEmpty()) return

        var nextIndex = 0
        for (i in lines.indices) {
            val line = lines[i]
            if (positionMs >= line.startMs && positionMs < line.endMs) {
                nextIndex = i
                break
            }
            if (positionMs >= line.startMs) {
                nextIndex = i
            }
        }

        if (nextIndex == activeIndex) return

        val previous = activeIndex
        activeIndex = nextIndex

        if (previous in lineViews.indices) {
            styleLine(previous, isActive = false)
        }
        if (nextIndex in lineViews.indices) {
            styleLine(nextIndex, isActive = true)
            scrollActiveIntoCenter(nextIndex)
        }

        if (nextIndex - 1 in lineViews.indices) {
            lineViews[nextIndex - 1].alpha = 0.50f
        }
        if (nextIndex + 1 in lineViews.indices) {
            lineViews[nextIndex + 1].alpha = 0.50f
        }
    }

    private fun styleLine(index: Int, isActive: Boolean) {
        val view = lineViews.getOrNull(index) ?: return
        view.textSize = if (isActive) 23f else 17f
        view.alpha = if (isActive) 1f else 0.22f
        view.setTypeface(view.typeface, if (isActive) Typeface.BOLD else Typeface.NORMAL)
    }

    private fun scrollActiveIntoCenter(index: Int) {
        val target = lineViews.getOrNull(index) ?: return
        val scroll = lyricsScrollView ?: return

        scroll.post {
            val desired = target.top - (scroll.height - target.height) / 2
            scroll.smoothScrollTo(0, max(0, desired))
        }
    }

    private fun setBackgroundPercent(value: Double, updateSeekBar: Boolean) {
        backgroundPercent = value.coerceIn(0.0, 100.0)
        updateCardBackground()
        backgroundValueView?.text = "${backgroundPercent.toInt()}%"
        if (updateSeekBar) {
            backgroundSeek?.progress = backgroundPercent.toInt()
        }
    }

    private fun updateCardBackground() {
        val alpha = ((backgroundPercent / 100.0) * 255.0).toInt().coerceIn(0, 255)
        cardBackground?.setColor(Color.argb(alpha, 0, 0, 0))
    }

    private fun clampPosition(x: Int, y: Int, width: Int, height: Int): Pair<Int, Int> {
        refreshScreenBounds()
        val maxX = max(0, screenWidthPx - width)
        val minY = safeTopPx
        val maxY = max(minY, screenHeightPx - safeBottomPx - height)
        return Pair(x.coerceIn(0, maxX), y.coerceIn(minY, maxY))
    }

    private fun snapToEdgeIfClose() {
        val p = params ?: return
        refreshScreenBounds()

        val maxX = max(0, screenWidthPx - p.width)
        val minY = safeTopPx
        val maxY = max(minY, screenHeightPx - safeBottomPx - p.height)

        var x = p.x.coerceIn(0, maxX)
        var y = p.y.coerceIn(minY, maxY)

        if (abs(x) <= snapDistancePx) {
            x = 0
        } else if (abs(maxX - x) <= snapDistancePx) {
            x = maxX
        }

        if (abs(y - minY) <= snapDistancePx) {
            y = minY
        } else if (abs(maxY - y) <= snapDistancePx) {
            y = maxY
        }

        p.x = x
        p.y = y
        updateLayoutSafely()
    }

    private fun refreshScreenBounds() {
        val metrics = resources.displayMetrics
        screenWidthPx = metrics.widthPixels
        screenHeightPx = metrics.heightPixels
        safeTopPx = systemDimension("status_bar_height")
        safeBottomPx = systemDimension("navigation_bar_height")
    }

    private fun systemDimension(name: String): Int {
        val id = resources.getIdentifier(name, "dimen", "android")
        return if (id > 0) resources.getDimensionPixelSize(id) else 0
    }

    private fun updateLayoutSafely() {
        val view = rootView ?: return
        val p = params ?: return
        try {
            windowManager.updateViewLayout(view, p)
        } catch (_: Exception) {
            // Ignore layout races while Android is removing the overlay.
        }
    }

    private fun removeOverlay() {
        val view = rootView ?: return
        try {
            windowManager.removeView(view)
        } catch (_: Exception) {
        } finally {
            rootView = null
            params = null
            lineViews.clear()
            lines.clear()
            activeIndex = -1
            lastLyricsSignature = ""
        }
    }

    private fun buildLyricsSignature(title: String, artist: String, array: JSONArray): String {
        val first = if (array.length() > 0) array.optJSONObject(0)?.optString("text", "") ?: "" else ""
        val last = if (array.length() > 0) array.optJSONObject(array.length() - 1)?.optString("text", "") ?: "" else ""
        return "$title|$artist|${array.length()}|$first|$last"
    }

    private fun formatTime(ms: Long): String {
        val totalSeconds = ms / 1000L
        val minutes = totalSeconds / 60L
        val seconds = totalSeconds % 60L
        return "%d:%02d".format(minutes, seconds)
    }

    private fun roundedSolid(color: Int, radiusDp: Int): GradientDrawable {
        return GradientDrawable().apply {
            setColor(color)
            cornerRadius = dp(radiusDp).toFloat()
        }
    }

    private fun dp(value: Int): Int {
        return (value * resources.displayMetrics.density).toInt()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channel = NotificationChannel(
            NOTIFICATION_CHANNEL_ID,
            "Lyriko floating lyrics",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Keeps synchronized lyrics visible over other apps."
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, NOTIFICATION_CHANNEL_ID)
                .setContentTitle("Lyriko")
                .setContentText("Floating synchronized lyrics are active")
                .setSmallIcon(android.R.drawable.ic_media_play)
                .setOngoing(true)
                .setContentIntent(pendingIntent)
                .build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setContentTitle("Lyriko")
                .setContentText("Floating synchronized lyrics are active")
                .setSmallIcon(android.R.drawable.ic_media_play)
                .setOngoing(true)
                .setContentIntent(pendingIntent)
                .build()
        }
    }

    private data class LyricLine(
        val text: String,
        val startMs: Long,
        val endMs: Long,
    )
}
