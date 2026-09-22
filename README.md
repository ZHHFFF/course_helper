
# 课程助手
一个管理学习通、雨课堂课程的应用。

> 本分支在原项目基础上新增了 **AI 答题、PPT 整份缓存、导出 PDF、自动预选与自动提交**等能力，
> 详见下方「功能」与「AI 答题」两节。
>
> **v4.8.8 起 UI 整体迁移到 Miuix（小米 HyperOS 风格）**：底栏改为 4 个 Tab
> （课程 / 账号 / 课件 / 设置）的 Miuix 标准样式 + 实时模糊，并新增「课件」页与「设置」页。
> 接手前请先读文末的「开发 / 接手须知（本 fork）」。
>
> ⚠️ 下方截图为旧版 UI（2 Tab），4 Tab 版本的截图待补。
>
|账号管理|课程列表|课程设置|签到功能|
|---|---|---|---|
| ![账号管理](images/screenshot/accounts.jpg) | ![课程列表](images/screenshot/courses.jpg) | ![课程设置](images/screenshot/course_setting.jpg) | ![签到功能](images/screenshot/sign_in.jpg) |

## 功能
- [x] 多账号操作

学习通:
- [x] 签到（所有五种签到任意设置，包括验证码、人脸识别）
- [x] 主题讨论
- [x] 评分
- [x] 投票
- [x] 问卷
- [x] 随堂练习（自动提交答案）
- [x] 随堂练习 AI 补差（服务器没给答案的题自动检索补上）
- [ ] 作业
- [x] 群聊签到（查看参与列表）
- [x] IM协议

雨课堂:
- [x] 动态二维码签到
- [x] PPT展示（查看整个PPT）
- [x] 课堂答题（支持延时提交）
- [x] PPT 整份缓存（进课堂自动预取全部幻灯片图片，翻页不再等加载）
- [x] PPT 导出为 PDF（缓存不完整时拒绝导出并提示，避免导出残缺课件）
- [x] 后台自动识题（整份 PPT 一次扫描，**不需要截图、翻页或视觉模型**）
- [x] AI 预搜答案（进课堂即批量搜好整份 PPT 的题，结果本地缓存复用）
- [x] 自动预选（老师发布题目的瞬间把答案填进作答区）
- [x] 自动提交（可配置拟人化延迟；网络失败会重试，失败时明确报错而非静默丢弃）
- [x] 建议答案卡片 + 缓存管理页

通用:
- [x] 课件页（底栏第 3 个 Tab）：全部课程 → 该课已缓存的课件列表 → **离线浏览 + 导出 PDF**
- [x] 逐份删除课件；**已取消自动清理**（删除只由用户手动触发）
- [x] 深浅色外观设置（跟随系统 / 浅色 / 深色）

## AI 答题
对接任意 **OpenAI 兼容**接口（DeepSeek / OpenAI / 阿里百炼 等），在设置页填「地址 / Key / 模型」即可。

- 题干与选项一并送模型；支持多模态，可把 PPT 图片直接喂给视觉模型
- 答案按**题目指纹**缓存，同一道题只搜一次；选项顺序变化不会误判成同一题
- 无内置 API Key，模型服务由使用者自行提供
- 可选接入自建网关（编译期注入，未配置时完全保持原行为）

## 平台
| 平台        | 状态    | 说明                       |
|-----------|-------|--------------------------|
| Android   | 可用    | 在 Release 中获取安装包         |
| iOS       | 需自行构建 | 缺少证书，需自行配置后构建            |
| Windows   | 需自行构建 | 部分功能（如扫描二维码）暂不可用         |
| HarmonyOS | 需自行构建 | 可使用 HarmonyFlutterSDK 构建 |

