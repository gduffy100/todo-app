---
name: sideload
description: Build a release APK and install it on the USB/Wi-Fi connected Android device.
---

1. Run `adb devices`. If no device is listed, tell the user to enable USB debugging (or run `adb pair` for wireless) and stop.
2. Run `flutter build apk --release`.
3. Run `adb install -r build/app/outputs/flutter-apk/app-release.apk`.
4. Launch the app: `adb shell monkey -p com.duffy.listo -c android.intent.category.LAUNCHER 1`.
5. Report the APK size and the install result.
