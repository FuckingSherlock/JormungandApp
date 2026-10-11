package dev.jormungand.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.graphics.drawable.Icon
import java.util.concurrent.atomic.AtomicInteger

/**
 * The app's system notifications (the VPN foreground one and the events); [NotifyChannel] is the
 * Dart-facing side, [JormungandVpnService] shows [vpnNotification].
 *
 *  - channel `vpn` (low): the ongoing "VPN is on" entry with the current entry / server and a
 *    Disconnect action; a tap opens the app.
 *  - channel `events` (default): the journal events Settings -> Notifications lets through, posted
 *    by Dart only while the app is not in the foreground. One notification per event (a tap opens
 *    Logs -> Events at it), all in one group with a summary, so a burst is a single entry on the
 *    shade; at most [MAX_CHILDREN] stay, the oldest are dropped. Only the summary makes a sound,
 *    and not more often than every [ALERT_GAP_MS]. A tap on a notification (or on the collapsed
 *    group: its newest event) opens Logs -> Events at the event. «Ignore site» works without the app
 *    ([EventActionReceiver]).
 */
object AppNotifier {
    const val VPN_CHANNEL = "vpn"
    const val EVENTS_CHANNEL = "events"
    const val ACTION_OPEN_EVENT = "dev.jormungand.app.notif.OPEN_EVENT"
    const val EXTRA_EVENT = "jorm_event_id"

    /** A button of an event notification (Create rule / Ignore site): opens the app and hands Dart the choice. */
    const val ACTION_EVENT_ACT = "dev.jormungand.app.notif.EVENT_ACT"
    const val EXTRA_ACT = "jorm_act"
    const val EXTRA_SITE = "jorm_site"
    const val EXTRA_VIA = "jorm_via"

    /**
     * «Ignore site» and its «Undo» do not open the app: broadcasts to [EventActionReceiver]. The texts
     * of the replaced notification come from Dart with the event (the app's language, not the system's).
     */
    const val ACTION_SITE_IGNORE = "dev.jormungand.app.notif.SITE_IGNORE"
    const val ACTION_SITE_UNDO = "dev.jormungand.app.notif.SITE_UNDO"
    const val EXTRA_IGNORED_TEXT = "jorm_ignored_text"
    const val EXTRA_UNDO_LABEL = "jorm_undo_label"
    private const val CONFIRM_MS = 10_000L

    /**
     * The app's own update ("Update available" / "Update ready · Install"): one slot, a newer text replaces
     * the older silently. A tap opens the app at Settings -> Data; with [EXTRA_INSTALL] it goes on to the
     * system install dialog. The Install button of a downloaded update (with its file) skips the app:
     * [UpdateInstallActivity]. Same channel as [ResumeNotifier]'s "Updated - tap to connect" (id 3).
     */
    const val UPDATE_CHANNEL = "update"
    const val ACTION_OPEN_UPDATE = "dev.jormungand.app.notif.OPEN_UPDATE"
    const val EXTRA_INSTALL = "jorm_install"
    const val ACTION_INSTALL_UPDATE = "dev.jormungand.app.notif.INSTALL_UPDATE"
    const val EXTRA_FILE = "jorm_file"
    private const val UPDATE_ID = 4
    private const val UPDATE_PREFS = "jorm_update"
    private const val UPDATE_ANNOUNCED = "announced"

    private const val GROUP = "jorm.events"
    private const val SUMMARY_ID = 2
    private const val EVENT_BASE = 1000
    private const val MAX_CHILDREN = 6
    private const val ALERT_GAP_MS = 15_000L

    /** The entry / server the tunnel goes through (Dart pushes it); null = nothing known (the plain text). */
    @Volatile
    var vpnNode: String? = null

    private const val PREFS = "jorm_notify" // the same file as NotifyChannel's "asked"
    private const val VPN_SHOWN = "vpnShown"

    private val burst = AtomicInteger(0)

    @Volatile
    private var lastAlert = 0L

    /**
     * Whether the VPN notification is to stay on the shade (Settings -> Notifications: the master and
     * Status switches). Dart pushes it on every change ([NotifyChannel] `setStatus`) and the choice is
     * kept here, so the service obeys it with no Dart running (a start after an update, the tile).
     * Default: shown. The service still enters the foreground with it (the 5 s rule) and then drops
     * it from the shade, see [JormungandVpnService].
     */
    fun vpnShown(ctx: Context): Boolean =
        ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getBoolean(VPN_SHOWN, true)

