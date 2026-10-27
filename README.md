# Padang Waiter (Flutter)
1. Install Flutter, then: `flutter create padang_waiter` and copy `lib/`, `assets/`, `pubspec.yaml` over the new project.
2. `flutter pub get` then `flutter run` (phone connected).
3. Android release builds: add `<uses-permission android:name="android.permission.INTERNET"/>` to android/app/src/main/AndroidManifest.xml.
4. iOS: add `NSLocalNetworkUsageDescription` to ios/Runner/Info.plist (needed to reach the LAN printer).
5. In the app: Settings > printer IP (port 9100), GST Reg. No., and optionally your Google Sheet CSV link for the live menu.
Menu falls back to assets/menu_all.csv when offline. GST 9% is included in prices.

## Get an APK without installing Flutter
Upload this folder to a new GitHub repository (keep the .github folder), open the Actions tab > "Build APK" > Run workflow.
After ~5 minutes download `padang-waiter-apk` from the run page, unzip, and install app-release.apk on the phone (allow "install unknown apps").
