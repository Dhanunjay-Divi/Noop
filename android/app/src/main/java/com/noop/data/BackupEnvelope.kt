package com.noop.data

import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.EOFException
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.IOException
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.SecureRandom
import java.security.GeneralSecurityException
import java.text.Normalizer
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Streaming NOOP encrypted-backup envelope shared with Apple.
 *
 * The outer envelope is portable and authenticated; its payload is the existing ZIP container.
 * The native database inside that ZIP remains platform-specific (Room on Android, GRDB on Apple),
 * while CSV remains the portable cross-platform transfer format.
 */
object BackupEnvelope {
    private val MAGIC = byteArrayOf(0x4e, 0x4f, 0x4f, 0x50, 0x42, 0x41, 0x4b, 0x00)
    private const val VERSION: Byte = 1
    private const val KDF_PBKDF2_SHA256: Byte = 1
    private const val CIPHER_AES_256_GCM_CHUNKED: Byte = 1
    private const val HEADER_BYTES = 64
    private const val SALT_BYTES = 16
    private const val NONCE_PREFIX_BYTES = 8
    private const val TAG_BYTES = 16
    private const val KEY_BYTES = 32
    const val PRODUCTION_ITERATIONS = 310_000
    const val PRODUCTION_CHUNK_BYTES = 1_048_576
    const val MIN_PASSPHRASE_CHARS = 12
    private const val MIN_ITERATIONS = 100_000
    private const val MAX_ITERATIONS = 2_000_000
    private const val MIN_CHUNK_BYTES = 65_536
    private const val MAX_CHUNK_BYTES = 8_388_608
    // Matches Apple's database + settings + archive-overhead limit.
    private const val MAX_PLAINTEXT_BYTES = 2_147_483_648L + 1_048_576L + 64L * 1024L * 1024L

    internal data class Parameters(
        val iterations: Int = PRODUCTION_ITERATIONS,
        val chunkBytes: Int = PRODUCTION_CHUNK_BYTES,
        val salt: ByteArray? = null,
        val noncePrefix: ByteArray? = null,
    )

    fun passphraseProblem(passphrase: String): String? {
        val normalized = Normalizer.normalize(passphrase, Normalizer.Form.NFC)
        val count = normalized.codePointCount(0, normalized.length)
        return if (count < MIN_PASSPHRASE_CHARS) {
            "Backup passphrase must be at least $MIN_PASSPHRASE_CHARS characters."
        } else null
    }

    fun isEnvelope(header: ByteArray): Boolean =
        header.size >= MAGIC.size && MAGIC.indices.all { header[it] == MAGIC[it] }

    @Throws(IOException::class)
    fun encrypt(source: File, destination: File, passphrase: String) =
        encrypt(source, destination, passphrase, Parameters())

    /** Deterministic parameters exist only for cross-platform golden tests; production never supplies them. */
    @Throws(IOException::class)
    internal fun encrypt(source: File, destination: File, passphrase: String, parameters: Parameters) {
        passphraseProblem(passphrase)?.let { throw IOException(it) }
        requireParameters(parameters)
        val plaintextLength = source.length()
        if (plaintextLength < 0 || plaintextLength > MAX_PLAINTEXT_BYTES) {
            throw IOException("Backup is too large to encrypt safely.")
        }
        val random = SecureRandom()
        val salt = parameters.salt?.copyOf() ?: ByteArray(SALT_BYTES).also(random::nextBytes)
        val noncePrefix = parameters.noncePrefix?.copyOf() ?: ByteArray(NONCE_PREFIX_BYTES).also(random::nextBytes)
        if (salt.size != SALT_BYTES || noncePrefix.size != NONCE_PREFIX_BYTES) {
            throw IOException("Invalid backup encryption parameters.")
        }
        val header = buildHeader(plaintextLength, parameters.iterations, parameters.chunkBytes, salt, noncePrefix)
        val key = deriveKey(passphrase, salt, parameters.iterations)
        try {
            publishAtomically(destination) { partial ->
                FileInputStream(source).use { rawInput ->
                    BufferedInputStream(rawInput).use { input ->
                        FileOutputStream(partial).use { rawOutput ->
                            BufferedOutputStream(rawOutput).use { output ->
                                output.write(header)
                                val buffer = ByteArray(parameters.chunkBytes)
                                var remaining = plaintextLength
                                var chunkIndex = 0
                                while (remaining > 0L) {
                                    val wanted = minOf(buffer.size.toLong(), remaining).toInt()
                                    readExactly(input, buffer, wanted)
                                    val cipher = gcmCipher(Cipher.ENCRYPT_MODE, key, nonce(noncePrefix, chunkIndex))
                                    cipher.updateAAD(aad(header, chunkIndex, wanted))
                                    output.write(cipher.doFinal(buffer, 0, wanted))
                                    remaining -= wanted
                                    chunkIndex++
                                }
                                output.flush()
                                rawOutput.fd.sync()
                            }
                        }
                    }
                }
            }
        } finally {
            key.fill(0)
        }
    }