    fun setVpnShown(ctx: Context, shown: Boolean) {
        ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().putBoolean(VPN_SHOWN, shown).apply()
    }

    private fun manager(ctx: Context) = ctx.getSystemService(NotificationManager::class.java)

    /** Notifications of the app may be shown: the Android 13 permission and the system switch together. */
    fun allowed(ctx: Context): Boolean = manager(ctx).areNotificationsEnabled()

    private fun ensureChannels(ctx: Context) {
        val nm = manager(ctx)
        nm.createNotificationChannel(
            NotificationChannel(VPN_CHANNEL, ctx.getString(R.string.jorm_channel_vpn), NotificationManager.IMPORTANCE_LOW),
        )
        nm.createNotificationChannel(
            NotificationChannel(EVENTS_CHANNEL, ctx.getString(R.string.jorm_channel_events), NotificationManager.IMPORTANCE_DEFAULT).apply {
                description = ctx.getString(R.string.jorm_channel_events_desc)
            },
        )
        nm.createNotificationChannel(
            NotificationChannel(UPDATE_CHANNEL, ctx.getString(R.string.jorm_channel_update), NotificationManager.IMPORTANCE_DEFAULT),
        )
    }

    /** The version the user was last told about by an update notification (null = none): see [postUpdate]. */
    fun updateAnnounced(ctx: Context): String? =
        ctx.applicationContext.getSharedPreferences(UPDATE_PREFS, Context.MODE_PRIVATE).getString(UPDATE_ANNOUNCED, null)

    fun setUpdateAnnounced(ctx: Context, version: String) {
        ctx.applicationContext.getSharedPreferences(UPDATE_PREFS, Context.MODE_PRIVATE).edit().putString(UPDATE_ANNOUNCED, version).apply()
    }

