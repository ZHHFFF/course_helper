# 代码复杂度精简报告

基线：`ec34e3e10e0fe91560a843359286bdce67500c5b`，2026-10-03。先完成 [审计](CODE_REDUCTION_AUDIT.md)，再按五个主题修改；最后独立反向比较语义 diff、补充边界回归并运行完整测试。没有新增产品功能。

主要收益：删除 8 个无调用 API 入口和 1 个无使用绘制器，折叠 2 个 crawler 转发入口及一个空 Widget/State；课件 Map 解包 6 份变为 1 份，路径白名单 3 份变为 1 份，离线图片 URL 选择 3 份变为 1 份；删除课堂 UI 的幻灯片 Map 副本和独立页数状态。测试的 adapter、应用壳、flush、PPT fixture、初始化、清理也各统一为一个实现。

## 1. 修改前后数据

Production 指 `lib` 排除仍由 CI 构建的 `lib/experiment`；test 包含 support。物理 LOC 包含注释/空行，代码 LOC 指至少含一个 Dart AST token 的行。统计不含生成代码、依赖、SDK、文档和构建输出。

| 指标 | Before | After | 说明 |
| -- | --: | --: | -- |
| Production LOC（原始物理行） | 34,647 | 34,767 | +120；原有未格式化内容被标准换行 |
| Production LOC（统一格式化口径） | 36,239 | 35,771 | **−468**，约 1.29% |
| Production 代码 LOC（原始布局） | 27,587 | 27,823 | 换行会影响此指标，不能作为行为或复杂度指标 |
| Production 词法 token | 152,365 | 150,266 | **−2,099**；排除注释和可选逗号，基本不受排版影响 |
| Test LOC（原始物理行） | 6,543 | 6,818 | +275；保留旧用例，新增边界覆盖 |
| Test LOC（统一格式化口径） | 6,873 | 7,057 | +184 |
| Test 代码 LOC（原始布局） | 5,457 | 5,716 | +259 |
| 全部 Dart 物理 LOC（含实验） | 41,733 | 42,128 | 原始行数没有下降，不将其包装为减行成果 |
| Production Dart 文件 | 90 | 89 | 删除孤立绘制器 |
| Test Dart 文件 | 31 | 34 | 新增 1 个测试模块、2 个专用 support |
| 全部 Dart 文件 | 122 | 124 | 含实验入口 |
| 仓库自有文件 | 178 | 182 | 已跟踪/待加入文件；新增两份报告，排除 ignored 输出 |
| 运行直接 dependencies | 37 | 37 | 含 Flutter SDK 包，无已证实可删项 |
| dev dependencies / overrides | 2 / 1 | 2 / 1 | 锁文件也未变更 |
| 最大 Dart 文件 | presentation.dart，3,293 | presentation.dart，3,354 | 原始物理行增加 61 |
| 最大文件（统一格式化口径） | presentation.dart，3,393 | presentation.dart，3,354 | −39；保留课堂完整生命周期 |
| 测试通过 / 既有跳过 | 407 / 7 | 424 / 7 | 新增 17 个运行用例，未减少旧覆盖 |

统一口径使用同一个 Dart 3.13.5 formatter、项目语言版本、默认 80 列，分别格式化基线和最终源码后计数（通过 `dart format --stdin-name=<原路径>`）。**原始 production LOC 增长来自格式化，项目在重复概念和实现数量上变小；不是声称物理行数下降。** Kotlin 38 行、shader 417 行、实验入口 543 行保持不变。

## 2. 删除内容和调用证明

“无调用”不是根据 import 图或类名频次猜测：检查全部 Dart AST 标识符使用、全仓符号/调用/导入检索、实际页面入口及 CI 实验入口；区分声明、URL 字符串、框架 override 和测试动态调用。应用 `publish_to: none`，未发现仓库之外的插件或公开库入口消费这些方法。

