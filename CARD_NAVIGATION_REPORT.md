# 卡片式双向页面转场

> 历史记录：本文描述 test97 / `6514c8f` 时的卡片转场。当前分支已改为统一 Miuix 水平视差和 Leading 圆角，实际实现、参数与验证见 [MIUIX_NAVIGATION_REPORT.md](MIUIX_NAVIGATION_REPORT.md)。

## 实现前审计与方案

基线：master `013b3b9`。已阅读用户提供的《页面转场开发说明》，查看三行分镜和 ZIP 中 Push / Back / Cancel 原始关键帧；未读取 MP4。

- 现有普通路由使用 MaterialPageRoute 和两条命名路由；没有业务自定义 PageRouteBuilder、CupertinoPageRoute、WillPopScope 或嵌套 Navigator。浅深色已共用 PageTransitionsTheme。
- 普通 Push/Pop 使用 Cupertino 动画；Android 手势使用 Flutter 默认预测性返回视觉，两者并不符合统一卡片层。默认预测性返回的确认阶段包含前景淡出。
- Flutter 3.47.6 的 TransitionRoute.handleCommitBackGesture 在确认时 reverse(from: upperBound)，会重置进度；不能直接把该值作为前景横移，否则松手时跳回全屏。
- 保留 MaterialPageRoute、Navigator 和 SDK 的手势开始/更新/取消/完成处理。在小组件中接收 WidgetsBindingObserver 系统事件，记录松手进度，仅把确认阶段重置后的动画映射到剩余视觉距离；取消则从当前位置回到全屏。
- 普通 Push/Pop、预测性返回及回弹共用一套页面层：水平位移、最多 1.5% 缩小、系统四角圆角（无系统值时回退 28dp）和底页黑色遮罩由同一个视觉进度驱动。底页不移动、不缩小，不重新构造其状态；前景先铺不透明主题背景再绘制原页面。
- Android 不注册 iOS 指针边缘手势。Apple 平台复用 SDK Cupertino 手势检测器，但给它静止动画，实际视觉仍由卡片组件负责。
- 保留 theme_predictive_back 的键、默认值及开关含义；开关或主题中途变化不会拆除系统手势观察器。减少动画时保留页面不透明和系统返回行为，取消卡片装饰及自主位移动画。
- 不修改 Manifest 已有配置、Miuix 组件实现、课件 _stage、底栏 PageView、课件/题目/缓存/课堂消息等业务代码。

## 验证计划

覆盖两种主题、开关两值、点击/旧系统/新系统返回按钮、左右边缘系统手势、多进度确认/取消、松手首帧连续性、圆角/缩放/遮罩/前景不透明、RTL、减少动画、多层路由、PopScope、输入/滚动状态、Miuix 实际应用和课件内层状态。执行 analyze、相关测试、全量测试、Android APK 构建，并反向审查 diff。

真机检查：当前 adb devices -l 无设备，已向用户询问可访问的授权设备连接；在获得设备前不得宣称 Android 真机验收完成。

## 最终实现

| 文件 | 变更 |
| --- | --- |
| lib/navigation/page_transitions.dart | 全平台统一卡片层；Android 系统事件观察器；确认/取消进度映射；保留 Apple SDK 边缘手势；减少动画适配 |
| lib/navigation/card_page_transition.dart | 单一进度驱动不透明前景、水平移动、圆角、缩放、阴影与底页遮罩 |
| pubspec.yaml / pubspec.lock | 移除不再调用的 cupertino_predictive_back 1.0.0；没有新增依赖 |
| test/navigation_transitions_test.dart | 保留原覆盖并扩展到 51 项；验证松手首帧、进度两端、重复终止消息、中途 PopScope 变化、快速返回、滚动和输入保留、RTL、减少动画、Apple 手势 |
| test/card_page_transition_test.dart | 31 项检查：原有像素/几何覆盖及系统四角、零值、null 回退、RTL、高 DPI、进度插值和显示参数更新时输入保留 |
| test/card_navigation_visual_test.dart | 真实 MyApp / SettingsPage / AppearanceSettingsPage 浅深色 Push/Pop/Cancel；保留 Miuix 顶栏、悬浮玻璃底栏和页面 State |
| docs/screenshots/navigation-card-light.png / navigation-card-dark.png | 实际 Flutter 渲染的三行、每行五帧分镜；并非 Android 真机截图；测试环境未提供系统圆角，图中展示 28dp 回退效果 |

