// Root build file — declares plugin versions once; applied per-module in app/build.gradle.kts.
// Keep these versions aligned with the shared contract:
//   Android Gradle Plugin 8.x · Kotlin 1.9.x · KSP matched to the Kotlin version · Room 2.6.x.
plugins {
    // API 36 needs AGP 8.9.1+. AGP 8.13.2 officially supports API 36.1; Gradle 8.14.5 is
    // intentionally above its 8.13 minimum because it is the first Gradle line that supports JDK 24,
    // the available local launcher runtime (CI remains on the supported JDK 17 baseline).
    id("com.android.application") version "8.13.2" apply false
    id("org.jetbrains.kotlin.android") version "1.9.24" apply false
    // KSP version is <kotlinVersion>-<kspVersion>; must track the Kotlin version exactly.
    id("com.google.devtools.ksp") version "1.9.24-1.0.20" apply false
}