## 致谢
- [Yuuki](https://github.com/SoyBeanMilkx) 提供学习通脱壳包
- [CookiesHax](https://github.com/CookiesHax) 提供基础数据包

## 声明
课程助手仅用于学习，开发者不承担任何责任。

本项目采用 GNU General Public License v3.0进行许可。
您有权使用、修改和分发本代码，但必须严格遵守 GPL v3 的条款。任何分发行为（包括但不限于提供二进制文件、托管源码、作为服务运行）都必须同时提供完整的对应源代码，并保留原始版权声明。

请注意： 违反 GPL 协议可能导致法律诉讼。如果您不确定自己的使用方式是否符合协议，请查阅 GPL v3 官方全文 或咨询法律专业人士。

---

## 开发 / 接手须知（本 fork）

> 完整版见工作区 `D:\CourseHelper\README.md`。这里只放最容易踩的几条。

**构建**（校园网环境，必须走国内镜像）：

```bash
bash /d/CourseHelper/build-apk.sh all      # pub get + analyze + test + build
```

**推送**：远端用 `gh`（`https://github.com:443/ZHHFFF/course_helper.git`，注意那个 `:443`）。
`origin` 指向只读镜像 `ghfast.top`，**只能拉不能推**（推会报
`Password authentication is not supported`）。
CI 只在 push 到 `master` / `main` 时触发，推 `feat/*` 需要本地出包。

---

### UI 结构（v4.8.8 起）

底栏 4 个 Tab，全部由 `lib/main.dart` 的 `Stack` 承载：

| # | Tab | 页面 | 保活 |
|---|-----|------|------|
| 0 | 课程 | `pages/courses/list.dart` | ✅ `Offstage`（3 秒轮询不能断） |
| 1 | 账号 | `pages/accounts.dart` | ❌ 切走即释放 |
| 2 | 课件 | `pages/courseware/list.dart` | ✅ `Offstage`（要记住打开到哪一层） |
| 3 | 设置 | `pages/settings/settings.dart` | ❌ 切走即释放 |

**底栏** = `pages/widget/miuix_blur_navigation_bar.dart` 的 `MiuixBlurNavigationBar`
= 包里的 `MiuixNavigationBar`（几何 / 字号 / 按压反馈 / 选中动画全由库定义）+ 一层
`BackdropFilter` 玻璃。顶栏与底栏共用同一套玻璃口径（`miuix_glass_spec.dart`）。

四条必须知道的：

1. ⚠️ **类名必须叫 `Blur` 而不是 `Glass`**：`flutter_miuix` 里**已经有**
   `MiuixGlassNavigationBar`，自定义组件叫同名会得到 `ambiguous_import`
   **编译错误**（不是覆盖）。而包里那个走「录图层快照 → 喂 shader」，
   `ListView` 的 `Viewport` 自己是重绘边界（`rendering/viewport.dart:752`），
   滚动时位于它之上的捕获节点收不到 `paint()` → 快照冻住（实测 ~19 次/秒），
   表现为「停住 → 跳一下 → 再停住」。所以那一个**不能用**。
2. ⚠️ **底栏必须由 `Stack` + `Positioned(bottom: 0)` 叠加**，不能进
   `Scaffold.bottomNavigationBar`：`BackdropFilter` 采的是「**已经画好的**内容」，
   进了槽位 body 会被顶到栏上方、栏底下没东西可糊。
3. ⚠️ **保活用 `Positioned.fill(child: Offstage(...))`**：`RenderOffstage` 在
   offstage 时执行 `size = constraints.smallest`，而 `Stack` 给**非定位**子节点的是
   **loose** 约束（min = 0）→ 会塌成 `0×0`。套 `Positioned.fill` 拿到 tight 约束才对。
4. ⚠️ **页面内部的层级切换不要用 `Navigator.push`**（课件页是三层 `_stage`）：
   push 出来的路由会盖住叠加式底栏，底栏点不到，「切走再切回还是那个页面」也落不了地。
   改用 `enum _Stage` + `PopScope(canPop: 仅最顶层, onPopInvokedWithResult: 退一层)`。

### 四条最容易踩的坑

1. **改代码改 `repo\`**（工作区里真正的工程根，编译/git 都在这里）。
   `src\` / `build\` 只是给上游的扁平补丁镜像，**不参与构建**。
2. **雨课堂 PPT 是一次性 JSON**：`/api/v3/lesson/presentation/fetch` 一次返回整份
   `slides[]`，每页题目就在 `slide.problem`。识题**不需要截图、不需要翻页、不需要视觉模型**。
3. **题目指纹不能排序选项**：顺序一变「选 A」的含义就变了。
   题干为空时**必须**退回课件文字，否则选项相同的两道题会撞成同一个键，A 题会复用 B 题的答案。
4. **`si`（幻灯片页码）是 1-based**，转数组下标要 `-1`。

### 另外三条（v4.8.8 新增）

5. **删课件不能直接删它引用的图片**：图片是同一节课**所有 PPT 共享**一个
   `ppt/images/` 目录的（同一张源图还可能被多页引用）。直接删会让**别的课件**变成
   一片空白，而当场看不出任何异常。正确做法是先删 json，再按「剩余 PPT 还引用着谁」
   清孤儿 —— 见 `CourseCache._sweepOrphanImages`，`test/courseware_cache_test.dart`
   有一条专门的用例钉住。
6. **`presentationId` 的白名单化只有一个实现**（`CourseCache.safeFile`）：
   写 / 列 / 删三处必须走同一个函数，两处各写一份迟早会写歪，
   症状是「列表里有、点进去 404」或者「删不掉」。
7. **顶栏不要传 `blurRadius` / `blurTintAlpha`**，用 `MiuixTopAppBar` 的默认值
   （24 / .55）—— 与底栏是同一套口径。想改就只改 `miuix_glass_spec.dart`。

### 课件缓存

`lib/cache/course_cache.dart` 的目录结构：

```
ppt_cache/lessons/<safeName(lessonId)>/
  meta.json                       { courseId, courseName, updatedAt }   ← v4.8.8 新增
  ppt/<presentationId>.json       整份 PPT 元数据（含每页 problem）
  ppt/images/<sha1(URL 路径)>.bin 幻灯片图片
  questions/<hash>.json           题目 → 建议答案
  .finished                       课程结束标记
```

- ⚠️ **课程名以前从来没落过盘**（`PresentationPage(title: course.name)` 只在内存里），
  所以 v4.8.8 之前的缓存目录在课件页里只能显示成一串 lessonId 数字。
  `meta.json` 是 v4.8.8 起才写的，老缓存在**重新进一次那门课**时会被回填。
- ⚠️ **已取消自动清理**：以前每次进课堂都会跑一遍 `CourseCache.cleanup()`
  （结束标记超 24h 删 / 7 天无写入删），v4.8.8 起不再自动跑。
  现在只有两个删除入口：课件 Tab 里逐份删、设置页 →「课件缓存」里手动清。
- 图片缓存键由 `utils/image_cache_key.dart` 推导（**只取 URL 路径、丢掉签名 query**）。
  落盘文件名、并发去重键、队列去重键**三者必须是同一个身份** ——
  这条已经踩过两次坑，所以抽成纯函数 + 单测钉住。

### 前台服务 / 保活

`flutter_foreground_task` 要求宿主 App 自己声明 `<service>`，
此前漏了导致前台服务**静默失败**（切后台可能漏签到、漏题）。已在 `AndroidManifest.xml`
补上，`test/android_manifest_test.dart` 有 4 条断言守着。

**问题**：`PresentationPage` 只能从「正在上课的课程」进，所以前台服务只有上课时才起，
而**不上课的时候才是你有空验证它的时候** —— 于是有了 v4.4 的「前台服务自检」页，
不用进课堂就能启动/停止/看状态/看日志。
（路径：v4.8.8 起在 **设置 Tab →「前台服务自检」**；更早版本在账号页右上角菜单里。）

**2026-09-21 已真机确认服务能跑起来**（锁屏静置 22 分钟仍存活、通知正常、唤醒锁在生效）。

### 待办（交给协作者）

1. ⚠️ **真机回归**（v4.8.8 只过了 `analyze` + `test`，真机没验完）：
   - 底栏 4 个 Tab 切换、选中态、滑动时模糊是否实时跟随
   - 数像素验小白条（真实 y 2724–2780 应是模糊背景，不再恒定 `#000000`）
   - 课件页三层（课程 → 课件列表 → 离线浏览）+ 逐份删除
   - 设置页各入口 + 深浅色切换
2. `lib/pages/presentation.dart`（111KB，最后动）
3. 底栏折射（方案 D）：`ImageFilter.shader`，**仅 Impeller 可用**
4. 应用被锁 60Hz（`frameRateOverride uid=10196`），需 Android 侧
   `Surface.setFrameRate` / `preferredDisplayModeId` 或 ColorOS 白名单
5. 老缓存的课程名回填（进一次那门课即可，见上）

### 约定

- ⚠️ **不要跑 `dart format`**（本项目没用它，一次重排 531 行，会造成大面积合并冲突）
- 换行符 CRLF、`core.autocrlf=true`
- ⚠️ 不要污染 `MediaQuery.viewPadding` —— 底栏靠它算手势区占位高度