main.dart 的现有浅深色共享配置直接使用新实现；主题设置的文案、键与持久化值保持兼容，Manifest 不重复修改。普通路由构造点、命名路由和业务代码均未修改。

视觉参数：普通进入/退出各 600ms；进入 easeOutCubic，退出 easeInCubic（作用于路由可见进度，等效右移 easeOut）；交互阶段直接使用系统进度。离开全屏时在前 18% 距离内连续增加到系统提供的四角半径和 0.985 缩放；只有系统圆角为 null 时才回退到 28dp；底页遮罩为黑色、alpha = 0.18 × 前景可见进度。确认后在剩余距离上 easeOut 滑出；取消后在剩余距离上 easeOut 回弹。不透明背景位于 ClipRRect 内，始终存在。

## 实际验证结果

环境：Flutter 3.47.6 / Dart 3.13.5 / JDK 17；没有模拟器或已连接真机。

- dart format：已执行，所有变更 Dart 文件格式化。
- flutter analyze：通过，无 issues。
- 相关测试：`flutter test test/navigation_transitions_test.dart test/card_page_transition_test.dart test/card_navigation_visual_test.dart test/courseware_navigation_test.dart test/android_manifest_test.dart test/tab_and_login_flow_test.dart`，102 项通过。
- 全量测试：`flutter test --reporter expanded`，543 项通过、7 项原有跳过（基线为 490 通过、7 跳过）；没有删除测试或降低原覆盖。
- 系统手势使用真实 Flutter `flutter/backgesture` 平台消息通道测试，但发送方是测试，不是 Android 系统。
- 分镜单独导出：2 项真实 Miuix 页面用例通过。使用可选 NAVIGATION_FRAME_DIR / NAVIGATION_PREVIEW_FONT / NAVIGATION_PREVIEW_ICON_FONT 参数导出 PNG；预览字体只在测试进程中加载，没有加入应用依赖或资源。
- 分镜测试的初始失败来自错误的 Tab 选择、越界滚动请求及测试 debug shadow 全局变量；修正测试操作并去掉 debug shadow 变量修改。最终测试不通过时没有降低前景不透明、导航栈、状态保留或松手位置的断言。
- Android APK 构建：`flutter build apk --release --split-per-abi --target-platform android-arm64 --build-name=1.2.24-system-corners-test --build-number=2101`，成功（Gradle 147.7s，71.8MB）。apksigner verify 通过；包名 com.anerycoft.coursehelper，实际 versionCode 4101（包含 Flutter ARM64 ABI 偏移），minSdk 24 / targetSdk 36 / compileSdk 37。
- 本地构建产物：`/workspace/artifacts/course-helper-1.2.24-system-corners-test-arm64.apk`；SHA256 `b3aacc18569058df64fc6e160dfe61a45f259213e65f9927fff58be284f8319a`。无本地发布密钥，使用现有 debug 签名回退；不能覆盖 GitHub 已发布的固定签名包，没有宣称它是公网下载包。Gradle / AGP / Kotlin 的将来版本支持提示为现有构建配置问题，本次未扩大修改范围。

## 反向审查

1. Flutter 确认时重置路由进度：记录松手值并读取 SDK 实际重启值，映射剩余视觉距离；兼容没有重置的实现。多个松手位置（0、3%、25%、75%、98%、100%）验证确认/取消首帧完全不跳。
2. 取消后不能遗留映射：完成时清回 idle，并验证下一次普通返回和五次连续取消。
3. 手势中途开关/主题变化：观察器维持同一 State，终止事件仍然被接收；绑定/解绑动画监听器，不新建额外计时器或 controller。
4. PopScope 中途拒绝：取消当前手势并通知失败，避免 SDK unconditional pop 绕过新的阻止状态。
5. 重复 commit/cancel：接受手势后只处理一个终止事件；测试在结算期间重复消息不会再次 pop。
6. Push 未结束就返回：CurvedAnimation 保持中途反向的曲线，首帧位置不跳；前景 opacity 保持 1。
7. 拆包、路径、缓存 key、课件页码、JSON、鉴权和网络处理没有 diff；未触碰业务异步取消/缓存生命周期。全量课件、历史题目、题目提示、PPT 下载与导出等回归一并通过。

