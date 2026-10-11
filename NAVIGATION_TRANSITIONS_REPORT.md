# 导航转场审查与验证

审查基线：`codex/ppt-question-discovery`，提交 `d4d8a6fc6aceadc2dfee197c29b5d368419dbfff`。

## 调用链与修改范围

| 文件/路径 | 原状与结论 | 本次处理 |
| --- | --- | --- |
| `lib/main.dart` | 深浅色主题分别配置 Android predictive/zoom；普通进退可能使用淡入淡出 | 两个主题共用同一个 `PageTransitionsTheme` 对象 |
| `lib/navigation/page_transitions.dart` | 原先没有统一配置入口 | 普通页面使用 Cupertino 水平滑动；Android 系统手势复用 SDK 预测性返回 |
| `lib/setting/theme_setting.dart` | 设置键 `theme_predictive_back`、默认 true、持久化 setter 已存在 | 只修正文档；键、默认值、读写方式保持原样 |
| `lib/pages/settings/appearance.dart` | “支援返回手勢”容易被理解为禁用整个系统返回 | 改为“預測性返回動畫”，明确 Android 14+ 跟随动画及关闭后仍可返回 |
| `android/app/src/main/AndroidManifest.xml` | application 已有 `android:enableOnBackInvokedCallback="true"`，MainActivity 没有覆盖为 false | 保留原声明，补回归测试；MainActivity 使用 FlutterActivity，未发现自定义返回拦截 |
| 全项目路由 | 20 处 `MaterialPageRoute`；另有 `/accounts`、`/login` 命名路由，均由主题接管 | 保留所有业务 push/pop，不替换路由类型 |
| `CupertinoPageRoute` / `PageRouteBuilder` / `WillPopScope` / 嵌套 Navigator | `lib/` 未发现这些实现 | 无需批量迁移；多层路由测试使用同一根 Navigator |
| `PopScope` | 课件内层、全屏课件、账号/登录扫码弹窗有现有处理 | 原回调全部保留；验证禁止返回、取消和成功返回 |
| `lib/pages/courseware/list.dart` 的 `_stage` | 课程列表 → PPT 列表 → 查看器是同一个 Tab 的状态切换 | 保留现有切换方式；**这些内层切换仍不产生路由动画**。单独测试逐层返回、单页模式退出、主题切换和真实底栏 Tab 保活 |

没有修改课件缓存、课堂消息、题目历史、导出、底栏 PageView 或业务状态管理。弹窗/抽屉属于模态交互，不在普通页面水平转场的调整范围内。

## 新依赖审查

采用并精确锁定 `cupertino_predictive_back: 1.0.0`。

