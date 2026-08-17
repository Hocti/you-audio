.PHONY: version bump apk install run test analyze

# 顯示現時版本（pubspec 係唯一來源，build.gradle 讀佢）
version:
	@grep -E '^version:' pubspec.yaml
	@grep -E 'flutter.versionCode|flutter.versionName' android/app/build.gradle

# 只升版號，唔 build
bump:
	@tool/bump_version.sh

# 每次 build 之前自動升版號，所以出嚟嘅 APK 一定係新 versionCode。
# 用 `flutter build`（唔用 `flutter install`）—— flutter install 見到舊 APK
# 存在就會直接裝舊嗰個，唔會重新 build。
apk: bump
	flutter build apk --release

# build 完直接裝落 USB 連住嘅機。-r = 覆蓋安裝，保留設定同已下載音檔。
install: apk
	adb install -r build/app/outputs/flutter-apk/app-release.apk

# 開發時邊跑邊睇 log（唔升版號）
run:
	flutter run --release

test:
	flutter test

analyze:
	flutter analyze
