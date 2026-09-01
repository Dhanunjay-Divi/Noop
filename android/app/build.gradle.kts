import java.security.MessageDigest
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("com.google.devtools.ksp")
}

// Release signing is fail-closed. Credentials live in `keystore.properties` (git-ignored, never
// committed) or the four NOOP_RELEASE_* environment variables used by CI. Debug builds continue
// to use Gradle's per-machine debug key.
val keystorePropsFile = rootProject.file("keystore.properties")
val keystoreProps = Properties().apply {
    if (keystorePropsFile.exists()) keystorePropsFile.inputStream().use { load(it) }
}
val releaseStoreFile = keystoreProps.getProperty("storeFile")
    ?: System.getenv("NOOP_RELEASE_STORE_FILE")
val releaseStorePassword = keystoreProps.getProperty("storePassword")
    ?: System.getenv("NOOP_RELEASE_STORE_PASSWORD")
val releaseKeyAlias = keystoreProps.getProperty("keyAlias")
    ?: System.getenv("NOOP_RELEASE_KEY_ALIAS")
val releaseKeyPassword = keystoreProps.getProperty("keyPassword")
    ?: System.getenv("NOOP_RELEASE_KEY_PASSWORD")
val releaseSigningValues = listOf(
    releaseStoreFile,
    releaseStorePassword,
    releaseKeyAlias,
    releaseKeyPassword,
)
val hasReleaseSigning = releaseSigningValues.all { !it.isNullOrBlank() }
val hasPartialReleaseSigning = releaseSigningValues.any { !it.isNullOrBlank() } && !hasReleaseSigning
val isStagingRelease = project.hasProperty("stagingRelease")
val noopCompileSdk = 36
val noopTargetSdk = 36
val noopRequiredPlayTargetSdk = 36
val isPlayRelease = project.hasProperty("playRelease")
val requestedReleaseBuild = gradle.startParameter.taskNames.any {
    it.contains("Release", ignoreCase = true)
}
val releaseSigningFailureMessage =
    "Refusing to build a release without private signing credentials. " +
        "Configure gitignored keystore.properties or all four NOOP_RELEASE_* environment variables. " +
        "-PstagingRelease changes the app ID; it does not permit public debug-key signing."
if (hasPartialReleaseSigning) {
    throw GradleException(
        "Incomplete release signing configuration. Provide storeFile, storePassword, keyAlias, " +
            "and keyPassword together (or all four NOOP_RELEASE_* environment variables)."
    )
}
if (isPlayRelease && noopTargetSdk < noopRequiredPlayTargetSdk) {
    throw GradleException(
        "Google Play release blocked: targetSdk $noopTargetSdk is below the required " +
            "API $noopRequiredPlayTargetSdk gate. Upgrade AGP/Gradle, install Android API " +
            "$noopRequiredPlayTargetSdk, update compileSdk/targetSdk, and re-run the full test matrix."
    )
}
// Aggregate tasks such as `assemble` do not contain "Release" in the command-line task name.
// Inspect the resolved task graph as a second gate so they cannot silently emit an unsigned release.
gradle.taskGraph.whenReady {
    val includesAppRelease = allTasks.any {
        it.project.path == project.path && it.name.contains("Release", ignoreCase = true)
    }
    if (!hasReleaseSigning && includesAppRelease) {
        throw GradleException(releaseSigningFailureMessage)
    }
}
val legalAssetsDir = layout.buildDirectory.dir("generated/legalAssets")
val prepareLegalAssets = tasks.register<Sync>("prepareLegalAssets") {
    // Keep one source of truth at the repository root while packaging the complete offline legal set.
    from(
        rootProject.file("../TERMS.md"),
        rootProject.file("../LICENSE"),
        rootProject.file("../NOTICE"),
        rootProject.file("../ATTRIBUTION.md"),
    )
    into(legalAssetsDir)
}

