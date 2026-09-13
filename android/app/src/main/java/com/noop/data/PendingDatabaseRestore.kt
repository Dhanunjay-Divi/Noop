package com.noop.data

import android.content.Context
import android.database.sqlite.SQLiteDatabase
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.util.Properties

/**
 * Crash-safe restore gate. Import only stages a candidate beside the Room database. The candidate is
 * swapped at the next cold database open, with the previous database retained until Room has opened
 * and migrated the replacement successfully. A killed process resumes from the durable phase marker.
 */
object PendingDatabaseRestore {
    private const val LEGACY_MARKER_VERSION = 1
    private const val CURRENT_MARKER_VERSION = 2
    private const val PENDING_SUFFIX = ".restore-candidate"
    private const val SETTINGS_SUFFIX = ".restore-settings"
    private const val ROLLBACK_SUFFIX = ".restore-rollback"
    private const val MARKER_SUFFIX = ".restore-state"

    enum class Phase {
        PENDING,
        APPLYING,
        APPLIED,
        FINALIZING,
        COMMITTED,
        ROLLING_BACK,
        ROLLED_BACK,
    }
    data class Preparation(
        val applied: Boolean,
        val hadPreviousDatabase: Boolean,
        /** Guards against a corruption callback silently replacing the candidate with a fresh DB. */
        val liveFileIdentity: String? = null,
    )

    internal data class WalCheckpointResult(
        val busy: Int,
        val logFrames: Long,
        val checkpointedFrames: Long,
    ) {
        val complete: Boolean
            get() = busy == 0 && checkpointedFrames == logFrames
    }

    internal enum class ResumeAction {
        APPLY_CANDIDATE,
        ACCEPT_LIVE,
        CLEANUP_COMMITTED,
        CLEANUP_ROLLED_BACK,
        ROLLBACK,
        NONE,
    }

    internal enum class RollbackFailureKind(val wireValue: String) {
        PHASE("phase"),
        METADATA("metadata"),
        MARKER("marker"),
        ROLLBACK_MISSING("rollback_missing"),
        ROLLBACK_CHECKSUM("rollback_checksum"),
        ROLLBACK_INVALID("rollback_invalid"),
        LIVE_RESTORE("live_restore"),
        LIVE_INVALID("live_invalid"),
        ROLLED_BACK_MARKER("rolled_back_marker"),
        TERMINAL_STATE("terminal_state"),
    }

    /** Fixed-category finalization failure; the durable marker phase remains the rollback authority. */
    internal class FinalizationPendingException(
        val failureKind: String,
        cause: Throwable,
    ) : IOException("Restore finalization remains pending.", cause)

    internal class SettingsPreparationException(
        val failureKind: String,
        cause: Throwable,
    ) : IOException("Staged restore settings could not be prepared.", cause)

    internal class RollbackValidationException(
        val failureKind: RollbackFailureKind,
        cause: Throwable,
    ) : IOException("Restore rollback evidence could not be verified.", cause)

    internal class AcceptedLiveValidationException(
        val failureKind: String,
        cause: Throwable,
    ) : IOException("The accepted restore database could not be verified.", cause)

    internal fun resumeAction(
        phase: Phase?,
        candidateExists: Boolean,
        liveExists: Boolean,
        liveMatchesCandidate: Boolean,
        rollbackExists: Boolean,
        hadPreviousDatabase: Boolean?,
    ): ResumeAction = when (phase) {
        Phase.PENDING -> if (candidateExists) ResumeAction.APPLY_CANDIDATE else ResumeAction.NONE
        Phase.APPLYING -> when {
            liveMatchesCandidate && canAcceptLive(hadPreviousDatabase, rollbackExists) ->
                ResumeAction.ACCEPT_LIVE
            candidateExists && canApplyCandidate(
                hadPreviousDatabase = hadPreviousDatabase,
                rollbackExists = rollbackExists,
                liveExists = liveExists,
            ) -> ResumeAction.APPLY_CANDIDATE
            canRollback(hadPreviousDatabase, rollbackExists) -> ResumeAction.ROLLBACK
            else -> ResumeAction.NONE
        }
        Phase.APPLIED -> if (
            liveMatchesCandidate && canAcceptLive(hadPreviousDatabase, rollbackExists)
        ) {
            ResumeAction.ACCEPT_LIVE
        } else if (canRollback(hadPreviousDatabase, rollbackExists)) {
            ResumeAction.ROLLBACK
        } else {
            ResumeAction.NONE
        }
        Phase.FINALIZING -> if (liveExists) ResumeAction.ACCEPT_LIVE else ResumeAction.NONE
        Phase.COMMITTED -> if (liveExists) ResumeAction.CLEANUP_COMMITTED else ResumeAction.NONE
        Phase.ROLLING_BACK -> ResumeAction.ROLLBACK
        Phase.ROLLED_BACK -> when (hadPreviousDatabase) {
            true -> if (liveExists) ResumeAction.CLEANUP_ROLLED_BACK else ResumeAction.NONE
            false -> if (!liveExists) ResumeAction.CLEANUP_ROLLED_BACK else ResumeAction.NONE
            null -> ResumeAction.NONE
        }
        null -> ResumeAction.NONE
    }

    private fun canAcceptLive(
        hadPreviousDatabase: Boolean?,
        rollbackExists: Boolean,
    ): Boolean = when (hadPreviousDatabase) {
        true -> rollbackExists
        false -> !rollbackExists
        null -> rollbackExists
    }

    private fun canApplyCandidate(
        hadPreviousDatabase: Boolean?,
        rollbackExists: Boolean,
        liveExists: Boolean,
    ): Boolean = when (hadPreviousDatabase) {
        true -> rollbackExists
        false -> !rollbackExists && !liveExists
        // A legacy APPLYING marker may still have the untouched previous live database. It can be
        // checkpointed and preserved before the swap; absence of both files remains ambiguous.
        null -> rollbackExists || liveExists
    }

    private fun canRollback(
        hadPreviousDatabase: Boolean?,
        rollbackExists: Boolean,
    ): Boolean = when (hadPreviousDatabase) {
        true -> rollbackExists
        false -> !rollbackExists
        null -> rollbackExists
    }

    internal fun terminalCleanupAllowed(
        phase: Phase,
        hadPreviousDatabase: Boolean?,
        liveExists: Boolean,
        liveMatchesRollback: Boolean,
        liveSqliteValid: Boolean,
    ): Boolean = when (phase) {
        Phase.COMMITTED -> liveExists && liveSqliteValid
        Phase.ROLLED_BACK -> when (hadPreviousDatabase) {
            true -> liveExists && liveMatchesRollback && liveSqliteValid
            false -> !liveExists
            null -> false
        }
        else -> false
    }

