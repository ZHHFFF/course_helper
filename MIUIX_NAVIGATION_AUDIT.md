# Miuix 导航审计与实施基线

基线 commit：6514c8f（包含 PPT 题目发现、提示卡片和上一轮转场）。Flutter 3.47.6 / Dart 3.13.5；锁定 flutter_miuix 1.2.0，不能使用上游 1.3.0 才有的 API。

参考源码：Compose Miuix `6ef604ae6d53e4b241cdb89ccbf2caf86a7a33d0`；Flutter Miuix upstream `3c6f64d7f49753ce58d16ea6f9149459962fe916`（1.3.0，仅比较，实际调用以本地锁定 1.2.0 为准）。阅读 miuix-nav 的 NavTransitions.kt、NavDisplayEffects.kt、NavMotion.kt、NavDriver.kt、NavSettleEasing.kt、NavDisplay.kt 与 zh_CN/guide/miuix-nav.md。

| 根因 | 基线位置 | 修改方向 |
| --- | --- | --- |
| secondaryAnimation 未使用，旧页静止，缺少 Miuix 视差 | page_transitions.dart 的 buildTransitions | 背景按上层同一动画进度移动 -0.25W |
| 普通进入/退出均 600ms；进入 easeOutCubic，退出 easeInCubic；取消剩余时间约 600ms×未完成比例，确认重播 600ms 但重新映射剩余距离 | page_transitions.dart | 集中参数；比较 Compose 500ms、进入 280/300/320 和退出 240/260/280；系统收尾临界阻尼、携带可估计的释放速度 |
| 1.5% 缩放 + All 圆角，不符合水平 MiuixDefault | card_page_transition.dart | 移除缩放；Leading 系统圆角，角幅按露出距离连续收敛 |
| 每帧重建 Stack、Transform、DecoratedBox、ClipRRect；动态阴影增加绘制成本 | card_page_transition.dart / AnimatedBuilder | 一个渲染对象监听 primary/secondary，仅更新绘制；复用 SDK 已有内容 RepaintBoundary，单一原生圆角裁剪，无 saveLayer 阴影 |
| SDK 确认会从 upperBound 重播；只有前景重映射，直接补背景会失配 | Android observer 的 commit/visualProgress | 使用 MaterialPageRoute 的公开 createSimulation 扩展点，让 route.animation 本身即视觉进度；前后页直接共享 SDK primary/secondary；不访问受保护控制器的外部代码 |
| observer 随页面销毁，原生终止消息可能落到其他页面 | 每页 WidgetsBindingObserver | Navigator 级稳定 dispatcher；系统会话持续到终止，页面移除也不会重复 pop |
| 页面初始化与内容可能自主刷新 | LogViewer AppLogger.revision、CacheManager 的异步 stats、顶栏/玻璃滤镜 | 保留真实更新，隔离导航绘制；不推迟数据请求，不隐藏加载，不冻结玻璃 |

Compose MiuixDefault：全宽线性前景、0.25W 线性视差；几何不含 easing。Leading / All 为独立效果；Leading 只裁 LTR 左角或 RTL 右角。默认普通运动 500ms、NavSettleEasing(response=.8,damping=.95)，手势 critical spring stiffness146，threshold .0025。被覆盖 alpha=.9 与默认 dim=.5 可配置；本项目保持页面不透明，以单一黑色 scrim 实现轻微变暗，避免整页 Opacity。

Flutter 1.2.0 可用：MiuixMotion.standardDecelerate、standardAccelerate、sinOut、pressSpring（1/.35）、bouncySpring（.85/.45）、folmeSpring。没有 NavDisplay/NavTransitions 导航 API；需应用适配。退出不使用 bouncySpring，防止过冲。

此前采用的 cupertino_predictive_back 1.0.0 源码把 CupertinoPageTransition 与 SDK PredictiveBackPageTransitionsBuilder 嵌套，并随 popGestureInProgress 切换活动动画；后者采用 SDK 自身的预测性缩放、圆角与收尾规则。当前基线已移除该依赖；审查其历史缓存源码后，本次继续使用应用适配器，没有重新引入它，也没有新增应用依赖。

审计所有生产 MaterialPageRoute 调用点、两条命名路由、PopScope；没有 CupertinoPageRoute、PageRouteBuilder、WillPopScope 或嵌套 Navigator。课件 _stage 和底栏 PageView 是内部状态，不改其业务行为。

验证：保留原覆盖，扩展真实设置→外观/日志/缓存，多个中间帧、前后同步、快速返回、左右边缘、取消/确认、PopScope、状态保留、系统会话中移除/切换路由，检查绘制层和内容 build 次数；运行分析、全量测试、Android 构建。提供可复现 Profile 探针和原始帧数据。云端 adb 无设备、无 Android emulator/KVM；GitHub Actions 被禁用后，已在本地 Docker / Xvfb / llvmpipe 完成五组 Profile 对照，原始数据和结果见 MIUIX_NAVIGATION_REPORT.md。软件光栅化仍超出帧预算，不能宣称 Android 真机性能或 OEM 预测性返回验收。
