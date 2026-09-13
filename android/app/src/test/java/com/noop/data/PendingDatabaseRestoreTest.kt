package com.noop.data

import com.noop.testing.FakeSharedPreferences
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertSame
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.attribute.BasicFileAttributes
import java.security.MessageDigest

class PendingDatabaseRestoreTest {
    @get:Rule
    val temporary = TemporaryFolder()

    private val sqliteMagic = byteArrayOf(
        0x53, 0x51, 0x4c, 0x69, 0x74, 0x65, 0x20, 0x66,
        0x6f, 0x72, 0x6d, 0x61, 0x74, 0x20, 0x33, 0x00,
    )

    private fun files(name: String): PendingDatabaseRestore.Fileset {
        val directory = temporary.newFolder(name)
        return PendingDatabaseRestore.Fileset(
            db = File(directory, WhoopDatabase.DB_NAME),
            identityOf = { file ->
                val key = Files.readAttributes(
                    file.toPath(),
                    BasicFileAttributes::class.java,
                ).fileKey()?.hashCode()?.toLong()?.and(0xffffffffL)
                key?.let { "$it:$it" }
            },
            checkpointWal = {
                PendingDatabaseRestore.WalCheckpointResult(
                    busy = 0,
                    logFrames = 0,
                    checkpointedFrames = 0,
                )
            },
        )
    }

    private fun sqlite(file: File, payload: String): File = file.apply {
        parentFile?.mkdirs()
        outputStream().use { output ->
            output.write(sqliteMagic)
            output.write(payload.toByteArray())
        }
    }

    private fun validSqlite(file: File): Boolean = DataBackup.isValidSqliteHeader(file)

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                digest.update(buffer, 0, count)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    private fun writeRawMarker(
        file: File,
        version: Int,
        phase: PendingDatabaseRestore.Phase,
        hash: String,
        hasSettings: Boolean = false,
        hadPreviousDatabase: Boolean? = null,
        rollbackSha256: String? = null,
        acceptedLiveFileIdentity: String? = null,
    ) {
        file.writeText(
            buildString {
                append("version=").append(version).append('\n')
                append("phase=").append(phase.name).append('\n')
                append("sha256=").append(hash).append('\n')
                append("settings=").append(if (hasSettings) 1 else 0).append('\n')
                hadPreviousDatabase?.let {
                    append("had_previous=").append(if (it) 1 else 0).append('\n')
                }
                rollbackSha256?.let {
                    append("rollback_sha256=").append(it).append('\n')
                }
                acceptedLiveFileIdentity?.let {
                    append("accepted_live_identity=").append(it).append('\n')
                }
            },
        )
    }

    private fun restoreTargets(
        profile: FakeSharedPreferences = FakeSharedPreferences(),
        noop: FakeSharedPreferences = FakeSharedPreferences(),
        notifications: FakeSharedPreferences = FakeSharedPreferences(),
        inactivity: FakeSharedPreferences = FakeSharedPreferences(),
        hydrationReminders: FakeSharedPreferences = FakeSharedPreferences(),
        windDown: FakeSharedPreferences = FakeSharedPreferences(),
    ) = BackupSettingsBridge.RestorePreferenceTargets(
        profile = profile,
        noop = noop,
        notifications = notifications,
        inactivity = inactivity,
        hydrationReminders = hydrationReminders,
        windDown = windDown,
    )

    @Test fun pendingRequiresCandidate() {
        assertEquals(
            PendingDatabaseRestore.ResumeAction.APPLY_CANDIDATE,
            PendingDatabaseRestore.resumeAction(
                phase = PendingDatabaseRestore.Phase.PENDING,
                candidateExists = true,
                liveExists = true,
                liveMatchesCandidate = false,
                rollbackExists = true,
                hadPreviousDatabase = null,
            ),
        )
        assertEquals(
            PendingDatabaseRestore.ResumeAction.NONE,
            PendingDatabaseRestore.resumeAction(
                phase = PendingDatabaseRestore.Phase.PENDING,
                candidateExists = false,
                liveExists = true,
                liveMatchesCandidate = false,
                rollbackExists = true,
                hadPreviousDatabase = null,
            ),
        )
    }

    @Test fun applyingResumesSwapOrAcceptsCompletedSwap() {
        assertEquals(
            PendingDatabaseRestore.ResumeAction.ACCEPT_LIVE,
            PendingDatabaseRestore.resumeAction(
                phase = PendingDatabaseRestore.Phase.APPLYING,
                candidateExists = false,
                liveExists = true,
                liveMatchesCandidate = true,
                rollbackExists = true,
                hadPreviousDatabase = true,
            ),
        )
        assertEquals(
            PendingDatabaseRestore.ResumeAction.APPLY_CANDIDATE,
            PendingDatabaseRestore.resumeAction(
                phase = PendingDatabaseRestore.Phase.APPLYING,
                candidateExists = true,
                liveExists = true,
                liveMatchesCandidate = false,
                rollbackExists = true,
                hadPreviousDatabase = true,
            ),
        )
    }

    @Test fun applyingAndAppliedFailClosedWithoutRequiredRollbackEvidence() {
        assertEquals(
            PendingDatabaseRestore.ResumeAction.NONE,
            PendingDatabaseRestore.resumeAction(
                phase = PendingDatabaseRestore.Phase.APPLYING,
                candidateExists = true,
                liveExists = true,
                liveMatchesCandidate = false,
                rollbackExists = false,
                hadPreviousDatabase = true,
            ),
        )
        assertEquals(
            PendingDatabaseRestore.ResumeAction.NONE,
            PendingDatabaseRestore.resumeAction(
                phase = PendingDatabaseRestore.Phase.APPLIED,
                candidateExists = false,
                liveExists = true,
                liveMatchesCandidate = true,
                rollbackExists = false,
                hadPreviousDatabase = null,
            ),
        )
        assertEquals(
            PendingDatabaseRestore.ResumeAction.NONE,
            PendingDatabaseRestore.resumeAction(
                phase = PendingDatabaseRestore.Phase.APPLIED,
                candidateExists = false,
                liveExists = true,
                liveMatchesCandidate = true,
                rollbackExists = true,
                hadPreviousDatabase = false,
            ),
        )
    }