    internal fun prepareSettingsPayload(
        phase: Phase,
        hasSettings: Boolean,
        settingsExists: Boolean,
        readText: () -> String,
    ): String? {
        if (!hasSettings) return null
        if (!settingsExists) {
            val failure = SettingsPreparationException(
                failureKind = "settings_missing",
                cause = IOException("Staged restore settings are missing."),
            )
            if (phase == Phase.FINALIZING) {
                throw FinalizationPendingException(failure.failureKind, failure)
            }
            throw failure
        }
        return try {
            readText()
        } catch (failure: FinalizationPendingException) {
            throw failure
        } catch (failure: Exception) {
            val prepared = SettingsPreparationException(
                failureKind = "settings_unreadable",
                cause = failure,
            )
            if (phase == Phase.FINALIZING) {
                throw FinalizationPendingException(prepared.failureKind, prepared)
            }
            throw prepared
        }
    }

    internal fun shouldRollbackDatabaseAfterOpenFailure(
        phase: Phase?,
        @Suppress("UNUSED_PARAMETER") failure: Throwable,
    ): Boolean = phase != Phase.FINALIZING && phase != Phase.COMMITTED

    internal fun shouldRollbackDatabaseAfterOpenFailure(
        context: Context,
        failure: Throwable,
    ): Boolean = shouldRollbackDatabaseAfterOpenFailure(
        readMarker(Fileset(context).marker)?.phase,
        failure,
    )

    @Synchronized
    @Throws(IOException::class)
    fun stage(context: Context, candidate: File, settings: File?) {
        stageFiles(Fileset(context), candidate, settings)
    }

    internal fun stageFiles(files: Fileset, candidate: File, settings: File?) {
        if (!DataBackup.isValidSqliteHeader(candidate)) throw IOException("Restore candidate is not SQLite.")
        files.db.parentFile?.mkdirs()
        // Invalidate an older still-PENDING marker before replacing its candidate. Otherwise a crash
        // between candidate publication and marker publication could leave the old hash pointing at
        // new bytes and turn the next launch into a false corruption failure.
        if (files.marker.exists()) {
            val existing = readMarker(files.marker)
                ?: throw IOException("An unreadable restore marker already exists; current data was not changed.")
            if (existing.phase != Phase.PENDING) {
                throw IOException("A restore is already being applied; restart NOOP before choosing another backup.")
            }
            if (!files.marker.delete()) throw IOException("Could not replace the pending restore marker.")
        }
        // A second pending import replaces only the unapplied candidate, never the live/rollback store.
        atomicCopy(candidate, files.candidate, files.syncParentDirectory)
        if (settings?.exists() == true) {
            atomicCopy(settings, files.settings, files.syncParentDirectory)
        } else if (files.settings.exists() && !files.settings.delete()) {
            throw IOException("Could not clear settings from the previous pending restore.")
        }
        val marker = Marker(Phase.PENDING, sha256(files.candidate), files.settings.exists())
        writeMarker(files.marker, marker, files.syncParentDirectory)
    }

    /** Called only while [WhoopDatabase]'s singleton lock is held and before Room is built. */
    @Synchronized
    @Throws(IOException::class)
    fun prepareAtColdOpen(context: Context): Preparation {
        return prepareAtColdOpenFiles(Fileset(context), ::isUsableSqlite)
    }

    internal fun prepareAtColdOpenFiles(
        files: Fileset,
        sqliteValid: (File) -> Boolean,
    ): Preparation {
        if (!files.marker.exists()) {
            // Orphans can only come from a killed/failed stage before the marker's atomic publish.
            files.candidate.delete()
            files.settings.delete()
            files.rollback.delete()
            return Preparation(false, files.db.exists())
        }
        val parsedMarker = readMarker(files.marker)
            ?: throw IOException("The pending restore state is unreadable; current data was not changed.")
        val marker = if (parsedMarker.formatVersion == LEGACY_MARKER_VERSION) {
            try {
                migrateLegacyMarker(files, parsedMarker, sqliteValid)
            } catch (failure: AcceptedLiveValidationException) {
                recordAcceptedLiveFailure(failure)
                throw failure
            } catch (failure: RollbackValidationException) {
                recordRollbackFailure(failure.failureKind)
                throw failure
            } catch (failure: IOException) {
                recordRollbackFailure(resumeFailureKind(parsedMarker, files))
                throw failure
            }
        } else {
            parsedMarker
        }
        val liveMatches = files.db.exists() && runCatching { sha256(files.db) == marker.sha256 }.getOrDefault(false)
        return when (
            resumeAction(
                phase = marker.phase,
                candidateExists = files.candidate.exists(),
                liveExists = files.db.exists(),
                liveMatchesCandidate = liveMatches,
                rollbackExists = files.rollback.exists(),
                hadPreviousDatabase = marker.hadPreviousDatabase,
            )
        ) {
            ResumeAction.NONE -> {
                if (marker.phase != Phase.PENDING) {
                    recordRollbackFailure(resumeFailureKind(marker, files))
                    throw IOException("A prior restore is incomplete and cannot be resumed safely.")
                }
                cleanupStaging(files, keepRollback = false)
                Preparation(applied = false, hadPreviousDatabase = files.db.exists())
            }
            ResumeAction.ROLLBACK -> {
                if (!rollbackFiles(files, marker, sqliteValid)) {
                    throw IOException("A prior restore was interrupted and the previous database could not be restored.")
                }
                Preparation(false, files.db.exists())
            }
            ResumeAction.CLEANUP_COMMITTED -> {
                requireTerminalCleanupState(files, marker, sqliteValid)
                recordCommittedCleanup(cleanupCommitted(files))
                Preparation(applied = false, hadPreviousDatabase = files.db.exists())
            }
            ResumeAction.CLEANUP_ROLLED_BACK -> {
                requireTerminalCleanupState(files, marker, sqliteValid)
                recordRolledBackCleanup(cleanupRolledBack(files))
                Preparation(applied = false, hadPreviousDatabase = files.db.exists())
            }
            ResumeAction.ACCEPT_LIVE -> {
                var acceptedMarker = marker
                if (marker.hadPreviousDatabase == null) {
                    // A legacy marker can be upgraded only when a preserved rollback proves that a
                    // previous database existed. Rollback absence cannot distinguish a true
                    // no-prior-database restore from lost recovery data, so it remains fail-closed.
                    if (!files.rollback.exists()) {
                        throw IOException("Legacy restore rollback state is ambiguous.")
                    }
                    acceptedMarker = marker.copy(
                        hadPreviousDatabase = true,
                        rollbackSha256 = sha256(files.rollback),
                    )
                }
                if (acceptedMarker.phase == Phase.FINALIZING) {
                    // FINALIZING is already the irreversible point: restored preferences may have
                    // been committed, so the previous database must never be reintroduced. Require
                    // coherent metadata and the exact post-migration live file that crossed that
                    // boundary, but do not make a now-unneeded rollback file an app-start gate.
                    try {
                        validateRollbackMetadata(acceptedMarker)
                        validateAcceptedLiveDatabase(files, acceptedMarker, sqliteValid)
                    } catch (failure: AcceptedLiveValidationException) {
                        recordAcceptedLiveFailure(failure)
                        throw failure
                    }
                } else {
                    try {
                        validateApplyRollback(
                            files = files,
                            marker = acceptedMarker,
                            beforeSwap = false,
                            sqliteValid = sqliteValid,
                        )
                    } catch (failure: RollbackValidationException) {
                        recordRollbackFailure(failure.failureKind)
                        throw failure
                    }
                }
                if (acceptedMarker.phase == Phase.APPLYING) {
                    acceptedMarker = acceptedMarker.copy(phase = Phase.APPLIED)
                }
                if (acceptedMarker != marker) {
                    writeMarker(files.marker, acceptedMarker, files.syncParentDirectory)
                }
                Preparation(
                    applied = true,
                    hadPreviousDatabase = acceptedMarker.hadPreviousDatabase
                        ?: throw IOException("Restore rollback metadata is incomplete."),
                    liveFileIdentity = files.identityOf(files.db),
                )
            }
            ResumeAction.APPLY_CANDIDATE -> try {
                applyCandidate(files, marker, sqliteValid)
            } catch (failure: RollbackValidationException) {
                recordRollbackFailure(failure.failureKind)
                throw failure
            }
        }
    }

