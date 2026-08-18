plugins {
    kotlin("js") version "2.2.21"
}

repositories {
    mavenCentral()
}

kotlin {
    js(IR) {
        binaries.executable()
        browser {
            webpackTask {
                mainOutputFileName = "sibionics-v115g.js"
            }
        }
        nodejs()
    }
    sourceSets {
        val main by getting
    }
}
