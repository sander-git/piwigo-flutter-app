import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:piwigo_ng/network/upload.dart';
import 'package:piwigo_ng/components/dialogs/confirm_dialog.dart';
import 'package:piwigo_ng/components/modals/choose_camera_picker_modal.dart';
import 'package:piwigo_ng/components/modals/choose_move_option_modal.dart';
import 'package:piwigo_ng/components/modals/delete_images_modal.dart';
import 'package:piwigo_ng/components/modals/select_move_or_copy_modal.dart';
import 'package:piwigo_ng/components/modals/piwigo_modal.dart';
import 'package:piwigo_ng/components/snackbars.dart';
import 'package:piwigo_ng/models/album_model.dart';
import 'package:piwigo_ng/models/image_model.dart';
import 'package:piwigo_ng/network/albums.dart';
import 'package:piwigo_ng/network/images.dart';
import 'package:piwigo_ng/network/users.dart';
import 'package:piwigo_ng/services/preferences_service.dart';
import 'package:piwigo_ng/utils/localizations.dart';
import 'package:piwigo_ng/views/image/edit_image_page.dart';

final ImagePicker _picker = ImagePicker();

Future<File> compressImage(File file,
    [int? cacheWidth, int? cacheHeight]) async {
  debugPrint("Compress image ${file.path}");
  try {
    // Get original file path
    final filePath = file.path;

    // Directory output
    var dir = await getTemporaryDirectory();

    // Extract file name and extension
    final String filename = filePath.split('/').last;

    // Output file path
    final outPath = "${dir.absolute.path}/display_cached-$filename";

    // Compress with quality parameter and exif metadata
    var result = await FlutterImageCompress.compressAndGetFile(
      filePath,
      outPath,
      minWidth: cacheWidth ?? 100,
      minHeight: cacheHeight ?? 100,
      format: CompressFormat.jpeg,
    );

    debugPrint("Upload Compress $result");
    if (result != null) {
      return File(result.path);
    } else {
      return file;
    }
  } catch (e) {
    debugPrint(e.toString());
  }
  return file;
}

bool isAllowedFileType(String fileName) {
  final availableTypes = Preferences.getAvailableFileTypes
      .map((e) => e.trim().toLowerCase().replaceAll('.', ''))
      .where((e) => e.isNotEmpty)
      .toSet();
  if (availableTypes.isEmpty) {
    return true;
  }
  final dotIndex = fileName.lastIndexOf('.');
  if (dotIndex == -1 || dotIndex == fileName.length - 1) return false;
  final ext = fileName.substring(dotIndex + 1).toLowerCase();
  return availableTypes.contains(ext);
}

Future<List<XFile>?> onPickImages() async {
  try {
    if (Platform.isAndroid) {
      if (!await askMediaPermission()) return null;
      try {
        const MethodChannel pickerChannel =
            MethodChannel('com.piwigo.piwigo_ng/media_picker');
        final bool requireOriginal = !Preferences.getRemoveMetadata;
        final List<dynamic>? paths =
            await pickerChannel.invokeMethod<List<dynamic>>('pickMedia', {
          'requireOriginal': requireOriginal,
        });
        if (paths != null && paths.isNotEmpty) {
          List<XFile> files = [];
          for (var p in paths) {
            final file = XFile(p.toString());
            if (isAllowedFileType(file.name)) {
              files.add(file);
            }
          }
          return files;
        } else if (paths != null && paths.isEmpty) {
          return [];
        }
      } catch (e) {
        debugPrint('Native media picker fallback: $e');
      }
    }

    List<XFile> pickedFiles = await _picker.pickMultipleMedia(
      imageQuality: Preferences.getRemoveMetadata
          ? (Preferences.getUploadQuality * 100).round()
          : (Preferences.getUploadQuality < 1.0
              ? (Preferences.getUploadQuality * 100).round()
              : null),
      requestFullMetadata: !Preferences.getRemoveMetadata,
    );
    List<XFile> files = [];
    for (var file in pickedFiles) {
      if (isAllowedFileType(file.name)) {
        files.add(file);
      }
    }
    return files;
  } catch (e) {
    debugPrint('${e.toString()}');
  }
  return null;
}

