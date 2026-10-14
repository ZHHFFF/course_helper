# 代码复杂度精简审计

审计基线：`ec34e3e10e0fe91560a843359286bdce67500c5b`，2026-10-03。本文先于源代码修改生成。范围包括主入口、实验入口、全部 Dart 声明/导入、测试、依赖声明和平台资源；重点逐段阅读课件、课堂、账户、网络、缓存、导出和对应回归调用链。

## 统计口径与基线

物理 LOC 包含注释、空行；代码 LOC 是 Dart AST token 所占的非空、非注释行，不将文档、生成产物、SDK 或依赖源码计入。格式化会改变两种行数，因此最终报告同时提供相同格式化口径的对比，避免将换行数量当作精简收益。

| 范围 | Dart 文件 | 物理 LOC | 代码 LOC |
| -- | --: | --: | --: |
| 全部 Dart | 122 | 41,733 | 33,456 |
| production（lib，排除实验入口） | 90 | 34,647 | 27,587 |
| lib 全部 | 91 | 35,190 | 27,999 |
| 实验入口（CI 仍构建） | 1 | 543 | 412 |
| test（含 support） | 31 | 6,543 | 5,457 |

仓库基线有 178 个已跟踪文件；其他自有运行代码包含 Kotlin 38 行、shader 417 行。直接 production dependencies 37 个（包含 Flutter SDK 包），dev dependencies 2 个，override 1 个。37 个直接运行依赖都有 Dart 使用，flutter_lints 是分析器配置依赖：本轮没有确认可删的依赖。基线 `flutter analyze` 无问题；`flutter test` 407 通过、7 跳过。

## 目录规模和职责

| 目录 | 文件数 | 物理 LOC | 代码 LOC | 职责 |
| -- | --: | --: | --: | -- |
| lib/pages/widget | 22 | 8,115 | 6,290 | 页面组件、主题/玻璃底栏、设置、缓存和日志界面 |
| test | 30 | 6,463 | 5,403 | 单元、组件、历史缺陷回归 |
| lib/pages | 3 | 5,129 | 4,132 | 账户、登录、实时课堂 |
| lib/api | 13 | 3,843 | 3,035 | 双平台请求、雨课堂历史抓取策略、答案检索 |
| lib/pages/actives | 5 | 3,459 | 3,053 | 超星答题/评估/问卷/投票等活动 |
| lib/cache | 7 | 2,530 | 1,742 | 磁盘目录/元数据、PPT、答案、图片、预取队列、题目扫描 |
| lib/pages/courseware | 3 | 2,451 | 2,143 | 课程搜索、历史课件列表与离线浏览 |
| lib/pages/actives/sign_in | 7 | 1,965 | 1,663 | 签到策略、二维码、位置、手势等 |
| lib/utils | 10 | 1,788 | 1,215 | 日志、加密、导出、图片 key、错误说明与题目策略 |
| lib/pages/courses | 3 | 1,618 | 1,430 | 课程列表、活动入口、课程设置 |
| lib/models | 6 | 1,427 | 1,151 | 服务端解析与持久领域结构 |
| lib | 2 | 817 | 572 | 启动、主题/导航与服务器平台切换 |
| lib/pages/settings | 3 | 560 | 451 | 测试支持 |
| lib/experiment | 1 | 543 | 412 | CI 使用的玻璃层实验入口 |
| lib/session | 2 | 393 | 304 | 账户和 cookie 身份边界 |
| lib/setting | 3 | 294 | 202 | 可持久配置及响应式通知 |
| lib/push | 1 | 258 | 204 | 即时消息集成 |
| test/support | 1 | 80 | 54 | 临时文件和平台 channel 测试环境 |

## 最大文件、类、函数

