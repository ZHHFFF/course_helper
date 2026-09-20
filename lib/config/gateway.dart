/// 官方 AI 网关配置（编译期注入）
///
/// 构建时通过 `--dart-define` 指定，例如：
///
/// ```
/// flutter build apk --release \
///   --dart-define=GATEWAY_URL=https://ai.example.com/v1 \
///   --dart-define=GATEWAY_NAME=官方服务
/// ```
///
/// 在 GitHub Actions 里可以从 Secrets 注入，避免把地址硬编码进公开仓库：
///
/// ```yaml
/// - run: flutter build apk --release --dart-define=GATEWAY_URL=${{ secrets.GATEWAY_URL }}
/// ```
///
/// 不指定 `GATEWAY_URL` 时，「官方服务」预设不会出现，
/// 学生仍然可以自己填 API 地址和 Key（保持原有行为）。
library;

/// 官方网关地址。写到 `/v1` 即可，App 会自动补 `/chat/completions`
const String kOfficialGatewayUrl = String.fromEnvironment(
  'GATEWAY_URL',
  defaultValue: '',
);

/// 官方服务在预设列表里显示的名字
const String kOfficialGatewayName = String.fromEnvironment(
  'GATEWAY_NAME',
  defaultValue: '官方服务（推荐）',
);

/// 官方服务的模型名。
/// 网关会强制使用自己配置的模型，所以这里填什么都行。
const String kOfficialGatewayModel = String.fromEnvironment(
  'GATEWAY_MODEL',
  defaultValue: 'auto',
);

/// 官方服务的说明文案
const String kOfficialGatewayHint = String.fromEnvironment(
  'GATEWAY_HINT',
  defaultValue: '直接用官方服务：地址已填好，把卡号粘贴到 API Key 即可。',
);

/// 是否配置了官方网关
bool get hasOfficialGateway => kOfficialGatewayUrl.trim().isNotEmpty;