android {
    namespace = "com.noop"
    compileSdk = noopCompileSdk
    // Use the API-36 toolchain already provisioned in local/CI images. AGP 8.13 otherwise defaults to
    // 35.0.0 and may attempt a surprise SDK mutation during an offline or space-constrained build.
    buildToolsVersion = "36.0.0"

    defaultConfig {
        applicationId = "com.noop.whoop"
        minSdk = 26
        targetSdk = noopTargetSdk
        versionCode = 303
        versionName = "9.2.0"

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        vectorDrawables {
            useSupportLibrary = true
        }
    }

    sourceSets {
        getByName("androidTest").assets.srcDir("schemas")
    }

    signingConfigs {
        create("release") {
            if (hasReleaseSigning) {
                storeFile = rootProject.file(requireNotNull(releaseStoreFile))
                storePassword = requireNotNull(releaseStorePassword)
                keyAlias = requireNotNull(releaseKeyAlias)
                keyPassword = requireNotNull(releaseKeyPassword)
            }
        }
    }

    buildTypes {
        debug {
            isMinifyEnabled = false
            applicationIdSuffix = ".debug"
            versionNameSuffix = "-debug"
        }
        release {
            // Shipped UNMINIFIED for reliability. R8 minification crashes this app at runtime: full-mode
            // over-strips reflective paths, and even with full-mode OFF + broad keeps (com.noop.** +
            // Tink/Worker/ViewModel) a minified build STILL died right after the terms gate on a real
            // device — a library reflective path we couldn't pin without a device to trace. Offline app,
            // a ~18 MB APK is fine. Re-enabling minify needs the exact crash trace + device verification.
            isMinifyEnabled = false
            isShrinkResources = false
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            if (!hasReleaseSigning && requestedReleaseBuild) {
                throw GradleException(releaseSigningFailureMessage)
            }
            // Never fall back to a debug key for a distributable variant.
            if (hasReleaseSigning) {
                signingConfig = signingConfigs.getByName("release")
            }
            // A staging release still requires a private signing identity. The property only gives it a
            // separate id/name so it installs beside the real app and a local .debug build.
            if (isStagingRelease) {
                applicationIdSuffix = ".staging"
                versionNameSuffix = "-staging"
            }
        }
    }

    // Two clearly-distinct apps that install side-by-side:
    //   • full → "NOOP"      (com.noop.whoop)     — the real app, starts empty, pair a strap / import.
    //   • demo → "NOOP Demo"  (com.noop.whoop.demo) — preloaded with 120 days of synthetic data and
    //                          a visible DEMO badge, so anyone can explore every screen with no strap.
    // Build e.g. ./gradlew assembleFullRelease assembleDemoRelease.
    flavorDimensions += "tier"
    productFlavors {
        create("full") {
            dimension = "tier"
            buildConfigField("String", "TIER", "\"full\"")
            buildConfigField("boolean", "ENABLE_DEMO", "false")
        }
        create("demo") {
            dimension = "tier"
            applicationIdSuffix = ".demo"
            versionNameSuffix = "-demo"
            buildConfigField("String", "TIER", "\"demo\"")
            buildConfigField("boolean", "ENABLE_DEMO", "true")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    composeOptions {
        // Compose Compiler extension matched to Kotlin 1.9.24 (see the official
        // Compose-to-Kotlin compatibility map). Bumping Kotlin requires bumping this.
        kotlinCompilerExtensionVersion = "1.5.14"
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }

    testOptions {
        managedDevices {
            allDevices {
                create<com.android.build.api.dsl.ManagedVirtualDevice>("pixel2Api35") {
                    device = "Pixel 2"
                    apiLevel = 35
                    systemImageSource = "aosp"
                }
            }
        }
    }

    sourceSets.getByName("main").assets.srcDir(legalAssetsDir)
}

tasks.register("verifyPlayTargetSdk") {
    group = "verification"
    description = "Fails unless the Android target SDK meets NOOP's Google Play release floor."
    doLast {
        if (noopTargetSdk < noopRequiredPlayTargetSdk) {
            throw GradleException(
                "Google Play release blocked: targetSdk $noopTargetSdk; " +
                    "required targetSdk is $noopRequiredPlayTargetSdk."
            )
        }
    }
}

tasks.matching { it.name.startsWith("merge") && it.name.endsWith("Assets") }.configureEach {
    dependsOn(prepareLegalAssets)
}

// Lint reads every declared asset source directly instead of going through the merge task.
// Make the generated notice bundle an explicit prerequisite so combined build/lint graphs
// cannot race on or reject the generated directory as an undeclared task output.
tasks.matching { it.name.contains("lint", ignoreCase = true) }.configureEach {
    dependsOn(prepareLegalAssets)
}

// Room<->GRDB parity oracle. KSP exports Room's exact generated schema into the build tree; unit tests
// compare a stable snapshot of it with the shared fixture used by the Swift GRDB tests.
val roomSchemaDir = layout.buildDirectory.dir("generated/roomSchemas")
ksp {
    arg("room.schemaLocation", roomSchemaDir.get().asFile.absolutePath)
}

// The schema oracle is intentionally produced by one canonical variant. Declaring the same directory as
// an output of every flavor's KSP task makes Gradle treat those tasks as competing producers; a focused
// demo test then fails validation even though it correctly depends on the full-debug oracle. Room's
// entity schema is flavor-independent, so keep one explicit producer and snapshot that output below.
tasks.matching { it.name == "kspFullDebugKotlin" }.configureEach {
    outputs.dir(roomSchemaDir).withPropertyName("roomSchemaExport")
    outputs.upToDateWhen {
        roomSchemaDir.get().asFile.walkTopDown().any { it.isFile && it.extension == "json" }
    }
}

val roomSchemaSnapshotDir = layout.buildDirectory.dir("roomSchemaOracle")
val roomSchemaInputs = files(
    "src/main/java/com/noop/data/Entities.kt",
    "src/main/java/com/noop/data/NutritionEntry.kt",
    "src/main/java/com/noop/data/NutritionCatalogItem.kt",
    "src/main/java/com/noop/data/PairedDevice.kt",
    "src/main/java/com/noop/data/StrengthTraining.kt",
    "src/main/java/com/noop/data/WhoopDatabase.kt",
)
val syncRoomSchemaSnapshot = tasks.register("syncRoomSchemaSnapshot") {
    inputs.files(roomSchemaInputs).withPropertyName("roomSchemaSources")
    outputs.dir(roomSchemaSnapshotDir).withPropertyName("roomSchemaSnapshot")
    // A Copy task is skipped as NO-SOURCE before its actions run when KSP's generated directory is
    // materialized incrementally. Keep this small snapshot action explicit so the hash guard below
    // always runs after the canonical KSP producer.
    outputs.upToDateWhen { false }
    dependsOn(tasks.matching { it.name == "kspFullDebugKotlin" })
    doLast {
        val source = roomSchemaDir.get().asFile
        val destination = roomSchemaSnapshotDir.get().asFile.apply { mkdirs() }
        val marker = destination.resolve(".schema-inputs.sha256")
        val digest = MessageDigest.getInstance("SHA-256")
        roomSchemaInputs.files.sortedBy { it.absolutePath }.forEach { schemaInput ->
            digest.update(schemaInput.absolutePath.toByteArray())
            digest.update(0)
            digest.update(schemaInput.readBytes())
            digest.update(0)
        }
        val sourceHash = digest.digest().joinToString("") { "%02x".format(it) }
        val generatedSchemaExists = source.walkTopDown()
            .any { it.isFile && it.extension == "json" }

        if (generatedSchemaExists) {
            project.copy {
                from(source)
                into(destination)
                include("**/*.json")
            }
            marker.writeText(sourceHash)
        } else {
            check(marker.isFile && marker.readText().trim() == sourceHash) {
                "KSP produced no Room schema after schema-bearing sources changed; refusing to test " +
                    "against a stale snapshot. Run :app:kspFullDebugKotlin --rerun-tasks."
            }
        }
    }
}

tasks.withType<Test>().configureEach {
    dependsOn(syncRoomSchemaSnapshot)
    systemProperty("room.schemaLocation", roomSchemaSnapshotDir.get().asFile.absolutePath)
    val wearableArchive = providers.environmentVariable("NOOP_WEARABLE_EXPORT_ARCHIVE")
    inputs.property("noopWearableExportArchive", wearableArchive.orElse(""))
    // Do not register the copied directory as a Test input. Android/KSP is free to clean generated
    // build directories while preparing the unit-test variant, and Gradle validates task inputs
    // before the test action; that race made otherwise unrelated focused tests fail before JUnit ran.
    // The Sync dependency remains the producer contract, and SchemaOracleTest itself fails with a
    // precise message if its snapshot is unavailable or stale.
}

// Resolve every external module to the exact version recorded in app/gradle.lockfile. Direct
// dependencies are already pinned below; this also freezes the transitive graph selected through
// AndroidX POMs and the Compose BOM. Update intentionally with `./gradlew :app:dependencies
// --write-locks` and review the lockfile diff alongside the dependency declaration change (#658).
dependencyLocking {
    lockAllConfigurations()
}

dependencies {
    // --- Compose (BOM pins all Compose artifact versions in lockstep) ---
    val composeBom = platform("androidx.compose:compose-bom:2024.06.00")
    implementation(composeBom)
    androidTestImplementation(composeBom)

    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.ui:ui-graphics")
    implementation("androidx.compose.ui:ui-tooling-preview")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-extended")

    // --- Home-screen widget ---
    implementation("androidx.glance:glance-appwidget:1.1.1")
    // Glance's own POM pins work-runtime 2.7.1 (Oct 2021). Keep the explicit maintained floor; an
    // intentional dependency refresh can move to 2.10+ now that this module compiles against API 36.
    implementation("androidx.work:work-runtime-ktx:2.9.0")

    // --- Activity / lifecycle / navigation ---
    implementation("androidx.core:core-ktx:1.13.1")
    implementation("androidx.activity:activity-compose:1.9.0")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.2")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.8.2")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.8.2") // collectAsStateWithLifecycle
    implementation("androidx.navigation:navigation-compose:2.7.7")

    // Explicit food-barcode capture. The scanner is user-launched and always has a manual fallback.
    implementation("com.journeyapps:zxing-android-embedded:4.3.0")

    // --- Coroutines ---
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.8.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.1")

    // --- Room (local-only persistence; on-device, nothing leaves the phone) ---
    val roomVersion = "2.6.1"
    implementation("androidx.room:room-runtime:$roomVersion")
    implementation("androidx.room:room-ktx:$roomVersion")
    ksp("androidx.room:room-compiler:$roomVersion")

    // --- AI Coach (opt-in, bring-your-own-key). HTTP client + Keystore-backed key storage. ---
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("androidx.security:security-crypto:1.1.0-alpha06")

    // --- Health Connect (optional native Android import of steps/HR/HRV/sleep/etc.) ---
    // Pinned for behavior stability; compileSdk 36 no longer constrains a future Health Connect update.
    implementation("androidx.health.connect:connect-client:1.1.0-alpha07")

    // --- Unit / instrumentation tests ---
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.8.1")
    testImplementation("org.json:json:20240303") // real org.json for JVM unit tests (android.jar ships throwing stubs)
    testImplementation("net.sf.kxml:kxml2:2.3.0") // real XmlPullParser for JVM tests (android.util.Xml is a throwing stub)
    androidTestImplementation("androidx.test.ext:junit:1.1.5")
    androidTestImplementation("androidx.test.espresso:espresso-core:3.5.1")
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    androidTestImplementation("androidx.room:room-testing:$roomVersion")

    // --- Compose tooling (debug-only) ---
    debugImplementation("androidx.compose.ui:ui-tooling")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
}
