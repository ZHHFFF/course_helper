import 'package:flutter/widgets.dart';

/// 卡片内容的标准内边距。
///
/// ⚠️⚠️ **裸用 `MiuixCard` 会让内容贴着卡片边缘** —— 这是个很容易踩的坑，
/// 因为「卡片应该有内边距」是直觉，但库里偏偏不是：
///
/// | 组件 | `insideMargin` 默认值 |
/// |------|----------------------|
/// | `MiuixCard` | `EdgeInsets.zero` ← **0，一点内边距都没有** |
/// | 各 preference（Switch / Arrow / Checkbox / Radio / Spinner…） | `EdgeInsets.all(16)` |
///
/// 也就是说 `MiuixCard` 只负责「画一块圆角底色」，**内边距要调用方自己给**；
/// 而 preference 自带 16。于是把裸 `MiuixCard` 和 preference 放在同一个页面里：
///
/// - 裸卡片的文字紧贴卡片左边缘（实测 x 距卡片边仅 ~5px）
/// - 卡片里的 preference 文字在 16dp 处（实测 ~65px）
/// - 两者上下并排 → 看起来就是「同一个页面的文字没对齐」
///
/// 2026-09-23 真机截图（答案检索设置页）像素取证确认：说明卡文字 x≈61、
/// 开关卡文字 x≈121，卡片左边缘 x≈56（dpr 3.5）。
///
/// 结论：**凡是 `MiuixCard` 直接包裸内容（Column / Row / Text…），
/// 必须显式传 `insideMargin: kMiuixCardInsideMargin`**，才能与 preference 的 16 对齐。
///
/// 反例（**不要**加，加了就是双重缩进）：
/// - 卡片里直接放 preference —— 它自己已经有 16
/// - 卡片里已经有显式 `Padding` —— 同上
/// - 卡片里是 `MiuixBasicComponent` 且已显式传了 `insideMargin`
const EdgeInsets kMiuixCardInsideMargin = EdgeInsets.all(16);