    @Throws(IOException::class)
    fun decrypt(source: File, destination: File, passphrase: String) {
        passphraseProblem(passphrase)?.let { throw IOException(it) }
        val sourceLength = source.length()
        if (sourceLength < HEADER_BYTES) throw IOException("That file is not an encrypted NOOP backup.")
        FileInputStream(source).use { rawInput ->
            BufferedInputStream(rawInput).use { input ->
                val header = ByteArray(HEADER_BYTES)
                readExactly(input, header, header.size)
                val parsed = parseHeader(header)
                val chunks = if (parsed.plaintextLength == 0L) 0L else
                    (parsed.plaintextLength + parsed.chunkBytes - 1L) / parsed.chunkBytes
                val expectedLength = checkedAdd(HEADER_BYTES.toLong(), parsed.plaintextLength, chunks * TAG_BYTES)
                if (sourceLength != expectedLength) throw IOException("Encrypted backup is truncated or has trailing data.")
                val key = deriveKey(passphrase, parsed.salt, parsed.iterations)
                try {
                    publishAtomically(destination) { partial ->
                        FileOutputStream(partial).use { rawOutput ->
                            BufferedOutputStream(rawOutput).use { output ->
                                var remaining = parsed.plaintextLength
                                var chunkIndex = 0
                                val encrypted = ByteArray(parsed.chunkBytes + TAG_BYTES)
                                while (remaining > 0L) {
                                    val plainBytes = minOf(parsed.chunkBytes.toLong(), remaining).toInt()
                                    val encryptedBytes = plainBytes + TAG_BYTES
                                    readExactly(input, encrypted, encryptedBytes)
                                    val cipher = gcmCipher(Cipher.DECRYPT_MODE, key, nonce(parsed.noncePrefix, chunkIndex))
                                    cipher.updateAAD(aad(header, chunkIndex, plainBytes))
                                    try {
                                        output.write(cipher.doFinal(encrypted, 0, encryptedBytes))
                                    } catch (_: AEADBadTagException) {
                                        throw IOException("Backup authentication failed. Check the passphrase or choose an untampered file.")
                                    } catch (_: GeneralSecurityException) {
                                        throw IOException("Backup authentication failed. Check the passphrase or choose an untampered file.")
                                    }
                                    remaining -= plainBytes
                                    chunkIndex++
                                }
                                output.flush()
                                rawOutput.fd.sync()
                            }
                        }
                    }
                } finally {
                    key.fill(0)
                }
            }
        }
    }