    /** Apply settings and discard rollback only after Room has opened/migrated the restored DB. */
    @Synchronized
    fun confirmOpened(context: Context) {
        val files = Fileset(context)
        val marker = readMarker(files.marker) ?: return
        if (marker.phase == Phase.COMMITTED) {
            requireTerminalCleanupState(files, marker, ::isUsableSqlite)
            recordCommittedCleanup(cleanupCommitted(files))
            return
        }
        if (marker.phase != Phase.APPLIED && marker.phase != Phase.FINALIZING) return
        val appContext = context.applicationContext
        val settingsPayload = try {
            // Read and cache the complete settings payload before FINALIZING. A killed process may
            // retry preference commits, but unreadable staged bytes can never become irreversible.
            prepareSettingsPayload(
                phase = marker.phase,
                hasSettings = marker.hasSettings,
                settingsExists = files.settings.exists(),
                readText = files.settings::readText,
            )
        } catch (failure: FinalizationPendingException) {
            recordFinalizationFailure(failure)
            throw failure
        } catch (failure: SettingsPreparationException) {
            recordSettingsPreparationFailure(failure)
            throw failure
        }
        val finalizingMarker = try {
            if (marker.phase == Phase.FINALIZING) {
                validateAcceptedLiveDatabase(files, marker, ::isUsableSqlite)
                marker
            } else {
                marker.copy(
                    phase = Phase.FINALIZING,
                    acceptedLiveFileIdentity = files.identityOf(files.db)
                        ?: throw AcceptedLiveValidationException(
                            failureKind = "live_identity",
                            cause = IOException("Accepted restore database identity is unavailable."),
                        ),
                )
            }
        } catch (failure: AcceptedLiveValidationException) {
            recordAcceptedLiveFailure(failure)
            throw failure
        }
        try {
            val cleanupComplete = completeConfirmedRestore(
                hasSettings = marker.hasSettings,
                settingsExists = files.settings.exists(),
                persistFinalizing = {
                    if (marker.phase != Phase.FINALIZING) {
                        finalizationStage("finalizing_marker") {
                            // This is the durable point of no return and must precede every
                            // SharedPreferences write. Room may already have migrated the live file,
                            // so future cold opens accept it without comparing the candidate hash.
                            writeMarker(
                                files.marker,
                                finalizingMarker,
                                files.syncParentDirectory,
                            )
                        }
                    }
                },
                persistPreferences = {
                    finalizationStage("preferences_commit") {
                        BackupSettingsBridge.applyRestoreDurably(
                            appContext,
                            settingsPayload,
                        )
                    }
                },
                reconcile = {
                    // Preference mirrors and OS schedulers may already have been initialized earlier
                    // in this launch. Reconcile only after every restored value is durable.
                    finalizationStage("schedule_reconcile") {
                        BackupSettingsBridge.reconcileAfterRestore(appContext)
                    }
                },
                persistCompletion = {
                    finalizationStage("completion_commit") {
                        val committed = com.noop.ui.NoopPrefs.of(appContext).edit()
                            .putLong("backup.lastRestoreAt", System.currentTimeMillis() / 1000L)
                            .commit()
                        if (!committed) {
                            throw IOException("Restore completion could not be persisted.")
                        }
                    }
                },
                persistAccepted = {
                    finalizationStage("accept_marker") {
                        // FINALIZING already made the database irreversible. COMMITTED records that
                        // settings/reconciliation completed so only marker-last cleanup remains.
                        writeMarker(
                            files.marker,
                            finalizingMarker.copy(phase = Phase.COMMITTED),
                            files.syncParentDirectory,
                        )
                    }
                },
                cleanup = {
                    cleanupCommitted(files)
                },
            )
            recordCommittedCleanup(cleanupComplete)
        } catch (error: FinalizationPendingException) {
            recordFinalizationFailure(error)
            throw error
        }
    }

    internal fun completeConfirmedRestore(
        hasSettings: Boolean,
        settingsExists: Boolean,
        persistFinalizing: () -> Unit,
        persistPreferences: () -> Unit,
        reconcile: () -> Unit,
        persistCompletion: () -> Unit,
        persistAccepted: () -> Unit,
        cleanup: () -> Boolean,
    ): Boolean {
        if (hasSettings && !settingsExists) {
            throw IOException("Staged restore settings are missing.")
        }
        persistFinalizing()
        persistPreferences()
        reconcile()
        persistCompletion()
        persistAccepted()
        return cleanup()
    }

    internal fun cleanupCommittedRestore(
        deleteRollback: () -> Boolean,
        deleteCandidate: () -> Boolean,
        deleteSettings: () -> Boolean,
        deleteMarker: () -> Boolean,
    ): Boolean {
        if (!deleteRollback()) return false
        if (!deleteCandidate()) return false
        if (!deleteSettings()) return false
        return deleteMarker()
    }

    fun stillSameAppliedFile(context: Context, preparation: Preparation): Boolean {
        if (!preparation.applied) return true
        val files = Fileset(context)
        return acceptedLiveIdentityMatches(
            expected = preparation.liveFileIdentity,
            actual = files.identityOf(files.db),
        )
    }

    internal fun acceptedLiveIdentityMatches(expected: String?, actual: String?): Boolean =
        expected != null && actual != null && expected == actual

    /** Restore the pre-import database after a Room open/migration failure. */
    @Synchronized
    fun rollbackAfterOpenFailure(context: Context): Boolean {
        val files = Fileset(context)
        val marker = readMarker(files.marker) ?: return false
        return rollbackFiles(files, marker, ::isUsableSqlite)
    }

