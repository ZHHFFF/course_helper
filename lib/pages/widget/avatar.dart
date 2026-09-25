import 'package:flutter/material.dart';
import 'dart:typed_data';
import 'package:dio/dio.dart';

import '../../api/api_service.dart';

class AvatarCache {
  static final Map<String, Future<Uint8List?>> _cache = {};
  
  /// 获取缓存的头像数据（天然合并并发请求）
  static Future<Uint8List?> getImage(String url) {
    return _cache.putIfAbsent(url, () => _fetchImage(url));
  }
  
  /// 获取图片
  static Future<Uint8List?> _fetchImage(String url) async {
    try {
      final response = await ApiService.sendRequest(url, responseType: ResponseType.bytes);
      return response?.data;
    } catch (e) {
      debugPrint('头像请求失败: $url, 错误: $e');
      return null;
    }
  }
}

/// 通用头像组件
/// 直接通过URL获取并显示头像图片
class AvatarWidget extends StatefulWidget {
  /// 头像图片URL
  final String? imageUrl;
  
  /// 头像图片Future
  final Future<Uint8List?>? imageFuture;
  
  /// 是否正在加载
  final bool isLoading;
  
  /// 头像大小，默认60
  final double size;
  
  /// 圆角半径，默认8
  final double borderRadius;
  
  /// 默认图标大小，默认40
  final double iconSize;
  
  /// 默认图标的颜色，默认Colors.grey[400]
  final Color? iconColor;
  
  /// 加载指示器的线宽，默认2
  final double loadingStrokeWidth;

  const AvatarWidget({
    super.key,
    this.imageUrl,
    this.imageFuture,
    this.isLoading = false,
    this.size = 60,
    this.borderRadius = 8,
    this.iconSize = 40,
    this.iconColor,
    this.loadingStrokeWidth = 2,
  });

  @override
  State<AvatarWidget> createState() => _AvatarWidgetState();
}

class _AvatarWidgetState extends State<AvatarWidget> {
  Uint8List? _cachedImageData;
  bool _hasLoaded = false;
  
  @override
  void didUpdateWidget(covariant AvatarWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 如果URL改变了，重置缓存
    if (oldWidget.imageUrl != widget.imageUrl) {
      _cachedImageData = null;
      _hasLoaded = false;
    }
  }
  
  @override
  Widget build(BuildContext context) {
    return Container(
      width: widget.size,
      height: widget.size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        color: Theme.of(context).cardColor,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        child: _buildAvatarContent(),
      ),
    );
  }

  Widget _buildAvatarContent() {
    // 显示网络图片
    if (widget.imageFuture != null) {
      return FutureBuilder<Uint8List?> (
        future: widget.imageFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            // 如果已经有缓存数据，显示缓存数据而不是加载指示器
            if (_cachedImageData != null) {
              return Image.memory(
                _cachedImageData!,
                width: widget.size,
                height: widget.size,
                fit: BoxFit.cover,
              );
            }
            return const Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            );
          }
          
          if (snapshot.hasData && snapshot.data != null) {
            // 缓存数据
            _cachedImageData = snapshot.data;
            _hasLoaded = true;
            return Image.memory(
              snapshot.data!,
              width: widget.size,
              height: widget.size,
              fit: BoxFit.cover,
            );
          }
          
          // 显示默认图标
          return Icon(
            Icons.person,
            size: widget.iconSize,
            color: widget.iconColor ?? Colors.grey[400],
          );
        },
      );
    }
    
    // 如果有URL但没有Future，直接调用API
    if (widget.imageUrl != null && widget.imageUrl!.isNotEmpty) {
      // 如果已经加载过且有缓存数据，直接显示
      if (_hasLoaded && _cachedImageData != null) {
        return Image.memory(
          _cachedImageData!,
          width: widget.size,
          height: widget.size,
          fit: BoxFit.cover,
        );
      }
      
      return FutureBuilder<Uint8List?> (
        future: AvatarCache.getImage(widget.imageUrl!),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(
              child: CircularProgressIndicator(strokeWidth: 2),
            );
          }
          
          if (snapshot.hasData && snapshot.data != null) {
            // 缓存数据
            _cachedImageData = snapshot.data;
            _hasLoaded = true;
            return Image.memory(
              snapshot.data!,
              width: widget.size,
              height: widget.size,
              fit: BoxFit.cover,
            );
          }
          
          // 显示默认图标
          return Icon(
            Icons.person,
            size: widget.iconSize,
            color: widget.iconColor ?? Colors.grey[400],
          );
        },
      );
    }
    
    // 显示加载状态
    if (widget.isLoading) {
      return const Center(
        child: CircularProgressIndicator(strokeWidth: 2),
      );
    }
    
    // 显示默认图标
    return Icon(
      Icons.person,
      size: widget.iconSize,
      color: widget.iconColor ?? Colors.grey[400],
    );
  }
}