    @Test fun legacyApplyingMarkerMayPreserveUntouchedLiveDatabaseBeforeSwap() {
        assertEquals(
            PendingDatabaseRestore.ResumeAction.APPLY_CANDIDATE,
            PendingDatabaseRestore.resumeAction(
                phase = PendingDatabaseRestore.Phase.APPLYING,
                candidateExists = true,
                liveExists = true,
                liveMatchesCandidate = false,
                rollbackExists = false,
                hadPreviousDatabase = null,
            ),
        )
        assertEquals(
            PendingDatabaseRestore.ResumeAction.NONE,
            PendingDatabaseRestore.resumeAction(
                phase = PendingDatabaseRestore.Phase.APPLYING,
                candidateExists = true,
                liveExists = false,
                liveMatchesCandidate = false,
                rollbackExists = false,
                hadPreviousDatabase = null,
            ),
        )
    }

    @Test fun finalizingAcceptsMigratedLiveBytesButFailsClosedWhenLiveIsMissing() {
        assertEquals(
            PendingDatabaseRestore.ResumeAction.ACCEPT_LIVE,
            PendingDatabaseRestore.resumeAction(
                phase = PendingDatabaseRestore.Phase.FINALIZING,
                candidateExists = false,
                liveExists = true,
                liveMatchesCandidate = false,
                rollbackExists = true,
                hadPreviousDatabase = true,
            ),
        )
        assertEquals(
            PendingDatabaseRestore.ResumeAction.NONE,
            PendingDatabaseRestore.resumeAction(
                phase = PendingDatabaseRestore.Phase.FINALIZING,
                candidateExists = false,
                liveExists = false,
                liveMatchesCandidate = false,
                rollbackExists = true,
                hadPreviousDatabase = true,
            ),
        )
    }

    @Test fun committedRestoreOnlyRetriesCleanup() {
        assertEquals(
            PendingDatabaseRestore.ResumeAction.CLEANUP_COMMITTED,
            PendingDatabaseRestore.resumeAction(
                PendingDatabaseRestore.Phase.COMMITTED,
                candidateExists = false,
                liveExists = true,
                liveMatchesCandidate = true,
                rollbackExists = true,
                hadPreviousDatabase = true,
            ),
        )
        assertEquals(
            PendingDatabaseRestore.ResumeAction.NONE,
            PendingDatabaseRestore.resumeAction(
                PendingDatabaseRestore.Phase.COMMITTED,
                candidateExists = false,
                liveExists = false,
                liveMatchesCandidate = false,
                rollbackExists = true,
                hadPreviousDatabase = true,
            ),
        )
        assertEquals(
            PendingDatabaseRestore.ResumeAction.CLEANUP_COMMITTED,
            PendingDatabaseRestore.resumeAction(
                PendingDatabaseRestore.Phase.COMMITTED,
                candidateExists = false,
                liveExists = true,
                liveMatchesCandidate = false,
                rollbackExists = false,
                hadPreviousDatabase = false,
            ),
        )
    }

    @Test fun missingCandidateRollsBackOnlyWhenSafeCopyExists() {
        assertEquals(
            PendingDatabaseRestore.ResumeAction.ROLLBACK,
            PendingDatabaseRestore.resumeAction(
                phase = PendingDatabaseRestore.Phase.APPLYING,
                candidateExists = false,
                liveExists = true,
                liveMatchesCandidate = false,
                rollbackExists = true,
                hadPreviousDatabase = true,
            ),
        )
        assertEquals(
            PendingDatabaseRestore.ResumeAction.NONE,
            PendingDatabaseRestore.resumeAction(
                phase = PendingDatabaseRestore.Phase.APPLYING,
                candidateExists = false,
                liveExists = true,
                liveMatchesCandidate = false,
                rollbackExists = false,
                hadPreviousDatabase = true,
            ),
        )
        assertEquals(
            PendingDatabaseRestore.ResumeAction.ROLLBACK,
            PendingDatabaseRestore.resumeAction(
                phase = PendingDatabaseRestore.Phase.APPLIED,
                candidateExists = false,
                liveExists = true,
                liveMatchesCandidate = false,
                rollbackExists = false,
                hadPreviousDatabase = false,
            ),
        )
    }

    @Test fun rollingBackResumesAndRolledBackOnlyRetriesCleanup() {
        assertEquals(
            PendingDatabaseRestore.ResumeAction.ROLLBACK,
            PendingDatabaseRestore.resumeAction(
                phase = PendingDatabaseRestore.Phase.ROLLING_BACK,
                candidateExists = false,
                liveExists = true,
                liveMatchesCandidate = false,
                rollbackExists = false,
                hadPreviousDatabase = true,
            ),
        )
        assertEquals(
            PendingDatabaseRestore.ResumeAction.CLEANUP_ROLLED_BACK,
            PendingDatabaseRestore.resumeAction(
                phase = PendingDatabaseRestore.Phase.ROLLED_BACK,
                candidateExists = true,
                liveExists = true,
                liveMatchesCandidate = false,
                rollbackExists = false,
                hadPreviousDatabase = true,
            ),
        )
        assertEquals(
            PendingDatabaseRestore.ResumeAction.CLEANUP_ROLLED_BACK,
            PendingDatabaseRestore.resumeAction(
                phase = PendingDatabaseRestore.Phase.ROLLED_BACK,
                candidateExists = true,
                liveExists = false,
                liveMatchesCandidate = false,
                rollbackExists = false,
                hadPreviousDatabase = false,
            ),
        )
        assertEquals(
            PendingDatabaseRestore.ResumeAction.NONE,
            PendingDatabaseRestore.resumeAction(
                phase = PendingDatabaseRestore.Phase.ROLLED_BACK,
                candidateExists = true,
                liveExists = true,
                liveMatchesCandidate = false,
                rollbackExists = false,
                hadPreviousDatabase = false,
            ),
        )
        assertEquals(
            PendingDatabaseRestore.ResumeAction.NONE,
            PendingDatabaseRestore.resumeAction(
                phase = PendingDatabaseRestore.Phase.ROLLED_BACK,
                candidateExists = true,
                liveExists = true,
                liveMatchesCandidate = false,
                rollbackExists = false,
                hadPreviousDatabase = null,
            ),
        )
    }

