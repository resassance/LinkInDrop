package dev.resassance.linkindrop

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.os.Handler
import android.os.Looper

class LocalNetwork(private val context: Context, private val changed: () -> Unit) {
    private val manager = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
    private val handler = Handler(Looper.getMainLooper())
    private var enabled = false
    private var selected: Network? = null
    private var failure: String? = null
    private var lastState = ""
    private val update = Runnable {
        apply()
        val state = status().toString()
        if (state != lastState) { lastState = state; changed() }
    }
    init {
        manager.registerNetworkCallback(NetworkRequest.Builder().removeCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN).build(), object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) { schedule() }
            override fun onLost(network: Network) { schedule() }
            override fun onLinkPropertiesChanged(network: Network, properties: android.net.LinkProperties) { schedule() }
            override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) { schedule() }
        })
    }
    private fun schedule() { handler.removeCallbacks(update); handler.postDelayed(update, 500) }
    private fun wifi(): Network? = manager.allNetworks.firstOrNull { network ->
        val caps = manager.getNetworkCapabilities(network)
        caps != null && caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_NOT_VPN) &&
            (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) || caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET))
    }
    private fun apply() {
        val next = if (enabled) wifi() else null
        if (next == selected && (next == null || manager.boundNetworkForProcess == next)) return
        try {
            if (!manager.bindProcessToNetwork(next)) { failure = NativeStrings.text(context, "Android не разрешил прямой маршрут. Проверьте настройки NekoBox и запрет соединений без VPN."); return }
            selected = next
            failure = null
        } catch (_: SecurityException) {
            failure = NativeStrings.text(context, "VPN запрещает обход. Разрешите LAN или исключите LinkInDrop в NekoBox.")
        }
    }
    fun setEnabled(value: Boolean): Map<String, Any?> { enabled = value; apply(); return status() }
    fun status(): Map<String, Any?> {
        val physical = wifi()
        val vpn = manager.allNetworks.any { manager.getNetworkCapabilities(it)?.hasTransport(NetworkCapabilities.TRANSPORT_VPN) == true }
        val active = manager.boundNetworkForProcess
        val addresses = if (enabled && selected != null && active == selected) manager.getLinkProperties(selected!!)?.linkAddresses?.map { it.address }?.filter { it is java.net.Inet4Address && !it.isLoopbackAddress }?.map { it.hostAddress } ?: emptyList() else emptyList()
        return mapOf("enabled" to enabled, "vpn" to vpn, "wifi" to (physical != null),
            "direct" to (enabled && selected != null && active == selected), "addresses" to addresses, "error" to failure)
    }
}