    internal fun rollbackAfterOpenFailureFiles(
        files: Fileset,
        sqliteValid: (File) -> Boolean,
    ): Boolean {
        val marker = readMarker(files.marker) ?: return false
        return rollbackFiles(files, marker, sqliteValid)
    }

    private fun applyCandidate(
        files: Fileset,
        marker: Marker,
        sqliteValid: (File) -> Boolean,
    ): Preparation {
        if (sha256(files.candidate) != marker.sha256) {
            cleanupStaging(files, keepRollback = true)
            throw IOException("Restore candidate changed before it could be applied.")
        }
        var activeMarker = marker
        var hadPrevious = marker.hadPreviousDatabase
        if (marker.phase == Phase.PENDING) {
            hadPrevious = files.db.exists()
            val rollbackSha256 = if (hadPrevious == true) {
                preserveCurrentDatabaseForRollback(files, sqliteValid)
            } else {
                if (!deleteIfPresent(files.rollback)) {
                    throw IOException("Could not clear a stale restore rollback file.")
                }
                null
            }
            activeMarker = marker.copy(
                phase = Phase.APPLYING,
                hadPreviousDatabase = hadPrevious,
                rollbackSha256 = rollbackSha256,
            )
            writeMarker(files.marker, activeMarker, files.syncParentDirectory)
        } else if (marker.phase == Phase.APPLYING && marker.hadPreviousDatabase == null) {
            activeMarker = addApplyRollbackMetadata(files, marker, sqliteValid)
            hadPrevious = activeMarker.hadPreviousDatabase
            writeMarker(files.marker, activeMarker, files.syncParentDirectory)
        }
        validateApplyRollback(
            files = files,
            marker = activeMarker,
            beforeSwap = true,
            sqliteValid = sqliteValid,
        )
        deleteLiveSidecars(files.db)
        atomicMove(files.candidate, files.db, files.syncParentDirectory)
        deleteLiveSidecars(files.db)
        if (sha256(files.db) != marker.sha256 || !sqliteValid(files.db)) {
            if (rollbackFiles(files, activeMarker, sqliteValid)) {
                return Preparation(false, files.db.exists())
            }
            throw IOException("The staged backup failed verification after the atomic swap.")
        }
        writeMarker(
            files.marker,
            activeMarker.copy(phase = Phase.APPLIED),
            files.syncParentDirectory,
        )
        return Preparation(
            applied = true,
            hadPreviousDatabase = hadPrevious ?: files.rollback.exists(),
            liveFileIdentity = files.identityOf(files.db),
        )
    }

    private fun addApplyRollbackMetadata(
        files: Fileset,
        marker: Marker,
        sqliteValid: (File) -> Boolean,
    ): Marker {
        if (marker.hadPreviousDatabase != null) return marker
        if (files.rollback.exists()) {
            return marker.copy(
                hadPreviousDatabase = true,
                rollbackSha256 = sha256(files.rollback),
            )
        }
        if (files.db.exists()) {
            return marker.copy(
                hadPreviousDatabase = true,
                rollbackSha256 = preserveCurrentDatabaseForRollback(files, sqliteValid),
            )
        }
        throw IOException("Legacy restore rollback state is ambiguous.")
    }

    private fun preserveCurrentDatabaseForRollback(
        files: Fileset,
        sqliteValid: (File) -> Boolean,
    ): String {
        // At this point there are no Room handles. Fold a surviving WAL into the main file before
        // preserving it, so rollback contains every committed row from the prior installation.
        try {
            val checkpoint = files.checkpointWal(files.db)
            if (!checkpoint.complete) {
                throw IOException("SQLite could not complete the restore checkpoint.")
            }
        } catch (error: Throwable) {
            throw RollbackValidationException(RollbackFailureKind.LIVE_RESTORE, error)
        }
        val rollbackHash = try {
            atomicCopy(files.db, files.rollback, files.syncParentDirectory)
            sha256(files.rollback)
        } catch (error: RollbackValidationException) {
            throw error
        } catch (error: Throwable) {
            throw RollbackValidationException(RollbackFailureKind.LIVE_RESTORE, error)
        }
        if (!sqliteValid(files.rollback)) {
            throw RollbackValidationException(
                RollbackFailureKind.ROLLBACK_INVALID,
                IOException("The current database could not be preserved safely for restore rollback."),
            )
        }
        return rollbackHash
    }

    private fun validateApplyRollback(
        files: Fileset,
        marker: Marker,
        beforeSwap: Boolean,
        sqliteValid: (File) -> Boolean,
    ) {
        try {
            validateRollbackMetadata(marker)
        } catch (failure: Exception) {
            throw RollbackValidationException(RollbackFailureKind.METADATA, failure)
        }
        when (marker.hadPreviousDatabase) {
            true -> {
                val expected = marker.rollbackSha256
                    ?: throw RollbackValidationException(
                        RollbackFailureKind.METADATA,
                        IOException("Restore rollback checksum is missing."),
                    )
                if (!files.rollback.exists()) {
                    throw RollbackValidationException(
                        RollbackFailureKind.ROLLBACK_MISSING,
                        IOException("Restore rollback file is missing."),
                    )
                }
                if (sha256(files.rollback) != expected) {
                    throw RollbackValidationException(
                        RollbackFailureKind.ROLLBACK_CHECKSUM,
                        IOException("Restore rollback checksum does not match."),
                    )
                }
                if (!sqliteValid(files.rollback)) {
                    throw RollbackValidationException(
                        RollbackFailureKind.ROLLBACK_INVALID,
                        IOException("Restore rollback database is invalid."),
                    )
                }
            }
            false -> {
                if (files.rollback.exists()) {
                    throw RollbackValidationException(
                        RollbackFailureKind.METADATA,
                        IOException("Unexpected restore rollback data exists."),
                    )
                }
                if (beforeSwap && files.db.exists()) {
                    throw RollbackValidationException(
                        RollbackFailureKind.METADATA,
                        IOException("Restore metadata would overwrite an unprotected live database."),
                    )
                }
            }
            null -> throw RollbackValidationException(
                RollbackFailureKind.METADATA,
                IOException("Restore rollback metadata is missing."),
            )
        }
    }