## 与参考分镜的差异及未验收范围

- 已实现参考的空间形态：底页原位、前景圆角卡片横移、轻微缩小、底页变暗、确认继续滑出、取消回弹铺满。截图来自本项目实际页面，不是套用参考应用页面。
- 圆角优先使用系统值；28dp 仅为缺省值，1.5% 缩小和 18% 遮罩按截图估计。原设备尺寸、手势速度和 OEM 插值未知，不能声称逐像素/逐时间完全还原。回弹采用连续 easeOut，没有添加截图无法确认的弹簧过冲。
- 系统返回箭头/边缘指示器和状态栏、导航栏由 Android 绘制；云端截图没有这些系统层，也没有设备屏幕圆角。未对这些系统层做变换。
- 底页不额外做视差，避免缩放底页造成边缘空洞；参考可见的底页原位关系被保留。
- 深色使用原有纯黑页面背景，两层黑色区域的圆角对比会较弱；有内容的区域仍表现层次。没有擅自改变项目深色背景。
- Widget 测试默认禁用绘制阴影，预览也遵循该默认；真机阴影、Impeller 下玻璃折射、平台纹理/扫码/地图页面、帧耗时及 OEM 原生手势差异尚未验证。玻璃底栏的组件/交互回归已运行，不能等同于原生渲染验收。
- 没有增加课件内部 _stage 转场；其原有切换和返回行为已通过真实应用测试。
- `adb devices -l` 仍为空；Android 14+ 和低版本真机均未验收。这一阶段是可审查实现，不能标记为真机验收完成。

### 真机验收步骤（待设备）

1. Android 14+：保持原预测性返回开关开启；设置 → 主題設定，观察新页从右进入、圆角收敛至全屏、旧页变暗，确认没有前景渐显。
2. 从左右边缘慢拖，分别在约 5%、25%、55%、90% 取消，连做五次；确认从当前点回弹，滚动位置与输入不变。再做快速和慢速确认，松手后不得回到起点或重复退出。
3. 点击页面返回、三键系统返回、连续多层 Push/Pop；关闭预测性动画后重复取消/确认，确认系统返回仍正常。
4. 浅深色、顶栏模糊、悬浮底栏/液态玻璃开关及减少动画；检查圆角外露出原页而非空白色块，系统栏不闪黑白。
5. 已缓存 PPT：进入课程 → PPT → 单页 → 全屏；取消返回后保持页码/滚动，确认返回后仍在原课件。检查课件内部状态返回不会误 pop 主路由。
6. Android 低版本重复普通进入、返回键、PopScope 阻止返回；同时检查扫码/地图页面的原生纹理和生命周期。

## 系统圆角修正

- 使用 `MediaQuery.displayCornerRadiiOf(context)` 获取四个角的逻辑像素值，保留四角差异；没有手工重复除以 DPR，也不随 RTL 交换物理四角。
- 系统提供 BorderRadius.zero 或某一个角为零时尊重零值；只有整个结果为 null 时才采用 28dp。
- ClipRRect 与阴影的 BoxDecoration 共用同一插值圆角；Push、Pop 和 Cancel 仍由既有统一进度控制，全屏时归零，屏幕物理圆角由系统裁切。
- MediaQuery 的依赖会随显示参数更新重新读取圆角，不缓存陈旧值；新增测试验证更新后输入与 State 不丢失。
- 审核上游 Flutter 3.41.8 / 3.44.0 / 3.44.6 / 3.47.0 源码：接口从 3.44 可用，项目声明的 Flutter 下限从 ^3.41.8 同步到 ^3.44.0。现有 pubspec.lock 的实际 Flutter 下限已是 >=3.44.0，因此没有升级依赖版本。
- 该字段当前在 Android API 31+ 提供；旧 Android / iOS / 其他平台或系统未提供时回退。没有新增原生通道、权限或依赖。
- 真机状态仍未验收；系统值由测试注入验证，不能等同于已在设备上验证系统数据来源。