| 删除内容 | 原文件 | 为什么无用 / 安全 | 如何确认调用者 |
| -- | -- | -- | -- |
| LiquidGlassHighlightPainter 及其孤立文件（128 行） | lib/pages/widget/liquid_glass_highlight.dart | 没有消费者或顶层初始化副作用；实际底栏使用 rim painter / shader | 文件 import 与类实例引用为零，主入口、实验入口、测试均无引用；保留实际 highlight shader |
| ActiveApi.getActiveInfo | lib/api/active.dart | 旧活动详情入口没有调用；使用的是 getActiveInfoWeb | AST 非声明引用为零，全仓调用检索仅原声明；活跃 Web 方法不变 |
| EvaluateApi.getStuScoreDetail | lib/api/evaluate.dart | 评分详情入口没有调用；评分加载/提交走当前接口 | 同上；未删除 stuSubmitAnswer 或页面 |
| QuizApi.answerReceipt | lib/api/quiz.dart | 回执方法没有调用，没有定时注册或回调注册 | 同上；保留测验/投票/问卷所有活跃 API |
| SignInApi.getSignReceipt | lib/api/sign_in.dart | 未调用的签到回执 | 同上；活动加载和签到策略保留 |
| SignInApi.groupSignWithUserData | lib/api/sign_in.dart | 没有调用者的旧群聊签到入口 | 同上；未删除当前群聊签到路径 |
| SignInApi.getGroupAttendCount | lib/api/sign_in.dart | 未调用的群签到计数入口 | 同上；仍用的 getGroupSignDetail / getGroupAttendList 保留 |
| RCCourseApi.getActivePresentation | lib/api/course.dart | 三个候选 URL 的旧 fallback 从未被当前 crawler 或课堂入口调用 | AST/调用检索为零；历史 crawler 的实际 summary/web/report/socket/card 降级路径完整保留 |
| AnswerSearchApi.reloadConfig | lib/api/answer_search.dart | 纯转发且未调用；设置写入路径已自行更新 AI 配置 | AST/调用检索为零；initialize、设置 setter 和 _loadAIConfig 全部保留 |
| QuizApi 的 AccountManager import | lib/api/quiz.dart | 唯一消费者是删除的 answerReceipt | 删除后 analyze 无 unused/undefined 问题 |
| Presentation / RCActivity import | lib/api/course.dart | 只用于下面被折叠的 static crawler 转发方法签名 | 检查该文件全部类型引用，删除后 analyze 通过 |
| RCCourseApi.getCourseActivities / crawlLessonPresentation | lib/api/course.dart | 不是死功能：删除的是逐参数转发层，真实实现仍是 RCCrawler | 所有生产调用原本只在 courseware/list；逐处改为 crawler / 带候选参数策略的页面私有方法，最终无旧调用 |
| MyHomePage / _MyHomePageState | lib/main.dart | 空 Widget 和 State 只返回 const MainPage，没有状态、策略、dispose 或 inherited scope | 唯一构造位置为 MyApp.home，改为 MainPage；Tab/登录/底栏回归通过 |
| _slides Map 副本、_totalCount 字段 | lib/pages/presentation.dart | Map 逐字段复制已有模型，计数始终由同一份 slides.length 写入；没有独立更新者 | 枚举所有读写点；模型赋值时机保留，UI/历史点击/翻页改读模型，页数直接取 length |
| 两个 cover != null 的死分支 | lib/pages/presentation.dart | 原 Map 的 coverAlt 总来自非空类型 String 字段；缺省/null JSON 已由模型转成空串，分支永不进入 | 检查模型解析和唯一 Map 构造；新增 3 个用例在普通及全屏 UI 验证空/缺省/带空格值，继续走原图片路径 |
| AnswerCache._safeFile、safeName 的复制白名单 | lib/cache/answer_cache.dart、course_cache.dart | 与 CourseCache.safeFile 的 rune 白名单及 unknown 默认一致；目录截断仍保留 | 逐条件比较，旧路径读/写/删除及超长/中文/emoji/穿越字符回归通过 |
| viewer 两个 _urlOf | lib/pages/courseware/viewer.dart | 选择 coverAlt、否则 cover，再 trim，与 SlideScanner.slideImageOf 完全一致 | 比较空/空白/有值两分支，调用都改用原 scanner 方法 |
| 测试中的两套 _Adapter / _app / _flush / _ppt / setup / teardown | test/review_async_regression_test.dart、reverse_async_regression_test.dart | 只删复制实现，测试操作与断言保留 | AST 比较确认原有 392 个用例声明无删除；除 helper 更名及一个 if 补括号外，旧测试 body token 不变 |
| fixture 合并后失效的测试 import | 上述两个 regression 文件 | dio/typed_data/convert/course_cache/platform/miuix 等按文件剩余使用分别移除 | analyze 无 unused import；仍用的异常类型、账号和登录测试依赖保留 |