    @Test fun terminalCleanupRequiresVerifiedLiveDatabaseOrVerifiedAbsence() {
        assertTrue(
            PendingDatabaseRestore.terminalCleanupAllowed(
                phase = PendingDatabaseRestore.Phase.COMMITTED,
                hadPreviousDatabase = true,
                liveExists = true,
                liveMatchesRollback = false,
                liveSqliteValid = true,
            ),
        )
        assertFalse(
            PendingDatabaseRestore.terminalCleanupAllowed(
                phase = PendingDatabaseRestore.Phase.COMMITTED,
                hadPreviousDatabase = true,
                liveExists = false,
                liveMatchesRollback = false,
                liveSqliteValid = false,
            ),
        )
        assertFalse(
            PendingDatabaseRestore.terminalCleanupAllowed(
                phase = PendingDatabaseRestore.Phase.ROLLED_BACK,
                hadPreviousDatabase = true,
                liveExists = true,
                liveMatchesRollback = false,
                liveSqliteValid = true,
            ),
        )
        assertTrue(
            PendingDatabaseRestore.terminalCleanupAllowed(
                phase = PendingDatabaseRestore.Phase.ROLLED_BACK,
                hadPreviousDatabase = true,
                liveExists = true,
                liveMatchesRollback = true,
                liveSqliteValid = true,
            ),
        )
        assertTrue(
            PendingDatabaseRestore.terminalCleanupAllowed(
                phase = PendingDatabaseRestore.Phase.ROLLED_BACK,
                hadPreviousDatabase = false,
                liveExists = false,
                liveMatchesRollback = false,
                liveSqliteValid = false,
            ),
        )
        assertFalse(
            PendingDatabaseRestore.terminalCleanupAllowed(
                phase = PendingDatabaseRestore.Phase.ROLLED_BACK,
                hadPreviousDatabase = false,
                liveExists = true,
                liveMatchesRollback = false,
                liveSqliteValid = true,
            ),
        )
    }

    @Test fun appliedFileIdentityFailsClosedWhenEitherIdentityIsUnavailable() {
        assertFalse(PendingDatabaseRestore.acceptedLiveIdentityMatches(null, "1:2"))
        assertFalse(PendingDatabaseRestore.acceptedLiveIdentityMatches("1:2", null))
        assertFalse(PendingDatabaseRestore.acceptedLiveIdentityMatches("1:2", "1:3"))
        assertTrue(PendingDatabaseRestore.acceptedLiveIdentityMatches("1:2", "1:2"))
    }

    @Test fun stagedNoPriorDatabaseRunsTheRealMarkerAndAtomicMovePath() {
        val files = files("staged-no-prior")
        val candidate = sqlite(temporary.newFile("candidate.sqlite"), "replacement")

        PendingDatabaseRestore.stageFiles(files, candidate, settings = null)
        val stagedMarker = PendingDatabaseRestore.readMarker(files.marker)

        assertEquals(PendingDatabaseRestore.Phase.PENDING, stagedMarker?.phase)
        assertTrue(files.candidate.exists())
        val preparation = PendingDatabaseRestore.prepareAtColdOpenFiles(
            files = files,
            sqliteValid = ::validSqlite,
        )

        assertTrue(preparation.applied)
        assertFalse(preparation.hadPreviousDatabase)
        assertEquals(candidate.readBytes().toList(), files.db.readBytes().toList())
        assertFalse(files.candidate.exists())
        val appliedMarker = PendingDatabaseRestore.readMarker(files.marker)
        assertEquals(2, appliedMarker?.formatVersion)
        assertEquals(PendingDatabaseRestore.Phase.APPLIED, appliedMarker?.phase)
        assertEquals(false, appliedMarker?.hadPreviousDatabase)
    }

    @Test fun legacyApplyingMarkerUpgradesOnlyWhenRollbackFileProvesPriorDatabase() {
        val files = files("legacy-marker")
        sqlite(files.db, "replacement")
        sqlite(files.rollback, "previous")
        val replacementHash = sha256(files.db)
        files.marker.writeText(
            "version=1\n" +
                "phase=APPLYING\n" +
                "sha256=$replacementHash\n" +
                "settings=0\n",
        )

        val preparation = PendingDatabaseRestore.prepareAtColdOpenFiles(
            files = files,
            sqliteValid = ::validSqlite,
        )

        assertTrue(preparation.applied)
        assertTrue(preparation.hadPreviousDatabase)
        val upgraded = PendingDatabaseRestore.readMarker(files.marker)
        assertEquals(2, upgraded?.formatVersion)
        assertEquals(PendingDatabaseRestore.Phase.APPLIED, upgraded?.phase)
        assertEquals(true, upgraded?.hadPreviousDatabase)
        assertEquals(sha256(files.rollback), upgraded?.rollbackSha256)
    }

    @Test fun legacyApplyingWithoutPriorDatabaseResumesCandidateSwap() {
        val files = files("legacy-applying-no-prior")
        val candidate = sqlite(files.candidate, "replacement")
        val candidateBytes = candidate.readBytes()
        writeRawMarker(
            file = files.marker,
            version = 1,
            phase = PendingDatabaseRestore.Phase.APPLYING,
            hash = sha256(candidate),
        )

        val preparation = PendingDatabaseRestore.prepareAtColdOpenFiles(
            files = files,
            sqliteValid = ::validSqlite,
        )

        assertTrue(preparation.applied)
        assertFalse(preparation.hadPreviousDatabase)
        assertFalse(files.candidate.exists())
        assertEquals(candidateBytes.toList(), files.db.readBytes().toList())
        val upgraded = PendingDatabaseRestore.readMarker(files.marker)
        assertEquals(2, upgraded?.formatVersion)
        assertEquals(PendingDatabaseRestore.Phase.APPLIED, upgraded?.phase)
        assertEquals(false, upgraded?.hadPreviousDatabase)
    }

    @Test fun legacyAppliedWithoutPriorDatabaseAcceptsSwappedLiveDatabase() {
        val files = files("legacy-applied-no-prior")
        val live = sqlite(files.db, "replacement")
        writeRawMarker(
            file = files.marker,
            version = 1,
            phase = PendingDatabaseRestore.Phase.APPLIED,
            hash = sha256(live),
        )

        val preparation = PendingDatabaseRestore.prepareAtColdOpenFiles(
            files = files,
            sqliteValid = ::validSqlite,
        )

        assertTrue(preparation.applied)
        assertFalse(preparation.hadPreviousDatabase)
        val upgraded = PendingDatabaseRestore.readMarker(files.marker)
        assertEquals(2, upgraded?.formatVersion)
        assertEquals(PendingDatabaseRestore.Phase.APPLIED, upgraded?.phase)
        assertEquals(false, upgraded?.hadPreviousDatabase)
    }

