# 答案检索模块 - 代码变更文档

## v3 更新（本次）—— 修复无法调用 API + 答案一键回填

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

### 4. 测试

`test/answer_search_test.dart` 从 22 个用例扩充到 **53 个**，新增覆盖：
地址补全（8 种输入形态）、`enable_thinking` 注入条件、多模态 content 构造、
错误体解析、404/401 文案、代码围栏剥离、`answerKeys` 匹配、判断题映射、`lettersOf`。

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

### 新增文件（5个）

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

### 修改文件（3个）

6. `lib/pages/actives/quiz.dart`（学习通随堂练习页）
   - 新增导入 + `_searchAnswer(dynamic quiz)` + 每道题的搜索 IconButton
   - v2：`fromChaoxing` 传入图片鉴权头与地址解析函数；提交失败区分网络异常
7. `lib/pages/presentation.dart`（雨课堂课堂答题页）
   - 新增导入 + `_searchAnswer()` + "搜索答案"按钮
   - v2：`_currentSlideText()` / `_currentSlideCover()`；`_slides` 保留 `shapes`；提交失败区分网络异常
8. `lib/pages/accounts.dart`（账号管理页）
   - 右上角三点菜单新增"答案检索设置"入口（原项目缺这个导航入口）

## 关键设计

- 检索优先级：内置答案(1.0) → AI 检索；结果按置信度降序
- 无本地缓存层，每次检索直接调用各检索源
- AI 检索使用独立 Dio 实例，不携带学习通/雨课堂 Cookie
- 配置存储使用 SharedPreferences（复用 `StorageManager`）
- 图片以 base64 data URL 发送，规避防盗链与鉴权问题
- 提交路径不改动 `ApiService.sendForEachUser` 的行为，只在闭包内旁路记录异常

## 未修改的文件

`lib/api/api_service.dart`、`lib/api/quiz.dart`、`lib/api/course.dart`、`lib/session/*`、
`lib/models/active.dart`、`lib/models/user.dart`、`lib/platform.dart`、`lib/utils/storage.dart`、
`lib/utils/encrypt.dart`、`lib/pages/courses/*`、`lib/pages/login.dart`、`pubspec.yaml`

## 依赖检查

新增代码使用的依赖全部已在 pubspec.yaml 中：
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
