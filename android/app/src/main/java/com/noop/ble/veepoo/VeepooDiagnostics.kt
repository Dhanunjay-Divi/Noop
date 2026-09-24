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

enum class VeepooSupplierLifecycleStage {
    ADOPTION,
    SECURE_CLEANUP,
    RECONCILIATION,
    REMOVAL,
}

enum class VeepooSupplierLifecycleOutcome {
    BEGAN,
    COMPLETED,
    FAILED,
}

enum class VeepooSupplierLifecycleTrigger {
    SOURCE_UNAVAILABLE,
    AUTHENTICATION_REJECTED,
    DEVICE_REMOVAL,
}

enum class VeepooSupplierLifecycleFailure {
    SECURE_PERSISTENCE,
    REGISTRY_PERSISTENCE,
    CLEANUP_FAILED,
    FALLBACK_UNAVAILABLE,
}

data class VeepooSupplierLifecycleEvent(
    val stage: VeepooSupplierLifecycleStage,
    val outcome: VeepooSupplierLifecycleOutcome,
    val trigger: VeepooSupplierLifecycleTrigger? = null,
    val failure: VeepooSupplierLifecycleFailure? = null,
) {
    internal fun fields(): Map<String, String> = buildMap {
        put("stage", stage.name.lowercase())
        put("outcome", outcome.name.lowercase())
        trigger?.let { put("trigger", it.name.lowercase()) }
        failure?.let { put("failure_kind", it.name.lowercase()) }
    }

    override fun toString(): String = "VeepooSupplierLifecycleEvent"
}

fun interface VeepooSupplierLifecycleDiagnosticSink {
    fun record(event: VeepooSupplierLifecycleEvent)
}

object AppVeepooSupplierLifecycleDiagnosticSink : VeepooSupplierLifecycleDiagnosticSink {
    override fun record(event: VeepooSupplierLifecycleEvent) {
        AppDiagnosticsRecorder.record(
            event = "band.supplier_lifecycle",
            fields = event.fields(),
        )
    }
}

internal fun VeepooSupplierLifecycleDiagnosticSink.recordSafely(
    stage: VeepooSupplierLifecycleStage,
    outcome: VeepooSupplierLifecycleOutcome,
    trigger: VeepooSupplierLifecycleTrigger? = null,
    failure: VeepooSupplierLifecycleFailure? = null,
) {
    runCatching {
        record(
            VeepooSupplierLifecycleEvent(
                stage = stage,
                outcome = outcome,
                trigger = trigger,
                failure = failure,
            ),
        )
    }
}