    @Test fun legacyAppliedWithUnpersistedSwapReappliesCandidateWithoutPriorDatabase() {
        val files = files("legacy-applied-unpersisted-swap")
        val candidate = sqlite(files.candidate, "replacement")
        val candidateBytes = candidate.readBytes()
        writeRawMarker(
            file = files.marker,
            version = 1,
            phase = PendingDatabaseRestore.Phase.APPLIED,
            hash = sha256(candidate),
        )

        val preparation = PendingDatabaseRestore.prepareAtColdOpenFiles(
            files = files,
            sqliteValid = ::validSqlite,
        )

        assertTrue(preparation.applied)
        assertFalse(preparation.hadPreviousDatabase)
        assertFalse(files.candidate.exists())
        assertEquals(candidateBytes.toList(), files.db.readBytes().toList())
        assertEquals(
            PendingDatabaseRestore.Phase.APPLIED,
            PendingDatabaseRestore.readMarker(files.marker)?.phase,
        )
    }

    @Test fun legacyAppliedWithMigratedLiveDatabaseResumesIrreversibleFinalization() {
        val files = files("legacy-applied-migrated-live")
        val originalCandidate = sqlite(File(files.db.parentFile, "original-candidate"), "replacement")
        val live = sqlite(files.db, "replacement-after-room-migration")
        val rollback = sqlite(files.rollback, "previous")
        val settings = sqlite(files.settings, "restored-settings")
        val liveBytes = live.readBytes()
        val rollbackBytes = rollback.readBytes()
        writeRawMarker(
            file = files.marker,
            version = 1,
            phase = PendingDatabaseRestore.Phase.APPLIED,
            hash = sha256(originalCandidate),
            hasSettings = true,
        )

        val preparation = PendingDatabaseRestore.prepareAtColdOpenFiles(
            files = files,
            sqliteValid = ::validSqlite,
        )

        assertTrue(preparation.applied)
        assertTrue(preparation.hadPreviousDatabase)
        assertEquals(liveBytes.toList(), files.db.readBytes().toList())
        assertEquals(rollbackBytes.toList(), files.rollback.readBytes().toList())
        assertTrue(settings.exists())
        val upgraded = PendingDatabaseRestore.readMarker(files.marker)
        assertEquals(2, upgraded?.formatVersion)
        assertEquals(PendingDatabaseRestore.Phase.FINALIZING, upgraded?.phase)
        assertEquals(true, upgraded?.hadPreviousDatabase)
        assertEquals(sha256(files.rollback), upgraded?.rollbackSha256)
        assertEquals(files.identityOf(files.db), upgraded?.acceptedLiveFileIdentity)
    }

    @Test fun legacyAppliedWithInvalidModifiedLiveDatabaseDoesNotRollback() {
        val files = files("legacy-applied-invalid-live")
        val rollback = sqlite(files.rollback, "previous")
        files.db.writeText("not a sqlite database")
        val liveBytes = files.db.readBytes()
        val rollbackBytes = rollback.readBytes()
        writeRawMarker(
            file = files.marker,
            version = 1,
            phase = PendingDatabaseRestore.Phase.APPLIED,
            hash = "1".repeat(64),
        )

        val thrown = assertThrows(PendingDatabaseRestore.AcceptedLiveValidationException::class.java) {
            PendingDatabaseRestore.prepareAtColdOpenFiles(
                files = files,
                sqliteValid = ::validSqlite,
            )
        }

        assertEquals("live_invalid", thrown.failureKind)
        assertEquals(liveBytes.toList(), files.db.readBytes().toList())
        assertEquals(rollbackBytes.toList(), files.rollback.readBytes().toList())
        assertEquals(1, PendingDatabaseRestore.readMarker(files.marker)?.formatVersion)
    }

    @Test fun legacyAppliedWithCandidateAndModifiedLiveDatabaseRemainsFailClosed() {
        val files = files("legacy-applied-ambiguous-live")
        val candidate = sqlite(files.candidate, "replacement")
        val live = sqlite(files.db, "different-valid-live")
        val rollback = sqlite(files.rollback, "previous")
        val liveBytes = live.readBytes()
        val rollbackBytes = rollback.readBytes()
        writeRawMarker(
            file = files.marker,
            version = 1,
            phase = PendingDatabaseRestore.Phase.APPLIED,
            hash = sha256(candidate),
        )

        val thrown = assertThrows(PendingDatabaseRestore.RollbackValidationException::class.java) {
            PendingDatabaseRestore.prepareAtColdOpenFiles(
                files = files,
                sqliteValid = ::validSqlite,
            )
        }

        assertEquals(PendingDatabaseRestore.RollbackFailureKind.METADATA, thrown.failureKind)
        assertEquals(liveBytes.toList(), files.db.readBytes().toList())
        assertEquals(rollbackBytes.toList(), files.rollback.readBytes().toList())
        assertTrue(files.candidate.exists())
        assertEquals(1, PendingDatabaseRestore.readMarker(files.marker)?.formatVersion)
    }

    @Test fun legacyFinalizingWithAcceptedIdentityUpgradesWithoutRollback() {
        val files = files("legacy-finalizing")
        val live = sqlite(files.db, "replacement")
        val identity = files.identityOf(live)
        writeRawMarker(
            file = files.marker,
            version = 1,
            phase = PendingDatabaseRestore.Phase.FINALIZING,
            hash = sha256(live),
            hadPreviousDatabase = false,
            acceptedLiveFileIdentity = identity,
        )

        val preparation = PendingDatabaseRestore.prepareAtColdOpenFiles(
            files = files,
            sqliteValid = ::validSqlite,
        )

        assertTrue(preparation.applied)
        assertFalse(preparation.hadPreviousDatabase)
        val upgraded = PendingDatabaseRestore.readMarker(files.marker)
        assertEquals(2, upgraded?.formatVersion)
        assertEquals(PendingDatabaseRestore.Phase.FINALIZING, upgraded?.phase)
        assertEquals(identity, upgraded?.acceptedLiveFileIdentity)
    }

