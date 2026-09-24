import 'package:flutter/material.dart';
// [新增] Miuix：整页按「所有规范都按 miuix」迁移
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_tencent_captcha/flutter_tencent_captcha.dart';
import 'dart:async';

import '../api/login.dart';
import '../models/user.dart';
import '../session/account.dart';
import '../utils/encrypt.dart';
import '../platform.dart';

/// 登录成功处理
///
/// ⚠️ 必须由调用方把 `MiuixSnackbarHostState` 传进来，不能用
/// `ScaffoldMessenger`。本仓库的页面都换成了 `MiuixScaffold`，而
/// `MiuixScaffold` **不是** Material 的 `Scaffold` ——
/// `ScaffoldMessenger.of(context)` 会一路找到 `MaterialApp` 的根 messenger，
/// 再挂到 `MyHomePage` 那一层 Material `Scaffold` 上。在账号页（Tab 页）
/// 的后果是提示显示在玻璃底栏**下面**、被底栏盖住。
Future<bool> handleLoginSuccess(
  BuildContext context, {
  required MiuixSnackbarHostState snackbarHost,
}) async {
  try {
    late User? user;
    if (PlatformManager().isChaoxing) {
      user = await CXLoginApi(User.empty).getUserInfo();
    } else {
      user = await RCLoginApi(User.empty).getUserInfo();
    }
    if (user == null) {
      if (context.mounted) snackbarHost.showSnackbar('获取用户信息失败');
      return false;
    }

    await AccountManager.addAccount(user);

    if (context.mounted) snackbarHost.showSnackbar('${user.name} 登录成功');
    return true;
  } catch (e) {
    if (context.mounted) snackbarHost.showSnackbar('登录处理失败');
    return false;
  }
}

class LoginPage extends StatefulWidget {
  final String initialLoginType;

  const LoginPage({super.key, this.initialLoginType = 'password'});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

/// 二维码登录状态管理类
class QRCodeLoginState {
  String? qrUuid;
  String? qrEnc; // 学习通
  String? qrToken; // 雨课堂
  String? qrImageUrl;
  bool isLoading = true;
  bool isRefreshing = false;
  bool isLoginActive = true;

  Timer? _pollingTimer;
  final _isChaoxing = PlatformManager().isChaoxing;
  VoidCallback? onRefresh;

  /// 获取二维码数据
  Future<Map<String, dynamic>?> _getQRCodeData() async {
    if (_isChaoxing) {
      return await CXLoginApi.getQRCodeData();
    } else {
      return await RCLoginApi.getQRCodeData();
    }
  }

  /// 更新二维码信息
  void _updateQRInfo(Map<String, dynamic> qrData) {
    if (_isChaoxing) {
      qrUuid = qrData['uuid'];
      qrEnc = qrData['enc'];
      qrImageUrl = 'https://passport2.chaoxing.com/createqr?uuid=$qrUuid&fid=-1';
    } else {
      qrToken = qrData['token'];
      qrImageUrl = qrData['qrImage'];
    }
  }

  /// 初始化二维码数据
  Future<bool> initialize() async {
    try {
      final qrData = await _getQRCodeData();
      if (qrData != null) {
        _updateQRInfo(qrData);
        isLoading = false;
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('初始化二维码失败: $e');
      return false;
    }
  }

  /// 开始轮询登录状态
  void startPolling(Function(bool success) onLoginComplete, {VoidCallback? onRefresh}) {
    _pollingTimer?.cancel();
    this.onRefresh = onRefresh;

    if (_isChaoxing) {
      // 每3秒检查一次
      _startChaoxingPolling(onLoginComplete);
    } else {
      _startRainClassroomNewPolling(onLoginComplete);
    }
  }

  /// 雨课堂新API轮询逻辑（使用token）
  void _startRainClassroomNewPolling(Function(bool success) onLoginComplete) async {
    while (isLoginActive && qrToken != null) {
      try {
        final result = await RCLoginApi.loginQRCode(qrToken!);
        if (result != null) {
          // 登录成功
          onLoginComplete(true);
          return;
        } else {
          // 超时或失败，刷新二维码
          await refreshQRCode();
          onRefresh?.call();
          if (!isLoginActive || qrToken == null) return;
        }
      } catch (e) {
        debugPrint('轮询失败: $e');
      }
      
      // 如果不是活跃状态则退出
      if (!isLoginActive) return;
    }
  }

  /// 学习通轮询逻辑
  void _startChaoxingPolling(Function(bool success) onLoginComplete) {
    _pollingTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      if (!isLoginActive || qrUuid == null || qrEnc == null) {
        timer.cancel();
        return;
      }

      try {
        final result = await CXLoginApi.checkQRAuthStatus(qrUuid!, qrEnc!);
        if (result != null) {
          if (result['status'] == true) {
            timer.cancel();
            onLoginComplete(true);
          } else if (result['type']?.toString() == '2') {
            timer.cancel();
            await refreshQRCode();
            onRefresh?.call();
          }
        }
      } catch (e) {
        debugPrint('轮询失败: $e');
      }
    });
  }

