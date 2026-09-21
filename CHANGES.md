# 答案检索模块 - 代码变更文档

## v3 更新（本次）—— 修复无法调用 API + 答案一键回填 + 运行日志

### 0. 根因：地址少了一段 `/chat/completions`

实测用户填的地址：

| 请求地址 | 结果 |
|---|---|
| `.../compatible-mode/v1` | **HTTP 404** |
| `.../compatible-mode/v1/chat/completions` | HTTP 401 `invalid_api_key`（接口存在） |

v2 是把用户填的地址**原样 POST**，没有补全；404 异常又被静默吞掉，
界面上只显示「未找到相关答案」，所以完全看不出问题。

### 1. 修 API 调用（`lib/api/answer_search.dart`）

- **地址自动补全** `AnswerSearchApi.normalizeApiUrl()`
  - `/compatible-mode/v1`、`/v1` → 补 `/chat/completions`
  - `/compatible-mode` → 补 `/v1/chat/completions`
  - 已是 `/chat/completions` → 原样；结尾多余斜杠、复制粘贴带的引号都会清掉
- **超时放宽**：检索 `连接 20s / 接收 180s`（可配，默认 180）；图片下载 `20s / 60s`；测试连接 `20s / 180s`
  - 原因：`qwen3.8-flash` 属混合思考模型，默认开思考，官方实测慢约 3 倍并建议超时 ≥180s
- **请求体**：显式 `stream: false`、`max_tokens: 2048`；
  模型名以 `qwen3` / `qvq` 开头时注入 `enable_thinking: false`（其他模型不传，避免 400）
- **错误可诊断**：Dio 放开 4xx（`validateStatus`），自己解析
  `{"error":{"code":"...","message":"..."}}`，统一成
  `认证失败（401）：...｜401 → invalid_api_key: ...` 这种文案
