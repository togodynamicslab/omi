plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

android {
    namespace = "com.togodynamics.nooto_v2"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // applicationId is overridden per-flavor below; this default is only
        // used if a build runs without selecting a flavor.
        applicationId = "com.togodynamics.nooto.dev"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Match legacy `app/` flavor pattern: dev → nooto-dev Firebase project,
    // prod → nooto-e2d27. Per-flavor `google-services.json` lives under
    // `src/<flavor>/`. FCM tokens cannot register on prod builds without
    // these flavors (the `.dev` package would otherwise be used everywhere).
    flavorDimensions += "flavor"

    productFlavors {
        create("dev") {
            dimension = "flavor"
            applicationId = "com.togodynamics.nooto.dev"
        }
        create("prod") {
            dimension = "flavor"
            applicationId = "com.togodynamics.nooto"
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