| 文件 | 物理 LOC |
| -- | --: |
| lib/pages/presentation.dart | 3,293 |
| lib/pages/courseware/list.dart | 1,726 |
| lib/pages/actives/quiz.dart | 1,504 |
| lib/pages/widget/miuix_liquid_glass_nav_bar.dart | 1,219 |
| lib/api/answer_search.dart | 1,089 |
| lib/pages/login.dart | 1,006 |
| lib/pages/actives/sign_in/sign_in.dart | 973 |
| lib/pages/accounts.dart | 830 |
| lib/pages/courses/list.dart | 805 |
| lib/cache/course_cache.dart | 799 |

| 最大类 | 文件 | 起始行 | 声明跨度 |
| -- | -- | --: | --: |
| _PresentationPageState | lib/pages/presentation.dart | 124 | 3144 |
| _CoursewarePageState | lib/pages/courseware/list.dart | 113 | 1597 |
| _QuizPageState | lib/pages/actives/quiz.dart | 94 | 1411 |
| _MiuixLiquidGlassNavigationBarState | lib/pages/widget/miuix_liquid_glass_nav_bar.dart | 97 | 920 |
| _AccountsPageState | lib/pages/accounts.dart | 34 | 797 |
| _LoginPageState | lib/pages/login.dart | 224 | 783 |
| _AnswerSearchSettingsPageState | lib/pages/widget/answer_search_settings.dart | 27 | 700 |
| _CoursesPageState | lib/pages/courses/list.dart | 136 | 670 |

| 最大 production 函数/方法 | 文件 | 起始行 | 声明跨度 |
| -- | -- | --: | --: |
| build | lib/pages/presentation.dart | 2091 | 363 |
| _buildBar | lib/pages/widget/miuix_liquid_glass_nav_bar.dart | 241 | 322 |
| crawlLessonPresentation | lib/api/rc_crawler.dart | 246 | 285 |
| build | lib/pages/courses/settings.dart | 330 | 272 |
| _buildActivityTile | lib/pages/courseware/list.dart | 1340 | 234 |
| _handleMessage | lib/pages/presentation.dart | 1369 | 221 |
| build | lib/pages/widget/accounts_selector.dart | 239 | 203 |
| build | lib/pages/courses/list.dart | 605 | 192 |
| _doAutoSubmit | lib/pages/presentation.dart | 543 | 179 |
| handleScanContent | lib/pages/courses/list.dart | 356 | 171 |

测试中的 `main` 是大量独立用例的注册容器，不能把它的跨度当成单个业务函数的复杂度。大 UI build 的规模真实存在，但搬文件或压缩布局语法并不会消除业务概念。

## 主要调用链与边界

- 启动：main → Storage / ApiService / Platform / Account / Cookie / Easemob / Theme → MyApp → MyHomePage → MainPage。MyHomePage 只创建 MainPage，没有状态、策略或生命周期职责，可以折叠。
- 历史课程：CoursewarePage → RCCourseApi.getAllCourses → RCCrawler（多来源合并）→ ApiService → Dio + CookieInterceptor。crawler 有历史兼容、身份、降级策略，不能整体删层。
- 历史活动：CoursewarePage → RCCourseApi.getCourseActivities → RCCrawler.getCourseActivities → ApiService。课程 API 此方法仅转发，可直达 crawler。
- 历史课件：CoursewarePage → RCCourseApi.crawlLessonPresentation → RCCrawler.crawlLessonPresentation → RCCourseApi 的具体接口 → ApiService；crawler 再写 PptCache / 检查 SlideImageStore。中间 static course 方法只逐项传参，没有捕获 user，可删除；crawler 的缓存优先、课时 token、候选 ID 顺序、summary/web/report/socket/card 降级不可删。
- 实时课堂：PresentationPage → RCCourseApi + WebSocket → Presentation → SlideScanner / AnswerQueue / 图片预取；本页面具有请求代次、滑动 revision、课堂历史与提交快照，不能将它与离线 viewer 合并。
- PDF：各页面分别准备原始逐页图片序列 → PptExporter → isolate → 完整 PDF → 文件/分享。离线 viewer 不联网，课堂导出会等待缓存；两者不能整体共享下载生命周期。
- 缓存：CourseCache 负责目录和原子 JSON 写入；PptCache 有磁盘验证后更新内存语义；AnswerCache 容忍落盘失败且有失败结果 TTL / LRU。API 不同是职责差异，不能强行泛化成万能缓存。