Future<XFile?> onTakePhoto(BuildContext context) async {
  final int? choice = await showPiwigoModal<int>(
    context: context,
    builder: (context) => ChooseCameraPickerModal(),
  );
  if (choice == null) return null;
  try {
    XFile? image;
    switch (choice) {
      case 0:
        image = await _picker.pickImage(
          source: ImageSource.camera,
          imageQuality: Preferences.getRemoveMetadata
              ? (Preferences.getUploadQuality * 100).round()
              : (Preferences.getUploadQuality < 1.0
                  ? (Preferences.getUploadQuality * 100).round()
                  : null),
          requestFullMetadata: !Preferences.getRemoveMetadata,
        );
        break;
      case 1:
        image = await _picker.pickVideo(source: ImageSource.camera);
        break;
    }
    return image;
  } catch (e) {
    debugPrint('${e.toString()}');
  }
  return null;
}

Future<bool?> onEditPhotos(
    BuildContext context, List<ImageModel> images) async {
  return await Navigator.of(context)
      .pushNamed(EditImagePage.routeName, arguments: {
    'images': images,
  });
}

Future<dynamic> onMovePhotos(BuildContext context, List<ImageModel> images,
    [AlbumModel? album]) async {
  late AlbumModel origin;
  if (album == null || images.length == 1) {
    origin = AlbumModel(
      id: images.first.categories.first['id'],
      name: '',
    );
  } else {
    origin = album;
  }
  return showPiwigoModal(
    context: context,
    builder: (_) => SelectMoveOrCopyModal(
      title: appStrings.moveImage_title,
      subtitle: appStrings.moveImage_selectAlbum(
        images.length,
        images.first.name ?? "",
      ),
      isImage: true,
      album: origin,
      onSelected: (selectedAlbum) async {
        final int? choice = await showPiwigoModal<int>(
          context: context,
          builder: (context) => ChooseMoveOptionModal(),
        );
        if (choice == null ||
            !await showConfirmDialog(
              context,
              title: appStrings.moveImage_title,
              message: appStrings.moveImage_message(
                  images.length, images.first, selectedAlbum.name),
            )) return false;
        int results = 0;
        switch (choice) {
          case 0:
            results = await moveImages(images, origin.id, selectedAlbum.id);
            break;
          case 1:
            results = await assignImages(images, selectedAlbum.id);
            break;
        }
        if (results > 0) {
          return true;
        }
        return false;
      },
    ),
  );
}

Future<bool> onDeletePhotos(
  BuildContext context,
  List<ImageModel> images, [
  AlbumModel? album,
]) async {
  DeleteAlbumModes? mode = await showPiwigoModal<DeleteAlbumModes>(
    context: context,
    builder: (context) => DeleteImagesModal(
      imageList: images,
      album: album,
    ),
  );
  if (mode == null) return false;

  if (!await showConfirmDialog(
    context,
    message: appStrings.deleteImage_message(
      images.length,
    ),
  )) {
    return false;
  }
  final int result = await deleteImages(
    images,
    album,
    mode,
  );
  if (result > 0) {
    ScaffoldMessenger.of(context).showSnackBar(
      successSnackBar(message: appStrings.deleteImageSuccess_message(result)),
    );
    return true;
  } else {
    ScaffoldMessenger.of(context).showSnackBar(
      errorSnackBar(message: appStrings.deleteImageFail_message),
    );
  }
  return false;
}

Future<bool?> onLikePhotos(
    List<ImageModel> images, bool hasNonFavorites) async {
  if (hasNonFavorites) {
    int success =
        await addFavorites(images.where((image) => !image.favorite).toList());
    if (success > 0) {
      return true;
    }
  } else {
    int success = await removeFavorites(images);
    if (success > 0) {
      return false;
    }
  }
  return null;
}
