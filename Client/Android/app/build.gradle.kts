import groovy.json.JsonSlurper
import java.util.Properties

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.plugin.compose")
}

val appPackage = "com.matthewdovi.teamtalkng"

// TeamTalk 5.22a for Android, built from BearWare's source with TeamTalk NG's
// changes, as the iPhone app's library is. It's not in this repository (see
// README.md).
val ttSdk: File = rootDir.resolve(
    (findProperty("teamtalkSdk") as String?)
        ?: "../../Library/TeamTalk_Android/tt5sdk_v5.22a_android_ng",
).canonicalFile.resolve("Library/TeamTalkJNI/libs")
require(ttSdk.resolve("TeamTalk5.jar").isFile) {
    "The TeamTalk 5 SDK for Android was not found at $ttSdk. See Client/Android/README.md."
}

// AudioNet's engine: built by AudioNet's apps/android/build-core.ps1. Its
// libaudionet_ffi.so goes to app/audionet/jniLibs/<abi>, its Kotlin bindings
// to app/audionet/java (see README.md). Without them the app builds and
// offers no AudioNet.
val audioNetDir = file("audionet")
val hasAudioNet = audioNetDir.resolve("java/uniffi").isDirectory

// Push notifications come through Firebase Cloud Messaging. app/google-services.json
// is read here instead of by the google-services plugin, as in MG Notify: without
// the file the app still builds and runs, just without Monitor notifications.
@Suppress("UNCHECKED_CAST")
val firebaseResources: Map<String, String> = run {
    val file = file("google-services.json")
    if (!file.isFile) {
        logger.warn("TeamTalk NG: app/google-services.json is missing; Monitor notifications are disabled in this build.")
        return@run emptyMap()
    }
    val json = JsonSlurper().parse(file) as Map<String, Any?>
    val projectInfo = json["project_info"] as Map<String, Any?>
    val clients = json["client"] as List<Map<String, Any?>>
    val client = clients.firstOrNull {
        val info = (it["client_info"] as Map<String, Any?>)["android_client_info"] as Map<String, Any?>
        info["package_name"] == appPackage
    } ?: error("google-services.json has no Android client for $appPackage")
    val clientInfo = client["client_info"] as Map<String, Any?>
    val apiKey = ((client["api_key"] as List<Map<String, Any?>>).first())["current_key"] as String
    buildMap {
        put("google_app_id", clientInfo["mobilesdk_app_id"] as String)
        put("gcm_defaultSenderId", projectInfo["project_number"] as String)
        put("project_id", projectInfo["project_id"] as String)
        put("google_api_key", apiKey)
        put("google_crash_reporting_api_key", apiKey)
        (projectInfo["storage_bucket"] as String?)?.let { put("google_storage_bucket", it) }
    }
}

// Release signing: a keystore kept outside the repository, named in
// ~/.teamtalkng-release/android-signing.properties (storeFile, storePassword,
// keyAlias, keyPassword). Without it, release builds are unsigned.
val signingFile = File(System.getProperty("user.home"), ".teamtalkng-release/android-signing.properties")
val signing = Properties().apply { if (signingFile.isFile) signingFile.inputStream().use { load(it) } }

android {
    namespace = appPackage
    compileSdk = 37

    defaultConfig {
        applicationId = appPackage
        // ChaCha20-Poly1305, which seals Monitor notifications, needs Android 9.
        minSdk = 28
        targetSdk = 37
        // versionName matches the iPhone app's MARKETING_VERSION. versionCode
        // goes up with every Android release: the updater offers only a higher one.
        versionCode = 1
        versionName = "1.0"
        buildConfigField("String", "SERVICE_URL", "\"${project.property("teamtalkNgService")}\"")
        buildConfigField("String", "UPDATES_URL", "\"https://ttmonitor.mad-gamer.com/downloads/android.json\"")
        buildConfigField("boolean", "HAS_AUDIONET", hasAudioNet.toString())
        firebaseResources.forEach { (name, value) -> resValue("string", name, value) }
        // Phones, and the x86_64 emulator; the only ABIs AudioNet's engine is built for.
        ndk { abiFilters += listOf("arm64-v8a", "x86_64") }
    }

    sourceSets {
        getByName("main") {
            jniLibs.directories.add(ttSdk.path)
            if (hasAudioNet) {
                jniLibs.directories.add(audioNetDir.resolve("jniLibs").path)
                kotlin.directories.add(audioNetDir.resolve("java").path)
                kotlin.directories.add("src/audionet/java")
            } else {
                kotlin.directories.add("src/noaudionet/java")
            }
        }
    }

    signingConfigs {
        if (signing.getProperty("storeFile") != null) {
            create("release") {
                storeFile = File(signingFile.parentFile, signing.getProperty("storeFile"))
                storePassword = signing.getProperty("storePassword")
                keyAlias = signing.getProperty("keyAlias")
                keyPassword = signing.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        debug {
            // A debug build can't update itself to a release (different signing key).
            buildConfigField("String", "UPDATES_URL", "\"\"")
        }
        release {
            isMinifyEnabled = false
            signingConfig = signingConfigs.findByName("release")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    lint {
        // Lint's analyzer can't follow ComponentActivity's and
        // FirebaseMessagingService's superclasses with this Kotlin version.
        disable += "Instantiatable"
    }
    buildFeatures {
        compose = true
        buildConfig = true
        resValues = true
    }
    packaging {
        // TeamTalk's library is 70 MB: compressed in the APK it's a third of that.
        jniLibs { useLegacyPackaging = true }
    }
}

dependencies {
    implementation(files(ttSdk.resolve("TeamTalk5.jar")))
    val composeBom = platform("androidx.compose:compose-bom:2026.09.00")
    implementation(composeBom)
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.material:material-icons-core")
    implementation("androidx.activity:activity-compose:1.13.0")
    implementation("androidx.core:core-ktx:1.19.1")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.11.0")
    implementation("androidx.fragment:fragment:1.9.1")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation(platform("com.google.firebase:firebase-bom:34.4.0"))
    implementation("com.google.firebase:firebase-messaging")
    // Sealed notification text (ChaCha20-Poly1305, as the service seals it) and
    // the keystore-encrypted sign-ins use the platform's own crypto.
    if (hasAudioNet) {
        // UniFFI's Kotlin bindings call the engine through JNA.
        implementation("net.java.dev.jna:jna:5.19.1@aar")
        // Must be the version AudioNet's engine was built with (its Cargo.lock).
        implementation("org.rustls:rustls-platform-verifier:0.2.0")
    }
}
