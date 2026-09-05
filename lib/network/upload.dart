import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:path_provider/path_provider.dart';
import 'package:piwigo_ng/app.dart';
import 'package:piwigo_ng/components/dialogs/confirm_dialog.dart';
import 'package:piwigo_ng/network/api_client.dart';
import 'package:piwigo_ng/network/api_interceptor.dart';
import 'package:piwigo_ng/network/authentication.dart';
import 'package:piwigo_ng/services/preferences_service.dart';
import 'package:piwigo_ng/services/upload_notifier.dart';
import 'package:piwigo_ng/utils/localizations.dart';
import 'package:piwigo_ng/views/upload/upload_status_page.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/chunked_uploader.dart';
import '../services/notification_service.dart';
import '../utils/flutter_absolute_path.dart';

export '../utils/flutter_absolute_path.dart';

/// Handle Android API permissions (including ACCESS_MEDIA_LOCATION for API 29+ and limited access on Android 14+)
Future<bool> askMediaPermission() async {
  if (!Platform.isAndroid) return true;

  AndroidDeviceInfo androidInfo = await DeviceInfoPlugin().androidInfo;
  List<Permission> permissionsToRequest = [];

  if (androidInfo.version.sdkInt >= 33) {
    final photosGranted = await Permission.photos.isGranted || await Permission.photos.isLimited;
    final videosGranted = await Permission.videos.isGranted || await Permission.videos.isLimited;
    if (!photosGranted) permissionsToRequest.add(Permission.photos);
    if (!videosGranted) permissionsToRequest.add(Permission.videos);
  } else {
    if (!await Permission.storage.isGranted) permissionsToRequest.add(Permission.storage);
  }

  // Append ACCESS_MEDIA_LOCATION on Android 10+ (API 29+) to the requested permissions list
  if (androidInfo.version.sdkInt >= 29) {
    if (!await Permission.accessMediaLocation.isGranted) {
      permissionsToRequest.add(Permission.accessMediaLocation);
    }
  }

  if (permissionsToRequest.isNotEmpty) {
    await permissionsToRequest.request();
  }

  if (androidInfo.version.sdkInt >= 33) {
    return await Permission.photos.isGranted ||
        await Permission.photos.isLimited ||
        await Permission.videos.isGranted ||
        await Permission.videos.isLimited;
  } else {
    return await Permission.storage.isGranted;
  }
}

/// Resolves an [XFile] to a local [File], resolving Android content URIs, stripping metadata if requested,
/// and applying upload quality compression if configured.
Future<File> resolveMediaFile(XFile xFile) async {
  String filePath = xFile.path;
  if (Platform.isAndroid && filePath.startsWith('content://')) {
    await askMediaPermission();
    try {
      filePath = await FlutterAbsolutePath.getAbsolutePath(
        filePath,
        requireOriginal: !Preferences.getRemoveMetadata,
      );
    } catch (e) {
      debugPrint("Error resolving content URI: $e");
    }
  }
  if (Preferences.getRemoveMetadata && Platform.isAndroid) {
    try {
      filePath = await FlutterAbsolutePath.stripMetadata(filePath);
    } catch (e) {
      debugPrint("Error stripping metadata: $e");
    }
  }

  // Cross-platform EXIF removal & quality compression:
  // When "Remove Metadata" is ON or quality < 100%, run images through FlutterImageCompress.
  // This cleanly strips EXIF from HEIC, JPEG, PNG, and WEBP on both Android and iOS without mangling filenames.
  final bool stripExif = Preferences.getRemoveMetadata;
  final int quality = (Preferences.getUploadQuality * 100).round();
  final bool needsProcessing = quality < 100 || stripExif;

  if (needsProcessing && !filePath.contains('/compressed/')) {
    final lower = filePath.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg') || lower.endsWith('.png') || lower.endsWith('.heic') || lower.endsWith('.webp')) {
      try {
        final dir = await getTemporaryDirectory();
        final subDir = Directory('${dir.path}/compressed/${DateTime.now().millisecondsSinceEpoch}_${filePath.hashCode.abs()}');
        if (!await subDir.exists()) await subDir.create(recursive: true);
        final cleanName = filePath.split(RegExp(r'[\\/]')).last;
        final targetPath = '${subDir.path}/$cleanName';
        final compressed = await FlutterImageCompress.compressAndGetFile(
          filePath,
          targetPath,
          quality: quality,
          keepExif: !stripExif,
        );
        if (compressed != null) {
          if (!stripExif && Platform.isAndroid) {
            try {
              await FlutterAbsolutePath.copyExif(filePath, compressed.path);
            } catch (e) {
              debugPrint("Error restoring EXIF after compression: $e");
            }
          }
          final String intermediatePath = filePath;
          filePath = compressed.path;
          safelyDeleteTempFile(File(intermediatePath));
        }
      } catch (e) {
        debugPrint("Error processing image for upload: $e");
      }
    }
  }

  return File(filePath);
}