  /// 刷新二维码
  Future<void> refreshQRCode() async {
    if (isRefreshing) return;

    isRefreshing = true;
    isLoading = true;
    qrImageUrl = null;
    onRefresh?.call();
    
    try {
      final qrData = await _getQRCodeData();
      if (qrData != null) {
        _updateQRInfo(qrData);
      }
    } catch (e) {
      debugPrint('刷新二维码失败: $e');
    } finally {
      isRefreshing = false;
      isLoading = false;
    }
  }

  void dispose() {
    isLoginActive = false;
    _pollingTimer?.cancel();
  }
}

class _LoginPageState extends State<LoginPage> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _captchaController = TextEditingController();
  final _usernameFocusNode = FocusNode();
  final _passwordFocusNode = FocusNode();
  final _captchaFocusNode = FocusNode();
  bool _isLoading = false;
  bool _showPassword = false;
  String _currentLoginType = '1'; // '1'密码登录，'2'验证码登录，'3'二维码登录
  Timer? _countdownTimer;
  int _countdownSeconds = 0;

  /// Miuix 的 Snackbar 走「host + state」模型，不是 `ScaffoldMessenger`。
  final MiuixSnackbarHostState _snackbarHost = MiuixSnackbarHostState();

  /// 顶栏滚动折叠行为。必须**只创建一次**（它持有折叠进度，
  /// 在 `build()` 里 new 会导致折叠状态每帧被重置）。
  late final MiuixExitUntilCollapsedScrollBehavior _topBarBehavior =
      miuixScrollBehavior();

  /// 内容顶部留白（= 顶栏**展开态**高度），只记最大值、不跟随折叠回缩。
  double _topBarInset = 0;
  
  // 腾讯验证码参数
  String? _ticket;
  String? _randstr;

  @override
  void initState() {
    super.initState();
    if (PlatformManager().isRainClassroom) {
      TencentCaptcha.init(Constant.tCaptchaAppId);
    }
    if (widget.initialLoginType == 'captcha') {
      _currentLoginType = '2';
    } else if (widget.initialLoginType == 'qrcode') {
      _currentLoginType = '3';
      _showQRCodeLogin();
    } else {
      _currentLoginType = '1';
    }
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    _captchaController.dispose();
    _usernameFocusNode.dispose();
    _passwordFocusNode.dispose();
    _captchaFocusNode.dispose();
    _countdownTimer?.cancel();
    _snackbarHost.dispose();
    super.dispose();
  }

  /// 显示二维码登录对话框
  Future<void> _showQRCodeLogin() async {
    final qrState = QRCodeLoginState();

    final initialized = await qrState.initialize();
    if (!initialized) {
      if (mounted) {
        _snackbarHost.showSnackbar('获取二维码失败');
      }
      qrState.dispose();
      return;
    }

    qrState.startPolling((bool success) async {
      if (success) {
        final loginSuccess = await handleLoginSuccess(context, snackbarHost: _snackbarHost);
        if (loginSuccess && mounted) {
          Navigator.pop(context, true);
        }
      }
      qrState.dispose();
    });

    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setState) {
            qrState.onRefresh = () {
              setState(() {});
            };
            
            return PopScope(
              canPop: true,
              onPopInvokedWithResult: (bool didPop, Object? result) {
                if (didPop) {
                  qrState.isLoginActive = false;
                  qrState.dispose();
                }
              },
              child: _wrapDialogPanel(_buildQrDialogPanel(qrState)),
            );
          },
        );
      },
    );

    qrState.dispose();
  }

  /// 显示腾讯验证码并进行验证
  Future<bool?> _showTencentCaptcha() async {
    final config = TencentCaptchaConfig(
      bizState: 'tencent-captcha',
      // 与 MiuixTheme 保持一致（支持外观设置手动切换深浅色）
      enableDarkMode:
          MiuixTheme.of(context).brightness == Brightness.dark,
    );

    try {
      late Map<dynamic, dynamic>? verifyResult;

      final Completer<bool?> completer = Completer<bool?>();

      await TencentCaptcha.verify(
        config: config,
        onSuccess: (data) {
          verifyResult = data;
          if (verifyResult != null) {
            _ticket = verifyResult!['ticket'];
            _randstr = verifyResult!['randstr'];
            completer.complete(true);
          } else {
            completer.complete(false);
          }
        },
        onFail: (data) {
          if (mounted) {
            _snackbarHost.showSnackbar('验证失败：${data['errorMessage']}');
          }
          completer.complete(false);
        },
      );

      return await completer.future;
    } catch (e) {
      if (mounted) {
        _snackbarHost.showSnackbar('验证异常：$e');
      }
      return false;
    }
  }

  /// 密码/验证码登录
  Future<void> _login() async {
    if (_formKey.currentState!.validate()) {
      setState(() {
        _isLoading = true;
      });
  
      try {
        Map<String, dynamic>? result;
          
        if (PlatformManager().isChaoxing) {
          result = await CXLoginApi.loginAPP(
            _currentLoginType,
            _usernameController.text,
            _currentLoginType == '2' ? _captchaController.text : _passwordController.text,
          );
  
          if (result != null && result['status']) {
            if (!result.containsKey('url')) {
              await _showSecurityVerificationDialog();
            }
  
            final success = await handleLoginSuccess(context, snackbarHost: _snackbarHost);
            if (success && mounted) {
              Navigator.pop(context, true);
            }
          } else {
            String errorMessage = result?['mes'] ?? '登录失败，请检查账号密码';
            if (mounted) {
              _snackbarHost.showSnackbar(errorMessage);
            }
          }
        } else {
          // 雨课堂验证码前置校验
          if (_currentLoginType == '2') {
            final verifyResult = await RCLoginApi.verifyCaptcha(
                _usernameController.text,
                _captchaController.text
            );
        
            if (verifyResult == null || verifyResult['code'] != 0) {
              if (mounted) {
                _snackbarHost.showSnackbar(verifyResult?['msg'] ?? '验证码验证失败');
              }
              return;
            }
          } else {
            // 非验证码模式需要腾讯验证码
            if (_ticket == null || _randstr == null){
              final captchaResult = await _showTencentCaptcha();
              if (captchaResult != true) {
                return;
              }
            }
          }

          result = await RCLoginApi.login(
            _currentLoginType == '2' ? 3 : 2, // 1: 密码登录 2: 邮箱登录 3: 验证码登录
            _usernameController.text,
            _currentLoginType == '2' ? _captchaController.text : _passwordController.text,
            _currentLoginType == '2' ? '' : (_ticket ?? ''),
            _currentLoginType == '2' ? '' : (_randstr ?? ''),
          );

          // 非验证码模式清空验证码凭证
          if (_currentLoginType != '2') {
            _ticket = null;
            _randstr = null;
          }

          late String errorMessage;
          if (result != null) {
            if (result['code'] == 0) {
              final success = await handleLoginSuccess(context, snackbarHost: _snackbarHost);
              if (success && mounted) {
                Navigator.pop(context, true);
              }
              return;
            } else {
              errorMessage = result['msg'];
            }
          } else {
            errorMessage = '登录失败，请检查账号密码';
          }
          if (mounted) {
            _snackbarHost.showSnackbar(errorMessage);
          }
        }
      } catch (e) {
        if (mounted) {
          _snackbarHost.showSnackbar('登录时发生错误：$e');
        }
      } finally {
        if (mounted) {
          setState(() {
            _isLoading = false;
          });
        }
      }
    }
  }

  Future<void> _sendCaptcha() async {
    String phone = _usernameController.text.trim();
    if (phone.isEmpty) {
      if (mounted) {
        _snackbarHost.showSnackbar('请输入手机号');
      }
      return;
    }
  
    // 仅雨课堂需要腾讯验证码验证
    if (PlatformManager().isRainClassroom) {
      final captchaResult = await _showTencentCaptcha();
      if (captchaResult != true) {
        return;
      }
  
      if (_ticket == null || _randstr == null) {
        if (mounted) {
          _snackbarHost.showSnackbar('验证码验证失败，请重试');
        }
        return;
      }
    }
  
    try {
      setState(() {
        _isLoading = true;
      });
  
      Map<String, dynamic>? result;
        
      if (PlatformManager().isChaoxing) {
        result = await CXLoginApi.sendCaptcha(phone);
          
        if (result == null) {
          if (mounted) {
            _snackbarHost.showSnackbar('发送验证码失败，请重试');
          }
          return;
        }
  
        if (result['status'] == true) {
          _startCountdown();
          if (mounted) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                _snackbarHost.showSnackbar('验证码已发送');
              }
            });
          }
        } else {
          final message = result['mes'] ?? '发送验证码失败';
          if (mounted) {
            _snackbarHost.showSnackbar(message);
          }
        }
      } else {
        result = await RCLoginApi.sendCaptcha(phone, _ticket!, _randstr!);
          
        if (result == null) {
          if (mounted) {
            _snackbarHost.showSnackbar('发送验证码失败，请重试');
          }
          return;
        }
  
        if (result['code'] == 0) {
          _startCountdown();
          if (mounted) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) {
                _snackbarHost.showSnackbar('验证码已发送');
              }
            });
          }
        } else {
          final message = result['msg'] ?? '发送验证码失败';
          if (mounted) {
            _snackbarHost.showSnackbar(message);
          }
        }
      }
    } catch (e) {
      if (mounted) {
        _snackbarHost.showSnackbar('发送验证码时发生错误：$e');
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  void _startCountdown() {
    _countdownSeconds = 60;
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_countdownSeconds > 0) {
        setState(() {
          _countdownSeconds--;
        });
      } else {
        timer.cancel();
      }
    });
  }

  Future<void> _showSecurityVerificationDialog() async {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return _wrapDialogPanel(
          MiuixSurface(
            color: MiuixTheme.of(context).colors.surfaceContainer,
            cornerRadius: 32,
            shadowElevation: 8,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MiuixText(
                    '安全验证',
                    fontSize: MiuixTheme.of(context).textStyles.title4.fontSize,
                    fontWeight: FontWeight.w600,
                  ),
                  const SizedBox(height: 12),
                  MiuixText('新设备登录需要安全验证，请使用验证码登录', fontSize: 14),
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      MiuixTextButton(
                        '取消',
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                      const SizedBox(width: 12),
                      MiuixButton(
                        // `MiuixButton` 默认取 `buttonColors`（次级色），
                        // 对话框的确认键要用主色
                        colors: MiuixButtonDefaults.buttonColorsPrimary(context),
                        onPressed: () {
                          Navigator.of(context).pop();
                          setState(() {
                            _currentLoginType = '2';
                          });
                        },
                        child: const MiuixText('确定'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Miuix 迁移新增的辅助方法
  // ---------------------------------------------------------------------------

  /// 把面板包成「居中 + 限宽」的弹窗。
  ///
  /// ⚠️ 必须自己包 `Center` + 限宽。本仓库 Flutter 版本的
  /// `DialogRoute.pageBuilder` 只做了 `SafeArea(Semantics(child: builder 结果))`，
  /// **既没有 `Align` 也没有 `ConstrainedBox`** —— 路由页把整屏的**紧约束**
  /// 直接交给返回值，`Column(mainAxisSize: MainAxisSize.min)` 在紧约束下形同虚设，
  /// 面板会铺满整屏（实测整屏 `#242424`）。Material 的 `Dialog` 组件内部才做了
  /// `Center` + 限宽，所以换成自绘面板就必须自己补这一层。
  Widget _wrapDialogPanel(Widget panel) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(minWidth: 280, maxWidth: 300),
        child: panel,
      ),
    );
  }

  /// 二维码登录弹窗的面板（Miuix 自绘）。
  Widget _buildQrDialogPanel(QRCodeLoginState qrState) {
    final colors = MiuixTheme.of(context).colors;
    final textStyles = MiuixTheme.of(context).textStyles;
    return MiuixSurface(
      // 弹窗面板用 `surfaceContainer`（深色 #242424），与 `MiuixOverlayDialog`
      // 的默认底色一致；`MiuixSurface` 自己的默认是 `surface`（深色纯黑），
      // 贴在黑色遮罩上会糊成一片、看不出面板边界。
      color: colors.surfaceContainer,
      cornerRadius: 32,
      shadowElevation: 8,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MiuixText(
              '二维码登录',
              fontSize: textStyles.title4.fontSize,
              fontWeight: FontWeight.w600,
            ),
            const SizedBox(height: 20),
            Container(
              width: 220,
              height: 220,
              decoration: BoxDecoration(
                // ⚠️ 必须是**白底**，不能跟主题走：
                // 二维码是黑白位图，深色底上扫不出来。
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: qrState.qrImageUrl != null
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: Image.network(
                        qrState.qrImageUrl!,
                        fit: BoxFit.contain,
                      ),
                    )
                  : qrState.isLoading
                  ? const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          MiuixCircularProgressIndicator(
                            size: 24,
                            strokeWidth: 3,
                          ),
                          SizedBox(height: 8),
                          // 白底上的文字用固定深色，不跟主题
                          MiuixText(
                            '生成中...',
                            fontSize: 12,
                            color: Colors.black54,
                          ),
                        ],
                      ),
                    )
                  : const Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.error_outline,
                            size: 48,
                            color: Colors.black38,
                          ),
                          SizedBox(height: 8),
                          MiuixText(
                            '二维码加载失败',
                            fontSize: 12,
                            color: Colors.black54,
                          ),
                        ],
                      ),
                    ),
            ),
            const SizedBox(height: 20),
            MiuixText(
              '请使用学习通APP扫描上方二维码进行登录',
              fontSize: 14,
              fontWeight: FontWeight.w500,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            MiuixText(
              '二维码失效时会自动刷新',
              fontSize: 12,
              color: colors.onSurfaceVariantSummary,
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: MiuixTextButton(
                '取消',
                onPressed: () {
                  qrState.isLoginActive = false;
                  qrState.dispose();
                  Navigator.pop(context);
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 输入框下方的错误提示。
  ///
  /// `MiuixTextField` **没有** `errorText`，错误文案得自己画。
  Widget _buildFieldError(String message, MiuixColors colors) {
    return Padding(
      padding: const EdgeInsets.only(left: 4, top: 6),
      child: MiuixText(message, fontSize: 12, color: colors.error),
    );
  }

  /// 账号输入框。
  ///
  /// ⚠️ `MiuixTextField` **没有** `validator` / `errorText`，所以外面套一层
  /// `FormField<String>` 把校验接回来：`validator` 直接读 controller，
  /// `_formKey.currentState!.validate()` 的语义与原来的 `TextFormField` 完全一致，
  /// 错误文案交给 `_buildFieldError` 画在输入框下方。
  ///
  /// 注：原来 `InputDecoration` 里的 `hintText`（「手机号/超星号」）没有对应组件 ——
  /// Miuix 的输入框只有 `label`，且 `useLabelAsPlaceholder: false`（默认）时
  /// 就是「空态贴内、有内容时上浮」的浮动标签，与 Material `labelText` 行为一致，
  /// 信息量与 hint 重复，故不再单独保留。
  Widget _buildAccountField(MiuixColors colors) {
    return FormField<String>(
      validator: (_) => _usernameController.text.isEmpty ? '请输入账号' : null,
      builder: (field) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MiuixTextField(
            controller: _usernameController,
            focusNode: _usernameFocusNode,
            keyboardType: _currentLoginType == '2'
                ? TextInputType.phone
                : TextInputType.text,
            autofocus: true,
            label: '账号',
            textInputAction: TextInputAction.next,
            onSubmitted: (_) {
              if (_currentLoginType == '1') {
                _passwordFocusNode.requestFocus();
              } else {
                _captchaFocusNode.requestFocus();
              }
            },
          ),
          if (field.hasError) _buildFieldError(field.errorText!, colors),
        ],
      ),
    );
  }

  /// 密码输入框（含显隐切换）。
  Widget _buildPasswordField(MiuixColors colors) {
    return FormField<String>(
      validator: (_) => _passwordController.text.isEmpty ? '请输入密码' : null,
      builder: (field) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          MiuixTextField(
            controller: _passwordController,
            focusNode: _passwordFocusNode,
            label: '密码',
            obscureText: !_showPassword,
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _login(),
            // ⚠️ `MiuixTextField.trailingIcon` 只是被放进 Row 的普通 Widget，
            // 不接管手势。这里放 `MiuixIconButton`（自带 `MiuixPressable`），
            // 它与输入框是**兄弟**关系且绘制在上层，命中测试时先入手势竞技场
            // → 点击能正常落到按钮上。
            trailingIcon: MiuixIconButton(
              onPressed: () => setState(() => _showPassword = !_showPassword),
              child: Icon(
                _showPassword ? Icons.visibility : Icons.visibility_off,
              ),
            ),
          ),
          if (field.hasError) _buildFieldError(field.errorText!, colors),
        ],
      ),
    );
  }

  /// 验证码输入框 + 「获取验证码」按钮。
  Widget _buildCaptchaRow(MiuixColors colors) {
    final canSend = _countdownSeconds == 0 && !_isLoading;
    return Row(
      children: [
        Expanded(
          flex: 3,
          child: FormField<String>(
            validator: (_) =>
                _captchaController.text.isEmpty ? '请输入验证码' : null,
            builder: (field) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                MiuixTextField(
                  controller: _captchaController,
                  focusNode: _captchaFocusNode,
                  keyboardType: TextInputType.number,
                  label: '验证码',
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _login(),
                ),
                if (field.hasError) _buildFieldError(field.errorText!, colors),
              ],
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          flex: 2,
          child: MiuixButton(
            // 倒计时中 / 加载中都点不动。传 `null` 让 `MiuixButton` 自己走
            // 禁用态配色（`disabledPrimaryButton` / `disabledOnPrimaryButton`），
            // 比原来手写「颜色变灰但按钮仍可点」更符合 Miuix 规范。
            onPressed: canSend
                ? () {
                    _sendCaptcha();
                    FocusScope.of(context).requestFocus(_captchaFocusNode);
                  }
                : null,
            colors: MiuixButtonDefaults.buttonColorsPrimary(context),
            child: MiuixText(
              _countdownSeconds > 0 ? '${_countdownSeconds}s' : '获取验证码',
              fontSize: 14,
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = MiuixTheme.of(context).colors;
    final title = _currentLoginType == '1'
        ? '密码登录'
        : _currentLoginType == '2'
        ? '验证码登录'
        : '二维码登录';

    return Material(
      color: Colors.transparent,
      child: MiuixScaffold(
        topBar: MiuixTopAppBar(
          title: title,
          largeTitle: title,
          blurred: true,
          // 不传 `blurRadius` / `blurTintAlpha` → 用库默认（24 / 0.55），
          // 与底栏是同一套玻璃口径（见 widget/miuix_glass_spec.dart）。
          scrollBehavior: _topBarBehavior,
          // ⚠️ `MiuixTopAppBar` **没有** `onBack`，返回键要用 `navigationIcon`。
          // 原来的 Material `AppBar` 靠 `automaticallyImplyLeading` 自动加返回键。
          navigationIcon: MiuixIconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Icon(Icons.arrow_back_ios_new, size: 20),
          ),
        ),
        snackbarHost: MiuixSnackbarHost(
          state: _snackbarHost,
          blurSigma: 30,
          blurBackgroundAlpha: 0.55,
        ),
        content: (contentPadding) {
          // 只记最大高度，不跟随折叠回缩 —— 原因见 `_topBarInset` 的注释
          if (contentPadding.top > _topBarInset) {
            _topBarInset = contentPadding.top;
          }
          final bottomInset = MediaQuery.viewInsetsOf(context).bottom;
          return MiuixScrollBehaviorListener(
            behavior: _topBarBehavior,
            child: SingleChildScrollView(
              // 顶部让开顶栏、底部让开安全区与软键盘弹出高度（彻底解决 IME 弹窗遮挡下半区导致密码框点不开）
              padding: EdgeInsets.fromLTRB(
                24,
                _topBarInset + 16,
                24,
                contentPadding.bottom + bottomInset + 24,
              ),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildAccountField(colors),
                    const SizedBox(height: 16),
                    if (_currentLoginType == '1')
                      _buildPasswordField(colors)
                    else
                      _buildCaptchaRow(colors),
                    const SizedBox(height: 24),
                    if (_isLoading)
                      const Center(child: MiuixCircularProgressIndicator())
                    else
                      SizedBox(
                        height: 50,
                        child: MiuixButton(
                          // 原来的 `ElevatedButton` 是主色底，`MiuixButton` 默认
                          // 走次级色，所以这里必须显式给 `buttonColorsPrimary`
                          colors: MiuixButtonDefaults.buttonColorsPrimary(context),
                          onPressed: _currentLoginType == '3'
                              ? _showQRCodeLogin
                              : _login,
                          child: MiuixText(
                            _currentLoginType == '1'
                                ? '登录'
                                : _currentLoginType == '2'
                                ? '验证码登录'
                                : '二维码登录',
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
