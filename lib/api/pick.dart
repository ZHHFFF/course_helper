import 'api_service.dart';

/// 上游选人接口；空响应和非课程响应视为加载失败。
class Pick extends Api {
  Pick([super.user]);

  Future<List<dynamic>?> getPickList(String activeId) async {
    final url =
        'https://mobilelearn.chaoxing.com/widget/webcache/pick/stu/pickAttend';
    final timeStampMS = DateTime.now().millisecondsSinceEpoch.toString();
    final params = {
      'activeId': activeId,
      'qasort': '0',
      'screenMode': '0',
      'webCacheId': activeId,
      '_': timeStampMS,
    };

    final response = await ApiService.sendRequest(url, params: params);
    // {"result":1,"msg":"2","data":{"userListChoose":[{"name":"","userScore":null,"userId":},{"name":"Anery...","userScore":5.0,"userId":}],"count":2,"userListForRand":[],"status":1},"errorMsg":null}
    final data = response?.data;
    if (data is! Map) return null;
    if (data['result'] == 0) {
      return [];
    } else if (data['result'] == 1) {
      final payload = data['data'];
      return payload is Map && payload['userListChoose'] is List
          ? payload['userListChoose'] as List
          : null;
    }
    return null;
  }
}
