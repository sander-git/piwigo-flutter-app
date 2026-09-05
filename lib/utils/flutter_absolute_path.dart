import 'dart:io';

import 'package:flutter/services.dart';

class FlutterAbsolutePath {
  static const MethodChannel _channel = MethodChannel('flutter_absolute_path');

  /// Gets absolute path of the file from android URI or iOS PHAsset identifier.
  /// When [requireOriginal] is true, retrieves unredacted original media including GPS tags.
  /// When false, retrieves redacted media and scrubs geographic metadata.
  static Future<String> getAbsolutePath(
    String uri, {
    bool requireOriginal = true,
  }) async {
    final Map<String, dynamic> params = <String, dynamic>{
      'uri': uri,
      'requireOriginal': requireOriginal,
    };
    final String? path = await _channel.invokeMethod<String>('getAbsolutePath', params);
    if (path == null) throw Exception('Failed to resolve absolute path');
    return path;
  }

  /// Strips GPS location metadata from a local file on Android.
  static Future<String> stripMetadata(String filePath) async {
    if (!Platform.isAndroid) return filePath;
    final Map<String, dynamic> params = <String, dynamic>{
      'path': filePath,
    };
    final String? path = await _channel.invokeMethod<String>('stripMetadata', params);
    return path ?? filePath;
  }

  /// Cleans up temporary cached media files created by the application on Android.
  static Future<void> clearCache() async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod<bool>('clearCache');
    } catch (e) {
      // Ignore cleanup error
    }
  }

  /// Copies EXIF and GPS tags from [src] to [dst] on Android.
  static Future<bool> copyExif(String src, String dst) async {
    if (!Platform.isAndroid) return false;
    try {
      final Map<String, dynamic> params = <String, dynamic>{
        'src': src,
        'dst': dst,
      };
      final bool? res = await _channel.invokeMethod<bool>('copyExif', params);
      return res ?? false;
    } catch (e) {
      return false;
    }
  }
}