- **解析增强**：`message.content` 为空时回退读 `message.reasoning_content`；
  剥离 ` ```json ` 围栏；`answer` 是数组时自动 join
- **诊断字段** `AnswerSearchApi.lastRequestInfo`（`AIRequestInfo`）：
  实际请求地址 / 模型 / HTTP 状态码 / 耗时 / 错误，弹窗与设置页都会展示
- **Prompt 改为返回选项 key**：新增 `answerKeys` 字段，并在题面里列出「answerKeys 只能从这些选项字母里选」
- 新增 `AnswerSearchApi.presets`：阿里云百炼 / 百炼旧域名 / DeepSeek / OpenAI / 自定义

### 2. 设置页强化（`lib/pages/widget/answer_search_settings.dart`）

- 服务商**预设按钮组**（ChoiceChip），点一下自动填地址与模型，并显示该服务商的注意事项
- **实际请求地址实时预览**：随输入变化，发生补全时高亮为绿色并标注「已自动补全」
  —— 从根上防止再出现「少一段路径」
- 新增**关闭思考模式**开关（默认开）与**接收超时**输入框（默认 180 秒）
- 测试连接：使用与正式检索一致的参数；失败时展示**服务端原始返回**，并按 401/404/400/超时分别给排查建议
- 配置项持久化：`answer_search_disable_thinking`、`answer_search_timeout_seconds`

### 3. 答案一键回填（不回填不提交）

- `AnswerSearchResult` 新增 `answerKeys`，以及 `matchOptionKeys()` / `lettersOf()` / `judgementOptionKey()`
  - 优先用 `answerKeys`；没有则从 `answer` 文本里抠字母（`AC` / `A、C` / `选A和C` 都认）
  - 判断题把「对/正确/是/√」「错/错误/否/×」映射到值为对/错的那个选项
  - 「不正确」不会被误判成「正确」
  - 返回值只含题目真实存在的 key，并按选项原始顺序排列
- 结果弹窗（`answer_search_dialog.dart`）每条结果新增：
  - 「复制答案」按钮
  - 「填入 A、C」按钮 → `Navigator.pop(context, result)` 回传给调用页
  - 多选题只给 1 个 key 时给黄色提醒；匹配不上选项时按钮置灰并给出说明
  - 空结果时除了失败原因，还会展示实际请求地址 / 模型 / HTTP 码 / 耗时
- 雨课堂页（`presentation.dart`）：`_searchAnswer()` 接住返回值 → `_applyPickedAnswer()` 写入
  `_answer`（选择/判断）或 `_textAnswer`（填空/简答），并弹出「已填入 A、C，请核对后提交」
  - 顺带补上 `problemType == 6`（判断题）的选项渲染，此前这类题根本不显示选项
- 学习通练习页（`quiz.dart`）：写入 `quiz['personAnswer']['myoption']`；
  填空/简答结构较复杂，改为**复制到剪贴板**并提示手动粘贴
- **始终不自动提交**，必须由用户核对后手动点提交

### 4. 运行日志系统（新增）

**新增文件**：`lib/utils/app_logger.dart`、`lib/pages/widget/log_viewer.dart`

目的：出问题时不用再靠猜，直接把日志导出来就能定位是 Key、地址、模型还是网络的问题。

`AppLogger`：

- 内存**环形缓冲** 3000 条（`maxEntries`），界面通过 `ValueNotifier<int> revision` 实时刷新
- 同时**按天落盘** `logs/app-YYYY-MM-DD.log`，单文件超 5MB 自动分卷（`-part2`、`-part3`…）
- 启动时清理 **7 天前**的旧日志（`keepDays`）
- 目录优先用 `getExternalStorageDirectory()`（Android 上不需要额外权限就能被文件管理器看到），
  失败回落到 `getApplicationDocumentsDirectory()`
- **Key 自动脱敏** `redact()`：`sk-xxx`、`Bearer xxx`、`api_key` / `apikey` / `access_token` /
  `password` / `secret` / `token` 字段一律打码成「前 6 位 + `****` + 后 4 位」，不足 10 位整体打码
  - ⚠️ 踩坑：Dart 的 `RegExp` **不支持内联 `(?i)` 标志**，写了会在运行到那一行时直接抛
    `FormatException`。必须改用 `RegExp(..., caseSensitive: false)`。已加测试锁住
- 单条消息超过 4000 字符自动截断并标注原长度（避免一次请求把整个日志刷爆）
- 写文件走 `_writeQueue` 串行化，避免并发写导致顺序错乱
- 便捷方法 `d/i/w/e(tag, message)`；`exportText({minLevel})` / `flush()` / `clear()`

`LoggingInterceptor`（Dio 拦截器）：

- 请求：method / uri / headers / body，并在 `options.extra` 里塞入开始时间戳
- 响应：状态码 + 耗时 + body（`logResponseBody: false` 可关掉，图片 base64 用）
- 异常：`DioExceptionType` + message + 服务端返回体

接线位置：

- `main.dart`：`await AppLogger.init()` 提前到最前面；安装 `FlutterError.onError` 与
  `PlatformDispatcher.instance.onError` 全局兜底，未捕获异常也会进日志
- `answer_search.dart`：`LoggingInterceptor(tag: 'AI请求')`，图片下载用
  `LoggingInterceptor(tag: 'AI图片', logResponseBody: false)`（否则 base64 会淹掉日志）；
  检索各阶段（开始 / 地址 / 模型 / 超时 / HTTP 非 200 / 内容为空 / 成功 / 异常 / 图片过大）都有落点
- `accounts.dart`：右上角菜单新增「运行日志」入口

`LogViewerPage`：

- 顶部信息卡：内存条数、当前文件大小、文件路径、保留策略
- 级别筛选：全部 / 警告及以上 / 仅错误（`LogLevel.weight` 比较）
- 列表倒序（最新在最上），**长按单条复制**
- 底部「复制全部」与「导出日志（分享/发送）」
  - 导出走 `SharePlus.instance.share(ShareParams(files: [XFile(...)]))`，
    可直接发微信 / QQ / 邮件，或存到文件
  - ⚠️ 踩坑：`share_plus` 13.x 已移除旧的 `Share.share()`，必须用新的 `SharePlus.instance`
  - ⚠️ 踩坑：iOS/iPadOS 需要 `sharePositionOrigin`，且要在 `await` 之前先取好，否则会报错
- 「清空」带二次确认

### 5. 测试

`test/answer_search_test.dart` 从 22 个用例扩充到 **53 个**，新增覆盖：
地址补全（8 种输入形态）、`enable_thinking` 注入条件、多模态 content 构造、
错误体解析、404/401 文案、代码围栏剥离、`answerKeys` 匹配、判断题映射、`lettersOf`。

`test/app_logger_test.dart`（新增 **16 个**用例）：脱敏（sk- / Bearer / 大小写 / JSON 字段 /
camelCase / 短值整体打码 / 普通文本不动 / 空串）、截断（未超长 / 超长标注 / 刚好等于上限）、
级别权重与标签、`LogEntry.formatTime` 毫秒补零与 `line` 格式、级别筛选。

**合计 69 个用例全部通过**，`flutter analyze` 在我改动的文件上零告警
（剩余 15 条 info/warning 全部来自上游原有代码）。

---

## v2 更新

在 v1（答案检索基础能力）之上，新增三项能力：

### 1. 题目采集更准 + 支持识别带题的 PPT

**改动文件**: `lib/models/answer_result.dart`、`lib/api/answer_search.dart`、`lib/pages/presentation.dart`、`lib/pages/actives/quiz.dart`、`lib/pages/widget/answer_search_dialog.dart`

- `StandardizedQuestion` 新增字段：
  - `slideText` - 雨课堂当前 PPT 页里所有形状的文字（`problem.body` 为空时兜底）
  - `imageUrls` - 带题图片地址列表（雨课堂当前页封面 / 学习通题干里的 `<img>`）
  - `imageHeaders` - 拉取图片所需的请求头（学习通图片需要鉴权）
- 新增派生属性：`effectiveText`、`hasText`、`hasImage`、`needsImageRecognition`、`isUsable`、`typeLabel`、`isChoice`、`isMultipleChoice`
- 题型识别增强：
  - 雨课堂补上 `problemType == 6` → 判断题（原来落到 unknown）
  - 服务器没给题型时，按选项特征推断（>1 个正确答案 → 多选；只有"对/错"两项 → 判断）
  - 学习通 `type == 5` 归为投票题
- **PPT 识图**：`AIAnswerProvider` 会把题目关联的图片下载下来转成 base64 data URL，
  以多模态消息（`text` + `image_url`）发给模型。
  这样不受图片防盗链、鉴权头限制，题目只写在 PPT 上也能识别。
  - 单张图片上限 5MB，最多 3 张，超限自动跳过
  - 发送给 AI 的提示词里会明确写出题型，并提示"多选必须给出全部正确选项"
- 雨课堂页面新增 `_currentSlideText()` / `_currentSlideCover()`，把当前页文字和封面一起交给检索模块
- 检索弹窗新增题型标签、来源标签（题干 / 题干+课件图片 / 课件图片（AI 识图））、选项数量
- 题目彻底拿不到时，弹窗直接给出明确提示，不发无效请求

### 2. API 设置页新增「测试连接」

**改动文件**: `lib/pages/widget/answer_search_settings.dart`、`lib/api/answer_search.dart`

- 新增 `AnswerSearchApi.testConnection({apiUrl, apiKey, model})`
  - 发送一条最小 Chat Completions 请求（`max_tokens: 16`）
  - 返回 `AIConnectionTestResult{success, message, detail, latencyMs}`
  - 区分地址为空 / 地址格式错 / Key 为空 / 401 / 403 / 404 / 429 / 5xx / 超时 / 断网
- 设置页新增「测试连接」按钮：
  - 直接用输入框当前内容测试，**不需要先保存**
  - 测试中显示 loading 并禁用按钮
  - 结果弹窗展示结论、耗时、服务端返回的原始错误信息、排查建议
- 顺带把 API Key 输入框加上「显示 / 隐藏」切换

### 3. 答题提交能识别网络失败

**改动文件**: `lib/utils/network_error.dart`（新）、`lib/pages/presentation.dart`、`lib/pages/actives/quiz.dart`

- 新增 `lib/utils/network_error.dart`：
  - `describeError(Object) -> RequestErrorInfo{kind, message, error}`
  - `describeErrorShort(Object) -> String`、`isNetworkError(Object) -> bool`
  - 覆盖 DioException 全部 8 种类型，以及 SocketException / TimeoutException / HandshakeException
  - 分类：`network`（断网、超时、连不上、证书）/ `auth`（401、403）/ `server`（5xx）/ `request`（4xx）/ `unknown`
- 提交时在 `sendForEachUser` 的闭包内 `try/catch` 记录每个账号的异常原因（按 uid 归集），
  再 `rethrow` 保持原有行为不变
- 失败列表里网络异常显示为 `张三: [网络异常] 连接超时：无法连接到服务器`，与业务失败区分开
- 结果弹窗区分四种标题：
  - `全部提交成功`
  - `网络异常，提交未完成`（全部账号都是网络失败）
  - `部分失败（含网络异常）`
  - `部分失败`
  - 并给出"网络异常表示请求没有到达服务器，请检查手机网络后重新提交"的提示
- 雨课堂 `_checkToken()` 的签到同样接入网络错误识别
- 弹窗内容改为可滚动，避免失败账号多时被截断

### 测试

`test/answer_search_test.dart` 从 6 个用例扩充到 20 个，覆盖：
- 题型识别（含 type 缺失时的推断、type 16 判断、type 5 投票）
- 图片地址提取与自定义解析函数
- `slideText` 兜底、`needsImageRecognition`、`isUsable`
- 网络错误分类

---

## v1 内容（答案检索基础能力）

## 变更概述

在 course_helper 项目中新增"题目答案检索"模块，不破坏现有登录、课程管理、签到、随堂练习和课堂答题功能。

## 文件清单

### 新增文件（7个）

1. `lib/models/answer_result.dart` - 数据模型
   - `StandardizedQuestion` - 标准化题目（`fromChaoxing` / `fromRainClassroomProblem`）
   - `StandardizedOption` - 标准化选项
   - `AnswerSearchResult` - 检索结果（answer / source / confidence / explanation / sourceType）
   - `AnswerSourceType` - 来源类型枚举（builtin, aiProvider）
2. `lib/api/answer_search.dart` - 检索核心
   - `AnswerSearchProvider` - 抽象检索源接口（可插拔）
   - `BuiltinAnswerProvider` - 内置答案源（学习通 `isanswer` 标记，置信度 1.0）
   - `AIAnswerProvider` - AI 检索源（OpenAI 兼容 Chat Completions）
   - `AnswerSearchApi` - 主入口（`search` / `saveAIConfig` / `getAIConfig` / `testConnection`）
3. `lib/pages/widget/answer_search_dialog.dart` - 结果弹窗
4. `lib/pages/widget/answer_search_settings.dart` - AI 配置页（含连通测试）
5. `lib/utils/network_error.dart` - 网络错误识别工具（v2 新增）
6. `lib/utils/app_logger.dart` - 运行日志器 + Dio 日志拦截器（v3 新增）
   - `LogLevel` / `LogEntry` / `AppLogger`（环形缓冲、按天落盘、分卷、清理、脱敏、导出）
   - `LoggingInterceptor` - 请求 / 响应 / 异常三阶段自动记录
7. `lib/pages/widget/log_viewer.dart` - 运行日志查看 / 导出页（v3 新增）
   - 级别筛选、长按复制、导出分享、清空

### 修改文件（5个）

8. `lib/pages/actives/quiz.dart`（学习通随堂练习页）
   - 新增导入 + `_searchAnswer(dynamic quiz)` + 每道题的搜索 IconButton
   - v2：`fromChaoxing` 传入图片鉴权头与地址解析函数；提交失败区分网络异常
   - v3：接住弹窗返回的答案，写入 `quiz['personAnswer']['myoption']`；填空/简答复制到剪贴板
9. `lib/pages/presentation.dart`（雨课堂课堂答题页）
   - 新增导入 + `_searchAnswer()` + "搜索答案"按钮
   - v2：`_currentSlideText()` / `_currentSlideCover()`；`_slides` 保留 `shapes`；提交失败区分网络异常
   - v3：`_applyPickedAnswer()` 一键回填；补上判断题（`problemType == 6`）的选项渲染
10. `lib/pages/accounts.dart`（账号管理页）
    - 右上角三点菜单新增"答案检索设置"入口（原项目缺这个导航入口）
    - v3：新增「运行日志」入口，跳转 `LogViewerPage`
11. `lib/main.dart`（应用入口）
    - v3：`await AppLogger.init()` 提到最前；安装 `FlutterError.onError` 与
      `PlatformDispatcher.instance.onError` 全局异常兜底
12. `pubspec.yaml`
    - v3：新增 `share_plus: ^13.3.0`（导出日志时调起系统分享）

## 关键设计

- 检索优先级：内置答案(1.0) → AI 检索；结果按置信度降序
- 无本地缓存层，每次检索直接调用各检索源
- AI 检索使用独立 Dio 实例，不携带学习通/雨课堂 Cookie
- 配置存储使用 SharedPreferences（复用 `StorageManager`）
- 图片以 base64 data URL 发送，规避防盗链与鉴权问题
- 提交路径不改动 `ApiService.sendForEachUser` 的行为，只在闭包内旁路记录异常
- 日志写入与展示**全部经过脱敏**，导出文件里不会出现完整 API Key
- 日志落盘失败不影响主流程（全部 `try/catch` 兜底）

## 未修改的文件

`lib/api/api_service.dart`、`lib/api/quiz.dart`、`lib/api/course.dart`、`lib/session/*`、
`lib/models/active.dart`、`lib/models/user.dart`、`lib/platform.dart`、`lib/utils/storage.dart`、
`lib/utils/encrypt.dart`、`lib/pages/courses/*`、`lib/pages/login.dart`

## 依赖检查

新增代码使用的依赖全部已在 pubspec.yaml 中：
- `share_plus: ^13.3.0` - 导出日志时调起系统分享（v3 新增）
- `dio: ^5.9.1` - HTTP 请求（AI API 调用、图片下载）
- `shared_preferences: ^2.2.2` - 本地存储
- `flutter` SDK - Material 组件

无需修改 pubspec.yaml。

## 集成说明

将 `lib/` 下对应文件复制到实际项目对应位置（新文件直接新增，已有文件替换），
然后运行 `flutter analyze` 与 `flutter test` 检查。

设置页入口已集成到账号页右上角三点菜单中（"答案检索设置"项），无需额外添加。

## AI API 需求

需要 OpenAI 兼容的 Chat Completions API，配置项：
- **API 地址**: 完整的 chat completions 端点 URL
- **API Key**: Bearer 认证密钥
- **模型名称**: 模型标识符

兼容的服务商：OpenAI / DeepSeek / 通义千问 / Moonshot / 本地 Ollama 等

**识图功能需要多模态模型**：gpt-4o / qwen-vl-max / glm-4v / gemini-1.5-flash 等。
纯文本模型（如 deepseek-chat）在题目只存在于 PPT 图片上时无法作答，但题干是文字时仍可正常使用。

---

# v4：PPT 缓存 + 后台自动识题 + AI 搜题

日期：2026-09-20 ｜ 版本：1.2.0+2003 ｜ 分支：`feat/ppt-cache`

## 核心思路

雨课堂取 PPT 是**一次性**接口（`GET /api/v3/lesson/presentation/fetch`），
一次返回整份 `{title, width, height, slides[]}`，每页的题目信息
（`slide.problem`：题号、题型、题干、选项）就在那个响应里。

所以「识题」不需要下载图片、不需要翻页、也不需要视觉模型 ——
整份 PPT 到手的那一刻，几十毫秒就能把所有题扫出来。

## 新增文件

### `lib/cache/`（7 个）

| 文件 | 职责 |
|---|---|
| `question_hash.dart` | 题目内容指纹（SHA-256），作为答案缓存的键 |
| `course_cache.dart` | 课程级目录管理、过期清理、原子写 JSON |
| `ppt_cache.dart` | 整份 PPT 元数据落盘（老师来回切同一份时不重复请求） |
| `cached_image.dart` | 幻灯片图片磁盘缓存（自定义 `ImageProvider`）+ 串行预取 |
| `answer_cache.dart` | 题目 → 建议答案 的读写、内存 LRU、预载 |
| `answer_queue.dart` | AI 检索队列：并发闸门 2 + in-flight 去重 + 结果广播 |
| `slide_scanner.dart` | 逐页识题、同题去重、需要识图的题单独标记 |

### `lib/pages/widget/suggested_answer_card.dart`

题目面板里的「建议答案」卡片：检索中 / 有答案 / 失败 三态，
**只回填，绝不自动提交**。

### 测试（5 个文件，61 个新用例）

`test/question_hash_test.dart`、`test/slide_scanner_test.dart`、
`test/answer_cache_test.dart`、`test/answer_queue_test.dart`、
`test/support/cache_test_env.dart`（把 path_provider 指到临时目录的测试脚手架）

## 修改文件

| 文件 | 改动 |
|---|---|
| `lib/pages/presentation.dart` | 接入缓存层；整份 PPT 到手后立刻识题 + 排队检索 + 预取图片；新增「回到当前页」按钮；**修掉 `_isLoading` 不复位的 bug** |
| `lib/pages/widget/answer_search_dialog.dart` | 支持直接展示已有结果（`initial`）、走调用方检索入口（`onSearch`）、显示「来自缓存」 |
| `lib/api/answer_search.dart` | `fromRainClassroomProblem` 带上 `problemId` |
| `lib/models/answer_result.dart` | `StandardizedQuestion` 新增 `problemId` 字段 |
| `pubspec.yaml` | 版本号 1.1.9+2002 → 1.2.0+2003 |

## 磁盘布局

```
<应用文档目录>/ppt_cache/
  lessons/
    <lessonId>/
      ppt/
        <presentationId>.json
        images/<sha1(url)>.bin
      questions/
        <questionHash>.json
      .finished
```

清理条件（满足任一即删整个课程目录）：
1. 有 `.finished` 标记且已过 24 小时
2. 目录内最后一次写入已过 7 天

## 依赖检查

新增代码只用到了 pubspec.yaml 里已有的依赖：
- `crypto: ^3.0.0` — 题目指纹 / 图片文件名摘要
- `path_provider: ^2.1.3` — 应用文档目录
- `path: ^1.9.0` — 路径拼接
- `dio: ^5.9.1` — 图片字节下载
- `flutter` SDK — `ImageProvider` / `ValueNotifier`

无需新增依赖。

## 设计要点

1. **题目判定口径**：只认服务器给的 `slide.problem`，不做图像扫描
2. **选项顺序不排序**：顺序一变答案字母的含义就变了
3. **题干为空时用课件文字兜底**：否则选项相同的两道题会撞成同一个键
4. **`empty`/`failed` 只保留 15 分钟**：既不刷屏重试，也不被一次网络抖动永久钉住
5. **图片预取串行 + 只下载字节**：并发抢带宽，解码吃内存
6. **默认继续跟随老师**，脱离后出现中立的「回到当前页」按钮
7. **只回填，不自动提交**

详细说明见 `docs/PPT缓存与自动识题设计_2026-09-20.md`。

## 同批次补充修复

### 1. 时间轴跳页 off-by-one（已修）

`_handleTimelineProblemClick()` 用的是 `targetIndex = slideIndex`（不减 1），
而 `_toSlide()` / `showpresentation` / `slide` / `slidenav` 都是 `slideIndex - 1`。

同一个 `si` 值不可能既是 0-based 又是 1-based 下标，必有一处错。证据：

1. 两处的 `si` 都来自 `_addTimelineEvents()` 里的 `event['si']`
2. `hello` 处理器也是取 `event['si']` 然后交给 `_toSlide()`
3. `_toSlide()` 被 5 个调用点共用，老师翻页跟随一直是正常的

所以 `si` 是 1-based 页码，已改为 `final targetIndex = slideIndex - 1;`。
这个 bug 在加了「回到当前页」按钮之后才变得看得见 ——
点开时间轴的题会多跳一页，右上角立刻冒出本不该出现的按钮。

### 2. 同一张图的并发下载互相覆盖（已修）

界面的 `SlideImage` 和后台 `SlideImagePrefetcher` 可能同时要同一张图，
原来两边都写同一个 `<hash>.bin.tmp`，互相把对方的文件 rename 掉，
其中一个抛「文件不存在」→ 页面显示莫名的错误图标。

修法：`SlideImageStore._inFlight` 按 `lessonId|url` 做 in-flight 去重，
临时文件名再带自增序号兜底，失败时把临时文件删掉。

### 3. `CourseCache.writeJson` 临时文件名会撞（已修）

原来固定 `<file>.tmp`，属于「靠调用方保证不并发」的脆弱假设。
改成带自增序号，失败时清理临时文件。

### 4. 新增 `lib/pages/widget/cache_manager.dart`

「PPT 缓存」管理页：展示占用、显示自动清理规则、提供「清理过期缓存」和
「清空全部缓存」。入口在账号页右上角菜单，紧挨「运行日志」。

### 5. 新增 `test/course_cache_test.dart`（25 个用例）

锁住保留策略：结束 24h 清、7 天未用清、边界保留、
结束标记优先于写入时间、统计与清空。

测试总数 130 → **155**，全部通过。

---

# v4.1：补上前台服务声明（后台保活）

日期：2026-09-20 ｜ 版本：1.2.1+2004 ｜ 分支：`feat/ppt-cache`

## 问题：前台服务其实从未启动过

`lib/pages/presentation.dart` 里那套 `_startForegroundService()` /
`_stopForegroundService()` / `_WebSocketKeepAliveHandler` **一直是死代码**。

原因：`flutter_foreground_task` 插件**不自己声明 `<service>`**，要求宿主 App 声明
（插件 README 注释：`Warning: Do not change service name.`）。
插件的 `AndroidManifest.xml` 里只有 4 个权限 + 2 个 receiver，`<service>` 只存在于
它的 `example` 工程。我们的 `android/app/src/main/AndroidManifest.xml` 只抄了权限，
漏了 `<service>`。

三重核对均确认没有 `ForegroundService`：

1. Gradle 合并后的 Manifest（`build/app/intermediates/merged_manifests/`）
2. `aapt2 dump xmltree` 拆 v4 APK
3. `android/` 全目录 grep

**后果**：没有前台通知、没有唤醒锁、没有 isolate 保活。
App 切后台或锁屏后 WebSocket 可能被系统冻结或杀掉 → 漏签到、漏题。

**最坑的是静默失败**：Android 上显式 Intent 指向未声明的组件会返回 null 且不抛异常，
插件拿到 null 后走 `result.success(true)`，Dart 侧以为启动成功了。

**5 秒自检法**：进课堂后拉下通知栏，看有没有「课堂助手 / 正在保持 WebSocket 连接...」
的通知。没有就是没起来。

## 修复（`android/app/src/main/AndroidManifest.xml`）

在 `<application>` 内、`MainActivity` 之后补上：

```xml
<service
    android:name="com.pravera.flutter_foreground_task.service.ForegroundService"
    android:foregroundServiceType="dataSync"
    android:exported="false"
    android:stopWithTask="true" />
```

- service 名不能改（插件硬编码）
- 用 `dataSync` 而非插件 README 的 `dataSync|remoteMessaging`：我们只声明了
  `FOREGROUND_SERVICE_DATA_SYNC` 权限，多声明 type 会在 Android 14+ 启动时被拒
- `stopWithTask="true"`：从最近任务划掉 App 就停服务，不留僵尸

## 待办：唤醒锁没有超时（本次未改）

服务真起来后，插件默认 `allowWakeLock: true` 会持**无超时的 `PARTIAL_WAKE_LOCK`**
（源码带 `@SuppressLint("WakelockTimeout")`），而 `presentation.dart` 里还显式开了
`allowWifiLock: true`（`WIFI_MODE_FULL_HIGH_PERF`）。这两个都会明显增加耗电。

建议改（`presentation.dart` 的 `FlutterForegroundTask.init`）：

```dart
foregroundTaskOptions: ForegroundTaskOptions(
  eventAction: ForegroundTaskEventAction.nothing(),
  allowWakeLock: false,
),
```

`nothing()` 是安全的：插件 `startRepeatTask()` 对 `NOTHING` 直接 `return`，与保活无关，
纯粹省掉那个 5 秒心跳。`allowWifiLock` 先保留 `true` 观察。

**为什么分两步**：一次只改一个变量。先确认「服务能起来、后台能收到消息」，
再单独量耗电；混在一起改，出问题分不清是哪个引起的。

## 文件清单

| 文件 | 改动 |
|---|---|
| `android/app/src/main/AndroidManifest.xml` | 新增 `<service>` 声明（+11 行含注释） |
| `pubspec.yaml` | 版本号 1.2.0+2003 → 1.2.1+2004（装出来 versionCode 4004） |
| `CHANGES.md` | 补上此前遗漏的 v4 段（`repo\` 一直没有，只有 `src\` / `build\` 有）+ 本节 |
| `README.md`（工作区） | 重写为面向接手的文档：目录真相源、构建/推送命令、架构铁律、已知问题 |

注意：`src\` / `build\` 补丁集原本只镜像 `lib\` 和 `test\`，
本次把 `android/app/src/main/AndroidManifest.xml` 也纳入了两个补丁集。

---

# v4.2：让前台服务「起没起来」看得见

日期：2026-09-20 ｜ 版本：1.2.2+2005 ｜ 分支：`feat/ppt-cache`

v4.1 补上 `<service>` 之后，又发现两处会让验证失真 —— 都会让人误判「修了也没用」。

## 1. 通知权限从没申请过（已修）

Android 13+ 的 `POST_NOTIFICATIONS` 是运行时权限。**没申请时前台服务照样在跑，
但那条常驻通知不会显示。** 于是「拉通知栏看有没有通知」这个验证方法会给出**假阴性**。

插件的 `startService()` **不会**自动申请；只有显式调用
`requestNotificationPermission()` 才会。原代码只申请了电池优化豁免。

修法（`lib/pages/presentation.dart` 的 `_startForegroundService()`）：

```dart
if (Platform.isAndroid &&
    await FlutterForegroundTask.checkNotificationPermission() ==
        NotificationPermission.denied) {
  await FlutterForegroundTask.requestNotificationPermission();
}
```

- 只在 `denied` 时申请，`permanently_denied` 不再反复弹窗
- 限定 Android：iOS 侧 `showNotification` 是 false，不该去打扰用户
- 为此把 `import 'dart:io' show WebSocket, File;` 改成 `show Platform, WebSocket, File;`

## 2. `startService()` 的返回值被 `await` 丢掉了（已修）

插件内部会等 5 秒确认 `isRunningService` 变成 `true`，起不来就返回
`ServiceRequestFailure(ServiceTimeoutException)`。

原代码：

```dart
await FlutterForegroundTask.startService(...);   // 返回值直接丢弃
```

**这个失败信号本来拿得到，是自己扔了。** 也就是说这个 bug 有两层隐身：
第一层是 Android 对未声明组件不报错，第二层是我们把插件给的错误信号扔了。

修法：接住 `ServiceRequestResult`，`switch` 到 `AppLogger`：

```dart
final ServiceRequestResult result;
if (await FlutterForegroundTask.isRunningService) {
  result = await FlutterForegroundTask.restartService();
} else {
  result = await FlutterForegroundTask.startService(...);
}

switch (result) {
  case ServiceRequestSuccess():
    AppLogger.i('ForegroundService', '前台服务已启动');
  case ServiceRequestFailure(:final error):
    AppLogger.e('ForegroundService',
        '前台服务启动失败：$error。检查 AndroidManifest.xml 是否声明了 '
        'com.pravera.flutter_foreground_task.service.ForegroundService');
}
```

`_stopForegroundService()` 同样接住了返回值（失败记 warn）。
外层再包一层 try/catch，异常也进日志，不再有静默路径。

## 3. 新增护栏测试 `test/android_manifest_test.dart`（4 个用例）

这个 bug 在仓库里藏了很久，因为它**没有任何东西守着**。用 4 条断言钉住：

1. 声明了 `com.pravera.flutter_foreground_task.service.ForegroundService`
2. `foregroundServiceType="dataSync"`，且与已声明的 `FOREGROUND_SERVICE_DATA_SYNC`
   权限一致（不照抄插件的 `dataSync|remoteMessaging` —— 那会在 Android 14+ 启动时被拒）
3. `stopWithTask="true"`
4. `exported="false"`

断言只作用在切出来的那个 `<service>` 元素上，不会被文件里别的
`android:exported="false"`（receiver）蒙混过关。

**有效性实测**：临时删掉 `<service>` 跑测试 → 4 条断言全红；还原 → 全绿。

## 验证

- 测试 155 → **159**，全部通过
- `flutter analyze` 仍是 15 条 info/warning，全部来自上游文件，新增代码零告警
- 产物 `dist\课程助手_v4.2_前台服务自检_arm64.apk`，70,932,189 字节，
  MD5 `8ad36c565301e55a5c40850eb714c326`，`versionCode 4005` / `versionName 1.2.2`，仅 arm64-v8a
- **确认新代码真进包**：`libapp.so` 里能搜到 UTF-16LE 编码的
  `前台服务已启动` / `前台服务启动失败`（v4 的包里搜不到）。
  注意 Dart AOT 快照里的中文是 **UTF-16LE**，用 UTF-8 搜会误判成「没打进去」
- `aapt2 dump xmltree` 确认 APK 内含 `ForegroundService`，
  `foregroundServiceType=0x1`（dataSync）、`stopWithTask=true`、`exported=false`
- v4 与 v4.2 的 `libapp.so` 大小**恰好都是** 10,158,984 字节，但 SHA-256 不同 ——
  **别用文件大小判断改动有没有进包**，用字符串探测或哈希

## 仍待处理

唤醒锁那组（`allowWakeLock: false` + `eventAction: nothing()`）依旧没动，
等真机确认服务能起来后再单独改。插件源码已确认 `startRepeatTask()` 对 `NOTHING`
直接 `return`（`ForegroundTask.kt:112`），所以 `nothing()` 与保活无关，
纯粹省掉每 5 秒一次的 `onRepeatEvent`。而我们的
`_WebSocketKeepAliveHandler.onRepeatEvent()` 是空实现 ——
现在服务真起来了，这 5 秒一次的空转就变成实打实的耗电了。

---

# v4.3：权限弹窗不再挡在服务前面

日期：2026-09-20 ｜ 版本：1.2.3+2006 ｜ 分支：`feat/ppt-cache`

## 问题：关键路径上放了两个会弹系统界面的 await

v4.2 把权限申请加进 `_startForegroundService()` 之后，执行顺序变成了：

```
申请通知权限 → 申请电池优化豁免 → init() → startService()
```

前两步都会弹系统界面，而插件用的是 `startActivityForResult` 模式：
Dart 侧的 Future **只在 `onActivityResult` / `onRequestPermissionsResult`
回来时才完成，插件没有超时**
（`MethodCallHandlerImpl.kt:121` 把 result 存进 `methodResults[requestCode]`，
只在 `onActivityResult` 里才 `success(...)`）。

Activity 一旦被系统重建（低内存、开发者选项「不保留活动」、进程被杀），
那个回调就永远不来了 → `await` 卡死 → **`startService()` 根本没机会执行**。
等于把「服务能不能起来」这件事，押在两个和它无关的系统弹窗上。

顺带还有个 UX 问题：电池优化豁免是**每次进课堂都弹**，
用户拒绝之后照样每次弹一个系统设置页。

## 改法

1. **顺序倒过来**：`init()` → `startService()` → 再申请权限。
   服务是关键路径，权限是锦上添花，不能让锦上添花挡住关键路径。
   服务启动失败时直接 `return`，不再申请权限（服务都没起来，申请也没意义）。
2. **两个权限各自加 `.timeout(30s)` 兜底**。
   这只是保险，真正靠得住的是第 1 条。
3. **电池优化豁免只问一次**：用 `StorageManager.prefs` 存
   `foreground_service_battery_opt_asked`，问过就不再问。
4. **权限后补上来时重新推一次通知**：通知是在没权限的时候推出去的，
   用户授权后不会自己冒出来，需要 `updateService()` 重新推。
   否则「拉通知栏看有没有通知」这个验证手段会再次给出假阴性。

## 新增

- 顶层常量 `_permissionTimeout`（30s）、`_batteryOptAskedKey`
- 新方法 `_requestForegroundPermissions()`、`_refreshServiceNotification()`
- `import '../utils/storage.dart';`

## 验证

- 测试 159/159 通过；`flutter analyze` 仍是 15 条上游告警、新增代码零告警
- 产物 `dist\课程助手_v4.3_权限不挡服务_arm64.apk`，`versionCode 4006` / `versionName 1.2.3`

## 顺手做的审计（没发现问题，记录一下）

顺着「静默失败」这条线把 v4 新代码的错误处理全扫了一遍：
`lib/cache/` 七个模块 + `suggested_answer_card.dart` + `cache_manager.dart`，
以及 `presentation.dart` 里的 `_initialize()` / `_indexQuestions()` /
`_enqueueScan()` / `_onAnswerReady()`。

结论是**干净**的：

- `AnswerQueue._execute()` 用 `finally` 归还并发额度，异常也会
  `complete(_RawAnswer(failed: true))`，不会让调用方永远等
- `SlideImagePrefetcher._pump()` 每张图单独 try/catch，失败计数 + debug 日志
- `PptCache` / `CourseCache` 的每个 `catch` 都有日志或明确的 best-effort 注释
  （`catch (_)` 只用在 stat 失败、文件被删、标记文件损坏这类真正无所谓的地方）
- `_enqueueScan()` 的 `.catchError` 会写日志并清掉 `_searching` 状态

也就是说 v4 里真正的「静默失败」只有两个：Manifest 漏声明 `<service>`（v4.1 修）
和 `startService()` 返回值被丢弃（v4.2 修）。这条线可以收了。

---

# v4.4：让「不进课堂也能验证前台服务」

日期：2026-09-20 ｜ 版本：1.2.4+2007 ｜ 分支：`feat/ppt-cache-fgs-diag`
（从 `feat/ppt-cache` 的 `f5f002b` 分出的子分支，**只在本地，未推送**）

## 起因：真机验证被卡住了

v4.3 补完 `<service>` 之后要在真机上验，结果发现**根本没法验**：

`PresentationPage` 只能从「正在上课的课程」列表点进去
（`lib/pages/courses/list.dart:543`），而那个列表是雨课堂的**实时**课堂列表。
周日晚上没有课 → 列表显示「暂无正在上课的课程」→ 进不去课堂页
→ `initState` 里的 `_startForegroundService()` 永远不会被调用。

也就是说：**前台服务只有上课时才会启动，可你恰恰只能在不上课时才有空验证它。**

## 改法

### 1. 抽出 `lib/utils/keep_alive_service.dart`（纯搬运，行为不变）

原来这套逻辑是 `_PresentationPageState` 的私有方法，现在搬到 `KeepAliveService`：

| 成员 | 作用 |
|---|---|
| `start()` | `init()` → `startService()` → 再申请权限 |
| `stop()` | 停止，并接住返回值 |
| `isRunning()` | 服务在不在跑 |
| `notificationPermission()` | 通知权限状态 |
| `isIgnoringBatteryOptimizations()` | 有没有电池优化豁免 |
| `requestBatteryOptimizationExemption()` | 自检页手动触发，不受「只问一次」限制 |
| `refreshNotification()` | 权限后补上来时重新推通知 |
| `lastResult` | `ValueNotifier<String>`，自检页显示最近一次操作结果 |
| `tag` | `'ForegroundService'`，日志 tag |

`WebSocketKeepAliveHandler` 和顶层 `keepAliveCallback()` 也一起搬了过来。

**行为完全没变，只是搬家** —— 这样真机测试结果对原有逻辑依然有效。
`presentation.dart` 里的两个方法缩成了三行委托。

### 2. 接通跨 isolate 上报通道（补上之前半成品的缺口）

`WebSocketKeepAliveHandler` 现在会上报 `started` / `timeout` / `stopped`，
主 isolate 侧写进 `AppLogger`。

**关键点：`FlutterForegroundTask.initCommunicationPort()` 必须显式调用。**
插件的 `init()` 和 `startService()` 都不管这件事；不调的话
`sendDataToMain` 是**静默 no-op** —— 又一个同类陷阱
（见 v4.2 的「静默失败」主题）。

另外 `_onKeepAliveTaskData` 必须是**顶层函数**：`addTaskDataCallback`
内部用 `contains` 去重，实例方法的 tear-off 每次都是新对象、去不掉重，
事件会被重复记 N 遍。

### 3. 新增「前台服务自检」页

`lib/pages/widget/keep_alive_checker.dart`，入口在账号页右上角菜单，
紧挨「运行日志」「PPT 缓存」。

- 状态：服务是否在跑 / 通知权限 / 电池优化豁免 / 最近一次操作结果
- 操作：启动 / 停止 / 刷新 / 申请电池优化豁免
- 现场日志：最近 20 条 `ForegroundService` 日志
- 附命令行验证方法

正常使用不需要它 —— 进课堂服务会自己起、离开课堂会自己停。

## 真机验证（一加 13 / PJZ110 / Android 15 / API 35）

### ✅ 已验证：`<service>` 声明在真机上确实生效

不用进课堂，直接用 adb 探测组件是否存在 —— 这个手法值得记住：

```bash
adb shell am startservice -n com.anerycoft.coursehelper/com.pravera.flutter_foreground_task.service.ForegroundService
adb shell am startservice -n com.anerycoft.coursehelper/com.anerycoft.coursehelper.DoesNotExistService
```

| 目标 | 返回 |
|---|---|
| `ForegroundService` | `Error: Requires permission not exported from uid 10196` |
| 不存在的服务（对照） | `Error: Not found; no service started.` |

两者错误**不同** → 系统成功解析到了我们的组件，只是因为 `exported="false"`
拒绝启动。**修复前这里会和不存在的服务报一样的 "Not found"。**

### ✅ 旁证：通知渠道从来没被创建过

```bash
adb shell dumpsys notification_manager | grep websocket_service
```

空的。通知渠道是第一次推通知时才创建的；应用从 2026-09-16 就装着、也用过，
渠道却从来没有过 → **前台服务确实一次都没起来过**，和之前的判断吻合。

### ✅ 签名一致性（顺带确认了「为什么签名不一致」）

| | 签名证书 SHA-256 |
|---|---|
| 已装的 v3（本地构建） | `e66761c4...c04a80` |
| v4.3（本地构建） | `e66761c4...c04a80` |

**本地构建之间签名一致**，`adb install -r` 直接覆盖安装，不用卸载、不丢数据。

之前遇到的签名冲突来自 **CI 构建**：`.github/workflows/build-apk.yml` 里的
「Generate test keystore」步骤**每次跑都 `keytool -genkeypair` 生成一对全新的随机密钥**：

```yaml
- name: Generate test keystore
  run: |
    keytool -genkeypair -v -keystore android/anerycoft.jks \
      -keyalg RSA -keysize 2048 -validity 10000 -alias anerycoft \
      -storepass android -keypass android \
      -dname "CN=test, OU=test, O=test, L=test, ST=test, C=CN"
```

所以**每个 CI 包的签名都不一样**，彼此也装不上去。本地 `android/anerycoft.jks`
是固定的（被 `android/.gitignore` 忽略、没进仓库），所以本地包彼此兼容。

> 要彻底统一签名：把 CI 那步改成「从 GitHub Secrets 取固定 keystore 并 base64 解码」，
> 而不是现场生成。

### ✅ 2026-09-21 真机验证：服务**真的跑起来了**（本轮完成）

装 `dist\课程助手_v4.4_前台服务自检_arm64.apk`（4007 覆盖 4006，签名一致、不用卸载），
走「账号 → ⋯ → 前台服务自检 → 启动服务」：

| 时间 | 观察 |
| --- | --- |
| 12:37:45 | 服务启动。系统日志 `Background started FGS: Allowed [... uidState: TOP ...]` |
| 12:42 | `isForeground=true foregroundId=1000 types=0x00000001`（dataSync） |
| 12:49 | 唤醒锁 `ForegroundService:WakeLock` ACQ=11m46s |
| 12:59 | 唤醒锁 ACQ=**22m4s**，App PID 仍是 **19645** |
| 13:18 | 唤醒锁 ACQ=**40m50s**，PID 仍是 **19645** |

自检页显示「前台服务：运行中 / 最近一次操作：已启动」；通知栏出现常驻通知
**「课堂助手 / 正在保持 WebSocket 连接...」**，渠道 `websocket_service`
—— **这个渠道此前从未被创建过**（见上面那条旁证），现在它出现了。

锁屏静置 **41 分钟**（全程 `mWakefulness=Dozing`）：`isForeground=true`、
`startRequested=true`、通知在、**PID 一次没变**、无 kill / ANR / crash 记录。
`dumpsys power` 里唤醒锁的 ACQ 时长一路涨到 40 分钟 →
**`allowWakeLock` 确实在生效，息屏后 CPU 没睡**。
`batterystats` 里同时能看到 `IrqTcpKeep=3 / TCPInput=15 / TCPOutput=69`，
说明这段时间有真实的网络收发。

### ❌ 仍未验的

1. **非充电状态下的锁屏存活** —— 本轮手机在充电（`Charge=true, Power=95`）。
   不少厂商 ROM 充电时对后台更宽松，**得拔掉电源再验一次**才算数。
2. **真实课堂的端到端**（要一节正在上的课）：进课堂自动起服务、退课堂自动停。
3. **切后台但不锁屏**（退到桌面放着）—— 本轮只验了锁屏 Dozing 这一种。

### ⚠️ 这轮顺带发现的两点（先记着，别急着改）

1. **`stopIfKilled=true`** —— `dumpsys` 里能看到这个属性，对应 `START_NOT_STICKY`：
   服务被系统杀掉后**不会自动重启**。对"保活"这个目标来说偏保守，
   理想是 `START_STICKY`。插件似乎固定用 `START_NOT_STICKY`，
   要改可能得自己写个原生壳。**先记着。**
2. **启动瞬间一条警告**：`W ForegroundServiceTypeLoggerModule: Foreground service
   start for UID: 10196 does not have any types`。但紧接着 `dumpsys` 里
   `types=0x00000001`（dataSync）是对的 —— 只是 `startForeground()` 调用那一瞬
   没带 type、由 Manifest 声明兜底的正常现象，不影响运行。

## 未改动的（刻意留着）

- `eventAction: ForegroundTaskEventAction.repeat(5000)` 仍是 `repeat`。
  `WebSocketKeepAliveHandler.onRepeatEvent()` 是空实现，所以这 5 秒一次纯属空转；
  插件源码 `ForegroundTask.kt:112` 对 `NOTHING` 直接 `return`，
  改成 `nothing()` 与保活无关、纯粹省电。**留到真机确认服务能跑起来之后再改**，
  一次只动一个变量。
  → **2026-09-21：服务已确认能跑起来，这个前置条件满足了，可以动。**
  但建议先补完「非充电状态下锁屏存活」那一项，别同时动两个变量。
- `allowWakeLock` 保持默认 `true`（代码里显式注释了理由）。
  息屏后 CPU 靠它不睡，WebSocket 收消息才不会被拖到超时 ——
  这是本 App 的核心价值，耗电换可靠。要改的话是一次真正的取舍，得单独量。

## 验证

- 测试 159/159 通过；`flutter analyze` 零错误（15 条 info/warning 全来自上游文件）
- 产物 `dist\课程助手_v4.4_前台服务自检_arm64.apk`，70,932,373 字节，
  MD5 `e5dec3fceda50bc9b80b64dc0ce7b3e9`，`versionCode 4007` / `versionName 1.2.4`，仅 arm64-v8a
- 已 `adb install -r` 到一加 13 上，版本号确认 `4007`
