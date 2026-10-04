package dev.jormungand.app

import android.net.DnsResolver
import android.os.Build
import android.os.CancellationSignal
import android.system.ErrnoException
import io.nekohasekai.libbox.ExchangeContext
import io.nekohasekai.libbox.LocalDNSTransport
import java.net.InetAddress
import java.net.UnknownHostException
import java.util.concurrent.CancellationException
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicReference

/**
 * sing-box's `local` DNS server on Android: the system resolver of the default network
 * (Android has no /etc/resolv.conf for Go to read). Blocks until the answer, as libbox expects;
 * sing-box-for-android's LocalResolver without coroutines.
 */
object LocalResolver : LocalDNSTransport {
    private const val RCODE_NXDOMAIN = 3
    private val executor = Executors.newCachedThreadPool()

    private var lastFailLog = 0L
    private var failsHidden = 0

    /** A failed lookup goes to the raw log, at most one line a second (a ping asks for dozens of names). */
    private fun failed(what: String, why: Any?) {
        val now = System.currentTimeMillis()
        synchronized(this) {
            if (now - lastFailLog < 1000) {
                failsHidden++
                return
            }
            lastFailLog = now
            val more = if (failsHidden > 0) " (+$failsHidden more)" else ""
            failsHidden = 0
            VpnBridge.log("warn", "dns: $what failed: $why$more")
        }
    }

    override fun raw(): Boolean = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

    @android.annotation.TargetApi(Build.VERSION_CODES.Q)
    override fun exchange(ctx: ExchangeContext, message: ByteArray) {
        val network = DefaultNetworkMonitor.defaultNetwork
        if (network == null) {
            failed("query", "missing default interface")
            error("missing default interface")
        }
        val done = CountDownLatch(1)
        val failure = AtomicReference<Throwable?>(null)
        val signal = CancellationSignal()
        ctx.onCancel {
            signal.cancel()
            failure.compareAndSet(null, CancellationException())
            done.countDown()
        }
        val callback = object : DnsResolver.Callback<ByteArray> {
            override fun onAnswer(answer: ByteArray, rcode: Int) {
                if (rcode == 0) ctx.rawSuccess(answer) else ctx.errorCode(rcode)
                done.countDown()
            }

            override fun onError(error: DnsResolver.DnsException) {
                failed("query", error)
                val cause = error.cause
                if (cause is ErrnoException) ctx.errnoCode(cause.errno) else failure.compareAndSet(null, error)
                done.countDown()
            }
        }
        DnsResolver.getInstance().rawQuery(network, message, DnsResolver.FLAG_NO_RETRY, executor, signal, callback)
        done.await()
        failure.get()?.let { throw it }
    }

    override fun lookup(ctx: ExchangeContext, network: String, domain: String) {
        val default = DefaultNetworkMonitor.defaultNetwork
        if (default == null) {
            failed("lookup of $domain", "missing default interface")
            error("missing default interface")
        }
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            val answer = try {
                default.getAllByName(domain)
            } catch (e: UnknownHostException) {
                ctx.errorCode(RCODE_NXDOMAIN)
                return
            }
            ctx.success(answer.mapNotNull { it.hostAddress }.joinToString("\n"))
            return
        }
        lookupQ(ctx, default, network, domain)
    }

    @android.annotation.TargetApi(Build.VERSION_CODES.Q)
    private fun lookupQ(ctx: ExchangeContext, default: android.net.Network, network: String, domain: String) {
        val done = CountDownLatch(1)
        val failure = AtomicReference<Throwable?>(null)
        val signal = CancellationSignal()
        ctx.onCancel {
            signal.cancel()
            failure.compareAndSet(null, CancellationException())
            done.countDown()
        }
        val callback = object : DnsResolver.Callback<Collection<InetAddress>> {
            override fun onAnswer(answer: Collection<InetAddress>, rcode: Int) {
                if (rcode == 0) {
                    ctx.success(answer.mapNotNull { it.hostAddress }.joinToString("\n"))
                } else {
                    failed("lookup of $domain", "rcode $rcode")
                    ctx.errorCode(rcode)
                }
                done.countDown()
            }

            override fun onError(error: DnsResolver.DnsException) {
                failed("lookup of $domain", error)
                val cause = error.cause
                if (cause is ErrnoException) ctx.errnoCode(cause.errno) else failure.compareAndSet(null, error)
                done.countDown()
            }
        }
        val type = when {
            network.endsWith("4") -> DnsResolver.TYPE_A
            network.endsWith("6") -> DnsResolver.TYPE_AAAA
            else -> null
        }
        if (type != null) {
            DnsResolver.getInstance().query(default, domain, type, DnsResolver.FLAG_NO_RETRY, executor, signal, callback)
        } else {
            DnsResolver.getInstance().query(default, domain, DnsResolver.FLAG_NO_RETRY, executor, signal, callback)
        }
        done.await()
        failure.get()?.let { throw it }
    }
}
