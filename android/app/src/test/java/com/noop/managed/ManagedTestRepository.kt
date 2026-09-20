package com.noop.managed

import java.io.File

internal fun managedTestRepositoryRoot(): File {
    val start = File(System.getProperty("user.dir") ?: ".").absoluteFile
    return generateSequence(start) { current -> current.parentFile }
        .firstOrNull { candidate ->
            File(candidate, "android/app/build.gradle.kts").isFile &&
                File(candidate, "Fixtures").isDirectory
        }
        ?: error("NOOP repository root is unavailable from ${start.path}")
}