    private fun rollbackFiles(
        files: Fileset,
        marker: Marker,
        sqliteValid: (File) -> Boolean,
    ): Boolean {
        if (marker.phase == Phase.FINALIZING || marker.phase == Phase.COMMITTED) {
            return rollbackFailed(RollbackFailureKind.PHASE)
        }
        if (marker.phase == Phase.ROLLED_BACK) {
            if (!terminalCleanupStateIsValid(files, marker, sqliteValid)) {
                return rollbackFailed(RollbackFailureKind.TERMINAL_STATE)
            }
            recordRolledBackCleanup(cleanupRolledBack(files))
            return true
        }

        val rollingBack = try {
            if (marker.phase == Phase.ROLLING_BACK) {
                validateRollbackMetadata(marker)
            } else {
                addRollbackMetadata(files, marker).copy(phase = Phase.ROLLING_BACK)
            }
        } catch (_: Throwable) {
            return rollbackFailed(RollbackFailureKind.METADATA)
        }
        if (marker.phase != Phase.ROLLING_BACK) {
            try {
                // Persist intent before changing either the rollback or live database file.
                writeMarker(files.marker, rollingBack, files.syncParentDirectory)
            } catch (_: Throwable) {
                return rollbackFailed(RollbackFailureKind.MARKER)
            }
        }

        restorePreviousDatabase(files, rollingBack, sqliteValid)?.let {
            return rollbackFailed(it)
        }
        try {
            writeMarker(
                files.marker,
                rollingBack.copy(phase = Phase.ROLLED_BACK),
                files.syncParentDirectory,
            )
        } catch (_: Throwable) {
            // The live database is already restored. ROLLING_BACK remains durable, so the next cold
            // open verifies the restored file and retries this marker transition.
            return rollbackFailed(RollbackFailureKind.ROLLED_BACK_MARKER)
        }
        val rolledBack = rollingBack.copy(phase = Phase.ROLLED_BACK)
        if (!terminalCleanupStateIsValid(files, rolledBack, sqliteValid)) {
            return rollbackFailed(RollbackFailureKind.TERMINAL_STATE)
        }
        recordRolledBackCleanup(cleanupRolledBack(files))
        return true
    }

    private fun addRollbackMetadata(files: Fileset, marker: Marker): Marker {
        marker.hadPreviousDatabase?.let { return validateRollbackMetadata(marker) }
        if (!files.rollback.exists()) {
            throw IOException("Restore rollback metadata is missing.")
        }
        return marker.copy(
            hadPreviousDatabase = true,
            rollbackSha256 = sha256(files.rollback),
        )
    }

    private fun validateRollbackMetadata(marker: Marker): Marker {
        return when (marker.hadPreviousDatabase) {
            true -> {
                if (marker.rollbackSha256 == null) {
                    throw IOException("Restore rollback checksum is missing.")
                }
                marker
            }
            false -> {
                if (marker.rollbackSha256 != null) {
                    throw IOException("Restore rollback metadata is inconsistent.")
                }
                marker
            }
            null -> throw IOException("Restore rollback metadata is missing.")
        }
    }

    private fun validateAcceptedLiveDatabase(
        files: Fileset,
        marker: Marker,
        sqliteValid: (File) -> Boolean,
    ) {
        val expectedIdentity = marker.acceptedLiveFileIdentity
            ?: throw AcceptedLiveValidationException(
                failureKind = "live_identity",
                cause = IOException("Accepted restore database identity is missing."),
            )
        val actualIdentity = files.identityOf(files.db)
        if (actualIdentity == null || actualIdentity != expectedIdentity) {
            throw AcceptedLiveValidationException(
                failureKind = "live_identity",
                cause = IOException("Accepted restore database identity changed."),
            )
        }
        if (!sqliteValid(files.db)) {
            throw AcceptedLiveValidationException(
                failureKind = "live_invalid",
                cause = IOException("Accepted restore database is invalid."),
            )
        }
    }

    private fun migrateLegacyMarker(
        files: Fileset,
        marker: Marker,
        sqliteValid: (File) -> Boolean,
    ): Marker {
        if (marker.formatVersion != LEGACY_MARKER_VERSION) return marker
        val migrated = when (marker.phase) {
            Phase.PENDING -> {
                if (legacyMarkerHasMetadata(marker)) {
                    throw rollbackMetadataFailure("Legacy pending restore metadata is inconsistent.")
                }
                marker.copy(formatVersion = CURRENT_MARKER_VERSION)
            }
            Phase.APPLYING,
            Phase.APPLIED,
            -> migrateLegacyApplyMarker(files, marker, sqliteValid)
            Phase.FINALIZING -> {
                requireLegacyRollbackMetadata(marker)
                if (marker.acceptedLiveFileIdentity == null) {
                    throw AcceptedLiveValidationException(
                        failureKind = "live_identity",
                        cause = IOException("Legacy finalizing restore identity is missing."),
                    )
                }
                validateAcceptedLiveDatabase(files, marker, sqliteValid)
                marker.copy(formatVersion = CURRENT_MARKER_VERSION)
            }
            Phase.COMMITTED -> migrateLegacyCommittedMarker(files, marker, sqliteValid)
            Phase.ROLLING_BACK,
            Phase.ROLLED_BACK,
            -> {
                requireLegacyRollbackMetadata(marker)
                if (marker.acceptedLiveFileIdentity != null) {
                    throw rollbackMetadataFailure("Legacy rollback marker metadata is inconsistent.")
                }
                marker.copy(formatVersion = CURRENT_MARKER_VERSION)
            }
        }
        if (!currentMarkerStructureIsValid(migrated)) {
            throw rollbackMetadataFailure("Legacy restore marker could not be upgraded safely.")
        }
        writeMarker(files.marker, migrated, files.syncParentDirectory)
        return migrated
    }

    private fun migrateLegacyApplyMarker(
        files: Fileset,
        marker: Marker,
        sqliteValid: (File) -> Boolean,
    ): Marker {
        if (marker.acceptedLiveFileIdentity != null) {
            throw rollbackMetadataFailure("Legacy apply marker contains accepted-live metadata.")
        }
        if (marker.hadPreviousDatabase != null || marker.rollbackSha256 != null) {
            requireLegacyRollbackMetadata(marker)
            return marker.copy(formatVersion = CURRENT_MARKER_VERSION)
        }

        val liveMatchesCandidate = files.db.exists() &&
            runCatching { sha256(files.db) == marker.sha256 }.getOrDefault(false)
        val candidateMatches = files.candidate.exists() &&
            runCatching { sha256(files.candidate) == marker.sha256 }.getOrDefault(false)
        return when {
            files.rollback.exists() -> migrateLegacyApplyWithRollback(
                files = files,
                marker = marker,
                liveMatchesCandidate = liveMatchesCandidate,
                sqliteValid = sqliteValid,
            )
            marker.phase == Phase.APPLYING && files.candidate.exists() && files.db.exists() ->
                marker.copy(
                    hadPreviousDatabase = true,
                    rollbackSha256 = preserveCurrentDatabaseForRollback(files, sqliteValid),
                    formatVersion = CURRENT_MARKER_VERSION,
                )
            marker.phase == Phase.APPLYING && files.candidate.exists() && !files.db.exists() ->
                marker.copy(
                    hadPreviousDatabase = false,
                    formatVersion = CURRENT_MARKER_VERSION,
                )
            liveMatchesCandidate -> marker.copy(
                hadPreviousDatabase = false,
                formatVersion = CURRENT_MARKER_VERSION,
            )
            marker.phase == Phase.APPLIED && candidateMatches && !files.db.exists() ->
                marker.copy(
                    phase = Phase.APPLYING,
                    hadPreviousDatabase = false,
                    formatVersion = CURRENT_MARKER_VERSION,
                )
            else -> throw rollbackMetadataFailure("Legacy restore apply state is ambiguous.")
        }
    }