/// Resolves a list of [XFile]s to local [File]s.
Future<List<File>> resolveMediaFiles(List<XFile> photos) async {
  List<File> files = [];
  for (var photo in photos) {
    files.add(await resolveMediaFile(photo));
  }
  return files;
}

/// Safely deletes an isolated temporary file created for upload without touching original user files.
void safelyDeleteTempFile(File file) {
  try {
    final normalized = file.path.replaceAll('\\', '/');
    if (normalized.contains('/original_media/') ||
        normalized.contains('/temp_upload/') ||
        normalized.contains('/compressed/')) {
      if (file.existsSync()) {
        file.deleteSync();
        final parent = file.parent;
        final parentName = parent.path.split(RegExp(r'[\\/]')).last;
        if (parentName != 'original_media' &&
            parentName != 'temp_upload' &&
            parentName != 'compressed') {
          final parentNormalized = parent.path.replaceAll('\\', '/');
          if (parentNormalized.contains('/original_media/') ||
              parentNormalized.contains('/temp_upload/') ||
              parentNormalized.contains('/compressed/')) {
            parent.deleteSync(recursive: true);
          }
        }
      }
    }
  } catch (e) {
    debugPrint("Error deleting temp upload file: $e");
  }
}

/// Prepare and upload with [uploadChunk] a list of files.
Future<List<int>> uploadPhotos(
  List<XFile> photos,
  int albumId, {
  Map<String, dynamic> info = const {},
}) async {
  // Check if Wifi is enabled and working before processing
  if (Preferences.getWifiUpload) {
    var connectivity = await Connectivity().checkConnectivity();
    if (!connectivity.contains(ConnectivityResult.wifi)) {
      if (!(await showConfirmDialog(
        App.navigatorKey.currentContext!,
        title: appStrings.uploadNoWiFiNetwork,
        cancel: appStrings.alertCancelButton,
        confirm: appStrings.imageUploadDetailsButton_title,
      ))) {
        return [];
      }
    }
  }

  // Initialize variables
  List<int> result = [];
  List<UploadItem> items = [];
  SharedPreferences prefs = await SharedPreferences.getInstance();
  FlutterSecureStorage storage = const FlutterSecureStorage();
  String? url = prefs.getString(Preferences.serverUrlKey);
  if (url == null) return [];
  String? username = await storage.read(key: Preferences.usernameKey);
  String? password = await storage.read(key: Preferences.passwordKey);
  UploadNotifier uploadNotifier = App.appKey.currentContext!.read<UploadNotifier>();
  int nbError = 0;

  // Creates Upload Item list for the upload notifier
  for (var photo in photos) {
    File uploadFile = await resolveMediaFile(photo);
    items.add(UploadItem(
      file: uploadFile,
      albumId: albumId,
    ));
  }

  // Add items to the queue
  uploadNotifier.addItems(items);

  // Closes the Upload Configuration page and opens the Upload Status page
  App.navigatorKey.currentState?.popAndPushNamed(UploadStatusPage.routeName);

  // Iterate on each item
  for (UploadItem item in items) {
    try {
      // Upload image
      Response? response = await uploadChunk(
        photo: item.file,
        category: albumId,
        url: url,
        username: username,
        password: password,
        info: info,
        cancelToken: item.cancelToken,
        onProgress: (progress) {
          item.progress.sink.add(progress);
        },
      );

      // Handle result
      if (response == null || json.decode(response.data)['stat'] == 'fail') {
        if (!item.cancelToken.isCancelled) {
          uploadNotifier.itemUploadCompleted(item, error: true);
          nbError++;
        }
      } else {
        var data = json.decode(response.data);
        result.add(data['result']['id']);

        // Notify provider the upload has completed.
        uploadNotifier.itemUploadCompleted(item);
        safelyDeleteTempFile(item.file);
        if (Preferences.getDeleteAfterUpload) {
          // todo: delete real file path, not the cached one.
        }
      }
    } on DioException catch (e) {
      debugPrint("${e.message}");
      debugPrint("${e.stackTrace}");
      uploadNotifier.itemUploadCompleted(item, error: true);
      nbError++;
    } catch (e) {
      debugPrint("$e");
      if (e is Error) {
        debugPrint("${e.stackTrace}");
      }
      uploadNotifier.itemUploadCompleted(item, error: true);
      nbError++;
    }
  }

  // Send notifications
  showUploadNotification(nbError, result.length);

  // If no image was successfully uploaded, no call for "uploadCompleted"
  if (result.isEmpty) return [];

  // Empty Piwigo lounge
  try {
    await uploadCompleted(result, albumId);
    if (await methodExist('community.images.uploadCompleted')) {
      await communityUploadCompleted(result, albumId);
    }
  } on DioException catch (e) {
    debugPrint(e.message);
  }

  return result;
}

