# 开发说明

本项目目前维护 Android 版本，应用源码位于 `lib/`，Android 宿主配置位于 `android/`。

## 环境

- Flutter stable；具体 Flutter 和 Dart 版本约束见 `pubspec.yaml`
- Android SDK，以及可运行 Android 应用的设备或模拟器

## 本地开发

```bash
flutter pub get
flutter analyze
flutter test
```

需要安装运行时可使用 `flutter run`。签名配置和构建产物不要提交；仓库的 Android 构建工作流会在推送指定分支后自动运行。

## CI 构建

`.github/workflows/build-apk.yml` 在 `master`、`main`、`makisekurisu` 分支更新时运行。工作流检查代码、运行测试，并生成 Android ARM64 APK。请在 GitHub Actions 对应运行记录中查看结果和下载产物。
