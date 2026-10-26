const fs = require('node:fs');
const path = require('node:path');

const gradlePath = path.join(__dirname, '..', 'android', 'app', 'build.gradle');
let gradle = fs.readFileSync(gradlePath, 'utf8');
const debugConfig = `    signingConfigs {
        debug {`;
const releaseConfig = `    signingConfigs {
        release {
            storeFile file(System.getenv('ANDROID_KEYSTORE_PATH'))
            storePassword System.getenv('ANDROID_KEYSTORE_PASSWORD')
            keyAlias System.getenv('ANDROID_KEY_ALIAS')
            keyPassword System.getenv('ANDROID_KEY_PASSWORD')
        }
        debug {`;
if (!gradle.includes(debugConfig)) throw new Error('Could not locate Android signingConfigs');
gradle = gradle.replace(debugConfig, releaseConfig);
const release = /(?<=buildTypes \{[\s\S]*?release \{[\s\S]*?)signingConfig signingConfigs\.debug/;
if (!release.test(gradle)) throw new Error('Could not locate Android release signing');
gradle = gradle.replace(release, 'signingConfig signingConfigs.release');
fs.writeFileSync(gradlePath, gradle);