/// Upload images as chunks using [ChunkedUploader]
Future<Response?> uploadChunk({
  required File photo,
  required int category,
  required String url,
  Map<String, dynamic> info = const {},
  Function(double)? onProgress,
  String? username,
  String? password,
  CancelToken? cancelToken,
}) async {
  SharedPreferences prefs = await SharedPreferences.getInstance();

  // Request query parameters
  Map<String, String> queries = {
    'format': 'json',
    'method': 'pwg.images.uploadAsync',
  };

  // Initialize fields
  Map<String, dynamic> fields = {
    'username': username,
    'password': password,
    'filename': photo.path.split('/').last,
    'category': category,
  };

  // Filter fields
  if (info['name'] != '' && info['name'] != null) fields['name'] = info['name'];
  if (info['comment'] != '' && info['comment'] != null) fields['comment'] = info['comment'];
  if (info['tag_ids']?.isNotEmpty ?? false) fields['tag_ids'] = info['tag_ids'].join(',');
  if (info['level'] != -1 && info['level'] != null) fields['level'] = info['level'];
  if (info['author'] != '' && info['author'] != null) fields['author'] = info['author'];

  // Create dio client
  Dio dio = Dio(
    BaseOptions(
      baseUrl: url,
    ),
  )..interceptors.add(ApiInterceptor());

  // Initialize chunk uploader service
  ChunkedUploader chunkedUploader = ChunkedUploader(dio);

  // Upload image as chunks
  return await chunkedUploader.upload(
    path: '/ws.php',
    filePath: photo.absolute.path,
    maxChunkSize: (prefs.getInt(Preferences.uploadChunkSizeKey) ?? 100) * 1000,
    params: queries,
    method: 'POST',
    data: fields,
    cancelToken: cancelToken,
    contentType: Headers.formUrlEncodedContentType,
    onUploadProgress: (value) {
      if (onProgress != null) onProgress(value);
    },
  );
}

Future<bool> uploadCompleted(List<int> imageId, int categoryId) async {
  SharedPreferences prefs = await SharedPreferences.getInstance();
  Map<String, String> queries = {
    'format': 'json',
    'method': 'pwg.images.uploadCompleted',
  };
  FormData formData = FormData.fromMap({
    'image_id': imageId,
    'pwg_token': prefs.getString(Preferences.tokenKey),
    'category_id': categoryId,
  });

  try {
    Response response = await ApiClient.post(data: formData, queryParameters: queries);
    if (response.statusCode == 200) {
      return true;
    }
  } on DioException catch (e) {
    debugPrint("$e");
  }
  return false;
}

Future<bool> communityUploadCompleted(List<int> imageId, int categoryId) async {
  SharedPreferences prefs = await SharedPreferences.getInstance();
  Map<String, String> queries = {
    'format': 'json',
    'method': 'community.images.uploadCompleted',
  };
  FormData formData = FormData.fromMap({
    'image_id': imageId,
    'pwg_token': prefs.getString(Preferences.tokenKey),
    'category_id': categoryId,
  });
  try {
    Response response = await ApiClient.post(data: formData, queryParameters: queries);
    if (response.statusCode == 200) {
      return true;
    }
  } on DioException catch (e) {
    debugPrint("$e");
  }
  return false;
}
