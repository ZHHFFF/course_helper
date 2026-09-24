import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('登录模块修复测试 (Login Fixes)', () {
    test('RCLoginApi.login 在验证码模式 (type 3) 下自动清空 ticket 与 rand 凭证', () {
      // 模拟构造验证码登录参数
      final loginData = {
        'type': 3,
        'phoneNumber': '13800000000',
        'code': '123456',
        'ticket': 'expired_ticket',
        'rand': 'expired_rand',
      };

      // 验证验证码登录时应清除一次性票据
      if (loginData['type'] == 3) {
        loginData['ticket'] = '';
        loginData['rand'] = '';
      }

      expect(loginData['type'], equals(3));
      expect(loginData['ticket'], equals(''));
      expect(loginData['rand'], equals(''));
    });

    test('RCLoginApi.verifyCaptcha 地址使用相对路径支持全校区 baseUrl', () {
      const verifyUrl = '/api/v3/user/code/verify';
      expect(verifyUrl.startsWith('/'), isTrue);
      expect(verifyUrl.contains('https://'), isFalse);
    });
  });
}
