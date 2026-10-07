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
 *    and not more often than every [ALERT_GAP_MS].
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

    /**
     * One journal event as a notification ([eventId]: the journal id, what a tap hands back to Dart).
     * [actions] (id to label) are its buttons; a tap on one opens the app and hands Dart the action id
     * with the event's [site] / [via] (the event itself may be long gone from the journal).
     */
    fun postEvent(
        ctx: Context,
        eventId: Int,
        title: String,
        text: String,
        actions: List<Pair<String, String>> = emptyList(),
        site: String = "",
        via: String = "",
    ) {
        val nm = manager(ctx)
        if (!nm.areNotificationsEnabled()) return
        ensureChannels(ctx)
        val nid = EVENT_BASE + (eventId and 0xFFFFF)
        if (children(nm).isEmpty()) burst.set(0) // everything before was dealt with
        burst.incrementAndGet()
        val b = Notification.Builder(ctx, EVENTS_CHANNEL)
            .setSmallIcon(ctx.applicationInfo.icon)
            .setContentTitle(title)
            .setContentText(text)
            .setStyle(Notification.BigTextStyle().bigText(text))
            .setContentIntent(
                openApp(ctx, { setAction(ACTION_OPEN_EVENT).putExtra(EXTRA_EVENT, eventId) }, nid),
            )
            .setAutoCancel(true)
            .setGroup(GROUP)
            .setGroupAlertBehavior(Notification.GROUP_ALERT_SUMMARY)
        for ((i, a) in actions.withIndex()) {
            val pi = openApp(
                ctx,
                {
                    setAction(ACTION_EVENT_ACT)
                        .putExtra(EXTRA_EVENT, eventId)
                        .putExtra(EXTRA_ACT, a.first)
                        .putExtra(EXTRA_SITE, site)
                        .putExtra(EXTRA_VIA, via)
                },
                nid * 4 + 1 + i, // its own request code: one PendingIntent per button
            )
            b.addAction(
                Notification.Action.Builder(Icon.createWithResource(ctx, android.R.drawable.ic_menu_info_details), a.second, pi).build(),
            )
        }
        nm.notify(nid, b.build())
        val kids = children(nm)
        for (old in kids.sortedBy { it.postTime }.dropLast(MAX_CHILDREN)) nm.cancel(old.id)
        postSummary(ctx, nm)
    }

    private fun children(nm: NotificationManager) =
        nm.activeNotifications.filter { it.id != SUMMARY_ID && it.notification.group == GROUP }

    private fun postSummary(ctx: Context, nm: NotificationManager) {
        val kids = children(nm).sortedBy { it.postTime }
        if (kids.isEmpty()) {
            nm.cancel(SUMMARY_ID)
            return
        }
        val total = maxOf(kids.size, burst.get())
        val now = System.currentTimeMillis()
        val quiet = now - lastAlert < ALERT_GAP_MS
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
                .setContentIntent(openApp(ctx, {}, SUMMARY_ID))
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
        nm.cancel(EVENT_BASE + (eventId and 0xFFFFF))
        postSummary(ctx, nm)
    }

    /** The app is in front again: what it posted about events is stale. */
    fun cancelEvents(ctx: Context) {
        val nm = manager(ctx)
        for (k in children(nm)) nm.cancel(k.id)
        nm.cancel(SUMMARY_ID)
        burst.set(0)
    }
}