未发现 UI → Controller → Manager → Service → Helper → Repository → Client 这样完整的七层空转链。存在上述两处局部纯转发和入口 Widget 空壳。

## 优先候选（前 10 个区域，按收益/风险排序）

| 项目 | 文件/模块 | 当前问题 | 建议 | 风险 | 预计减少复杂度 |
| -- | ----- | ---- | -- | -- | ------- |
| 1 / P0 死绘制器 | pages/widget/liquid_glass_highlight.dart | LiquidGlassHighlightPainter 没有 import、实例或测试引用；实际底栏用 rim/shader 实现 | 删除整文件；保留真正使用的 highlight shader | 低；需检查实验入口 | 消除 1 个未使用实现，约 128 行 |
| 2 / P0 无调用 API | api/course、active、evaluate、quiz、sign_in、answer_search | getActivePresentation、getActiveInfo、getStuScoreDetail、answerReceipt、getSignReceipt、groupSignWithUserData、getGroupAttendCount、reloadConfig 仅有声明（部分还含同名 URL） | 逐项全仓引用确认后删除；移除因此失效的 import | 低；不可将同类的活跃接口一起删除 | 去掉约 8 个入口、100–140 行 |
| 3 / P2 历史抓取转发 | api/course.dart、pages/courseware/list.dart | 两个 static 方法完整转发 crawler；单个/批量抓取重复构造候选参数 | 页面直达 crawler；共用只负责参数选择的私有方法 | 低到中；保留 cached ID fallback 和两种异常/UI 生命周期 | 少 1 层转发、1 份参数策略，约 35–45 行 |
| 4 / P1 GET 解包 | api/course.dart | 6 个 Map 接口重复 token/header/code/data 检查 | 同 API 内共享带明确返回类型的 GET 解包；列表返回接口保留独立解析 | 中；code 缺省、坏 Map 异常、身份和请求 URL 需测试 | 响应解包 6 → 1，约 65–90 行 |
| 5 / P1 缓存路径白名单 | cache/course_cache.dart、answer_cache.dart | 3 份 ASCII/rune 白名单；目录有 80 字符截断，文件名没有 | 文件名统一 CourseCache.safeFile；safeName 只加目录长度策略 | 中；不能改旧文件路径、缓存 key 或 Unicode 行为 | 白名单 3 → 1，约 35 行 |
| 6 / P3-P4 幻灯片状态 | pages/presentation.dart | 同时维护 List<PresentationSlide>、List<Map> 和页数 | UI 直接读已有模型；页数由模型长度推导；不改加载时机和 guard | 中；保留空 coverAlt 的旧行为，不能顺手改 cover 回退 | 去掉 1 个重复模型/状态容器和 1 个计数状态，约 15 行 |
| 7 / P1 离线图片 URL | pages/courseware/viewer.dart、cache/slide_scanner.dart | viewer 两个 state 各自复制 coverAlt/cover 选择 | 直接复用已使用的 SlideScanner.slideImageOf | 低；仅与 viewer 相同，实时课堂 UI 不是同语义 | URL 选择 3 → 1，约 7 行 |
| 8 / P2 启动空壳 | main.dart | MyHomePage + State 仅返回 MainPage | 入口直接 MainPage，保活/底栏组件仍保留 | 低；不动主题与 MediaQuery 初始化顺序 | 少 1 个 widget 和 1 个 State，约 14 行 |
| 9 / P5 回归 fixture | test/review_async_regression_test.dart、reverse_async_regression_test.dart | JSON adapter、应用壳、8 轮 flush、PPT fixture、setup/teardown 完全相同 | 专用课堂测试 support，维持响应延迟、泵次数与清理顺序 | 低到中；不能换 pumpAndSettle 或删除任何用例 | 6 份测试机制各 2 → 1，约 40–70 行 |
| 10 / 留待后续大型 UI | presentation / courseware list / quiz / 玻璃底栏 | 大 build/state，但回调及生命周期不同 | 本轮仅上述可测试局部精简；后续另立布局抽取主题 | 高；模块合并可能改变缓存、窗口或异步状态 | 不承诺通过搬文件获得复杂度收益 |