    @Test fun legacyExtendedAppliedMarkerPreservesRollbackContract() {
        val files = files("legacy-extended-applied")
        val live = sqlite(files.db, "replacement")
        val rollback = sqlite(files.rollback, "previous")
        writeRawMarker(
            file = files.marker,
            version = 1,
            phase = PendingDatabaseRestore.Phase.APPLIED,
            hash = sha256(live),
            hadPreviousDatabase = true,
            rollbackSha256 = sha256(rollback),
        )

        val preparation = PendingDatabaseRestore.prepareAtColdOpenFiles(
            files = files,
            sqliteValid = ::validSqlite,
        )

        assertTrue(preparation.applied)
        assertTrue(preparation.hadPreviousDatabase)
        val upgraded = PendingDatabaseRestore.readMarker(files.marker)
        assertEquals(2, upgraded?.formatVersion)
        assertEquals(true, upgraded?.hadPreviousDatabase)
        assertEquals(sha256(rollback), upgraded?.rollbackSha256)
    }

    @Test fun legacyFinalizingIdentityMismatchRemainsFailClosed() {
        val files = files("legacy-finalizing-mismatch")
        val live = sqlite(files.db, "replacement")
        val liveBytes = live.readBytes()
        writeRawMarker(
            file = files.marker,
            version = 1,
            phase = PendingDatabaseRestore.Phase.FINALIZING,
            hash = sha256(live),
            hadPreviousDatabase = false,
            acceptedLiveFileIdentity = "0:0",
        )

        val thrown = assertThrows(PendingDatabaseRestore.AcceptedLiveValidationException::class.java) {
            PendingDatabaseRestore.prepareAtColdOpenFiles(
                files = files,
                sqliteValid = ::validSqlite,
            )
        }

        assertEquals("live_identity", thrown.failureKind)
        assertEquals(liveBytes.toList(), files.db.readBytes().toList())
        assertEquals(1, PendingDatabaseRestore.readMarker(files.marker)?.formatVersion)
    }

    @Test fun originalLegacyCommittedMarkerUpgradesAndCompletesCleanup() {
        val files = files("legacy-committed")
        val live = sqlite(files.db, "accepted")
        sqlite(files.rollback, "previous")
        sqlite(files.candidate, "staged")
        sqlite(files.settings, "settings")
        writeRawMarker(
            file = files.marker,
            version = 1,
            phase = PendingDatabaseRestore.Phase.COMMITTED,
            hash = sha256(live),
            hasSettings = true,
        )

        val preparation = PendingDatabaseRestore.prepareAtColdOpenFiles(
            files = files,
            sqliteValid = ::validSqlite,
        )

        assertFalse(preparation.applied)
        assertTrue(files.db.exists())
        assertFalse(files.rollback.exists())
        assertFalse(files.candidate.exists())
        assertFalse(files.settings.exists())
        assertFalse(files.marker.exists())
    }

    @Test fun malformedV2AppliedAndCommittedMarkersRemainFailClosed() {
        val appliedFiles = files("malformed-v2-applied")
        val appliedLive = sqlite(appliedFiles.db, "replacement")
        val appliedBytes = appliedLive.readBytes()
        writeRawMarker(
            file = appliedFiles.marker,
            version = 2,
            phase = PendingDatabaseRestore.Phase.APPLIED,
            hash = sha256(appliedLive),
        )

        assertThrows(IOException::class.java) {
            PendingDatabaseRestore.prepareAtColdOpenFiles(
                files = appliedFiles,
                sqliteValid = ::validSqlite,
            )
        }
        assertTrue(appliedFiles.marker.exists())
        assertEquals(appliedBytes.toList(), appliedFiles.db.readBytes().toList())

        val committedFiles = files("malformed-v2-committed")
        val committedLive = sqlite(committedFiles.db, "accepted")
        writeRawMarker(
            file = committedFiles.marker,
            version = 2,
            phase = PendingDatabaseRestore.Phase.COMMITTED,
            hash = sha256(committedLive),
            hadPreviousDatabase = false,
        )

        assertThrows(IOException::class.java) {
            PendingDatabaseRestore.prepareAtColdOpenFiles(
                files = committedFiles,
                sqliteValid = ::validSqlite,
            )
        }
        assertTrue(committedFiles.marker.exists())
        assertTrue(committedFiles.db.exists())
    }

    @Test fun busyWalCheckpointRetainsLiveDatabaseAndPendingRestoreState() {
        assertCheckpointFailureRetainsState(
            name = "checkpoint-busy",
            result = PendingDatabaseRestore.WalCheckpointResult(
                busy = 1,
                logFrames = 4,
                checkpointedFrames = 4,
            ),
        )
    }

    @Test fun incompleteWalCheckpointRetainsLiveDatabaseAndPendingRestoreState() {
        assertCheckpointFailureRetainsState(
            name = "checkpoint-incomplete",
            result = PendingDatabaseRestore.WalCheckpointResult(
                busy = 0,
                logFrames = 4,
                checkpointedFrames = 3,
            ),
        )
    }

    @Test fun parentDirectoryFsyncFailureAfterDatabaseRenameResumesFromApplying() {
        val files = files("database-rename-fsync")
        val candidate = sqlite(temporary.newFile("fsync-candidate.sqlite"), "replacement")
        val candidateBytes = candidate.readBytes()
        PendingDatabaseRestore.stageFiles(files, candidate, settings = null)
        val failingFiles = files.copy(
            syncParentDirectory = { renamed ->
                if (renamed == files.db) {
                    throw IOException("injected directory fsync failure")
                }
            },
        )

        assertThrows(IOException::class.java) {
            PendingDatabaseRestore.prepareAtColdOpenFiles(
                files = failingFiles,
                sqliteValid = ::validSqlite,
            )
        }

        assertFalse(files.candidate.exists())
        assertEquals(candidateBytes.toList(), files.db.readBytes().toList())
        val interrupted = PendingDatabaseRestore.readMarker(files.marker)
        assertEquals(2, interrupted?.formatVersion)
        assertEquals(PendingDatabaseRestore.Phase.APPLYING, interrupted?.phase)
        assertEquals(false, interrupted?.hadPreviousDatabase)

        val resumed = PendingDatabaseRestore.prepareAtColdOpenFiles(
            files = files,
            sqliteValid = ::validSqlite,
        )

        assertTrue(resumed.applied)
        assertFalse(resumed.hadPreviousDatabase)
        val completed = PendingDatabaseRestore.readMarker(files.marker)
        assertEquals(PendingDatabaseRestore.Phase.APPLIED, completed?.phase)
        assertEquals(candidateBytes.toList(), files.db.readBytes().toList())
    }

