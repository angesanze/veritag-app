package com.example.arttrust_mobile

import android.content.Intent
import android.nfc.NdefMessage
import android.nfc.NfcAdapter
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/// Receives ArtTrust tags dispatched by the OS (the manifest routes our
/// external-type NDEF record here — never to a browser: the record is data,
/// not a URI) and hands the payload to Dart over the `arttrust/nfc` channel.
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pendingPayload: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pendingPayload = payloadFrom(intent) ?: pendingPayload
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "arttrust/nfc").also {
            it.setMethodCallHandler { call, result ->
                if (call.method == "takeLaunchPayload") {
                    result.success(pendingPayload)
                    pendingPayload = null
                } else {
                    result.notImplemented()
                }
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val payload = payloadFrom(intent) ?: return
        val ch = channel
        if (ch != null) ch.invokeMethod("tag", payload) else pendingPayload = payload
    }

    /// Extract the ArtTrust record payload (`v1;u=…;c=…;m=…`) from an NFC
    /// dispatch intent; null for anything that isn't ours.
    private fun payloadFrom(intent: Intent?): String? {
        if (intent?.action != NfcAdapter.ACTION_NDEF_DISCOVERED) return null
        @Suppress("DEPRECATION")
        val messages = intent.getParcelableArrayExtra(NfcAdapter.EXTRA_NDEF_MESSAGES) ?: return null
        for (raw in messages) {
            val msg = raw as? NdefMessage ?: continue
            for (record in msg.records) {
                if (record.type?.toString(Charsets.US_ASCII) == "arttrust.com:t") {
                    return record.payload?.toString(Charsets.US_ASCII)
                }
            }
        }
        return null
    }
}