没有删除已使用的资源、package、feature flag、schema 兼容、异常处理、cancel、retry 或任何测试。

## 3. 合并内容及语义一致性

| 合并 | 原来的重复点 | 共享实现 | 一致性依据 / 保留差异 |
| -- | -- | -- | -- |
| 6 个课件 Map GET 接口 | 每个方法复制 bearer、xtbz、账号、code/data 检查和 typed Map 转换 | RCCourseApi._getLessonMap | 均是 GET，code 为 0 或缺省/null 才接受 Map data，其他返回 null；Map.from 的类型转换错误继续传播；每次调用读取当前 bearer。列表响应接口保留独立解析；签到/提交完全不动 |
| 单个/批量抓取参数 | coursewareId、旧缓存 lesson/presentation ID、classroom ID 与候选列表选择逐项重复 | _CoursewarePageState._fetchActivityPresentation | 原参数表达式逐项一致，cached 查找仍在请求前同步发生；helper 只负责这份参数策略，不合并两种提示/计数/异常/清理/entry guard |
| 缓存白名单 | 三份 trim + ASCII 字母数字/下划线/连字符 + rune 替换 | CourseCache.safeFile | 不使用 UTF-16 code unit 替换，不改变 emoji 下划线数量；safeName 单独保留 80 字符截断，文件名不截断；内存 key 与磁盘 schema 均不改 |
| 离线 URL 选择 | 两个 viewer state 复制 scanner 的图片选择 | SlideScanner.slideImageOf | 都是 alt.trim 非空则取它，否则取 cover.trim；**实时课堂 UI 不在此次 URL 合并内** |
| 幻灯片表示 | 类型模型 → 字段几乎完全相同的 UI Map，再维护页数 | 原 List<PresentationSlide> | UI 所读 problem/coverAlt 是同一个原对象/原字符串，未增加 trim/回退或 DTO 默认值；题目 dt 的 copyWith 仍独立，不污染 slide.problem |
| JSON 测试网络 | 两份 HttpClientAdapter 的相同 fetch/close | test/support/json_http_adapter.dart | await 用例响应 Future，jsonEncode，HTTP 200 与相同 content-type；原先忽略 requestStream/cancelFuture/close 的语义相同，错误照常传播；也服务新 GET 边界测试 |
| 课堂测试环境与数据 | 完全相同的初始化/清理、MaterialApp+Miuix、8 轮等待、按 index 建空 PPT | test/support/classroom_test_env.dart | 保留 Cache → Platform reset → Account → Api → Platform → root 顺序，清理先 session/reset 再 Cache.dispose；仍是 8 次 1ms pump + runAsync 5ms，没有换 settle 或改受控 Future 的竞争顺序 |

没有制造跨模块万能 Utils、通用 DTO、动态类型缓存框架或巨型 service。新增 helper 都有明确的共享策略或测试隔离职责。

## 4. 抽象层精简

历史活动 Before：

`CoursewarePage → RCCourseApi.getCourseActivities → RCCrawler.getCourseActivities → ApiService → Dio`

After：

`CoursewarePage → RCCrawler.getCourseActivities → ApiService → Dio`

历史课件 Before：

`CoursewarePage（两份参数策略） → RCCourseApi.crawlLessonPresentation → RCCrawler → 各课件 API / 缓存 / 图片完整性检查`

After：

`CoursewarePage（单份候选参数策略） → RCCrawler → 各课件 API / 缓存 / 图片完整性检查`

被删除的两处 static course 入口没有状态、user 捕获、鉴权转换、缓存、策略或生命周期，只转发原参数。页面私有 helper 有候选 ID 和本地缓存 fallback 策略；crawler 本身有历史兼容和抓取生命周期，保留。