    private fun migrateLegacyApplyWithRollback(
        files: Fileset,
        marker: Marker,
        liveMatchesCandidate: Boolean,
        sqliteValid: (File) -> Boolean,
    ): Marker {
        val rollbackHash = sha256(files.rollback)
        if (marker.phase != Phase.APPLIED || liveMatchesCandidate) {
            return marker.copy(
                hadPreviousDatabase = true,
                rollbackSha256 = rollbackHash,
                formatVersion = CURRENT_MARKER_VERSION,
            )
        }

        // A shipped v1 APPLIED marker remained durable while Room opened/migrated the replacement
        // and restored preferences were committed. A migration changes the live-file hash, so rolling
        // back here could pair the previous history database with partially restored preferences.
        // Candidate absence plus a valid live file is the deterministic compatibility proof that the
        // replacement crossed the Room-open boundary; upgrade directly to irreversible finalization.
        if (files.candidate.exists() || !files.db.exists()) {
            throw rollbackMetadataFailure("Legacy applied restore state is ambiguous.")
        }
        if (!sqliteValid(files.db)) {
            throw AcceptedLiveValidationException(
                failureKind = "live_invalid",
                cause = IOException("Legacy applied restore database is invalid."),
            )
        }
        val identity = files.identityOf(files.db)
            ?: throw AcceptedLiveValidationException(
                failureKind = "live_identity",
                cause = IOException("Legacy applied restore database identity is unavailable."),
            )
        return marker.copy(
            phase = Phase.FINALIZING,
            hadPreviousDatabase = true,
            rollbackSha256 = rollbackHash,
            acceptedLiveFileIdentity = identity,
            formatVersion = CURRENT_MARKER_VERSION,
        )
    }

    private fun migrateLegacyCommittedMarker(
        files: Fileset,
        marker: Marker,
        sqliteValid: (File) -> Boolean,
    ): Marker {
        val migrated = if (!legacyMarkerHasMetadata(marker)) {
            val identity = files.identityOf(files.db)
                ?: throw AcceptedLiveValidationException(
                    failureKind = "live_identity",
                    cause = IOException("Legacy committed restore identity is unavailable."),
                )
            marker.copy(
                // The original v1 COMMITTED state did not retain prior-database metadata. It is
                // already irreversible, so that historical bit is not needed for terminal cleanup.
                hadPreviousDatabase = false,
                acceptedLiveFileIdentity = identity,
                formatVersion = CURRENT_MARKER_VERSION,
            )
        } else {
            requireLegacyRollbackMetadata(marker)
            if (marker.acceptedLiveFileIdentity == null) {
                throw AcceptedLiveValidationException(
                    failureKind = "live_identity",
                    cause = IOException("Legacy committed restore identity is missing."),
                )
            }
            marker.copy(formatVersion = CURRENT_MARKER_VERSION)
        }
        validateAcceptedLiveDatabase(files, migrated, sqliteValid)
        return migrated
    }

    private fun legacyMarkerHasMetadata(marker: Marker): Boolean =
        marker.hadPreviousDatabase != null ||
            marker.rollbackSha256 != null ||
            marker.acceptedLiveFileIdentity != null

    private fun requireLegacyRollbackMetadata(marker: Marker) {
        try {
            validateRollbackMetadata(marker)
        } catch (failure: Exception) {
            throw RollbackValidationException(RollbackFailureKind.METADATA, failure)
        }
    }

    private fun rollbackMetadataFailure(message: String): RollbackValidationException =
        RollbackValidationException(
            RollbackFailureKind.METADATA,
            IOException(message),
        )

    private fun restorePreviousDatabase(
        files: Fileset,
        marker: Marker,
        sqliteValid: (File) -> Boolean,
    ): RollbackFailureKind? {
        return try {
            if (marker.hadPreviousDatabase == true) {
                val expected = marker.rollbackSha256 ?: return RollbackFailureKind.METADATA
                if (files.rollback.exists()) {
                    if (sha256(files.rollback) != expected) {
                        return RollbackFailureKind.ROLLBACK_CHECKSUM
                    }
                    if (!sqliteValid(files.rollback)) {
                        return RollbackFailureKind.ROLLBACK_INVALID
                    }
                    deleteLiveSidecars(files.db)
                    atomicMove(files.rollback, files.db, files.syncParentDirectory)
                } else {
                    // A prior attempt may already have moved the rollback into place before dying.
                    // Verify those bytes before touching any sidecars or marker state.
                    if (!files.db.exists()) return RollbackFailureKind.ROLLBACK_MISSING
                    if (sha256(files.db) != expected) return RollbackFailureKind.LIVE_RESTORE
                    if (!sqliteValid(files.db)) {
                        return RollbackFailureKind.LIVE_INVALID
                    }
                }
                if (!files.db.exists()) return RollbackFailureKind.ROLLBACK_MISSING
                if (sha256(files.db) != expected) return RollbackFailureKind.LIVE_RESTORE
                if (!sqliteValid(files.db)) {
                    return RollbackFailureKind.LIVE_INVALID
                }
            } else {
                if (files.rollback.exists()) return RollbackFailureKind.METADATA
                deleteLiveSidecars(files.db)
                if (files.db.exists() && !files.db.delete()) return RollbackFailureKind.LIVE_RESTORE
                deleteLiveSidecars(files.db)
                if (files.db.exists()) return RollbackFailureKind.LIVE_RESTORE
            }
            null
        } catch (_: Throwable) {
            RollbackFailureKind.LIVE_RESTORE
        }
    }

    internal data class Marker(
        val phase: Phase,
        val sha256: String,
        val hasSettings: Boolean,
        val hadPreviousDatabase: Boolean? = null,
        val rollbackSha256: String? = null,
        val acceptedLiveFileIdentity: String? = null,
        val formatVersion: Int = CURRENT_MARKER_VERSION,
    )

    internal data class Fileset(
        val db: File,
        val syncParentDirectory: (File) -> Unit = {},
        val identityOf: (File) -> String? = { null },
        val checkpointWal: (File) -> WalCheckpointResult = { file ->
            PendingDatabaseRestore.checkpointWal(file)
        },
    ) {
        constructor(context: Context) : this(
            db = context.applicationContext.getDatabasePath(WhoopDatabase.DB_NAME),
            syncParentDirectory = { file ->
                PendingDatabaseRestore.syncParentDirectory(file)
            },
            identityOf = { file -> PendingDatabaseRestore.fileIdentity(file) },
            checkpointWal = { file -> PendingDatabaseRestore.checkpointWal(file) },
        )
        val candidate = File(db.path + PENDING_SUFFIX)
        val settings = File(db.path + SETTINGS_SUFFIX)
        val rollback = File(db.path + ROLLBACK_SUFFIX)
        val marker = File(db.path + MARKER_SUFFIX)
    }