    /** Public for the cross-platform golden-vector tests. */
    internal fun pbkdf2HmacSha256(password: ByteArray, salt: ByteArray, iterations: Int, length: Int = KEY_BYTES): ByteArray {
        require(iterations > 0 && length > 0)
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(password, "HmacSHA256"))
        val hLen = mac.macLength
        val blocks = (length + hLen - 1) / hLen
        val result = ByteArray(blocks * hLen)
        for (block in 1..blocks) {
            mac.reset()
            mac.update(salt)
            var u = mac.doFinal(int32(block))
            val t = u.copyOf()
            repeat(iterations - 1) {
                mac.reset()
                u = mac.doFinal(u)
                for (i in t.indices) t[i] = (t[i].toInt() xor u[i].toInt()).toByte()
            }
            t.copyInto(result, (block - 1) * hLen)
            u.fill(0)
            t.fill(0)
        }
        return result.copyOf(length).also { result.fill(0) }
    }

    private data class Header(
        val iterations: Int,
        val chunkBytes: Int,
        val plaintextLength: Long,
        val salt: ByteArray,
        val noncePrefix: ByteArray,
    )

    private fun deriveKey(passphrase: String, salt: ByteArray, iterations: Int): ByteArray {
        val normalized = Normalizer.normalize(passphrase, Normalizer.Form.NFC).toByteArray(Charsets.UTF_8)
        return try {
            pbkdf2HmacSha256(normalized, salt, iterations)
        } finally {
            normalized.fill(0)
        }
    }

    private fun requireParameters(parameters: Parameters) {
        if (parameters.iterations !in MIN_ITERATIONS..MAX_ITERATIONS ||
            parameters.chunkBytes !in MIN_CHUNK_BYTES..MAX_CHUNK_BYTES
        ) throw IOException("Invalid backup encryption parameters.")
    }

    private fun buildHeader(length: Long, iterations: Int, chunkBytes: Int, salt: ByteArray, nonce: ByteArray): ByteArray =
        ByteBuffer.allocate(HEADER_BYTES).order(ByteOrder.BIG_ENDIAN).apply {
            put(MAGIC)
            put(VERSION)
            put(KDF_PBKDF2_SHA256)
            put(CIPHER_AES_256_GCM_CHUNKED)
            put(0)
            putInt(iterations)
            putInt(chunkBytes)
            putLong(length)
            put(salt)
            put(nonce)
            put(ByteArray(12))
        }.array()

    private fun parseHeader(bytes: ByteArray): Header {
        if (!isEnvelope(bytes) || bytes.size != HEADER_BYTES) throw IOException("That file is not an encrypted NOOP backup.")
        val b = ByteBuffer.wrap(bytes).order(ByteOrder.BIG_ENDIAN)
        val magic = ByteArray(MAGIC.size); b.get(magic)
        if (b.get() != VERSION || b.get() != KDF_PBKDF2_SHA256 || b.get() != CIPHER_AES_256_GCM_CHUNKED || b.get() != 0.toByte()) {
            throw IOException("This encrypted backup version is not supported.")
        }
        val iterations = b.int
        val chunkBytes = b.int
        val length = b.long
        val salt = ByteArray(SALT_BYTES); b.get(salt)
        val nonce = ByteArray(NONCE_PREFIX_BYTES); b.get(nonce)
        val reserved = ByteArray(12); b.get(reserved)
        if (iterations !in MIN_ITERATIONS..MAX_ITERATIONS || chunkBytes !in MIN_CHUNK_BYTES..MAX_CHUNK_BYTES ||
            length < 0L || length > MAX_PLAINTEXT_BYTES || reserved.any { it != 0.toByte() }
        ) throw IOException("Encrypted backup header is invalid.")
        return Header(iterations, chunkBytes, length, salt, nonce)
    }

    private fun nonce(prefix: ByteArray, chunkIndex: Int): ByteArray = prefix + int32(chunkIndex)
    private fun aad(header: ByteArray, chunkIndex: Int, plainBytes: Int): ByteArray =
        header + int32(chunkIndex) + int32(plainBytes)
    private fun int32(value: Int): ByteArray = ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN).putInt(value).array()
    private fun gcmCipher(mode: Int, key: ByteArray, nonce: ByteArray): Cipher =
        Cipher.getInstance("AES/GCM/NoPadding").apply {
            init(mode, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        }

    private fun readExactly(input: java.io.InputStream, buffer: ByteArray, count: Int) {
        var offset = 0
        while (offset < count) {
            val read = input.read(buffer, offset, count - offset)
            if (read < 0) throw EOFException("Encrypted backup is truncated.")
            offset += read
        }
    }

    private fun checkedAdd(a: Long, b: Long, c: Long): Long = try {
        Math.addExact(Math.addExact(a, b), c)
    } catch (_: ArithmeticException) {
        throw IOException("Encrypted backup length is invalid.")
    }

    private inline fun publishAtomically(destination: File, writer: (File) -> Unit) {
        destination.parentFile?.mkdirs()
        val parent = destination.parentFile ?: throw IOException("Backup destination has no parent directory.")
        val partial = File.createTempFile(".${destination.name}.", ".partial", parent)
        try {
            writer(partial)
            Files.move(
                partial.toPath(), destination.toPath(),
                StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING,
            )
        } finally {
            partial.delete()
        }
    }
}