    private fun assertCheckpointFailureRetainsState(
        name: String,
        result: PendingDatabaseRestore.WalCheckpointResult,
    ) {
        val files = files(name)
        val liveBytes = sqlite(files.db, "previous").readBytes()
        val wal = File(files.db.path + "-wal").apply { writeBytes(byteArrayOf(1, 2, 3, 4)) }
        val shm = File(files.db.path + "-shm").apply { writeBytes(byteArrayOf(5, 6, 7, 8)) }
        val walBytes = wal.readBytes()
        val shmBytes = shm.readBytes()
        val candidate = sqlite(temporary.newFile("$name-candidate.sqlite"), "replacement")
        PendingDatabaseRestore.stageFiles(files, candidate, settings = null)
        val markerBytes = files.marker.readBytes()
        val failingFiles = files.copy(checkpointWal = { result })

        val thrown = assertThrows(PendingDatabaseRestore.RollbackValidationException::class.java) {
            PendingDatabaseRestore.prepareAtColdOpenFiles(
                files = failingFiles,
                sqliteValid = ::validSqlite,
            )
        }

        assertEquals(PendingDatabaseRestore.RollbackFailureKind.LIVE_RESTORE, thrown.failureKind)
        assertEquals(liveBytes.toList(), files.db.readBytes().toList())
        assertEquals(walBytes.toList(), wal.readBytes().toList())
        assertEquals(shmBytes.toList(), shm.readBytes().toList())
        assertTrue(files.candidate.exists())
        assertFalse(files.rollback.exists())
        assertEquals(markerBytes.toList(), files.marker.readBytes().toList())
        assertEquals(
            PendingDatabaseRestore.Phase.PENDING,
            PendingDatabaseRestore.readMarker(files.marker)?.phase,
        )
    }

    @Test fun invalidRollbackEvidenceCannotReplaceTheExistingLiveDatabase() {
        val files = files("invalid-rollback")
        val previousBytes = sqlite(files.db, "previous").readBytes()
        sqlite(files.candidate, "replacement")
        sqlite(files.rollback, "previous")
        PendingDatabaseRestore.writeMarker(
            files.marker,
            PendingDatabaseRestore.Marker(
                phase = PendingDatabaseRestore.Phase.APPLYING,
                sha256 = sha256(files.candidate),
                hasSettings = false,
                hadPreviousDatabase = true,
                rollbackSha256 = "0".repeat(64),
            ),
        )

        val thrown = assertThrows(PendingDatabaseRestore.RollbackValidationException::class.java) {
            PendingDatabaseRestore.prepareAtColdOpenFiles(
                files = files,
                sqliteValid = ::validSqlite,
            )
        }

        assertEquals(PendingDatabaseRestore.RollbackFailureKind.ROLLBACK_CHECKSUM, thrown.failureKind)
        assertEquals(previousBytes.toList(), files.db.readBytes().toList())
        assertTrue(files.candidate.exists())
        assertTrue(files.marker.exists())
    }

    @Test fun rollingBackMarkerResumesAfterRollbackWasAlreadyMovedIntoPlace() {
        val files = files("rollback-restart")
        val restoredBytes = sqlite(files.db, "previous").readBytes()
        sqlite(files.candidate, "replacement")
        sqlite(files.settings, "settings")
        val restoredHash = sha256(files.db)
        PendingDatabaseRestore.writeMarker(
            files.marker,
            PendingDatabaseRestore.Marker(
                phase = PendingDatabaseRestore.Phase.ROLLING_BACK,
                sha256 = sha256(files.candidate),
                hasSettings = true,
                hadPreviousDatabase = true,
                rollbackSha256 = restoredHash,
            ),
        )

        assertTrue(
            PendingDatabaseRestore.rollbackAfterOpenFailureFiles(
                files = files,
                sqliteValid = ::validSqlite,
            ),
        )
        assertEquals(restoredBytes.toList(), files.db.readBytes().toList())
        assertFalse(files.rollback.exists())
        assertFalse(files.candidate.exists())
        assertFalse(files.settings.exists())
        assertFalse(files.marker.exists())
    }

    @Test fun rollbackMovesVerifiedPreviousDatabaseBackBeforeMarkerLastCleanup() {
        val files = files("rollback-move")
        sqlite(files.db, "replacement")
        val previousBytes = sqlite(files.rollback, "previous").readBytes()
        sqlite(files.candidate, "staged")
        sqlite(files.settings, "settings")
        val rollbackHash = sha256(files.rollback)
        PendingDatabaseRestore.writeMarker(
            files.marker,
            PendingDatabaseRestore.Marker(
                phase = PendingDatabaseRestore.Phase.ROLLING_BACK,
                sha256 = sha256(files.db),
                hasSettings = true,
                hadPreviousDatabase = true,
                rollbackSha256 = rollbackHash,
            ),
        )

        assertTrue(
            PendingDatabaseRestore.rollbackAfterOpenFailureFiles(
                files = files,
                sqliteValid = ::validSqlite,
            ),
        )
        assertEquals(previousBytes.toList(), files.db.readBytes().toList())
        assertFalse(files.rollback.exists())
        assertFalse(files.marker.exists())
    }

    @Test fun noPriorDatabaseRollbackDeletesReplacementAndAllRecoveryArtifacts() {
        val files = files("rollback-no-prior")
        sqlite(files.db, "replacement")
        sqlite(files.candidate, "staged")
        sqlite(files.settings, "settings")
        PendingDatabaseRestore.writeMarker(
            files.marker,
            PendingDatabaseRestore.Marker(
                phase = PendingDatabaseRestore.Phase.ROLLING_BACK,
                sha256 = sha256(files.db),
                hasSettings = true,
                hadPreviousDatabase = false,
                rollbackSha256 = null,
            ),
        )

        assertTrue(
            PendingDatabaseRestore.rollbackAfterOpenFailureFiles(
                files = files,
                sqliteValid = ::validSqlite,
            ),
        )
        assertFalse(files.db.exists())
        assertFalse(files.candidate.exists())
        assertFalse(files.settings.exists())
        assertFalse(files.marker.exists())
    }

    @Test fun committedMarkerCleansRecoveryArtifactsOnlyAfterLiveFileVerification() {
        val files = files("committed-cleanup")
        sqlite(files.db, "accepted")
        sqlite(files.rollback, "previous")
        sqlite(files.candidate, "staged")
        sqlite(files.settings, "settings")
        PendingDatabaseRestore.writeMarker(
            files.marker,
            PendingDatabaseRestore.Marker(
                phase = PendingDatabaseRestore.Phase.COMMITTED,
                sha256 = sha256(files.db),
                hasSettings = true,
                hadPreviousDatabase = true,
                rollbackSha256 = sha256(files.rollback),
                acceptedLiveFileIdentity = files.identityOf(files.db),
            ),
        )

        val preparation = PendingDatabaseRestore.prepareAtColdOpenFiles(
            files = files,
            sqliteValid = ::validSqlite,
        )

        assertFalse(preparation.applied)
        assertTrue(files.db.exists())
        assertFalse(files.rollback.exists())
        assertFalse(files.candidate.exists())
        assertFalse(files.settings.exists())
        assertFalse(files.marker.exists())
    }

