package com.noop.ble.veepoo

import com.noop.AppDiagnosticsRecorder

enum class VeepooDiagnosticCategory {
    DISCOVERY,
    SELECTION,
    CONNECTION,
    PAIRING_CONFIRMATION,
    AUTHENTICATION,
    CAPABILITY,
    BATTERY,
    LIVE_DISPLAY,
    RECONNECT,
    DISCONNECT,
    CLEANUP,
}

enum class VeepooDiagnosticOutcome {
    BEGAN,
    COMPLETED,
    CANCELLED,
    REJECTED,
    FAILED,
    TIMED_OUT,
    STALE,
}

enum class VeepooDiagnosticFailure {
    UNAVAILABLE,
    PERMISSION,
    NO_RESULT,
    TIMEOUT,
    REJECTED,
    AUTHENTICATION,
    DISCONNECTED,
    UNSUPPORTED,
    BUSY,
    INVALID_STATE,
    INVALID_INPUT,
    INTERNAL,
}

data class VeepooDiagnosticEvent(
    val category: VeepooDiagnosticCategory,
    val outcome: VeepooDiagnosticOutcome,
    val failure: VeepooDiagnosticFailure? = null,
) {
    internal fun fields(): Map<String, String> = buildMap {
        put("category", category.name.lowercase())
        put("outcome", outcome.name.lowercase())
        failure?.let { put("failure", it.name.lowercase()) }
    }

    override fun toString(): String = "VeepooDiagnosticEvent"
}

fun interface VeepooDiagnosticSink {
    fun record(event: VeepooDiagnosticEvent)
}

object AppVeepooDiagnosticSink : VeepooDiagnosticSink {
    override fun record(event: VeepooDiagnosticEvent) {
        AppDiagnosticsRecorder.record(
            event = "band.supplier.lifecycle",
            fields = event.fields(),
        )
    }
}
