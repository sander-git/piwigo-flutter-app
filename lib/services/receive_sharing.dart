import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';
import 'package:listen_sharing_intent/listen_sharing_intent.dart';
import 'package:piwigo_ng/network/upload.dart';
import 'package:piwigo_ng/services/preferences_service.dart';

class SharedIntent {
  static List<XFile>? sharedFiles;
  static StreamSubscription<List<SharedMediaFile>>? _intentDataStreamSubscription;

  static Future<List<XFile>> _resolveMediaFiles(List<SharedMediaFile> receivedFiles) async {
    if (Platform.isAndroid) {
      await askMediaPermission();
    }
    List<XFile> resolvedFiles = [];
    final bool requireOriginal = !Preferences.getRemoveMetadata;
    for (var sharedFile in receivedFiles) {
      String path = sharedFile.path;
      if (Platform.isAndroid && path.startsWith('content://')) {
        try {
          path = await FlutterAbsolutePath.getAbsolutePath(
            path,
            requireOriginal: requireOriginal,
          );
        } catch (e) {
          debugPrint('Error resolving content URI in shared intent: $e');
        }
      }
      resolvedFiles.add(XFile(path));
    }
    return resolvedFiles;
  }

  static bool get hasSharedFiles => sharedFiles != null && sharedFiles!.isNotEmpty;

  static Future<List<XFile>?> receiveSharedData() async {
    try {
      ReceiveSharingIntent receiveSharingIntent = await ReceiveSharingIntent.instance;
      List<SharedMediaFile> receivedFiles = await receiveSharingIntent.getInitialMedia();

      if (receivedFiles.isNotEmpty) {
        sharedFiles = await _resolveMediaFiles(receivedFiles);
        await receiveSharingIntent.reset();
        return sharedFiles;
      } else {
        return null;
      }
    } catch (e) {
      debugPrint('Error receiving shared data: $e');
      return null;
    }
  }

  static void listenForSharedMedia(void Function(List<XFile> files) onData) async {
    try {
      ReceiveSharingIntent receiveSharingIntent = await ReceiveSharingIntent.instance;

      // Handle cold start: query initial media if not already consumed
      List<SharedMediaFile> initialMedia = await receiveSharingIntent.getInitialMedia();
      if (initialMedia.isNotEmpty) {
        List<XFile> resolved = await _resolveMediaFiles(initialMedia);
        await receiveSharingIntent.reset();
        if (resolved.isNotEmpty) {
          sharedFiles = resolved;
          onData(resolved);
        }
      } else if (hasSharedFiles) {
        onData(sharedFiles!);
      }

      _intentDataStreamSubscription?.cancel();
      _intentDataStreamSubscription = receiveSharingIntent.getMediaStream().listen((List<SharedMediaFile> receivedFiles) async {
        if (receivedFiles.isNotEmpty) {
          List<XFile> resolvedFiles = await _resolveMediaFiles(receivedFiles);
          if (resolvedFiles.isNotEmpty) {
            sharedFiles = resolvedFiles;
            onData(resolvedFiles);
          }
        }
      }, onError: (err) {
        debugPrint('getMediaStream error: $err');
      });
    } catch (e) {
      debugPrint('Error setting up sharing listener: $e');
    }
  }

  static void dispose() {
    _intentDataStreamSubscription?.cancel();
    _intentDataStreamSubscription = null;
  }

  static void cleanupSharedFiles() {
    sharedFiles = null;
  }
}