    /**
     * The update notification. [install]: the file is downloaded, so a tap (and the [installLabel] button) lead
     * to the install dialog; otherwise a tap opens the update block. It replaces a still-shown one without
     * a second alert (a "ready" right after an "available" is one nudge, not two).
     */
    fun postUpdate(ctx: Context, title: String, text: String, install: Boolean, installLabel: String, file: String = "") {
        val nm = manager(ctx)
        if (!nm.areNotificationsEnabled()) return
        ensureChannels(ctx)
        // With the downloaded file the button installs by itself, so the body only opens the update block;
        // without it the button is the tap (the app opens and starts the installer)
        val direct = install && file.isNotEmpty()
        val tap = openApp(ctx, { setAction(ACTION_OPEN_UPDATE).putExtra(EXTRA_INSTALL, install && !direct) }, UPDATE_ID * 2 + (if (install && !direct) 1 else 0))
        val b = Notification.Builder(ctx, UPDATE_CHANNEL)
            .setSmallIcon(ctx.applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setContentIntent(tap)
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
        if (install && installLabel.isNotEmpty()) {
            val button = if (direct) installNow(ctx, file) else tap
            b.addAction(Notification.Action.Builder(Icon.createWithResource(ctx, android.R.drawable.ic_menu_upload), installLabel, button).build())
        }
        nm.notify(UPDATE_ID, b.build())
    }

    /**
     * The Install button: straight to the system installer with the downloaded APK, no app window
     * ([UpdateInstallActivity], a transparent activity: a notification may not start an activity from a
     * receiver on Android 12+, and the installer's confirmation needs a foreground app).
     */
    private fun installNow(ctx: Context, file: String): PendingIntent {
        val intent = Intent(ctx, UpdateInstallActivity::class.java)
            .setAction(ACTION_INSTALL_UPDATE)
            .putExtra(EXTRA_FILE, file)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_NO_ANIMATION)
        return PendingIntent.getActivity(ctx, UPDATE_ID * 2 + 2, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    fun cancelUpdate(ctx: Context) {
        runCatching { manager(ctx).cancel(UPDATE_ID) }
    }

    private fun openApp(ctx: Context, extra: Intent.() -> Unit = {}, code: Int = 0): PendingIntent {
        val intent = Intent(ctx, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            .apply(extra)
        return PendingIntent.getActivity(ctx, code, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    /** The foreground notification of the tunnel (what the service enters the foreground with, shown or not). */
    fun vpnNotification(ctx: Context): Notification {
        ensureChannels(ctx)
        val node = vpnNode
        val text = if (node.isNullOrEmpty()) ctx.getString(R.string.jorm_vpn_on) else ctx.getString(R.string.jorm_vpn_on_via, node)
        val stop = PendingIntent.getService(
            ctx,
            0,
            Intent(ctx, JormungandVpnService::class.java).setAction(JormungandVpnService.ACTION_DISCONNECT),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val action = Notification.Action.Builder(
            Icon.createWithResource(ctx, android.R.drawable.ic_menu_close_clear_cancel),
            ctx.getString(R.string.jorm_disconnect),
            stop,
        ).build()
        return Notification.Builder(ctx, VPN_CHANNEL)
            .setContentTitle("Jormungand")
            .setContentText(text)
            .setSmallIcon(ctx.applicationInfo.icon)
            .setContentIntent(openApp(ctx))
            .addAction(action)
            .setCategory(Notification.CATEGORY_SERVICE)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .build()
    }

    /** A tap on the body of an event's notification: the app opens at that event (Logs -> Events). */
    private fun openEvent(ctx: Context, eventId: Int, code: Int): PendingIntent =
        openApp(ctx, { setAction(ACTION_OPEN_EVENT).putExtra(EXTRA_EVENT, eventId) }, code)

    private fun broadcast(ctx: Context, action: String, code: Int, extra: Intent.() -> Unit): PendingIntent {
        val intent = Intent(ctx, EventActionReceiver::class.java).setAction(action).apply(extra)
        return PendingIntent.getBroadcast(ctx, code, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
    }

    private fun undoButton(ctx: Context, eventId: Int, site: String, label: String): Notification.Action {
        val pi = broadcast(ctx, ACTION_SITE_UNDO, notifId(eventId) * 4 + 3) {
            putExtra(EXTRA_EVENT, eventId).putExtra(EXTRA_SITE, site)
        }
        return Notification.Action.Builder(Icon.createWithResource(ctx, android.R.drawable.ic_menu_revert), label, pi).build()
    }

    private fun notifId(eventId: Int) = EVENT_BASE + (eventId and 0xFFFFF)

    /**
     * One journal event as a notification ([eventId]: the journal id, what a tap hands back to Dart).
     * [actions] (id to label) are its buttons. `rule` opens the app and hands Dart the action id with the
     * event's [site] / [via] (the event itself may be long gone from the journal). `ignore` does not open
     * anything: [EventActionReceiver] records the choice and [ignoredEvent] swaps the notification for
     * [ignoredText] with an [undoLabel] button.
     */
    fun postEvent(
        ctx: Context,
        eventId: Int,
        title: String,
        text: String,
        actions: List<Pair<String, String>> = emptyList(),
        site: String = "",
        via: String = "",
        ignoredText: String = "",
        undoLabel: String = "",
    ) {
        val nm = manager(ctx)
        if (!nm.areNotificationsEnabled()) return
        ensureChannels(ctx)
        val nid = notifId(eventId)
        if (children(nm).isEmpty()) burst.set(0) // everything before was dealt with
        burst.incrementAndGet()
        val b = Notification.Builder(ctx, EVENTS_CHANNEL)
            .setSmallIcon(ctx.applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setContentIntent(openEvent(ctx, eventId, nid))
            .setAutoCancel(true)
            .setGroup(GROUP)
            .setGroupAlertBehavior(Notification.GROUP_ALERT_SUMMARY)
        for ((i, a) in actions.withIndex()) {
            val code = nid * 4 + 1 + i // its own request code: one PendingIntent per button
            val pi = if (a.first == "ignore") {
                broadcast(ctx, ACTION_SITE_IGNORE, code) {
                    putExtra(EXTRA_EVENT, eventId)
                        .putExtra(EXTRA_SITE, site)
                        .putExtra(EXTRA_IGNORED_TEXT, ignoredText.ifEmpty { site })
                        .putExtra(EXTRA_UNDO_LABEL, undoLabel)
                }
            } else {
                openApp(
                    ctx,
                    {
                        setAction(ACTION_EVENT_ACT)
                            .putExtra(EXTRA_EVENT, eventId)
                            .putExtra(EXTRA_ACT, a.first)
                            .putExtra(EXTRA_SITE, site)
                            .putExtra(EXTRA_VIA, via)
                    },
                    code,
                )
            }
            b.addAction(
                Notification.Action.Builder(Icon.createWithResource(ctx, android.R.drawable.ic_menu_info_details), a.second, pi).build(),
            )
        }
        nm.notify(nid, b.build())
        val kids = children(nm)
        for (old in kids.sortedBy { it.postTime }.dropLast(MAX_CHILDREN)) nm.cancel(old.id)
        postSummary(ctx, nm)
    }

    /**
     * The «Ignore site» button was pressed ([EventActionReceiver]): the event's notification is replaced, in
     * place (same id), by a short «[text]» with one [undoLabel] button. It leaves the group (it is no
     * longer an event to look at), makes no sound and goes by itself after [CONFIRM_MS]; a tap on it still
     * opens the app at the event.
     */
    fun ignoredEvent(ctx: Context, eventId: Int, site: String, text: String, undoLabel: String) {
        val nm = manager(ctx)
        val nid = notifId(eventId)
        val b = Notification.Builder(ctx, EVENTS_CHANNEL)
            .setSmallIcon(ctx.applicationInfo.icon)
            .setContentTitle(text.ifEmpty { site })
            .setContentIntent(openEvent(ctx, eventId, nid))
            .setAutoCancel(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .setTimeoutAfter(CONFIRM_MS)
        if (undoLabel.isNotEmpty()) b.addAction(undoButton(ctx, eventId, site, undoLabel))
        nm.notify(nid, b.build())
        postSummary(ctx, nm, alert = false) // it left the group: the count and the lines follow
    }

    private fun children(nm: NotificationManager) =
        nm.activeNotifications.filter { it.id != SUMMARY_ID && it.notification.group == GROUP }

    /** [alert]: a new event arrived (the summary may make a sound); off for a summary redone after a removal. */
    private fun postSummary(ctx: Context, nm: NotificationManager, alert: Boolean = true) {
        val kids = children(nm).sortedBy { it.postTime }
        if (kids.isEmpty()) {
            nm.cancel(SUMMARY_ID)
            return
        }
        val total = maxOf(kids.size, burst.get())
        val now = System.currentTimeMillis()
        val quiet = !alert || now - lastAlert < ALERT_GAP_MS
        if (!quiet) lastAlert = now
        val inbox = Notification.InboxStyle()
        for (k in kids.takeLast(MAX_CHILDREN).reversed()) {
            val x = k.notification.extras
            inbox.addLine("${x.getCharSequence(Notification.EXTRA_TITLE) ?: ""} ${x.getCharSequence(Notification.EXTRA_TEXT) ?: ""}".trim())
        }
        val summary = ctx.resources.getQuantityString(R.plurals.jorm_events_summary, total, total)
        nm.notify(
            SUMMARY_ID,
            Notification.Builder(ctx, EVENTS_CHANNEL)
                .setSmallIcon(ctx.applicationInfo.icon)
                .setContentTitle("Jormungand")
                .setContentText(summary)
                .setStyle(inbox.setSummaryText(summary))
                // a tap on the collapsed group opens the app at the newest event of it (not just the app)
                .setContentIntent(openEvent(ctx, kids.last().id - EVENT_BASE, SUMMARY_ID))
                .setAutoCancel(true)
                .setGroup(GROUP)
                .setGroupSummary(true)
                .setGroupAlertBehavior(Notification.GROUP_ALERT_SUMMARY)
                .setOnlyAlertOnce(quiet)
                .build(),
        )
    }

    /** The notification of one event (a button of it was pressed: a button does not dismiss it by itself). */
    fun cancelEvent(ctx: Context, eventId: Int) {
        val nm = manager(ctx)
        nm.cancel(notifId(eventId))
        postSummary(ctx, nm, alert = false)
    }

    /** The app is in front again: what it posted about events is stale. */
    fun cancelEvents(ctx: Context) {
        val nm = manager(ctx)
        for (k in children(nm)) nm.cancel(k.id)
        nm.cancel(SUMMARY_ID)
        nm.cancel(UPDATE_ID) // the update block is a tap away in the app itself
        burst.set(0)
    }
}
