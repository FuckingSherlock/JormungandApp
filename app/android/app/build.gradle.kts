plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "dev.jormungand.app"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.jormungand.app"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// >>> jormungand overlay (app/tool/apply_android_overlay.mjs rewrites this block)
dependencies {
    implementation(files("libs/libbox.aar"))
}
dependencies {
    implementation("androidx.work:work-runtime-ktx:2.9.1")
}
// plain key=value parse: in a .kts body `java` is the java extension, so java.util.Properties does not resolve
val jormKeyProps: Map<String, String> = rootProject.file("key.properties").let { f ->
    if (!f.exists()) emptyMap() else f.readLines().mapNotNull { l ->
        l.split("=", limit = 2).takeIf { it.size == 2 && !l.trimStart().startsWith("#") }?.let { it[0].trim() to it[1].trim() }
    }.toMap()
}
if (jormKeyProps["storeFile"] != null) {
    android {
        signingConfigs {
            create("jormRelease") {
                val pass = jormKeyProps["storePassword"] ?: System.getenv("JORM_ANDROID_KS_PASS")
                storeFile = rootProject.file(jormKeyProps.getValue("storeFile"))
                storePassword = pass
                keyAlias = jormKeyProps["keyAlias"]
                keyPassword = jormKeyProps["keyPassword"] ?: pass
            }
        }
    }
    android {
        buildTypes {
            getByName("release") { signingConfig = signingConfigs.getByName("jormRelease") }
        }
    }
}
android {
    buildTypes {
        getByName("release") { proguardFiles("jormungand-proguard.pro") }
    }
}
