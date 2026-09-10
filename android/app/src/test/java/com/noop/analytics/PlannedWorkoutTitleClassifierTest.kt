package com.noop.analytics

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PlannedWorkoutTitleClassifierTest {
    @Test fun recognizesConservativeWorkoutTitles() {
        listOf(
            "Gym",
            "Morning run",
            "Strength training",
            "Yoga with Maya",
            "HIIT 45",
            "Swim",
            "Evening bike ride",
            "Spin class",
            "Trail running",
            "10K training",
        ).forEach {
            assertTrue("Expected workout title: $it", PlannedWorkoutTitleClassifier.isWorkoutTitle(it))
        }
    }

    @Test fun rejectsAmbiguousAndWorkTitles() {
        listOf<String?>(
            null,
            "",
            "Training",
            "Training meeting",
            "Project run review",
            "Run payroll",
            "Run backup",
            "Spin up staging",
            "Running payroll",
            "Morning backup run",
            "Disaster recovery runbook",
            "Run errands",
            "School run",
            "Dry run",
            "Yoga workshop",
            "Team standup",
            "Bike repair",
            "Football watch party",
            "Tennis tickets",
            "Gym equipment shopping",
        ).forEach {
            assertFalse(
                "Expected non-workout title: ${it ?: "nil"}",
                PlannedWorkoutTitleClassifier.isWorkoutTitle(it),
            )
        }
    }
}