启动 Before：

`MyApp → _GlassNavInsets → MyHomePage → _MyHomePageState.build → MainPage`

After：

`MyApp → _GlassNavInsets → MainPage`

空壳没有生命周期职责；MainPage、Tab 保活、主题、底部 padding 与 viewPadding 规则保持。

## 5. 风险审查

| 区域 | 本次影响和保护 | 验证 |
| -- | -- | -- |
| 课件列表 | 活动请求直达原 crawler；远程/本地合并、排序、离线 fallback 不变 | crawler/cache/link/async/Tab 测试 |
| 课件搜索 | 查询、教师/课程名、大小写和原顺序实现未改 | courseware_search_test |
| 课件切换 | 仅删除 Map 副本；generation、pending Future identity、slideRevision、mounted 及页码 clamp 保留 | 两套 async 回归覆盖 A/B/A、迟到请求和最新翻页 |
| 历史 PPT | 原 URL、候选 ID、降级顺序、token 范围保留 | rc_crawler、GET contract、历史下载测试 |
| 历史题目 | timeline 归属及加载前保存、跨课件点击、题号命名空间不变 | reverse_async、problem_publish/resync |
| PPT 下载 | metadata + 所有有效图片才算完整，失败仍保留部分 | historical_ppt_download_test |
| PPT 缓存 | 目录截断、文件名、verifyDisk、写后内存更新、删除失效不变 | courseware_cache、review/reverse_cache |
| 图片缓存 | URL key、digest、并发队列、格式验证、暂停/取消不变；离线选择共用 scanner | image_cache_key、历史下载、scanner；新课堂 coverAlt 回归 |
| PPT 导出 | 保留原始逐页重复/缺图序列与全部成功校验；isolate、JPEG/PNG 校验及保存分享不变 | ppt_exporter、scanner、历史下载 |
| 课堂消息 | WebSocket op、事件时序、历史处理未改 | async、problem_publish/resync |
| 重复消息处理 | 请求合并、重复题目/提交成功账号集合、revision/session 保护不改 | async、queue/hash、token 回归 |
| 异步取消 | 所有 timer/stream/socket 关闭、pending cancel 与 in-flight 保留语义不改 | async/queue 回归；逐方法 token 对比 |
| 网络异常 | ApiService timeout/retry/redirect/cookie/error 返回策略不变，Map 解包仍严格区分 code/data | GET contract、网络失败 async、answer/body 回归 |
| 本地文件 | 路径 ASCII/rune 白名单一致、目录 80 截断不变、文件名不截断；原子写和部分删除失败处理不变 | 新旧路径 read/write/remove、cache 回归 |
| 登录/鉴权 | 活跃登录 API、Cookie、账号持久化/切换不变；GET 请求仍带原 userId，动态读取 bearer | login_fix、Tab/login、QR 迟到/dispose、lesson_token、GET contract |

保留高风险实现：PPT 与答案缓存的不同失败语义、实时与离线 viewer 的不同网络职责、PDF 与预取的不同页序列、课程/活动/题目模型边界、AI provider 协议、WebSocket 重连/心跳、提交快照及部分成功、多账号课时 token、旧缓存/设置迁移、实验入口及 SEED_TEST_DATA。未对大 UI 做整体拆分或职责合并。

验证是本地单元/组件/回归测试及本机 HTTP 图片服务；没有设备/模拟器，也没有访问真实雨课堂账号验证服务器响应或系统分享 UI。本次未重新生成 APK，Android 代码和依赖未改变。

## 6. 实际验证

环境：Flutter 3.47.6 / Dart 3.13.5，使用现有云环境 `/workspace/.cloud-setup/env.sh`。基线 analyze 无问题、完整测试 407 通过 / 7 跳过。

每个主题对修改的 Dart 代码执行 `dart format` 和 `flutter analyze`，再执行下表相关测试与完整测试。第一批完整测试在最后用从基线恢复、仅包含第一批改动的独立 `/tmp` 快照补验；没有覆盖主工作区。