- 已下载并阅读 pub.dev 归档中的完整 `lib/cupertino_predictive_back.dart`、README、示例、测试、pubspec 和 MIT LICENSE。
- 归档与锁文件 SHA-256：`2b64b824befadf543082ffffc4eb57c7f7301008880f6430b218ebbb35e5028d`。
- [发布包源码](https://pub.dev/api/archives/cupertino_predictive_back-1.0.0.tar.gz)，[上游仓库](https://github.com/parapsychic/CupertinoPushPredictiveBackBuilder)。
- 包要求 Dart `^3.9.0` / Flutter `>=3.35.0`，仅依赖 Flutter；与本项目声明的 Dart `^3.12.2` / Flutter `^3.41.8` 约束兼容，没有引入原生插件或额外传递依赖。
- 实际验证 SDK：Flutter **3.47.6** / Dart **3.13.5**；同时阅读当前 SDK 的 MaterialRouteTransitionMixin、PageTransitionsTheme、CupertinoPageTransition、PredictiveBackPageTransitionsBuilder、WidgetsBinding 和路由手势生命周期源码。
- 实现始终挂载 SDK 手势检测器：普通进退把 SDK 的淡入淡出动画固定在已完成/未开始值，由外层 Cupertino 水平动画驱动；手势时改用 SDK 原生预测性动画。Android 没有增加与系统手势竞争的 iOS 触摸边缘返回检测器。
- 系统预测性动画允许 SDK 的缩放、位移和完成后的淡出；**普通 push/pop 不淡入淡出**。没有要求系统手势外形与 iOS 相同。

关闭预测性动画时，Android 使用无手势检测器的 Cupertino 水平转场。系统手势完成仍由 Flutter 正常返回路径处理，取消不会 pop；Android 低版本的返回键同样走正常返回路径。

## 反向审查

发现并修复了设置切换竞态：若进行中的手势遇到预测性动画开关变为 false，直接切换 builder 会卸载 SDK 手势观察者；取消和完成后 `userGestureInProgress` 都可能停留为 true。已用等待主题插值结束的两项测试复现失败，再加保护并复跑通过：进行中的手势保留原 builder，设置在后续手势生效。

其余审查结论：

- 路由仍使用原来的 `MaterialPageRoute`，`maintainState`、返回值、pop 次数和 `PopScope` 回调没有改变。
- 两主题共享配置；动画期间换主题保留 Navigator 和页面 State。
- 按钮、系统返回键和预测性完成均只 pop 顶层一次；取消保留输入及页面状态。
- 不修改缓存 key、文件路径、请求、JSON、鉴权、定时器、dispose 或异步取消逻辑。
- 课件全屏路由取消保留全屏 State，完成恢复内层查看器；课件阶段回退不额外 pop 根路由，缓存 JSON 内容不变。
- 普通转场在多个中间帧检查页面祖先 opacity 为 1；深浅色、开关开/关组合进行渲染像素检查，页面背景覆盖采样横线及两边，没有出现底层空隙或黑白背景闪现。

## 实际验证

| 执行项 | 结果 |
| --- | --- |
| `flutter pub get` | 成功；锁文件仅增加所审查的 1.0.0 依赖 |
| `dart format`（新增导航与测试文件、main） | 通过；保留其他旧文件的既有格式以控制 diff |
| `flutter analyze --no-pub` | 无问题 |
| `flutter test --no-pub test/navigation_transitions_test.dart test/courseware_navigation_test.dart test/tab_and_login_flow_test.dart test/android_manifest_test.dart --reporter expanded` | **49 项通过** |
| `flutter test --no-pub --reporter expanded` | **483 项通过，7 项既有跳过** |
| `flutter build apk --release --split-per-abi --target-platform android-arm64 --build-number=2092 --build-name=1.2.24-navigation-test` | **成功，203.8 秒**；ARM64 APK 71.8 MB |
| `git diff --check` | 通过 |

新增测试覆盖普通进入/点击返回、低版本系统返回路径、Android 14+ 返回键事件、左右两侧预测性手势进度/取消/完成、关闭动画、深浅色切换、三层路由、PopScope 拒绝与重新允许、手势中关闭设置、Android 不增加 iOS 触摸返回、课件内层返回与真实 Tab 保活、全屏课件预测性返回。

### 本地 APK 核验

- 输出：`build/app/outputs/flutter-apk/app-arm64-v8a-release.apk`。
- 包名 `com.anerycoft.coursehelper`，versionName `1.2.24-navigation-test`，实际 versionCode **4092**（基础 2092 + Flutter ARM64 分包偏移 2000）。
- minSdk 24（Android 7.0），targetSdk 36，compileSdk 37，native ABI 仅 `arm64-v8a`。
- `aapt dump xmltree` 核对合并后的 AndroidManifest，`enableOnBackInvokedCallback` 为 true。
- `apksigner verify --verbose --print-certs` 通过 APK v2 签名验证。
- SHA-256：`191495828384b9e4f463a581c21c6ccb5201501853d03dc5f95e3c1f0954e2b3`。
- 本地缺少 release keystore，按仓库已有构建逻辑使用 **Android Debug 签名**；证书 SHA-256 为 `1699f1e2696ac1c72b474af2807e91c03af3bdbc692e47180dafd6a7b42f805e`，与之前 GitHub test91 固定测试证书不同，**此本地构建包不能覆盖安装 test91**。没有把它当作可覆盖安装的公开发行包发布。

## 公开测试安装包（test92）

为解决云工作区本地文件链接无法下载的问题，另通过仓库现有 GitHub Actions 固定测试密钥构建并公开发布了 test92。这是独立于上述 debug 签名本地构建包的安装包。

- [直接下载 APK](https://github.com/ZHHFFF/course_helper/releases/download/test-apk-ios-navigation-test92/course-helper-1.2.3-test92-e5d0bec-arm64.apk)，[公开发布页面](https://github.com/ZHHFFF/course_helper/releases/tag/test-apk-ios-navigation-test92)。无需 GitHub 登录，无需解压。
- [构建来源](https://github.com/ZHHFFF/course_helper/actions/runs/38118967238)：提交 `e5d0bec071c67b035b07b9d087a7dade798d1b2d`，构建流程全部通过；[发布流程](https://github.com/ZHHFFF/course_helper/actions/runs/38119737079)也已通过。
- versionName `1.2.3-test92`，实际 versionCode **4092**；包名 `com.anerycoft.coursehelper`，Android ARM64，Android 7.0 及以上。
- APK v2 签名验证通过，证书 SHA-256 为 `504a40cb3262b8c4a1f94cd76b2cdb3310d01195fab6aeb6df05e898e7d27c46`，与 test91 相同；版本号高于 test91 的 4091，支持覆盖安装。
- SHA-256：`15323f633f6c44b590fe12c1aea1690ba2e8b39b8d84762a0e0c9522344e28f8`；大小 **72,247,817 字节**。核对合并 Manifest 的预测性返回声明为 true，并确认 Dart AOT 包含新的预测性动画文案及已有 PPT 题目发现/详情文案。
- 已用无登录凭据的请求下载完整公开 APK，HTTP **200**，文件 SHA-256 与已验证包及 Release 元数据一致；公开发布页面也返回 HTTP 200。

## 验证边界

- `adb devices` 没有设备。预测性返回使用 `flutter/backgesture` 通道模拟平台事件，未做 Android 14/15/16 真机或模拟器的原生手势验收；OEM 系统合成、导航栏、GPU/Impeller 实际呈现仍需设备验证。
- 实际运行的 SDK 是 3.47.6，未在项目声明允许的每个更早 SDK 上运行完整矩阵。
- 没有现存嵌套 Navigator；本次验证的是根 Navigator 多层堆栈，不声明覆盖未来新增的嵌套导航或自定义 PageRouteBuilder。
- 课件 `_stage` 保持原来的即时内层切换，并未增加跟随系统手势的阶段预览动画；测试验证其既有返回与保活行为。
