package dev.jormungand.app

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/**
 * «Ignore site» on an event notification and its «Undo» (docs/platforms.md, "Системные уведомления").
 * No activity starts: the receiver
 *  1. records the choice in [IgnoreQueue] (SharedPreferences), so nothing is lost when no Dart runs;
 *  2. swaps the notification ([AppNotifier.ignoredEvent]) or removes it (Undo);
 *  3. tells Dart, when the engine is there, to read the queue (`ignoreQueued` on the notify channel).
 * Dart applies the queue to the ignored sites list on start and on every such ping
 * (`NotifyIo.takeIgnoreOps`).
 */
class EventActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val app = context.applicationContext
        val site = intent.getStringExtra(AppNotifier.EXTRA_SITE) ?: ""
        val id = intent.getIntExtra(AppNotifier.EXTRA_EVENT, -1)
        if (site.isEmpty() || id < 0) return
        when (intent.action) {
            AppNotifier.ACTION_SITE_IGNORE -> {
                IgnoreQueue.push(app, ignore = true, site = site)
                AppNotifier.ignoredEvent(
                    app,
                    id,
                    site,
                    intent.getStringExtra(AppNotifier.EXTRA_IGNORED_TEXT) ?: site,
                    intent.getStringExtra(AppNotifier.EXTRA_UNDO_LABEL) ?: "",
                )
            }
            AppNotifier.ACTION_SITE_UNDO -> {
                IgnoreQueue.push(app, ignore = false, site = site)
                AppNotifier.cancelEvent(app, id) // Undo: the notification just goes away
            }
            else -> return
        }
        // a live engine hears of it now; a cold one finds the queue when its shell starts
        runCatching { NotifyChannel.dart?.invokeMethod("ignoreQueued", null) }
    }
}

/**
 * The choices made on the shade, in order, until Dart has applied them: one `+host` / `-host` per line
 * in SharedPreferences (the same file as [AppNotifier]'s switches). Main thread only in practice (the
 * receiver and the channel); synchronized anyway.
 */
object IgnoreQueue {
    private const val PREFS = "jorm_notify"
    private const val KEY = "ignoreQueue"

    private fun prefs(ctx: Context) = ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    @Synchronized
    fun push(ctx: Context, ignore: Boolean, site: String) {
        val host = site.replace('\n', ' ').trim()
        if (host.isEmpty()) return
        val p = prefs(ctx)
        val now = p.getString(KEY, "") ?: ""
        p.edit().putString(KEY, now + (if (ignore) "+" else "-") + host + "\n").commit()
    }

    /** What is queued, oldest first, as `{op: ignore | unignore, site}`; empties the queue. */
    @Synchronized
    fun take(ctx: Context): List<Map<String, String>> {
        val p = prefs(ctx)
        val raw = p.getString(KEY, "") ?: ""
        if (raw.isEmpty()) return emptyList()
        p.edit().remove(KEY).commit()
        return raw.split('\n').filter { it.length > 1 && (it[0] == '+' || it[0] == '-') }
            .map { mapOf("op" to if (it[0] == '+') "ignore" else "unignore", "site" to it.substring(1)) }
    }
}
