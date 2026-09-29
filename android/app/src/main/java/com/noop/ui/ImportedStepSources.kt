package com.noop.ui

private val importedStepSources = listOf("apple-health", "health-connect")

internal suspend fun AppViewModel.importedStepsForDay(day: String): Int? =
    importedStepSources
        .flatMap { source -> repo.appleDaily(source, day, day) }
        .mapNotNull { it.steps }
        .maxOrNull()