    @Test fun databaseOnlyRestoreClearsDerivedPlannerStateAfterConfirmedOpen() {
        val prefs = FakeSharedPreferences(commitResults = listOf(true, false))
        prefs.edit()
            .putInt(BackupSettingsCodec.LEGACY_RECOVERY_MINUTES_KEY, 45)
            .apply()

        BackupSettingsBridge.applyRestoreValuesDurably(
            restoreTargets(windDown = prefs),
            emptyMap(),
        )

        assertFalse(prefs.contains(BackupSettingsCodec.LEGACY_RECOVERY_MINUTES_KEY))
    }

    @Test fun settingsRestoreClearsDerivedStateBeforeUnknownOnlyPayloadNoOp() {
        val prefs = FakeSharedPreferences(commitResults = listOf(true, false))
        prefs.edit()
            .putInt(BackupSettingsCodec.LEGACY_RECOVERY_MINUTES_KEY, 45)
            .apply()
        val decoded = BackupSettingsCodec.decode("""{"unknown.setting":true}""")

        BackupSettingsBridge.applyRestoreValuesDurably(
            restoreTargets(windDown = prefs),
            decoded,
        )

        assertTrue(decoded.isEmpty())
        assertFalse(prefs.contains(BackupSettingsCodec.LEGACY_RECOVERY_MINUTES_KEY))
    }

    @Test fun declaredSettingsRestoreFailsBeforeChangingPreferencesWhenPayloadIsMissing() {
        val events = mutableListOf<String>()

        assertThrows(IOException::class.java) {
            PendingDatabaseRestore.completeConfirmedRestore(
                hasSettings = true,
                settingsExists = false,
                persistFinalizing = { events += "finalizing" },
                persistPreferences = { events += "persist" },
                reconcile = { events += "reconcile" },
                persistCompletion = { events += "completion" },
                persistAccepted = { events += "accepted" },
                cleanup = {
                    events += "cleanup"
                    true
                },
            )
        }

        assertTrue(events.isEmpty())
    }

    @Test fun settingsPayloadMustBeReadableBeforeFinalizingBecomesDurable() {
        val events = mutableListOf<String>()
        val readFailure = IOException("unreadable")

        val thrown = assertThrows(PendingDatabaseRestore.SettingsPreparationException::class.java) {
            val payload = PendingDatabaseRestore.prepareSettingsPayload(
                phase = PendingDatabaseRestore.Phase.APPLIED,
                hasSettings = true,
                settingsExists = true,
                readText = {
                    events += "read"
                    throw readFailure
                },
            )
            PendingDatabaseRestore.completeConfirmedRestore(
                hasSettings = true,
                settingsExists = true,
                persistFinalizing = { events += "finalizing" },
                persistPreferences = {
                    events += "persist"
                    assertEquals(payload, "never")
                },
                reconcile = { events += "reconcile" },
                persistCompletion = { events += "completion" },
                persistAccepted = { events += "accepted" },
                cleanup = {
                    events += "cleanup"
                    true
                },
            )
        }

        assertEquals("settings_unreadable", thrown.failureKind)
        assertEquals(listOf("read"), events)
    }

    @Test fun unreadableSettingsAfterFinalizingRemainRetryableWithoutRollback() {
        val thrown = assertThrows(PendingDatabaseRestore.FinalizationPendingException::class.java) {
            PendingDatabaseRestore.prepareSettingsPayload(
                phase = PendingDatabaseRestore.Phase.FINALIZING,
                hasSettings = true,
                settingsExists = true,
                readText = { throw IOException("unreadable") },
            )
        }

        assertEquals("settings_unreadable", thrown.failureKind)
    }

    @Test fun failedCommitAbortsAcrossProcessBoundaryAndPreservesRollbackCleanup() {
        val noop = FakeSharedPreferences(
            commitResult = false,
            applyFailedCommitsToMemory = true,
        )
        val events = mutableListOf<String>()

        assertThrows(IOException::class.java) {
            PendingDatabaseRestore.completeConfirmedRestore(
                hasSettings = true,
                settingsExists = true,
                persistFinalizing = { events += "finalizing" },
                persistPreferences = {
                    events += "persist"
                    BackupSettingsBridge.applyRestoreValuesDurably(
                        restoreTargets(noop = noop),
                        mapOf("units.system" to "metric"),
                    )
                },
                reconcile = { events += "reconcile" },
                persistCompletion = { events += "completion" },
                persistAccepted = { events += "accepted" },
                cleanup = {
                    events += "cleanup"
                    true
                },
            )
        }

        // A failed SharedPreferences commit may already be visible in this process. It is still not
        // durable, so the restore must fail and leave the database rollback/staging files untouched.
        assertEquals("metric", noop.getString("units.system", null))
        assertEquals(listOf("finalizing", "persist"), events)
    }

    @Test fun finalizingMarkerMustPersistBeforeAnyPreferenceWrite() {
        val events = mutableListOf<String>()
        val expected = IOException("marker write failed")

        val thrown = assertThrows(IOException::class.java) {
            PendingDatabaseRestore.completeConfirmedRestore(
                hasSettings = true,
                settingsExists = true,
                persistFinalizing = {
                    events += "finalizing"
                    throw expected
                },
                persistPreferences = { events += "persist" },
                reconcile = { events += "reconcile" },
                persistCompletion = { events += "completion" },
                persistAccepted = { events += "accepted" },
                cleanup = {
                    events += "cleanup"
                    true
                },
            )
        }

        assertSame(expected, thrown)
        assertEquals(listOf("finalizing"), events)
    }

