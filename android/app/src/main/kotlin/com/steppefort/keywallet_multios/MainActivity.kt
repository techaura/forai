package com.steppefort.keywallet_multios

import android.content.ClipData
import android.content.ClipboardManager
import android.content.ClipDescription
import android.content.Context
import android.os.Build
import android.os.PersistableBundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.security.MessageDigest

class MainActivity : FlutterActivity() {
    companion object {
        private const val CLIPBOARD_CHANNEL =
            "com.steppefort.keywallet_multios/clipboard"
    }

    private var ownedClipboardFingerprint: ByteArray? = null
    private var clipboardAppWasPaused = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            CLIPBOARD_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "setSensitiveText" -> {
                    val text = call.argument<String>("text")
                    val trackForClear =
                        call.argument<Boolean>("trackForClear") ?: false

                    if (text == null) {
                        result.error(
                            "invalid_argument",
                            "Missing clipboard text",
                            null,
                        )
                        return@setMethodCallHandler
                    }

                    try {
                        val clipboard =
                            getSystemService(Context.CLIPBOARD_SERVICE)
                                as ClipboardManager
                        val clip = ClipData.newPlainText("WalletWalley", text)

                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                            val extras = PersistableBundle()

                            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                                extras.putBoolean(
                                    ClipDescription.EXTRA_IS_SENSITIVE,
                                    true,
                                )
                            } else {
                                extras.putBoolean(
                                    "android.content.extra.IS_SENSITIVE",
                                    true,
                                )
                            }

                            clip.description.extras = extras
                        }

                        clipboard.setPrimaryClip(clip)

                        ownedClipboardFingerprint =
                            if (trackForClear) sha256(text) else null
                        clipboardAppWasPaused = false

                        result.success(null)
                    } catch (error: Exception) {
                        ownedClipboardFingerprint = null
                        clipboardAppWasPaused = false
                        result.error(
                            "clipboard_write_failed",
                            error.message,
                            null,
                        )
                    }
                }

                "disableOwnedClear" -> {
                    ownedClipboardFingerprint = null
                    clipboardAppWasPaused = false
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        }
    }

    override fun onPause() {
        if (ownedClipboardFingerprint != null) {
            clipboardAppWasPaused = true
        }
        super.onPause()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)

        if (!hasFocus || !clipboardAppWasPaused) {
            return
        }

        val expected = ownedClipboardFingerprint ?: return
        clipboardAppWasPaused = false

        // Run after the focus callback has completed. At this point Android
        // should grant this foreground Activity clipboard read access.
        window.decorView.post {
            clearOwnedClipboardIfStillPresent(expected)
        }
    }

    private fun clearOwnedClipboardIfStillPresent(expected: ByteArray) {
        val currentExpected = ownedClipboardFingerprint ?: return

        if (!MessageDigest.isEqual(currentExpected, expected)) {
            return
        }

        try {
            val clipboard =
                getSystemService(Context.CLIPBOARD_SERVICE) as ClipboardManager
            val clip = clipboard.primaryClip
            val currentText =
                if (clip != null && clip.itemCount > 0) {
                    clip.getItemAt(0).text?.toString()
                } else {
                    null
                }

            if (currentText == null ||
                !MessageDigest.isEqual(sha256(currentText), expected)
            ) {
                // Another app changed or cleared the clipboard.
                ownedClipboardFingerprint = null
                return
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                clipboard.clearPrimaryClip()
            } else {
                clipboard.setPrimaryClip(
                    ClipData.newPlainText("WalletWalley", ""),
                )
            }

            ownedClipboardFingerprint = null
        } catch (_: SecurityException) {
            // Keep ownership so a later pause/focus cycle can retry.
        } catch (_: RuntimeException) {
            // Vendor clipboard implementations can throw runtime errors.
            // Keep ownership for a later retry rather than touching unknown data.
        }
    }

    private fun sha256(value: String): ByteArray {
        return MessageDigest
            .getInstance("SHA-256")
            .digest(value.toByteArray(Charsets.UTF_8))
    }
}