    internal fun readMarker(file: File): Marker? = runCatching {
        val p = Properties().apply { file.inputStream().use(::load) }
        val formatVersion = p.getProperty("version")?.toIntOrNull()
        if (formatVersion != LEGACY_MARKER_VERSION && formatVersion != CURRENT_MARKER_VERSION) {
            return null
        }
        val phase = Phase.valueOf(p.getProperty("phase"))
        val hash = p.getProperty("sha256")
        if (!hash.matches(Regex("[0-9a-f]{64}"))) return null
        val hasSettings = when (p.getProperty("settings")) {
            "1" -> true
            "0" -> false
            else -> return null
        }
        val hadPrevious = when (p.getProperty("had_previous")) {
            "1" -> true
            "0" -> false
            null -> null
            else -> return null
        }
        val rollbackHash = p.getProperty("rollback_sha256")?.also {
            if (!it.matches(Regex("[0-9a-f]{64}"))) return null
        }
        val acceptedLiveIdentity = p.getProperty("accepted_live_identity")?.also {
            if (!it.matches(Regex("[0-9]+:[0-9]+"))) return null
        }
        val marker = Marker(
            phase = phase,
            sha256 = hash,
            hasSettings = hasSettings,
            hadPreviousDatabase = hadPrevious,
            rollbackSha256 = rollbackHash,
            acceptedLiveFileIdentity = acceptedLiveIdentity,
            formatVersion = formatVersion,
        )
        if (formatVersion == CURRENT_MARKER_VERSION && !currentMarkerStructureIsValid(marker)) {
            return null
        }
        marker
    }.getOrNull()

    internal fun writeMarker(
        file: File,
        marker: Marker,
        syncParentDirectory: (File) -> Unit = {},
    ) {
        val currentMarker = marker.copy(formatVersion = CURRENT_MARKER_VERSION)
        if (!currentMarkerStructureIsValid(currentMarker)) {
            throw IOException("Restore marker metadata is incomplete.")
        }
        val body = buildString {
            append("version=").append(CURRENT_MARKER_VERSION).append('\n')
            append("phase=").append(currentMarker.phase.name).append('\n')
            append("sha256=").append(currentMarker.sha256).append('\n')
            append("settings=").append(if (currentMarker.hasSettings) 1 else 0).append('\n')
            currentMarker.hadPreviousDatabase?.let {
                append("had_previous=").append(if (it) 1 else 0).append('\n')
            }
            currentMarker.rollbackSha256?.let {
                append("rollback_sha256=").append(it).append('\n')
            }
            currentMarker.acceptedLiveFileIdentity?.let {
                append("accepted_live_identity=").append(it).append('\n')
            }
        }.toByteArray(Charsets.US_ASCII)
        publishAtomically(file, syncParentDirectory) { partial ->
            FileOutputStream(partial).use { out -> out.write(body); out.fd.sync() }
        }
    }

    private fun currentMarkerStructureIsValid(marker: Marker): Boolean {
        if (marker.formatVersion != CURRENT_MARKER_VERSION) return false
        val rollbackMetadataValid = when (marker.hadPreviousDatabase) {
            true -> marker.rollbackSha256 != null
            false -> marker.rollbackSha256 == null
            null -> false
        }
        return when (marker.phase) {
            Phase.PENDING ->
                marker.hadPreviousDatabase == null &&
                    marker.rollbackSha256 == null &&
                    marker.acceptedLiveFileIdentity == null
            Phase.APPLYING,
            Phase.APPLIED,
            Phase.ROLLING_BACK,
            Phase.ROLLED_BACK,
            -> rollbackMetadataValid && marker.acceptedLiveFileIdentity == null
            Phase.FINALIZING,
            Phase.COMMITTED,
            -> rollbackMetadataValid && marker.acceptedLiveFileIdentity != null
        }
    }

    private fun cleanupStaging(files: Fileset, keepRollback: Boolean) {
        files.candidate.delete()
        files.settings.delete()
        files.marker.delete()
        if (!keepRollback) files.rollback.delete()
    }

    private fun cleanupCommitted(files: Fileset): Boolean =
        cleanupCommittedRestore(
            deleteRollback = { deleteIfPresent(files.rollback) },
            deleteCandidate = { deleteIfPresent(files.candidate) },
            deleteSettings = { deleteIfPresent(files.settings) },
            // The marker is deliberately last. If an earlier deletion fails, the next cold open sees
            // COMMITTED and retries cleanup without ever attempting database rollback.
            deleteMarker = { deleteIfPresent(files.marker) },
        )

    internal fun cleanupRolledBackRestore(
        deleteCandidate: () -> Boolean,
        deleteSettings: () -> Boolean,
        deleteRollback: () -> Boolean,
        deleteMarker: () -> Boolean,
    ): Boolean {
        if (!deleteCandidate()) return false
        if (!deleteSettings()) return false
        if (!deleteRollback()) return false
        return deleteMarker()
    }

    private fun cleanupRolledBack(files: Fileset): Boolean =
        cleanupRolledBackRestore(
            deleteCandidate = { deleteIfPresent(files.candidate) },
            deleteSettings = { deleteIfPresent(files.settings) },
            deleteRollback = { deleteIfPresent(files.rollback) },
            // ROLLED_BACK is durable proof that the previous database is live. Keep the marker until
            // every staging artifact is gone so a later launch can retry bounded cleanup safely.
            deleteMarker = { deleteIfPresent(files.marker) },
        )

    private fun terminalCleanupStateIsValid(
        files: Fileset,
        marker: Marker,
        sqliteValid: (File) -> Boolean,
    ): Boolean {
        val liveExists = files.db.exists()
        val liveSqliteValid = liveExists &&
            runCatching { sqliteValid(files.db) }.getOrDefault(false)
        val liveMatchesRollback = marker.hadPreviousDatabase == true &&
            marker.rollbackSha256 != null &&
            liveExists &&
            runCatching { sha256(files.db) == marker.rollbackSha256 }.getOrDefault(false)
        val terminalStateValid = terminalCleanupAllowed(
            phase = marker.phase,
            hadPreviousDatabase = marker.hadPreviousDatabase,
            liveExists = liveExists,
            liveMatchesRollback = liveMatchesRollback,
            liveSqliteValid = liveSqliteValid,
        )
        if (!terminalStateValid) return false
        return marker.phase != Phase.COMMITTED ||
            runCatching {
                marker.acceptedLiveFileIdentity != null &&
                    files.identityOf(files.db) == marker.acceptedLiveFileIdentity
            }.getOrDefault(false)
    }

