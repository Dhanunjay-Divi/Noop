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
            "Ride",
            "Morning ride",
            "Spin class",
            "Trail running",
            "10K training",
        ).forEach {
            assertTrue("Expected workout title: $it", PlannedWorkoutTitleClassifier.isWorkoutTitle(it))
        }
    }

    @Test fun recognizesWorkoutTitlesAcrossEveryLocalizedAppLanguage() {
        listOf(
            "Schwimmen",
            "Gimnasio",
            "Natation",
            "Palestra",
            "Ginásio",
            "Тренировка",
            "Йога",
            "游泳",
            "騎行",
            "早上跑步",
            "晚间瑜伽课",
            "晚上騎行課",
        ).forEach {
            assertTrue(
                "Expected localized workout title: $it",
                PlannedWorkoutTitleClassifier.isWorkoutTitle(it),
            )
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
            "Train ride",
            "Bus ride",
            "Airport ride",
            "Evening train ride",
            "Gym equipment shopping",
            "Gimnasio reunión",
            "Schwimmen Besprechung",
            "Yoga Vorstellungsgespräch",
            "Тренировка встреча",
            "健身会议",
            "健身會議",
            "早上跑步会议",
            "晚间瑜伽研讨会",
            "晚上騎行研討會",
        ).forEach {
            assertFalse(
                "Expected non-workout title: ${it ?: "nil"}",
                PlannedWorkoutTitleClassifier.isWorkoutTitle(it),
            )
        }
    }
}
