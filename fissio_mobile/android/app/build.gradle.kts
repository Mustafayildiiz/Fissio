import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Yayın imzası: android/key.properties (git'te YOK; örnek: key.properties.example). Dosya yoksa release debug anahtarıyla
// imzalanır (yalnızca `flutter run --release` denemesi için); FISSIO_REQUIRE_RELEASE_KEY=true iken derleme BAŞARISIZ olur.
val keyProps = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val hasReleaseKey = keyProps.getProperty("storeFile") != null

android {
    // namespace = Kotlin/Java kaynak paketi (sınıf adları); applicationId = mağazadaki kimlik. İkisi bilerek ayrı.
    namespace = "com.example.fissio_mobile"
    // flutter_local_notifications 23 (ve androidx.core 1.19) Android SDK 37 ile derlenmeyi gerektirir.
    compileSdk = maxOf(flutter.compileSdkVersion, 37)
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // flutter_local_notifications (planlı bildirimler) için core library desugaring gerekir.
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "app.fissio.mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = rootProject.file(keyProps.getProperty("storeFile"))
                storePassword = keyProps.getProperty("storePassword")
                keyAlias = keyProps.getProperty("keyAlias")
                keyPassword = keyProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
            if (hasReleaseKey) {
                signingConfig = signingConfigs.getByName("release")
            } else {
                if (System.getenv("FISSIO_REQUIRE_RELEASE_KEY") == "true") {
                    throw GradleException("android/key.properties yok: yayın imzası gerekli (bkz. key.properties.example)")
                }
                logger.warn("UYARI: android/key.properties yok, release DEBUG anahtarıyla imzalanıyor (yayın için kullanmayın).")
                signingConfig = signingConfigs.getByName("debug")
            }
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
    // Dijital fiş / e-fatura PDF'inin metin katmanı (cihaz içi; bkz. PdfChannel.kt). Apache-2.0.
    implementation("com.tom-roush:pdfbox-android:2.0.27.0")
}

flutter {
    source = "../.."
}