    @Test fun successfulRestoreCleansUpOnlyAfterDurabilityAndReconciliation() {
        val events = mutableListOf<String>()

        PendingDatabaseRestore.completeConfirmedRestore(
            hasSettings = true,
            settingsExists = true,
            persistFinalizing = { events += "finalizing" },
            persistPreferences = { events += "persist" },
            reconcile = {
                assertEquals(listOf("finalizing", "persist"), events)
                events += "reconcile"
            },
            persistCompletion = {
                assertEquals(listOf("finalizing", "persist", "reconcile"), events)
                events += "completion"
            },
            persistAccepted = {
                assertEquals(
                    listOf("finalizing", "persist", "reconcile", "completion"),
                    events,
                )
                events += "accepted"
            },
            cleanup = {
                assertEquals(
                    listOf("finalizing", "persist", "reconcile", "completion", "accepted"),
                    events,
                )
                events += "cleanup"
                true
            },
        )

        assertEquals(
            listOf("finalizing", "persist", "reconcile", "completion", "accepted", "cleanup"),
            events,
        )
    }

    @Test fun reconciliationFailurePropagatesBeforeCompletionOrCleanup() {
        val expected = IllegalStateException("reconcile failed")
        val events = mutableListOf<String>()

        val thrown = assertThrows(IllegalStateException::class.java) {
            PendingDatabaseRestore.completeConfirmedRestore(
                hasSettings = true,
                settingsExists = true,
                persistFinalizing = { events += "finalizing" },
                persistPreferences = { events += "persist" },
                reconcile = {
                    events += "reconcile"
                    throw expected
                },
                persistCompletion = { events += "completion" },
                persistAccepted = { events += "accepted" },
                cleanup = {
                    events += "cleanup"
                    true
                },
            )
        }

        assertSame(expected, thrown)
        assertEquals(listOf("finalizing", "persist", "reconcile"), events)
    }

    @Test fun durableFinalizationPhaseControlsRollbackForEveryThrowableKind() {
        val failure = PendingDatabaseRestore.FinalizationPendingException(
            failureKind = "preferences_commit",
            cause = IOException("commit failed"),
        )

        assertFalse(
            PendingDatabaseRestore.shouldRollbackDatabaseAfterOpenFailure(
                PendingDatabaseRestore.Phase.FINALIZING,
                failure,
            ),
        )
        assertFalse(
            PendingDatabaseRestore.shouldRollbackDatabaseAfterOpenFailure(
                PendingDatabaseRestore.Phase.FINALIZING,
                AssertionError("fatal after preference commit"),
            ),
        )
        assertFalse(
            PendingDatabaseRestore.shouldRollbackDatabaseAfterOpenFailure(
                PendingDatabaseRestore.Phase.COMMITTED,
                IOException("cleanup failed"),
            ),
        )
        assertTrue(
            PendingDatabaseRestore.shouldRollbackDatabaseAfterOpenFailure(
                PendingDatabaseRestore.Phase.APPLIED,
                failure,
            ),
        )
        assertTrue(
            PendingDatabaseRestore.shouldRollbackDatabaseAfterOpenFailure(
                PendingDatabaseRestore.Phase.APPLYING,
                IOException("Room open failed"),
            ),
        )
    }

    @Test fun acceptedCleanupDeletesRollbackFirstAndMarkerLast() {
        val events = mutableListOf<String>()

        val complete = PendingDatabaseRestore.cleanupCommittedRestore(
            deleteRollback = {
                events += "rollback"
                true
            },
            deleteCandidate = {
                events += "candidate"
                true
            },
            deleteSettings = {
                events += "settings"
                true
            },
            deleteMarker = {
                events += "marker"
                true
            },
        )

        assertTrue(complete)
        assertEquals(listOf("rollback", "candidate", "settings", "marker"), events)
    }

    @Test fun failedAcceptedCleanupLeavesMarkerForNextColdOpen() {
        val events = mutableListOf<String>()

        val complete = PendingDatabaseRestore.cleanupCommittedRestore(
            deleteRollback = {
                events += "rollback"
                false
            },
            deleteCandidate = {
                events += "candidate"
                true
            },
            deleteSettings = {
                events += "settings"
                true
            },
            deleteMarker = {
                events += "marker"
                true
            },
        )

        assertFalse(complete)
        assertEquals(listOf("rollback"), events)
    }

    @Test fun acceptedMarkerPersistsEvenWhenCleanupMustRetry() {
        val events = mutableListOf<String>()

        val cleanupComplete = PendingDatabaseRestore.completeConfirmedRestore(
            hasSettings = true,
            settingsExists = true,
            persistFinalizing = { events += "finalizing" },
            persistPreferences = { events += "persist" },
            reconcile = { events += "reconcile" },
            persistCompletion = { events += "completion" },
            persistAccepted = { events += "accepted" },
            cleanup = {
                events += "cleanup"
                false
            },
        )

        assertFalse(cleanupComplete)
        assertEquals(
            listOf("finalizing", "persist", "reconcile", "completion", "accepted", "cleanup"),
            events,
        )
    }

    @Test fun rolledBackCleanupDeletesMarkerLast() {
        val events = mutableListOf<String>()

        val complete = PendingDatabaseRestore.cleanupRolledBackRestore(
            deleteCandidate = {
                events += "candidate"
                true
            },
            deleteSettings = {
                events += "settings"
                true
            },
            deleteRollback = {
                events += "rollback"
                true
            },
            deleteMarker = {
                events += "marker"
                true
            },
        )

        assertTrue(complete)
        assertEquals(listOf("candidate", "settings", "rollback", "marker"), events)
    }

    @Test fun failedRolledBackCleanupPreservesDurableMarker() {
        val events = mutableListOf<String>()

        val complete = PendingDatabaseRestore.cleanupRolledBackRestore(
            deleteCandidate = {
                events += "candidate"
                true
            },
            deleteSettings = {
                events += "settings"
                false
            },
            deleteRollback = {
                events += "rollback"
                true
            },
            deleteMarker = {
                events += "marker"
                true
            },
        )

        assertFalse(complete)
        assertEquals(listOf("candidate", "settings"), events)
    }

    @Test fun rollbackDiagnosticsUseOnlyBoundedFixedCategories() {
        assertEquals(
            listOf(
                "phase",
                "metadata",
                "marker",
                "rollback_missing",
                "rollback_checksum",
                "rollback_invalid",
                "live_restore",
                "live_invalid",
                "rolled_back_marker",
                "terminal_state",
            ),
            PendingDatabaseRestore.RollbackFailureKind.entries.map { it.wireValue },
        )
        assertTrue(
            PendingDatabaseRestore.RollbackFailureKind.entries.all {
                it.wireValue.matches(Regex("[a-z_]+"))
            },
        )
    }
}
