# 课程助手

面向 Android 的学习通（超星）和雨课堂课程管理应用，使用 Flutter 开发。

[下载 Android 测试版](https://github.com/ZHHFFF/course_helper/releases) · [查看构建状态](https://github.com/ZHHFFF/course_helper/actions)

## 功能

- 多账号管理
- 学习通签到、课程活动和随堂练习
- 雨课堂动态二维码签到、课堂答题和课件浏览
- 已结课课程的活动与课件回看
- 课件离线缓存和 PDF 导出
- 可选的 OpenAI 兼容接口，用于答案检索和课件题目识别
- 自动预选与自动提交可单独配置；使用前请确认答案并遵守课程要求

具体改动摘要见 [CHANGELOG.md](CHANGELOG.md)。

## 下载与安装

本项目目前只维护 Android 版本。前往 [GitHub Releases](https://github.com/ZHHFFF/course_helper/releases)，选择最新测试版并下载 Android ARM64 APK。安装前请确认设备允许安装该 APK；系统若提示覆盖安装失败，请先确认旧版本签名来源。

## 从源码运行

需要 Flutter stable（版本要求见 [`pubspec.yaml`](pubspec.yaml)）和 Android SDK。

```bash
git clone https://github.com/ZHHFFF/course_helper.git
cd course_helper
flutter pub get
flutter run
```

## 构建

推送到 `master`、`main` 或 `makisekurisu` 会触发 GitHub Actions，执行分析、测试并构建 Android ARM64 APK。构建完成后，在对应的 [Actions 运行记录](https://github.com/ZHHFFF/course_helper/actions)下载产物。

```bash
flutter analyze
flutter test
flutter build apk --release --split-per-abi --target-platform android-arm64
```

更多开发说明见 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可

本项目使用 [GNU GPL v3.0](LICENSE)。
