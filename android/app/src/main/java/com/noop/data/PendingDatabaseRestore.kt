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
    private const val VERSION = "1"
    private const val PENDING_SUFFIX = ".restore-candidate"
    private const val SETTINGS_SUFFIX = ".restore-settings"
    private const val ROLLBACK_SUFFIX = ".restore-rollback"
    private const val MARKER_SUFFIX = ".restore-state"

    enum class Phase { PENDING, APPLYING, APPLIED }
    data class Preparation(
        val applied: Boolean,
        val hadPreviousDatabase: Boolean,
        /** Guards against a corruption callback silently replacing the candidate with a fresh DB. */
        val liveFileIdentity: String? = null,
    )

    internal enum class ResumeAction { APPLY_CANDIDATE, ACCEPT_LIVE, ROLLBACK, NONE }

    internal fun resumeAction(
        phase: Phase?,
        candidateExists: Boolean,
        liveMatchesCandidate: Boolean,
        rollbackExists: Boolean,
    ): ResumeAction = when (phase) {
        Phase.PENDING -> if (candidateExists) ResumeAction.APPLY_CANDIDATE else ResumeAction.NONE
        Phase.APPLYING -> when {
            liveMatchesCandidate -> ResumeAction.ACCEPT_LIVE
            candidateExists -> ResumeAction.APPLY_CANDIDATE
            rollbackExists -> ResumeAction.ROLLBACK
            else -> ResumeAction.NONE
        }
        Phase.APPLIED -> if (liveMatchesCandidate) ResumeAction.ACCEPT_LIVE
            else if (rollbackExists) ResumeAction.ROLLBACK else ResumeAction.NONE
        null -> ResumeAction.NONE
    }

    @Synchronized
    @Throws(IOException::class)
    fun stage(context: Context, candidate: File, settings: File?) {
        if (!DataBackup.isValidSqliteHeader(candidate)) throw IOException("Restore candidate is not SQLite.")
        val files = Fileset(context)
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
        atomicCopy(candidate, files.candidate)
        if (settings?.exists() == true) {
            atomicCopy(settings, files.settings)
        } else if (files.settings.exists() && !files.settings.delete()) {
            throw IOException("Could not clear settings from the previous pending restore.")
        }
        val marker = Marker(Phase.PENDING, sha256(files.candidate), files.settings.exists())
        writeMarker(files.marker, marker)
    }

    /** Called only while [WhoopDatabase]'s singleton lock is held and before Room is built. */
    @Synchronized
    @Throws(IOException::class)
    fun prepareAtColdOpen(context: Context): Preparation {
        val files = Fileset(context)
        if (!files.marker.exists()) {
            // Orphans can only come from a killed/failed stage before the marker's atomic publish.
            files.candidate.delete()
            files.settings.delete()
            return Preparation(false, files.db.exists())
        }
        val marker = readMarker(files.marker) ?: return Preparation(false, false)
        val liveMatches = files.db.exists() && runCatching { sha256(files.db) == marker.sha256 }.getOrDefault(false)
        return when (resumeAction(marker.phase, files.candidate.exists(), liveMatches, files.rollback.exists())) {
            ResumeAction.NONE -> {
                cleanupStaging(files, keepRollback = true)
                Preparation(false, files.db.exists())
            }
            ResumeAction.ROLLBACK -> {
                if (!rollbackFiles(files)) {
                    throw IOException("A prior restore was interrupted and the previous database could not be restored.")
                }
                Preparation(false, files.db.exists())
            }
            ResumeAction.ACCEPT_LIVE -> {
                if (marker.phase != Phase.APPLIED) writeMarker(files.marker, marker.copy(phase = Phase.APPLIED))
                Preparation(true, files.rollback.exists(), fileIdentity(files.db))
            }
            ResumeAction.APPLY_CANDIDATE -> applyCandidate(files, marker)
        }
    }

    /** Apply settings and discard rollback only after Room has opened/migrated the restored DB. */
    @Synchronized
    fun confirmOpened(context: Context) {
        val files = Fileset(context)
        val marker = readMarker(files.marker) ?: return
        if (marker.phase != Phase.APPLIED) return
        val appContext = context.applicationContext
        val restoredPreferences = restorePreferencesAfterConfirmedOpen(
            hasSettings = marker.hasSettings,
            settingsExists = files.settings.exists(),
            applySettings = {
                BackupSettingsBridge.apply(appContext, files.settings.readText())
            },
            clearDerivedPlannerState = {
                BackupSettingsBridge.clearDerivedPlannerState(appContext)
            },
        )
        if (restoredPreferences) {
            // Preference mirrors and OS schedulers may already have been initialized earlier in this
            // launch. Reconcile only after Room accepted the replacement and settings were committed.
            BackupSettingsBridge.reconcileAfterRestore(appContext)
        }
        cleanupStaging(files, keepRollback = false)
        runCatching {
            com.noop.ui.NoopPrefs.of(appContext).edit()
                .putLong("backup.lastRestoreAt", System.currentTimeMillis() / 1000L).apply()
        }
    }

    internal fun restorePreferencesAfterConfirmedOpen(
        hasSettings: Boolean,
        settingsExists: Boolean,
        applySettings: () -> Unit,
        clearDerivedPlannerState: () -> Unit,
    ): Boolean {
        val clearedDerivedPlannerState = runCatching(clearDerivedPlannerState).isSuccess
        if (!clearedDerivedPlannerState) return false
        if (hasSettings && settingsExists) {
            runCatching(applySettings)
        }
        return true
    }

    fun stillSameAppliedFile(context: Context, preparation: Preparation): Boolean {
        if (!preparation.applied) return true
        val before = preparation.liveFileIdentity ?: return true
        return fileIdentity(Fileset(context).db) == before
    }

    /** Restore the pre-import database after a Room open/migration failure. */
    @Synchronized
    fun rollbackAfterOpenFailure(context: Context): Boolean = rollbackFiles(Fileset(context))

    private fun applyCandidate(files: Fileset, marker: Marker): Preparation {
        if (sha256(files.candidate) != marker.sha256) {
            cleanupStaging(files, keepRollback = true)
            throw IOException("Restore candidate changed before it could be applied.")
        }
        val hadPrevious = files.db.exists()
        if (marker.phase == Phase.PENDING) {
            if (hadPrevious) {
                // At this point there are no Room handles. Fold a surviving WAL into the main file before
                // preserving it, so rollback contains every committed row from the prior installation.
                try {
                    SQLiteDatabase.openDatabase(
                        files.db.path,
                        null,
                        SQLiteDatabase.OPEN_READWRITE,
                        android.database.DatabaseErrorHandler { broken -> runCatching { broken.close() } },
                    ).use { db ->
                        db.rawQuery("PRAGMA wal_checkpoint(TRUNCATE)", null).use { it.moveToFirst() }
                    }
                } catch (error: Throwable) {
                    throw IOException("Could not checkpoint the current database before restore.", error)
                }
                atomicCopy(files.db, files.rollback)
            } else {
                files.rollback.delete()
            }
            writeMarker(files.marker, marker.copy(phase = Phase.APPLYING))
        }
        deleteLiveSidecars(files.db)
        atomicMove(files.candidate, files.db)
        deleteLiveSidecars(files.db)
        if (sha256(files.db) != marker.sha256 || !DataBackup.isValidSqliteHeader(files.db) ||
            DataBackup.sqliteQuickCheckFailure(files.db) != null
        ) {
            if (rollbackFiles(files)) return Preparation(false, files.db.exists())
            throw IOException("The staged backup failed verification after the atomic swap.")
        }
        writeMarker(files.marker, marker.copy(phase = Phase.APPLIED))
        return Preparation(true, hadPrevious, fileIdentity(files.db))
    }

    private fun rollbackFiles(files: Fileset): Boolean {
        runCatching { deleteLiveSidecars(files.db) }.getOrElse { return false }
        val restored = if (files.rollback.exists()) {
            runCatching { atomicMove(files.rollback, files.db); true }.getOrDefault(false)
        } else {
            runCatching { !files.db.exists() || files.db.delete() }.getOrDefault(false)
        }
        if (restored) cleanupStaging(files, keepRollback = false)
        return restored
    }

    private data class Marker(val phase: Phase, val sha256: String, val hasSettings: Boolean)

    private data class Fileset(val db: File) {
        constructor(context: Context) : this(context.applicationContext.getDatabasePath(WhoopDatabase.DB_NAME))
        val candidate = File(db.path + PENDING_SUFFIX)
        val settings = File(db.path + SETTINGS_SUFFIX)
        val rollback = File(db.path + ROLLBACK_SUFFIX)
        val marker = File(db.path + MARKER_SUFFIX)
    }

    private fun readMarker(file: File): Marker? = runCatching {
        val p = Properties().apply { file.inputStream().use(::load) }
        if (p.getProperty("version") != VERSION) return null
        val phase = Phase.valueOf(p.getProperty("phase"))
        val hash = p.getProperty("sha256")
        if (!hash.matches(Regex("[0-9a-f]{64}"))) return null
        Marker(phase, hash, p.getProperty("settings") == "1")
    }.getOrNull()

    private fun writeMarker(file: File, marker: Marker) {
        val body = buildString {
            append("version=").append(VERSION).append('\n')
            append("phase=").append(marker.phase.name).append('\n')
            append("sha256=").append(marker.sha256).append('\n')
            append("settings=").append(if (marker.hasSettings) 1 else 0).append('\n')
        }.toByteArray(Charsets.US_ASCII)
        publishAtomically(file) { partial ->
            FileOutputStream(partial).use { out -> out.write(body); out.fd.sync() }
        }
    }

    private fun cleanupStaging(files: Fileset, keepRollback: Boolean) {
        files.candidate.delete()
        files.settings.delete()
        files.marker.delete()
        if (!keepRollback) files.rollback.delete()
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

    private fun atomicCopy(source: File, destination: File) = publishAtomically(destination) { partial ->
        source.inputStream().use { input ->
            FileOutputStream(partial).use { output ->
                input.copyTo(output)
                output.fd.sync()
            }
        }
    }

    private fun atomicMove(source: File, destination: File) {
        destination.parentFile?.mkdirs()
        // Both files are deliberately staged in the database directory. If this filesystem cannot
        // provide an atomic rename, fail closed and keep the live DB instead of risking a torn swap.
        Files.move(source.toPath(), destination.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
    }

    private inline fun publishAtomically(destination: File, writer: (File) -> Unit) {
        destination.parentFile?.mkdirs()
        val parent = destination.parentFile ?: throw IOException("Restore destination has no parent.")
        val partial = File.createTempFile(".${destination.name}.", ".partial", parent)
        try {
            writer(partial)
            atomicMove(partial, destination)
        } finally {
            partial.delete()
        }
    }
}