    private fun requireTerminalCleanupState(
        files: Fileset,
        marker: Marker,
        sqliteValid: (File) -> Boolean,
    ) {
        if (terminalCleanupStateIsValid(files, marker, sqliteValid)) return
        if (marker.phase == Phase.ROLLED_BACK) {
            recordRollbackFailure(RollbackFailureKind.TERMINAL_STATE)
        } else {
            com.noop.AppDiagnosticsRecorder.record(
                "database.restore_settings",
                fields = mapOf(
                    "outcome" to "failed",
                    "failure_kind" to "terminal_state",
                ),
            )
        }
        throw IOException("Restore terminal state could not be verified safely.")
    }

    private fun resumeFailureKind(marker: Marker, files: Fileset): RollbackFailureKind {
        return when {
            marker.phase == Phase.COMMITTED ||
                marker.phase == Phase.FINALIZING ||
                marker.phase == Phase.ROLLED_BACK -> RollbackFailureKind.TERMINAL_STATE
            marker.hadPreviousDatabase == true && !files.rollback.exists() ->
                RollbackFailureKind.ROLLBACK_MISSING
            else -> RollbackFailureKind.METADATA
        }
    }

    private fun isUsableSqlite(file: File): Boolean =
        DataBackup.isValidSqliteHeader(file) &&
            DataBackup.sqliteQuickCheckFailure(file) == null

    private fun deleteIfPresent(file: File): Boolean = !file.exists() || file.delete()

    private inline fun finalizationStage(kind: String, block: () -> Unit) {
        try {
            block()
        } catch (failure: FinalizationPendingException) {
            throw failure
        } catch (failure: Exception) {
            throw FinalizationPendingException(kind, failure)
        }
    }

    private fun recordFinalizationFailure(failure: FinalizationPendingException) {
        com.noop.AppDiagnosticsRecorder.record(
            "database.restore_settings",
            fields = mapOf(
                "outcome" to "retry_pending",
                "failure_kind" to failure.failureKind,
            ),
        )
    }

    private fun recordSettingsPreparationFailure(failure: SettingsPreparationException) {
        com.noop.AppDiagnosticsRecorder.record(
            "database.restore_settings",
            fields = mapOf(
                "outcome" to "failed",
                "failure_kind" to failure.failureKind,
            ),
        )
    }

    private fun recordAcceptedLiveFailure(failure: AcceptedLiveValidationException) {
        com.noop.AppDiagnosticsRecorder.record(
            "database.restore_settings",
            fields = mapOf(
                "outcome" to "failed",
                "failure_kind" to failure.failureKind,
            ),
        )
    }

    private fun recordCommittedCleanup(complete: Boolean) {
        com.noop.AppDiagnosticsRecorder.record(
            "database.restore_settings",
            fields = mapOf(
                "outcome" to if (complete) "completed" else "cleanup_pending",
            ),
        )
    }

    private fun rollbackFailed(kind: RollbackFailureKind): Boolean {
        recordRollbackFailure(kind)
        return false
    }

    private fun recordRollbackFailure(kind: RollbackFailureKind) {
        com.noop.AppDiagnosticsRecorder.record(
            "database.restore_rollback",
            fields = mapOf(
                "outcome" to "failed",
                "failure_kind" to kind.wireValue,
            ),
        )
    }

    private fun recordRolledBackCleanup(complete: Boolean) {
        com.noop.AppDiagnosticsRecorder.record(
            "database.restore_rollback",
            fields = mapOf(
                "outcome" to if (complete) "completed" else "cleanup_pending",
            ),
        )
    }

    private fun deleteLiveSidecars(db: File) {
        for (sidecar in listOf(File(db.path + "-wal"), File(db.path + "-shm"))) {
            if (sidecar.exists() && !sidecar.delete()) {
                throw IOException("Could not clear stale database sidecar ${sidecar.name}.")
            }
        }
    }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                digest.update(buffer, 0, n)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
    }

    private fun fileIdentity(file: File): String? = runCatching {
        val stat = android.system.Os.stat(file.path)
        "${stat.st_dev}:${stat.st_ino}"
    }.getOrNull()

    private fun checkpointWal(file: File): WalCheckpointResult =
        SQLiteDatabase.openDatabase(
            file.path,
            null,
            SQLiteDatabase.OPEN_READWRITE,
            android.database.DatabaseErrorHandler { broken -> runCatching { broken.close() } },
        ).use { db ->
            db.rawQuery("PRAGMA wal_checkpoint(TRUNCATE)", null).use { cursor ->
                if (!cursor.moveToFirst()) {
                    throw IOException("SQLite did not report a checkpoint result.")
                }
                WalCheckpointResult(
                    busy = cursor.getInt(0),
                    logFrames = cursor.getLong(1),
                    checkpointedFrames = cursor.getLong(2),
                )
            }
        }

    private fun atomicCopy(
        source: File,
        destination: File,
        syncParentDirectory: (File) -> Unit,
    ) = publishAtomically(destination, syncParentDirectory) { partial ->
        source.inputStream().use { input ->
            FileOutputStream(partial).use { output ->
                input.copyTo(output)
                output.fd.sync()
            }
        }
    }

    private fun atomicMove(
        source: File,
        destination: File,
        syncParentDirectory: (File) -> Unit,
    ) {
        destination.parentFile?.mkdirs()
        // Both files are deliberately staged in the database directory. If this filesystem cannot
        // provide an atomic rename, fail closed and keep the live DB instead of risking a torn swap.
        Files.move(source.toPath(), destination.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        syncParentDirectory(destination)
    }

    private fun publishAtomically(
        destination: File,
        syncParentDirectory: (File) -> Unit,
        writer: (File) -> Unit,
    ) {
        destination.parentFile?.mkdirs()
        val parent = destination.parentFile ?: throw IOException("Restore destination has no parent.")
        val partial = File.createTempFile(".${destination.name}.", ".partial", parent)
        try {
            writer(partial)
            atomicMove(partial, destination, syncParentDirectory)
        } finally {
            partial.delete()
        }
    }

    private fun syncParentDirectory(file: File) {
        val parent = file.parentFile
            ?: throw IOException("Restore destination has no parent directory.")
        val descriptor = try {
            android.system.Os.open(
                parent.path,
                android.system.OsConstants.O_RDONLY,
                0,
            )
        } catch (error: Throwable) {
            throw IOException("Could not open the restore directory for synchronization.", error)
        }
        try {
            android.system.Os.fsync(descriptor)
        } catch (error: Throwable) {
            throw IOException("Could not synchronize the restore directory.", error)
        } finally {
            runCatching { android.system.Os.close(descriptor) }
        }
    }
}
