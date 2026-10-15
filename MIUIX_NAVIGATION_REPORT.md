# Miuix 页面转场重构与验证

审计基线：`6514c8f`。实现提交：`69cc54e`，参考审计补充：`f3505bf`；路由返回值与采集工具：`7623693`；最终裁剪、背景及竞态修复：`110cdbd`。实际工具链为 Flutter 3.47.6 / Dart 3.13.5，锁定 flutter_miuix 1.2.0。此次修改没有新增或升级应用依赖；仅独立 Profile 工具需要 Python websocket-client。

## 1. 根因与对应修改

| 原有问题 | 代码位置 | 修改结果 |
| --- | --- | --- |
| 前景卡片运动，背景没有使用 secondaryAnimation，缺少视差 | 原 page_transitions.dart / card_page_transition.dart | 前后页面直接使用同一个路由控制器的 primary/secondary 进度 |
| 普通动画与手势确认的进度重新映射不同，补入背景后容易失配 | 原 _CardRouteTransition 的 commit / visualProgress | MiuixPageRoute.createSimulation 直接驱动真实视觉进度，确认不重置到 upperBound |
| 600ms 进入与退出、1.5% 缩放、四角裁剪不符合本次水平导航要求 | 原 _CardPageTransitionsBuilder / CardPageTransition | 300ms 进入、260ms 退出，无缩放，统一 Leading 裁剪 |
| 每帧生成动画包装组件、阴影及裁剪 | 原 CardPageTransition 的 AnimatedBuilder | 单一 RenderMiuixPageTransition 监听进度，仅更新绘制；复用 SDK 内容 RepaintBoundary，移除动态阴影及额外边界 |
| 页面级系统观察者销毁后，迟到终止事件可能作用于其他页面 | 原 _CardRouteTransitionState | Navigator 级 MiuixBackGestureDispatcher 持有系统会话至终止，处理移除、覆盖及重复消息 |
| 路由动画可能重新创建 SDK 子包装 | MiuixPageRoute.buildTransitions | 缓存转场宿主，在内部更新 SDK 的输入/焦点包装，保留 SDK 返回动画期间的 IgnorePointer |

SDK 自身仍会更新路由作用域；本次没有声称整个 Flutter 框架停止 build。测试验证页面 State、页面内容 build 次数与转场组件身份在纯动画 tick 中保持稳定。

## 2. 参考规范与实现对应