预计经调用证明可安全删除/合并 350–550 行（统一格式化口径；不是承诺原始物理行减少同等数量）。新增边界测试和基线格式化可能抵消原始行数收益；目标是减少重复策略、入口与状态，而不是压行。

## 全面检查结论与不建议改动的区域

- **无用类/函数/字段/import**：AST 声明和全仓引用交叉检查；flutter analyze 没有 unused import 或私有成员警告。public 字段可能由框架、动态测试或序列化使用，不能按名称频次直接删除。仅将表中有闭环证据的死入口执行删除。Shape/Presentation 元数据的解析还可能改变坏 JSON 的异常行为，本轮保留。
- **模型/转换**：Course 与缓存课程摘要、RCActivity 与 Presentation、ProblemOption 与 StandardizedOption 分属来源/持久性/答案语义；不合并。PresentationSlide → UI Map 是同一对象的字段复制，没有边界价值，适合删除。Course 的 identity、sameShallowAs、copyWith、历史默认值保持。
- **请求/retry/timeout/错误**：公共网络出口已是 ApiService；重定向、cookie 与返回 null 策略留在原处。只统一 RCCourseApi 的同语义 GET Map 解包。提交 JSON content-type、多账号部分成功与只重试传输失败必须保留；AI provider 有不同响应格式/超时/流式协议，不合并。日志与用户可见提示即使文字相似也可能有不同来源、异常语义。
- **缓存/图片/导出**：safeName 80 字符与 safeFile 无限长不能被混同；统一低层白名单而保留边界策略。预取去重序列与 PDF 逐页（保留重复/缺图）序列不能合并。JPEG/PNG 完整性检查、原子写/临时文件、删除后失效、局部下载保留和 verifyDisk 必须保留。
- **状态/生命周期**：请求 generation、slide revision、entry identity、mounted、timer、WebSocket session generation、重连退避、token 按 uid/lesson、冻结提交快照、队列 hash 去重、取消 pending 与 in-flight 差别均有独立保护职责。无证据可删；仅页数和 Map 副本为可推导状态。
- **历史兼容/feature flag**：SEED_TEST_DATA 仍由课程/账户入口使用；实验入口由 CI 构建。legacy lesson ID、candidate ID、summary/web/card 回退是已测试功能，保留。AutoAnswer 的旧延迟迁移与缓存 schema 默认值仍保护旧用户数据，不能假定过时。
- **依赖/资源**：全部直接依赖有使用；html override 保护 flutter_html 兼容。images/logo.png 与 xxxhdpi launcher foreground 字节相同，但分别被 Flutter 资源和 Android 系统装载，不能因 hash 相同删一份。其余两张图片/四个 shader 都有使用。底栏 shader/filter/rim 与 Skia 降级生命周期不等价，保留。
- **只用一处的 helper**：PptExporter 是 isolate/二进制验证边界，QuestionHash 是持久 key，ProblemPublish 是题号空间及时间策略；调用少不表示无职责。保留 CacheTestEnv（系统 channel、磁盘和静态状态隔离），仅在其上消除两套相同 classroom setup。
- **测试**：不删用例、不改断言预期；共享 fixture 保留定时行为。已有空 widget_test、7 个既有跳过用例不作为“减行”目标。新增测试针对旧路径、JSON/code 边界和 UI 模型替换后的异步回归。

## 执行与验证方案

按死入口 → 请求/抓取链 → 白名单/URL → 重复幻灯片状态/启动空壳 → 测试 fixture 五个主题分批执行。每批对修改 Dart 文件运行 dart format、flutter analyze、相关 unit/regression，最后完整 flutter test。每次失败先判定基线或本批问题；最终反向检查忽略格式化的 diff，并记录实际验证和保留区域。
