package com.noop.managed

import com.google.android.gms.tasks.Task
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

internal suspend fun <T> Task<T>.awaitManaged(): T =
    suspendCancellableCoroutine { continuation ->
        addOnCompleteListener { task ->
            if (!continuation.isActive) return@addOnCompleteListener
            when {
                task.isSuccessful -> continuation.resume(task.result)
                task.isCanceled -> continuation.cancel()
                else -> continuation.resumeWithException(
                    task.exception ?: IllegalStateException("Firebase task failed."),
                )
            }
        }
    }