Compose 源码固定于 [`6ef604ae`](https://github.com/compose-miuix-ui/miuix/tree/6ef604ae6d53e4b241cdb89ccbf2caf86a7a33d0/miuix-nav/src/commonMain/kotlin/top/yukonga/miuix/kmp/nav)，并阅读了 [Miuix Nav 文档](https://compose-miuix-ui.github.io/miuix/zh_CN/guide/miuix-nav)。Flutter 上游参考固定于 [`3c6f64d7`](https://github.com/ChuxinNeko/flutter_miuix/tree/3c6f64d7f49753ce58d16ea6f9149459962fe916)，但实际调用以锁定的 1.2.0 导出 API 为准。

| Miuix 参考 | 本项目适配 |
| --- | --- |
| NavTransitions.MiuixDefault 全宽前景 + 四分之一屏宽背景视差 | 前景 `(1-p)W`，背景 `-0.25qW`，不透明度始终 1 |
| NavDisplayEffects 的 Leading / All | 使用 Leading；本次不缩放，因此不启用 All |
| 系统或统一设计圆角 | MediaQuery.displayCornerRadii，null 时统一回退 28 逻辑像素；系统明确报告 0 时保留 0 |
| 可配置背景 dim | 单一黑色背景遮罩，最大 0.18；不用整页 Opacity |
| 普通 motion 与手势 progress 分离 | 普通路由使用 MiuixMotion 曲线；拖动直接写入原始进度，不叠加曲线或固定时长动画 |
| Folme / 临界阻尼收尾 | 使用 1.2.0 导出的 folmeSpring，结合当前进度和估计释放速度，限制过冲 |

Compose 默认普通运动为 500ms，使用 NavSettleEasing(response=.8,damping=.95)；手势默认 stiffness146、damping1。它们与 Flutter Miuix 的运动 API 不同。本项目移植几何与效果规则，采用可集中调整的应用运动参数，并在 Profile 探针中比较 Compose 500ms 曲线及三组较快候选。没有调用 Flutter 包中不存在的 NavDisplay/NavTransitions。

审查了此前采用的 cupertino_predictive_back 1.0.0 历史缓存源码：它嵌套 CupertinoPageTransition 与 SDK PredictiveBackPageTransitionsBuilder，手势时采用 SDK 自身的缩放、圆角与收尾；当前基线已经移除该依赖，本次未重新引入。iOS 仅保留 Flutter SDK 边缘返回检测器，其视觉动画输入固定为完成/未开始，真实几何仍由本项目负责。

## 3. 修改文件

| 文件 | 原因 |
| --- | --- |
| lib/navigation/miuix_navigation_motion.dart | 集中时长、曲线、视差、遮罩、回退圆角、无过冲弹簧 |
| lib/navigation/miuix_page_route.dart | Material 路由语义、共享视觉进度、系统返回生命周期、稳定转场宿主 |
| lib/navigation/miuix_page_transition.dart | 替代 card_page_transition.dart，统一位移、Leading 原生 RRect、透明内容的实体底色、命中测试与语义坐标 |
| lib/navigation/page_transitions.dart | 统一平台 builder、保留 iOS 检测器、单一 Android 系统会话分发 |
| lib/main.dart | 深浅色继续共用配置；持有稳定 dispatcher；根路由及命名路由使用统一 route |
| lib/pages/accounts.dart | 路由构造器与 import 替换 |
| lib/pages/actives/sign_in/qrcode.dart | 同上 |
| lib/pages/actives/sign_in/sign_in.dart | 同上 |
| lib/pages/courses/content.dart | 同上 |
| lib/pages/courses/list.dart | 同上 |
| lib/pages/courses/settings.dart | 同上 |
| lib/pages/courseware/list.dart | 同上，不修改 _stage |
| lib/pages/courseware/viewer.dart | 同上，保留全屏查看结果及页码状态 |
| lib/pages/settings/settings.dart | 同上，设置子页共用统一 route |
| test/navigation_transitions_test.dart | 几何、状态、返回事件、生命周期及绘制层回归 |
| test/card_page_transition_test.dart | Leading 圆角、系统半径、像素不透明及接缝检测 |
| test/card_navigation_visual_test.dart | 深浅色真实设置→外观/日志/缓存、取消状态及逐帧导出 |
| test/miuix_navigation_motion_test.dart | 运动端点、导数、不同初值/速度的弹簧单调性与收尾 |
| tool/navigation_profile.dart | 不带登录/课堂请求的受控 Profile 探针，复用真实玻璃底栏 |
| tool/run_navigation_profile.sh | 按锁定依赖生成隔离 Linux 探针、运行候选参数 |
| tool/collect_navigation_timeline.py | 采集 FrameTiming 与 VM Service Timeline 原始数据 |
| tool/summarize_navigation_profile.py | 分场景汇总预热后 UI/raster 数据及预算超限数量 |
| .github/workflows/navigation-profile.yml | 可复现五组候选 Profile 比较；当前仓库 Actions 被禁用，改为本地 Docker 验证 |
| MIUIX_NAVIGATION_AUDIT.md / 本报告 | 保存审计依据、实现与验证范围 |
| CARD_NAVIGATION_REPORT.md | 标注旧测试包报告已被本次实现取代，避免混淆 |
| docs/miuix-navigation/ | 保存深浅色分镜、Profile 汇总与原始数据归档 |

未修改 theme_setting.dart 的 `theme_predictive_back` 持久化键和值、appearance.dart 开关含义、AndroidManifest.xml 的 enableOnBackInvokedCallback=true。未修改 PPT 识题、缓存、历史题目、实时消息、请求取消、导出或底栏 PageView。

## 4. 最终参数及几何

| 场景 | 参数 |
| --- | --- |
| 普通进入 | 300ms；MiuixMotion.standardDecelerate，即 `1-(1-t)^2` |
| 普通退出 | 260ms；MiuixMotion.sinOut，即 `sin(pi*t/2)` |
| Android 拖动 | 路由视觉进度 `p=1-systemProgress`，不使用 easing，不添加 Android 指针检测器 |
| Android 完成/取消 | folmeSpring(damping=1,response=.25)，从当前 p 收尾；非固定时长，精确归位 |
| 弹簧结束阈值 | 距离小于半个物理像素，速度阈值 .02 progress/s，snapToEnd=true |
| 减少动画设置 | 即时端点，系统普通返回保留 |

释放速度通过相邻有效系统帧时间与进度差估计，超过 100ms 的旧速度归零；不是来自 Android 原生事件的直接速度值。种子限制在朝向终点且不越过终点的临界阻尼范围；反向或过大速度会被截断。这优先保证无过冲，也意味着极端手势速度不能完全连续保留，须真机确认。

以 LTR 为例：前景位移为 `round((1-p)*W*dpr)/dpr`，下层位移为 `-.25*q*W`，q 直接来自上层同一动画的 secondaryAnimation。多级路由自身位移与被覆盖位移相加；RTL 对称镜像。左右 Android 边缘都使用相同语义进度和统一的 LTR/RTL 路由方向。

Leading 为 LTR 左上/左下、RTL 右上/右下。取系统对应角半径后乘 `min(1, exposedDistance/maxLeadingRadius)`；全屏归位为零，末段随物理像素位移连续收敛。使用原生 ClipRRectLayer + antiAlias，不使用 ClipPath 或 antiAliasWithSaveLayer。每个活动前景只有一个导航裁剪，已完成页面没有导航裁剪。实体底色优先取 MiuixTheme.background，确保透明内容及视差暴露区域使用同一主题表面。

iOS 保留 SDK 手势完成/取消时序；不能把 Android 的弹簧参数写成 iOS SDK 的实际收尾时长。

## 5. 测试及构建

实际执行 `dart format`：导航实现、main.dart、相关测试与 Profile Dart 文件。九个业务文件仅替换 import/route 构造器，避免把此前未格式化的业务代码改成大范围格式 diff。

| 检查 | 结果 |
| --- | --- |
| flutter analyze | No issues found |
| 相关导航、像素、真实设置、运动、课件回归测试 | 最终 154 项通过 |
| flutter test --reporter expanded | 最终 610 项通过，7 项原有跳过，无失败 |
| 带 MiSans / MaterialIcons 的真实页面逐帧导出测试 | 5 项通过，生成 30 张深浅色 Push / Back / Cancel 中间帧，并人工查看浅色 Push、深色 Back |
| flutter build apk --release --target-platform android-arm64 | 成功；检查发现插件附带其他 ABI，因此追加与 CI 一致的 --split-per-abi 构建 |
| flutter build apk --release --split-per-abi --target-platform android-arm64 --build-name 1.2.24-miuix-110cdbd --build-number 4102 | 成功；71,772,773 字节，仅 arm64-v8a；aapt 检查实际 versionCode=6102（Flutter 分 ABI 偏移）、minSDK24 / targetSDK36 / compileSDK37 |

APK：`/workspace/artifacts/course-helper-miuix-navigation-110cdbd-arm64.apk`，SHA256 `3350ef34c58142ef5240b71e8beee41e8f310bae3a6e10a2e088493f22681546`。apksigner 校验通过；本地 debug 证书 SHA256 `1699f1e2696ac1c72b474af2807e91c03af3bdbc692e47180dafd6a7b42f805e`。构建仍提示项目原有 Gradle 8.14.5 / AGP 8.11.1 / Kotlin 2.2.20 后续兼容警告，本次未为动画修改构建工具或关闭依赖验证。

实际 Widget 捕获分镜：[浅色](docs/miuix-navigation/light-reference.png)、[深色](docs/miuix-navigation/dark-reference.png)。它们不是 Android 真机录屏，也没有用合成图片替代应用渲染。

测试覆盖：设置→外观/日志/缓存、点击返回、普通系统返回、双侧预测性完成/取消、多层连续导航、快速重复返回、主题切换、PopScope 初始阻止与拖动期间改为阻止、课件 _stage/全屏查看、输入与滚动 State 保留、页面移除/被新路由覆盖时的迟到终止、重复终止及重复开始。检查位置、固定尺寸、无缩放/透明度、Leading 中间值、前后进度同步、像素 alpha255、没有错误底色洞、动画末端精确归位、用户手势计数最终归零。

Widget 平台通道模拟验证的是 Flutter 事件处理；Android 低版本、Android14+ 真机回调时序与 OEM 表现仍需设备验证。七个已有跳过项没有因本次修改而启用、删除或修改预期。

## 6. 性能测量、取舍与局限

Profile 采用同一锁定工具链与依赖，在 Linux / Xvfb / Mesa llvmpipe（LLVM20.1.2 / Mesa25.2.8，无 GPU 设备）中运行；日志确认 Impeller OpenGLESSDF，窗口 1280×720、DPR1，分别比较旧 600ms 实现、Compose 500ms、280/240、300/260、320/280。每组普通、模糊、玻璃场景各 12 次进入/退出，前两轮预热，剩余 10 轮汇总。记录全部 FrameTiming、带阶段标记的 VM Timeline（DevTools 使用的同一数据源）及页面 build 计数，保留原始冷启动数据。每次复跑归档旧文件，校验运行 ID 和至少 30 个完整 Push / Pop 标记；最终四组新实现还核对 renderer 源码 SHA256 一致。不能拿前一次输出作为新运行结果。

最终源码 `110cdbd` 的数据如下，单位 ms。Frames 是预热后测量窗口内帧数；最后一列统计 UI 或 raster 超过预算的帧数。plain / blur / glass 分别为普通、模糊顶栏、模糊顶栏加真实玻璃底栏。各组时长不同，不能用帧数减少来推导掉帧改善。

| Candidate | Style | Frames | UI p95/max ms | Raster p95/max ms | >16.67 / >8.33 ms |
| --- | --- | ---: | ---: | ---: | ---: |
| before | plain | 467 | 1.239/10.148 | 40.42/179.287 | 335/441 |
| before | blur | 190 | 2.218/7.89 | 106.565/123.594 | 190/190 |
| before | glass | 124 | 3.609/8.077 | 165.746/178.152 | 124/124 |
| native500 | plain | 270 | 1.792/4.161 | 62.695/80.205 | 242/260 |
| native500 | blur | 156 | 2.083/4.714 | 118.495/133.592 | 156/156 |
| native500 | glass | 107 | 2.444/4.609 | 182.862/256.194 | 107/107 |
| 280-240 | plain | 176 | 1.897/3.305 | 51.902/62.58 | 147/165 |
| 280-240 | blur | 110 | 2.059/3.849 | 116.026/128.946 | 110/110 |
| 280-240 | glass | 80 | 3.138/7.786 | 183.247/191.599 | 80/80 |
| 300-260 | plain | 174 | 1.98/10.763 | 55.353/68.079 | 144/163 |
| 300-260 | blur | 110 | 2.016/2.97 | 128.214/153.19 | 110/110 |
| 300-260 | glass | 82 | 3.655/6.051 | 176.194/192.579 | 82/82 |
| 320-280 | plain | 185 | 1.869/3.048 | 59.972/78.189 | 159/176 |
| 320-280 | blur | 119 | 2.131/4.257 | 112.712/137.53 | 119/119 |
| 320-280 | glass | 86 | 2.277/5.146 | 177.485/198.662 | 86/86 |

最终 300/260 的 UI p95 为 1.980 / 2.016 / 3.655ms，raster p95 为 55.353 / 128.214 / 176.194ms。软件光栅化明显超出 60Hz 和 120Hz 帧预算；新视差会同时暴露两页及其滤镜，此环境下部分指标比旧实现更差。因此没有证据证明已提升帧率或修复真机卡顿。300/260 是本次选用的可调初值，不是已证明最优的方案；共享云 CPU 单轮比较也不足以给出稳定排名。

曾在相同 300/260 几何下单独比较原生 RSuperellipse 与 RRect：plain / blur / glass 的 raster p95 从 55.182 / 126.078 / 185.362ms 变为 49.420 / 125.304 / 168.444ms。最终选择较简单的原生 RRect；后续完整重跑的波动说明不能把这次单轮差异当作稳定收益或优化百分比。RRect 也不是 Compose 超椭圆的逐像素复刻。尾部补色范围缩减由像素正确性回归证明，未单独测得其性能收益。

可审计数据：[完整汇总 JSON](docs/miuix-navigation/profile-summary.json)、[原始 FrameTiming / Timeline 与裁剪实验 ZIP](docs/miuix-navigation/profile-data.zip)。四组新实现的 renderer SHA256 均为 `1195b82f4b50d812399f925d0cba1af21762fa127bd39071617117a2958cb827`。无额外转场页面 build 的结构性回归通过，但这不能替代设备帧时间。

复跑方式：安装 Linux Flutter 桌面编译依赖、Xvfb、Python websocket-client，在相同锁定 SDK 下分别执行 `bash tool/run_navigation_profile.sh SOURCE_REPO PROBE_SOURCE OUTPUT CANDIDATE`，候选依次为 `before native500 280-240 300-260 320-280`。before 的 SOURCE_REPO 使用基线 `6514c8f` 独立 checkout；其余使用 `110cdbd`，PROBE_SOURCE 均指本次工具所在仓库。将各 OUTPUT 放在同一根目录的候选同名子目录后，运行 `python3 tool/summarize_navigation_profile.py OUTPUT_ROOT`。工作流记录了依赖安装步骤。原始 Timeline 可导入 DevTools 分析，本次没有声称操作过 DevTools GUI。

该探针使用受控列表和真实 NavigationBarHost，不是所有业务页面的端到端性能测试。不把软件渲染超过 16.67/8.33ms 的数量解释为真实手机掉帧率，不把时长变短解释为光栅性能提高。没有 Android GPU、120Hz 设备、实际系统手势或 DevTools GUI 录制；设备首次 shader 编译、图片解码、日志高频更新和真实课堂流量仍未测量。

## 7. 反向审查与行为对照

实际新增回归先复现了两项原生竞态：拖动中 pushReplacement 后提交误 pop 新页；同帧 removeRoute 后提交误 pop 下层页。二者在修复前失败，增加 isCurrent 门禁后通过。另有 LTR / RTL 两项像素回归证实，尚未进入完成的页面被覆盖时，全屏背景补色会隐藏更老页面；改为只补视差产生的尾部空隙，修复了该视觉问题，也限制了额外补色的面积。没有通过放宽“不得额外 pop”、像素颜色或不透明度预期来通过测试。

| 审查项 | 结论 |
| --- | --- |
| 双重动画 | delegatedTransition=null；iOS SDK 视觉动画固定；没有 Android 指针手势竞争 |
| 进度重置 / 中途切换 | route.animation 本身就是视觉进度；Android 确认不调用 SDK 重置到 upperBound 的路径 |
| 圆角跳变 | Leading 唯一责任方；系统零值保留；末段按暴露像素收敛；两种主题同规则 |
| 页面 State / 输入保护 | 保留 MaterialPageRoute 与 SDK 内部包装；纯 tick 不重建内容；取消、覆盖、主题和课件状态回归通过 |
| 重复 pop / 原生会话 | 稳定 dispatcher；移除后终止仍被原会话消费；重复 start 保持 observer 归属，避免 fallback 返回另一页 |
| PopScope / 路由竞态 | 确认前先验证原路由仍为 current，再用 maybePop 重查；返回被否决则回弹；新页面覆盖时恢复原页面并只释放本次用户手势 |
| 绘制成本 | 位移及图层复用、单一裁剪、无页级 Opacity/Scale/shadow/saveLayer；已有模糊和真实内容更新继续保留 |
| 业务副作用 | 业务改动仅 route 类型；没有更改缓存键、请求参数、JSON、状态、定时器、取消或课堂逻辑 |

原来是旧页静止、前景缩放并裁四角、600ms 单独进度映射；现在前后连续水平运动、四分之一视差、前景不透明且不缩放、Leading 统一圆角、普通时长 300/260ms、Android 进度直接跟手并从当前位置弹簧收尾。

## 8. 残留风险与验收状态

代码、Widget 回归和可用环境构建可以验证；真机视觉与性能验收尚未完成。当前云环境 adb 没有设备、没有 Android 模拟器/KVM。不能宣称所有手机已无卡顿或 Android 系统 Predictive Back 已通过真机验收。

项目当前没有嵌套 Navigator；dispatcher 挂在现有根 Navigator。未来若新增嵌套导航，需要明确最上层会话仲裁，不能简单复制多个全局观察者。当前弹窗仍遵守其原有模态转场，不纳入普通页面水平转场。

首次业务同步工作、异步缓存统计和日志刷新没有被延迟或冻结；若真机仍掉帧，需要结合实际 UI/raster Timeline 定位，而不能继续仅调曲线。系统圆角不可用时仍为统一设计回退值，SDK/设备实际几何报告及 iOS 边缘速度需硬件复核。最终采用 Leading 原生 RRect，保留系统半径与连续收敛规则；它不是 Compose absoluteSquircleClip 超椭圆轮廓的逐像素移植。

GitHub Actions 接口返回 HTTP422「Actions has been disabled for this repository」；未更改仓库 Actions 权限。恢复 Actions 后，可推送 codex/miuix-navigation 触发工作流；若已将工作流合入默认分支，也可在 Actions 手动运行。当前未宣称 GitHub runner 已执行通过。测试验证包使用本地 debug 证书，不能覆盖安装现有固定测试签名版本；本报告不将本地路径描述为公开下载地址。
