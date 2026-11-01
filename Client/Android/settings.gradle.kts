// TeamTalk NG for Android: a native app (Kotlin, Jetpack Compose) that mirrors
// the iPhone app, on BearWare's official TeamTalk 5 SDK for Android.
// Build with: gradlew assembleDebug
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
        // The Android part of rustls-platform-verifier, which AudioNet's engine uses.
        maven { url = uri("https://github.com/rustls/rustls-platform-verifier/raw/maven-archive/android-release-support/maven/") }
    }
}
rootProject.name = "TeamTalk NG"
include(":app")
