# 实时课堂 PPT 题目发现提示

本次复用现有 SlideScanner 整份课件扫描结果，在课堂消息时间线添加本地提示。
发现题目与教师正式发布题目是两个独立概念：查看详情不提交、不解锁、不调整倒计时。

## 修改文件

| 文件 | 修改内容 |
| --- | --- |
| `lib/pages/presentation.dart` | `_indexQuestions()` 接入本地时间线类型 `coursewareQuestions`；按课时/课件替换扫描快照；独立原页跳转；区分教师课件/页码与用户正在查看的课件/页码；保护迟到响应和销毁后的回调 |
| `lib/models/courseware_question_discovery.dart` | 保存题目扫描快照、原页图片及 `(lessonId, presentationId, slideIndex, hash)` 身份；显示页码集中转换为 `slideIndex + 1` |
| `lib/pages/widget/courseware_question_discovery_card.dart` | MIUIX 提示卡片；超过 3 题默认折叠汇总；支持历史课件提示和展开/收起 |
| `lib/pages/widget/courseware_question_details.dart` | 只读详情：完整标准化题干、题型、选项、题目/选项插图、原页预览；独立关闭/跳页按钮；沿用 MIUIX 深色主题及现有图片缓存 |
| `test/courseware_question_discovery_test.dart` | 10 项模型/Widget 测试，涵盖六种已知题型、完整长题干、HTML 选项文本、纯图片题、折叠及深色模式 |
| `test/presentation_question_discovery_test.dart` | 14 项页面回归，涵盖页码、去重、历史详情、跨课件/课时隔离、教师状态及异步交错 |

另为已有选项 UI 补齐透明 Material 宿主，解决跳到选择题时 Flutter 的 ListTile 绘制断言；未知题型标签返回“未知题型”，避免原页跳转后的非法枚举异常。

## 调用链与边界

`_loadPresentation → _indexQuestions → SlideScanner.scanSlides → CoursewareQuestionBatch → coursewareQuestions 时间线卡片 → 只读详情`

- 没有新增扫描器，保留 scanner 的内容指纹去重规则：同一题多页出现只提示首次出现的页。
- 每个 lesson/presentation 只有一个本地汇总条目；重新扫描替换内容，保留条目位置及首次发现时间。
- 原有 `problem` 历史事件仍走原处理路径，服务器历史发题仍会恢复既有发布状态。
- 详情按钮仅返回跳页意图；页面单独核验 lesson、presentation、数组下标、题目指纹和异步版本。
- 原页跳转只改变用户查看位置，不调用教师翻页/历史发题逻辑；“回到当前页”同时恢复教师课件与页码。
- 教师目标课件/页码在消息到达时保存，防止本地导航取消加载后丢失教师位置。首次加载中的独立翻页仍立即记录最新页码。
- 继续使用原课件加载代次、共享请求和生命周期保护；本地异步跳转额外检查页码版本。
- 原扫描后的答案缓存同步、后台检索、自动预选/答题触发条件、图片预取、PPT 下载/导出、登录与鉴权路径保持原有逻辑。

## 测试与反向审查

实际执行命令均使用已安装依赖（`--no-pub`）：

```sh
dart format lib/pages/presentation.dart lib/models/courseware_question_discovery.dart lib/pages/widget/courseware_question_details.dart lib/pages/widget/courseware_question_discovery_card.dart test/courseware_question_discovery_test.dart test/presentation_question_discovery_test.dart
flutter analyze --no-pub
flutter test --no-pub --timeout 45s test/courseware_question_discovery_test.dart test/presentation_question_discovery_test.dart test/reverse_async_regression_test.dart test/review_async_regression_test.dart test/slide_scanner_test.dart test/problem_publish_test.dart test/problem_resync_test.dart test/rc_lesson_token_test.dart test/rc_answer_body_test.dart test/answer_queue_test.dart test/answer_search_test.dart
flutter test --no-pub
git diff --check
```

| 检查 | 最终结果 |
| --- | --- |
| `dart format` | 通过 |
| `flutter analyze --no-pub` | No issues found |
| 本次新增模型/Widget/页面回归 | 24 项通过 |
| 上述 11 个相关测试文件 | 172 项通过 |
| 完整 `flutter test --no-pub` | 448 项通过、7 项既有跳过，All tests passed |
| `git diff --check` | 通过 |

重点回归场景：第 86 页对应下标 85；重复 hello/showpresentation 与 A/B/A 切换只保留一个汇总；旧课件迟到不能产生提示；详情打开时教师切换课件仍保留原题快照；过期指纹拒绝跳页；历史跳页迟到不覆盖教师新翻页；教师连续翻页取最新消息；退出页面后迟到请求不操作已销毁状态；教师新课件加载被用户历史跳转打断后仍可返回教师指定页；本地未发布题与正式历史发题共存但不会互相解锁。

新增本地提示测试在开启自动提交设置的情况下检查没有答案提交请求。既有倒计时测试确认查看/跳页不重置计时。相关回归覆盖原后台队列、答案检索、重连发题补查及鉴权/提交参数；完整套件同时覆盖历史 PPT 下载、缓存、导出及课程检索。

反向审查已修复首次加载期间教师翻页被错误等待、教师目标页码在加载被本地导航打断后丢失的风险；检查了请求参数、缓存键、JSON 默认值、取消/销毁保护、发题状态和倒计时，未改动这些既有契约。

## 覆盖范围与限制

- 单选、多选、投票、填空、简答、判断均覆盖只读详情；未知题型覆盖详情和原页跳转。
- 纯图片题覆盖未识别提示、题干图片、选项图片和原页预览；没有新增 OCR，不能识别图片中的文字或公式。
- scanner 没有识别出的页面不生成提示；不额外推断没有 `problem` 元数据的普通 PPT 图片是否是题目。
- 未覆盖拖拽、连线、编程等模型未定义的交互题型，也没有验证复杂公式/富文本的完整排版；展示沿用 StandardizedQuestion 的文本及图片数据。
- 验证为本地 Widget/单元/回归测试，没有真机、模拟器或真实雨课堂账号的在线课堂、图片签名过期验证。
