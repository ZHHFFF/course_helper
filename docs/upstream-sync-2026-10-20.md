# 2026-10-20 上游选择性同步

比较基线：本 fork `013b3b9`，上游 `AneryCoft/course_helper@2b6111a`。
采用功能级移植，不直接 merge 上游分支，不覆盖整份业务文件。

| 上游提交 | 处理 | 理由 / 适配 |
| --- | --- | --- |
| 5258812、c533243、014c9d9 | 已有等效修改 | 既有 f312cf1 等已处理 SO 兼容、重复定位、主题色；不重复覆盖 |
| 1bb4f3e、900ed39、742ad5d | 跳过 | 保留 fork 版本和 CI versionCode 递增规则 |
| a8979c2 | 跳过 | 保留现有 Miuix 提示样式 |
| 5cb08ed（9ca8cc0 为对应 merge） | 移植 | 动态获取 signType 后也读取定位信息；将定位范围转为字符串 |
| 7c063d6 | 适配 | 上游单行贪婪正则会丢失多行 JSON 支持；改用平衡括号提取，兼容嵌套、转义和题干中的 `];` / `};`，覆盖两条加载路径 |
| 2b3bbe9 | 暂缓 | 现用 flutter_miuix 1.2.0 的 MiuixTextField 未暴露 autofillHints；直接增加参数不能编译，不替换已修好的登录表单 |
| 39824fa | 适配 | 在现有更新检查增加跳过具体 release tag，保留 prerelease 列表、原更新源及版本解析，不采用上游 releases/latest |
| 676f716 | 跳过 | 上游关于弹窗会替换本 fork Miuix 弹窗、开发者署名和链接 |
| 68d3e09 | 不引入第二套日志系统 | 保留 AppLogger、脱敏、文件轮转、日志导出；新增代码接入 AppLogger |
| f5fe99b | 移植 | 重新选择直接打开地图；手动清除位置后阻止课程配置立即自动填回 |
| 905d2e2、2b6111a | 移植 | 单点不提交；手势区域赢得手势竞争，防止画图带动外层滚动 |
| c007244 | 已有更完整实现 | 整份 PPT 缓存、离线查看、PDF 导出已具备；上游替换会丢掉自动搜题、发布题 ID 修复与缓存回归修复 |
| 445a2ad | 保留现有保活服务 | 现有 KeepAliveService / 自检页已负责电池优化；上游把引导阻塞放在前台服务启动前，会重新引入曾修复的启动阻塞 |
| b2fd16e | 暂缓 | 上游明确标注 untested / FIXME，依赖未经确认的定位签到字段，还会自动提交位置和弹 debug 数据框 |
| 4779898、75dbf9f | 适配 | 新增群聊签到历史入口；使用 Miuix 顶栏、现有 AppLogger，防止分页游标停滞和旧刷新覆盖新结果 |
| 19bc532 | 适配 | 批量活动提示、未读角标和稳定分组排序；保留 mounted 检查；修正非课程消息判空、通知 ID、通知失败后的应用内提醒，以及退出时清理定时器 |

## 保留的关键实现

以下文件不做上游覆盖：`presentation.dart`、`api/rc_crawler.dart`、
`api/login.dart`、`api/course.dart`、`utils/keep_alive_service.dart`、
所有缓存/答案队列/扫描器实现、`pages/courseware/`、
液态玻璃导航组件和 shaders、`navigation/`、依赖版本与现有发布构建流程。

课程列表保留 loadGeneration/pollGeneration、可见性轮询保护和 Miuix 样式；
未读排序后的点击捕获排序后的 Course 对象，不以原列表索引跳转。

新增回归测试覆盖 JSON 多行/嵌套/转义提取、手势与滚动冲突和单点误提交、
未读消息按课程与班级隔离及清空。完整验证结果见本次 PR。

## 本次验证

- Flutter 3.47.7 / Dart 3.13.5。
- `flutter analyze --no-pub --no-fatal-infos --no-fatal-warnings`：No issues found。
- `flutter test --no-pub`：496 passed，7 skipped，0 failed（包含新增 6 项测试）。
- 新增测试明确检查未读排序后打开的 courseId/classId 与显示课程一致。
- 与基线比较，上述保护文件、pubspec.yaml、pubspec.lock 和发布 workflow 均无差异。
- 测试环境按项目声明范围解析依赖；不提交本地解析引起的依赖更新。
- 真实学习通群聊/推送和地图签到仍需登录设备联调，自动化测试不证明服务端行为。