| 批次 | 实际相关 `flutter test` 文件（均在 test/ 下） | 相关结果 | 完整 `flutter test` |
| -- | -- | -- | -- |
| P0 死入口 | answer_search、rc_crawler、rc_lesson_token、rc_answer_body、review_async_regression、reverse_async_regression | 108 通过 | 第一批隔离快照 407 通过 / 7 跳过 |
| GET / crawler 链 | rc_course_response、rc_crawler、rc_lesson_token、rc_answer_body、historical_ppt_download、courseware_cache、courseware_link、courseware_search、review_async_regression、reverse_async_regression | 115 通过 | 419 通过 / 7 跳过 |
| 路径 / URL | answer_cache、course_cache、courseware_cache、historical_ppt_download、slide_scanner、ppt_exporter、review_cache_regression、reverse_cache_regression | 113 通过 / 7 跳过 | 421 通过 / 7 跳过 |
| 模型状态 / 空 Widget | review_async_regression、reverse_async_regression、problem_publish、problem_resync、rc_answer_body、rc_lesson_token、answer_queue、slide_scanner、tab_and_login_flow、miuix_nav_metrics、login_fix | 109 通过 | 421 通过 / 7 跳过 |
| 测试 fixture | review_async_regression、reverse_async_regression、rc_course_response | 38 通过 | 421 通过 / 7 跳过 |
| 反向审查补充回归 | reverse_async_regression（新增 3 个 coverAlt 用例） | 13 通过 | **最终 424 通过 / 7 跳过** |

所有文件名称均带 `_test.dart` 后缀。例如第二批包含实际执行的 `flutter test test/rc_course_response_test.dart ...`。最终实际执行 `flutter analyze` 为 **No issues found**，`flutter test` 为 **All tests passed**。`git diff --check` 通过。

实施中修正过分析失败：格式化将原有单行 if 换行后触发花括号 lint；fixture 合并后留下一个 unused import；新增缓存测试最初误写 delete，实际 API 名为 remove。均在继续下一批前修正。没有通过修改既有断言预期掩盖失败，也没有新增 skip。7 个跳过保持基线状态。

## 7. 反向审查结果

重新从“找出重构导致的 bug”的角度比较基线与最终源码，而非只检查编译成功：

- 按文件、类、方法对比 AST token，过滤注释/排版/可选逗号：未变化的网络出口、checkIn、answer body、socket 消息处理、初始化、dispose、提交策略、缓存写入和失效 guard 没有语义改动。变化均限定在表中的共享调用、字段读取、死入口和无副作用补括号。
- 核对共享 GET 的六个 URL 和顺序参数；仍是原账号/GET/xtbz，bearer 在每次请求前取值，无新增缓存或 retry。Map/null/code/非法 data 的 12 个运行用例验证原响应契约。
- 核对旧 safeName / 两种 safeFile：空串、trim、非法字符、Unicode rune、超长目录和文件名结果相同；没有改变 memory key、PPT presentationId、图片 digest 或 JSON 默认值。
- 核对 slide UI Map 原字段均直接取自同一个 model；只删除副本，不改变 problem identity、copyWith、JSON 解析、加载赋值顺序或代次。页数原来只有初始化和加载时写入，因此可由模型推导。
- 特别检查空 coverAlt：没有采用 scanner 的 cover 回退来“修正”课堂 UI。新增普通/全屏用例确认原值（含空格）、空串与 null JSON 均保持原行为；删除的 null arm 确实不可达。
- 逐条保留 generation、revision、mounted、entry identity、Future identity、timer cancel、WebSocket 关闭及课时 token guard；原 stale-request 和历史题目回归全部通过。
- 核对 MyHomePage 没有 inherited scope、RenderObject、PageStorageKey 或初始化/dispose 逻辑；仅删除空 Element，原 MainPage 状态、主题和 Tab 保活仍在。
- 比较所有旧测试声明与 callback token：原有 392 个声明全部存在，只有 helper 名更换及一个 if 的等价括号，断言内容不变。新增 5 个参数化/独立声明生成 17 个运行用例。

审查未发现需要回滚的行为变化。剩余不确定性是未执行真实设备和真实服务器联调；没有以此为理由删掉相关保护或兼容逻辑。
