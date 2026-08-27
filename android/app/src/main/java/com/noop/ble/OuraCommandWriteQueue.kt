package com.noop.ble

import com.noop.oura.OuraCommand
import java.util.ArrayDeque

/**
 * Pure single-delivery queue for Oura's write-without-response command characteristic.
 *
 * Android permits only one GATT operation at a time. The transport submits [active] once, holds the
 * slot for a short pacing interval, then calls [completeActive] before taking another command.
 * Teardown preserves an already-submitted command but replaces pending background work with the
 * live-HR disable/unsubscribe pair.
 */
internal class OuraCommandWriteQueue {
    private val pending = ArrayDeque<OuraCommand>()
    private var active: OuraCommand? = null

    @Synchronized
    fun enqueue(commands: Iterable<OuraCommand>) {
        commands.forEach(pending::addLast)
    }

    @Synchronized
    fun beginNext(): OuraCommand? {
        if (active != null || pending.isEmpty()) return null
        return pending.removeFirst().also { active = it }
    }

    @Synchronized
    fun completeActive(): OuraCommand? {
        val completed = active
        active = null
        return completed
    }

    @Synchronized
    fun replacePendingForTeardown(commands: Iterable<OuraCommand>) {
        pending.clear()
        commands.forEach(pending::addLast)
    }

    @Synchronized
    fun reset() {
        pending.clear()
        active = null
    }

    @get:Synchronized
    val isDrained: Boolean
        get() = active == null && pending.isEmpty()

    @get:Synchronized
    val pendingLabels: List<String>
        get() = pending.map(OuraCommand::label)

    @get:Synchronized
    val activeLabel: String?
        get() = active?.label
}
