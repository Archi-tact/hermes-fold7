plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// 중계 서버 주소(순서대로 시도). hermes-fold7 에서는 폰 안의 중계 서버(127.0.0.1:8787) 하나.
// 다른 주소가 필요하면 -PhermesRelayUrls=url1,url2
val relayUrls = (findProperty("hermesRelayUrls") as String?) ?: "http://127.0.0.1:8787"

android {
    namespace = "com.architact.hermesvoice"
    compileSdk = 35

    defaultConfig {
        // hermes-fold7 빌드: 원래 앱(com.architact.hermesvoice)과 겹치지 않게 별도 패키지
        applicationId = "ai.hermesfold7.voice"
        minSdk = 26
        targetSdk = 35
        versionCode = 3
        versionName = "0.3.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        buildConfigField("String", "RELAY_URLS", "\"$relayUrls\"")
    }

    // HANDS_KEYSTORE 가 있으면 Hermes Hands 와 같은 고정 키로 서명(업데이트 설치 가능), 없으면 디버그 키
    val ks = System.getenv("HANDS_KEYSTORE")
    signingConfigs {
        if (ks != null) create("stable") {
            storeFile = file(ks)
            storePassword = System.getenv("HANDS_KEYSTORE_PASSWORD")
            keyAlias = "hands"
            keyPassword = System.getenv("HANDS_KEYSTORE_PASSWORD")
        }
    }
    buildTypes {
        release {
            isMinifyEnabled = false
            signingConfig = if (ks != null) signingConfigs.getByName("stable") else signingConfigs.getByName("debug")
        }
    }

    buildFeatures { buildConfig = true }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions { jvmTarget = "17" }

    testOptions { unitTests.isIncludeAndroidResources = true }
}

dependencies {
    implementation("androidx.activity:activity-ktx:1.10.0")
    implementation("androidx.lifecycle:lifecycle-viewmodel-ktx:2.8.7")
    implementation("androidx.lifecycle:lifecycle-runtime-ktx:2.8.7")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.9.0")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
    // android.jar only ships org.json stubs; the real implementation is needed on the JVM test classpath.
    testImplementation("org.json:json:20240303")
}
