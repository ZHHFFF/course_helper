import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';
import '../../setting/theme_setting.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../../../api/image.dart';
import '../../../api/pick.dart';
import '../../../models/active.dart';
import '../../../push/notification.dart';
import '../../../session/account.dart';
import '../widget/avatar.dart';

/// 学习通选人列表，按当前账号轮询并提醒新选中的本地账号。
class PickPage extends StatefulWidget {
  final Active active;

  const PickPage({super.key, required this.active});

  @override
  State<PickPage> createState() => _PickPageState();
}

class _PickPageState extends State<PickPage> with WidgetsBindingObserver {
  bool _isLoading = true;
  String? _errorMessage;

  List<Map<String, dynamic>> _pickList = [];
  bool _hasInitialData = false;
  bool _polling = false;
  String? _scope;

  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadPickList();
    _startPolling();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 后台停止网络轮询，回到前台再更新。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _pollTimer?.cancel();
    if (state == AppLifecycleState.resumed) {
      _loadPickList();
      _startPolling();
    }
  }

  void _startPolling() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(
      const Duration(seconds: 1), // 原版为3秒
      (_) => _loadPickList(),
    );
  }

  Future<void> _loadPickList() async {
    if (_polling || !AccountManager.hasActiveSession()) return;
    final scope = AccountManager.currentSessionId;
    if (_scope != scope) {
      _scope = scope;
      _hasInitialData = false;
      _pickList = [];
    }
    _polling = true;
    try {
      final list = await Pick().getPickList(widget.active.id);
      if (!mounted || scope != AccountManager.currentSessionId) return;

      if (list == null) {
        setState(() {
          _isLoading = false;
          if (_pickList.isEmpty) {
            _errorMessage = '获取选人列表失败';
          }
        });
        return;
      }

      final parsed = list
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();

      if (_hasInitialData) {
        _checkPickedAccounts(_diffNewItems(parsed, _pickList));
      }

      setState(() {
        _pickList = parsed;
        _isLoading = false;
        _errorMessage = null;
        _hasInitialData = true;
      });
    } catch (e) {
      if (mounted && scope == AccountManager.currentSessionId) {
        setState(() {
          _isLoading = false;
          if (_pickList.isEmpty) {
            _errorMessage = '加载数据出错: $e';
          }
        });
      }
    } finally {
      _polling = false;
    }
  }

  List<Map<String, dynamic>> _diffNewItems(
    List<Map<String, dynamic>> current,
    List<Map<String, dynamic>> previous,
  ) {
    final previousUids = previous
        .map((e) => (e['userId'] ?? '').toString())
        .toSet();
    return current
        .where((e) => !previousUids.contains((e['userId'] ?? '').toString()))
        .toList();
  }

  void _checkPickedAccounts(List<Map<String, dynamic>> newItems) {
    final accountUids = AccountManager.allAccounts.map((u) => u.uid).toSet();
    final picked = <({String uid, String name})>[];

    for (final item in newItems) {
      final uid = item['userId'].toString();
      if (uid.isEmpty || !accountUids.contains(uid)) continue;

      picked.add((uid: uid, name: item['name']?.toString() ?? ''));
    }

    if (picked.isNotEmpty) {
      _notifyPicked(picked);
    }
  }

  void _notifyPicked(List<({String uid, String name})> picked) {
    final displayNames = picked
        .map((p) => p.name.isEmpty ? 'ID: ${p.uid}' : p.name)
        .toList();
    final body = picked.length == 1
        ? '你被选中了：${displayNames.first}'
        : '你有 ${picked.length} 个账号被选中：${displayNames.join('、')}';

    NotificationService().show(
      title: '选人活动',
      body: body,
      androidDetails: const AndroidNotificationDetails(
        'course_pick_channel',
        '选人',
        channelDescription: '选人通知',
      ),
    );
  }

  Widget _buildScore(num? userScore) {
    if (userScore == null) {
      return const SizedBox.shrink();
    }

    final score = userScore.toInt();
    final color = score < 0
        ? Theme.of(context).colorScheme.error
        : Theme.of(context).colorScheme.primary;
    final text = score > 0 ? '+$score' : '$score';

    return Text(
      text,
      style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.bold),
    );
  }

  Widget _buildPickItem(Map<String, dynamic> item) {
    final uid = item['userId'].toString();
    final name = item['name']?.toString() ?? '';
    final isLocalAccount = AccountManager.allAccounts.any((u) => u.uid == uid);

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: isLocalAccount
          ? Theme.of(context).colorScheme.primaryContainer
          : null,
      child: ListTile(
        leading: AvatarWidget(
          imageUrl: CXImageApi.getAvatarUrlByUid(uid, 80),
          size: 50,
          borderRadius: 8,
          iconSize: 20,
        ),
        title: Text(name),
        subtitle: Text('ID: $uid'),
        trailing: _buildScore(item['userScore']),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: MiuixScaffold(
        topBar: MiuixTopAppBar(
          title: widget.active.name,
          blurred: ThemeSetting.blurOf(context),
          navigationIcon: MiuixIconButton(
            onPressed: () => Navigator.of(context).maybePop(),
            child: const Icon(Icons.arrow_back_ios_new, size: 20),
          ),
        ),
        content: (padding) => Padding(
          padding: padding,
          child: _isLoading
              ? const Center(child: CircularProgressIndicator())
              : _errorMessage != null
              ? SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Card(
                    color: Theme.of(context).colorScheme.errorContainer,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.error_outline,
                            size: 48,
                            color: Theme.of(context).colorScheme.error,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            _errorMessage!,
                            style: const TextStyle(fontSize: 16),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: 16),
                          ElevatedButton(
                            onPressed: _loadPickList,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Theme.of(
                                context,
                              ).colorScheme.primary,
                              foregroundColor: Colors.white,
                            ),
                            child: const Text('重新加载'),
                          ),
                        ],
                      ),
                    ),
                  ),
                )
              : _pickList.isEmpty
              ? const Center(
                  child: Text(
                    '暂未开始选人',
                    style: TextStyle(fontSize: 16, color: Colors.grey),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  itemCount: _pickList.length,
                  itemBuilder: (context, index) =>
                      _buildPickItem(_pickList[index]),
                ),
        ),
      ),
    );
  }
}
