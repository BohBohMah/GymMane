import java.util.Properties
import java.io.FileInputStream
import com.android.build.gradle.internal.api.ApkVariantOutputImpl

plugins {
    id("com.android.application")
    id("kotlin-android")
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

// Real-device test builds. The property is unset for normal production builds,
// so the default application id, label and manifest stay exactly as before.
// Pass it with:
//   flutter build apk --release -t lib/main.dart \
//     --android-project-arg=gymmaneTestVariant=phone \
//     --dart-define=GYMMANE_TEST_BUILD=true
val gymmaneTestVariant = providers.gradleProperty("gymmaneTestVariant").orNull
require(
    gymmaneTestVariant == null || gymmaneTestVariant == "phone" || gymmaneTestVariant == "wear",
) {
    "gymmaneTestVariant must be 'phone' or 'wear', got '$gymmaneTestVariant'"
}
val phoneTestBuild = gymmaneTestVariant == "phone"
val wearTestBuild = gymmaneTestVariant == "wear"
val variantApplicationId = when {
    phoneTestBuild -> "com.gymmane.test.phone"
    wearTestBuild -> "com.gymmane.test.wear"
    else -> "com.gymmane.app"
}

android {
    namespace = "com.gymmane.app"
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    buildFeatures {
        buildConfig = true
    }

    sourceSets["main"].java.srcDir("../../packages/wear_protocol/src/main/kotlin")

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = variantApplicationId
        minSdk = if (wearTestBuild) 31 else 24
        targetSdk = 36
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        buildConfigField(
            "boolean",
            "GYMMANE_WEAR_DIAGNOSTICS",
            (phoneTestBuild || wearTestBuild).toString(),
        )
        manifestPlaceholders["gymmaneScheme"] = if (phoneTestBuild) "gymmane-test-phone" else "gymmane"
        manifestPlaceholders["gymmaneLabel"] = when {
            phoneTestBuild -> "GymMane Test Phone"
            wearTestBuild -> "GymMane Test Watch"
            else -> "GymMane"
        }
    }

    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
    }

    if (keystorePropertiesFile.exists()) {
        signingConfigs {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = keystoreProperties["storeFile"]?.let { file(it) }
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (phoneTestBuild || wearTestBuild) {
                signingConfigs.getByName("debug")
            } else if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }

    if (phoneTestBuild || wearTestBuild) {
        // Test APK manifests are release-only, so they do not inherit the debug
        // INTERNET permission. Each role also gets an application-id-safe
        // static-shortcut resource and a role-specific manifest.
        val testOverlay = if (wearTestBuild) "src/wearTest" else "src/phoneTest"
        for (buildType in listOf("debug", "release")) {
            sourceSets.getByName(buildType).apply {
                manifest.srcFile("$testOverlay/AndroidManifest.xml")
                res.srcDir("$testOverlay/res")
            }
        }
    }
}

val abiCodes = mapOf("armeabi-v7a" to 1, "arm64-v8a" to 2, "x86_64" to 3)
android.applicationVariants.configureEach {
    val variant = this
    variant.outputs.forEach { output ->
        val abiVersionCode = abiCodes[output.filters.find { it.filterType == "ABI" }?.identifier]
        if (abiVersionCode != null) {
            (output as ApkVariantOutputImpl).versionCodeOverride = variant.versionCode * 10 + abiVersionCode
        }
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
    implementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.7.3")
    implementation("androidx.wear.tiles:tiles:1.4.1")
    implementation("androidx.wear.protolayout:protolayout:1.2.1")
    implementation("androidx.wear.watchface:watchface-complications-data-source:1.2.1")
    implementation("androidx.wear:wear-ongoing:1.1.0")
    implementation("androidx.concurrent:concurrent-futures:1.2.0")
    implementation("com.google.guava:guava:33.3.1-android")
}

flutter {
    source = "../.."
}
