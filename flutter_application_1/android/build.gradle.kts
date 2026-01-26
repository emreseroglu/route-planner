buildscript {
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        // 1. Android Gradle Plugin (Sürümü projenizle uyumlu olmalı, genelde 7.3.0 veya 8.x)
        // Eğer hata alırsanız burayı eski sürümünüzle değiştirin.
        classpath("com.android.tools.build:gradle:7.3.0")

        // 2. Kotlin Gradle Plugin
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:1.7.10")

        // 3. ✅ FIREBASE (Google Services) - Sorun çıkaran kısım buydu, buraya ekledik.
        classpath("com.google.gms:google-services:4.4.0")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}