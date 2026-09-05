package com.remi.piwigo_ng

import android.app.Activity
import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import android.provider.MediaStore
import android.provider.OpenableColumns
import android.util.Log
import androidx.exifinterface.media.ExifInterface
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.io.InputStream
import java.util.UUID

class MainActivity: FlutterActivity() {
    private val CHANNEL = "flutter_absolute_path"
    private val MEDIA_PICKER_CHANNEL = "com.piwigo.piwigo_ng/media_picker"
    private val REQUEST_CODE_PICK_MEDIA = 27401

    private var pendingPickerResult: MethodChannel.Result? = null
    private var pendingRequireOriginal: Boolean = true

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Background cache cleanup for files older than 24h
        Thread {
            try {
                cleanupCache(applicationContext, 24 * 60 * 60 * 1000L)
            } catch (ignored: Throwable) {}
        }.start()

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
            when (call.method) {
                "getAbsolutePath" -> {
                    val uriString = call.argument<String>("uri")
                    val requireOriginal = call.argument<Boolean>("requireOriginal") ?: true
                    if (uriString.isNullOrEmpty()) {
                        result.error("INVALID_ARGUMENT", "URI must not be null or empty", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val resolvedPath = getAbsolutePath(applicationContext, Uri.parse(uriString), requireOriginal)
                        if (resolvedPath != null) {
                            result.success(resolvedPath)
                        } else {
                            result.error("NOT_FOUND", "Could not resolve path for URI: $uriString", null)
                        }
                    } catch (e: Exception) {
                        result.error("UNEXPECTED_ERROR", e.localizedMessage ?: e.toString(), null)
                    }
                }
                "stripMetadata" -> {
                    val path = call.argument<String>("path")
                    if (path.isNullOrEmpty()) {
                        result.error("INVALID_ARGUMENT", "Path must not be null or empty", null)
                        return@setMethodCallHandler
                    }
                    try {
                        val sourceFile = File(path)
                        if (!sourceFile.exists()) {
                            result.error("NOT_FOUND", "File does not exist: $path", null)
                            return@setMethodCallHandler
                        }
                        // NEVER mutate original user files in-place!
                        // If file is not inside app cacheDir, create a sandbox copy in cacheDir before stripping.
                        val cacheCanonical = applicationContext.cacheDir.canonicalPath
                        val isAlreadyInCache = sourceFile.canonicalPath.startsWith(cacheCanonical)
                        val targetFile = if (isAlreadyInCache) {
                            sourceFile
                        } else {
                            val tempDir = File(File(applicationContext.cacheDir, "temp_upload"), UUID.randomUUID().toString())
                            if (!tempDir.exists()) tempDir.mkdirs()
                            val copyFile = File(tempDir, sourceFile.name)
                            sourceFile.copyTo(copyFile, overwrite = true)
                            copyFile
                        }
                        stripMetadataSafely(targetFile)
                        result.success(targetFile.absolutePath)
                    } catch (e: Exception) {
                        result.error("STRIP_ERROR", e.localizedMessage ?: e.toString(), null)
                    }
                }
                "copyExif" -> {
                    val src = call.argument<String>("src")
                    val dst = call.argument<String>("dst")
                    if (src.isNullOrEmpty() || dst.isNullOrEmpty()) {
                        result.error("INVALID_ARGUMENT", "src and dst must not be null or empty", null)
                        return@setMethodCallHandler
                    }
                    try {
                        copyExif(File(src), File(dst))
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("COPY_EXIF_ERROR", e.localizedMessage ?: e.toString(), null)
                    }
                }
                "clearCache" -> {
                    Thread {
                        try {
                            cleanupCache(applicationContext, 0L)
                            runOnUiThread { result.success(true) }
                        } catch (t: Throwable) {
                            runOnUiThread { result.error("CLEANUP_ERROR", t.localizedMessage ?: t.toString(), null) }
                        }
                    }.start()
                }
                else -> {
                    result.notImplemented()
                }
            }
        }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, MEDIA_PICKER_CHANNEL).setMethodCallHandler { call: MethodCall, result: MethodChannel.Result ->
            if (call.method == "pickMedia") {
                if (pendingPickerResult != null) {
                    pendingPickerResult?.error("CANCELLED", "A new pick request was started", null)
                    pendingPickerResult = null
                }
                pendingPickerResult = result
                pendingRequireOriginal = call.argument<Boolean>("requireOriginal") ?: true

                // ACTION_PICK_IMAGES (Photo Picker) redacts GPS/location EXIF by design.
                // To preserve unredacted EXIF/GPS metadata, use ACTION_GET_CONTENT with system chooser across all Android versions.
                val intent = Intent(Intent.ACTION_GET_CONTENT).apply {
                    type = "*/*"
                    putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("image/*", "video/*"))
                    putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
                    addCategory(Intent.CATEGORY_OPENABLE)
                }
                startActivityForResult(Intent.createChooser(intent, "Select Media"), REQUEST_CODE_PICK_MEDIA)
            } else {
                result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        if (pendingPickerResult != null) {
            try {
                pendingPickerResult?.error("CANCELLED", "Activity was destroyed", null)
            } catch (ignored: Exception) {}
            pendingPickerResult = null
        }
        super.onDestroy()
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_CODE_PICK_MEDIA) {
            val result = pendingPickerResult ?: return
            pendingPickerResult = null
            val requireOriginal = pendingRequireOriginal

            if (resultCode != Activity.RESULT_OK || data == null) {
                result.success(emptyList<String>())
                return
            }

            val uris = mutableListOf<Uri>()
            val clipData = data.clipData
            if (clipData != null) {
                for (i in 0 until clipData.itemCount) {
                    uris.add(clipData.getItemAt(i).uri)
                }
            } else if (data.data != null) {
                uris.add(data.data!!)
            }

            Thread {
                try {
                    val paths = mutableListOf<String>()
                    for (uri in uris) {
                        val path = getAbsolutePath(applicationContext, uri, requireOriginal)
                        if (path != null) {
                            paths.add(path)
                        }
                    }
                    runOnUiThread {
                        result.success(paths)
                    }
                } catch (t: Throwable) {
                    runOnUiThread {
                        result.error("PICK_MEDIA_ERROR", t.localizedMessage ?: t.toString(), null)
                    }
                }
            }.start()
        }
    }

    private fun resolveToMediaUri(context: Context, uri: Uri): Uri {
        try {
            if (DocumentsContract.isDocumentUri(context, uri)) {
                if (uri.authority == "com.android.providers.media.documents") {
                    val docId = DocumentsContract.getDocumentId(uri)
                    val split = docId.split(":")
                    val type = split[0]
                    val id = split.getOrNull(1)?.toLongOrNull()
                    if (id != null) {
                        return when (type) {
                            "image" -> ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, id)
                            "video" -> ContentUris.withAppendedId(MediaStore.Video.Media.EXTERNAL_CONTENT_URI, id)
                            else -> uri
                        }
                    }
                }
            }
        } catch (ignored: Exception) {}
        return uri
    }

    private fun getAbsolutePath(context: Context, originalUri: Uri, requireOriginal: Boolean = true): String? {
        if (originalUri.scheme == "file" || originalUri.scheme != ContentResolver.SCHEME_CONTENT) {
            val rawPath = originalUri.path ?: return null
            val sourceFile = File(rawPath)
            if (!sourceFile.exists()) return null

            if (requireOriginal) {
                return sourceFile.absolutePath
            } else {
                // NEVER mutate source file in-place! Copy to cacheDir sandbox first.
                val tempDir = File(File(context.cacheDir, "temp_upload"), UUID.randomUUID().toString())
                if (!tempDir.exists()) tempDir.mkdirs()
                val tempFile = File(tempDir, sourceFile.name)
                sourceFile.copyTo(tempFile, overwrite = true)
                stripMetadataSafely(tempFile)
                return tempFile.absolutePath
            }
        }

        val mediaUri = resolveToMediaUri(context, originalUri)
        Log.d("PiwigoMedia", "Original URI: $originalUri, resolved mediaUri: $mediaUri, requireOriginal=$requireOriginal")
        val unredactedUri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q && requireOriginal) {
            try {
                MediaStore.setRequireOriginal(mediaUri)
            } catch (e: Exception) {
                Log.w("PiwigoMedia", "setRequireOriginal failed on $mediaUri: ${e.message}")
                mediaUri
            }
        } else {
            mediaUri
        }

        var inputStream: InputStream? = null
        try {
            inputStream = context.contentResolver.openInputStream(unredactedUri)
            Log.d("PiwigoMedia", "Opened inputStream from unredactedUri: $unredactedUri")
        } catch (e: Exception) {
            Log.w("PiwigoMedia", "openInputStream failed on $unredactedUri: ${e.message}, falling back to $originalUri")
            try {
                inputStream = context.contentResolver.openInputStream(originalUri)
            } catch (fallbackEx: Exception) {
                Log.e("PiwigoMedia", "openInputStream fallback failed on $originalUri: ${fallbackEx.message}")
                return null
            }
        }

        return inputStream?.use { stream ->
            val rawName = getFileName(context, originalUri) ?: "media"
            val fileDir = File(File(context.cacheDir, "original_media"), UUID.randomUUID().toString())
            if (!fileDir.exists()) {
                fileDir.mkdirs()
            }
            val tempFile = File(fileDir, rawName)
            FileOutputStream(tempFile).use { output ->
                stream.copyTo(output)
            }
            if (!requireOriginal) {
                stripMetadataSafely(tempFile)
            }
            try {
                val exif = ExifInterface(tempFile.absolutePath)
                val latLong = exif.latLong
                Log.d("PiwigoMedia", "Copied to ${tempFile.absolutePath}, hasGPS=${latLong != null}, latLong=${latLong?.contentToString()}")
            } catch (e: Exception) {
                Log.d("PiwigoMedia", "Copied to ${tempFile.absolutePath}, EXIF check exception: ${e.message}")
            }
            tempFile.absolutePath
        }
    }

    private fun copyExif(src: File, dst: File) {
        if (!src.exists() || !dst.exists() || !dst.canWrite()) return
        try {
            val srcExif = ExifInterface(src.absolutePath)
            val dstExif = ExifInterface(dst.absolutePath)
            val tags = arrayOf(
                ExifInterface.TAG_GPS_LATITUDE,
                ExifInterface.TAG_GPS_LATITUDE_REF,
                ExifInterface.TAG_GPS_LONGITUDE,
                ExifInterface.TAG_GPS_LONGITUDE_REF,
                ExifInterface.TAG_GPS_ALTITUDE,
                ExifInterface.TAG_GPS_ALTITUDE_REF,
                ExifInterface.TAG_GPS_TIMESTAMP,
                ExifInterface.TAG_GPS_DATESTAMP,
                ExifInterface.TAG_GPS_PROCESSING_METHOD,
                ExifInterface.TAG_GPS_AREA_INFORMATION,
                ExifInterface.TAG_GPS_SPEED,
                ExifInterface.TAG_GPS_SPEED_REF,
                ExifInterface.TAG_GPS_TRACK,
                ExifInterface.TAG_GPS_TRACK_REF,
                ExifInterface.TAG_GPS_IMG_DIRECTION,
                ExifInterface.TAG_GPS_IMG_DIRECTION_REF,
                ExifInterface.TAG_DATETIME,
                ExifInterface.TAG_DATETIME_ORIGINAL,
                ExifInterface.TAG_DATETIME_DIGITIZED,
                ExifInterface.TAG_SUBSEC_TIME,
                ExifInterface.TAG_SUBSEC_TIME_ORIGINAL,
                ExifInterface.TAG_SUBSEC_TIME_DIGITIZED,
                ExifInterface.TAG_OFFSET_TIME,
                ExifInterface.TAG_OFFSET_TIME_ORIGINAL,
                ExifInterface.TAG_OFFSET_TIME_DIGITIZED,
                ExifInterface.TAG_MAKE,
                ExifInterface.TAG_MODEL,
                ExifInterface.TAG_ORIENTATION
            )
            var modified = false
            for (tag in tags) {
                val value = srcExif.getAttribute(tag)
                if (value != null) {
                    dstExif.setAttribute(tag, value)
                    modified = true
                }
            }
            if (modified) {
                dstExif.saveAttributes()
            }
        } catch (ignored: Exception) {}
    }

    private fun stripMetadataSafely(file: File) {
        if (!file.exists() || !file.canWrite()) return
        try {
            val exif = ExifInterface(file.absolutePath)
            val tagsToStrip = arrayOf(
                // GPS location metadata
                ExifInterface.TAG_GPS_LATITUDE,
                ExifInterface.TAG_GPS_LATITUDE_REF,
                ExifInterface.TAG_GPS_LONGITUDE,
                ExifInterface.TAG_GPS_LONGITUDE_REF,
                ExifInterface.TAG_GPS_ALTITUDE,
                ExifInterface.TAG_GPS_ALTITUDE_REF,
                ExifInterface.TAG_GPS_TIMESTAMP,
                ExifInterface.TAG_GPS_DATESTAMP,
                ExifInterface.TAG_GPS_PROCESSING_METHOD,
                ExifInterface.TAG_GPS_AREA_INFORMATION,
                ExifInterface.TAG_GPS_SPEED,
                ExifInterface.TAG_GPS_SPEED_REF,
                ExifInterface.TAG_GPS_TRACK,
                ExifInterface.TAG_GPS_TRACK_REF,
                ExifInterface.TAG_GPS_IMG_DIRECTION,
                ExifInterface.TAG_GPS_IMG_DIRECTION_REF,
                ExifInterface.TAG_GPS_DEST_LATITUDE,
                ExifInterface.TAG_GPS_DEST_LATITUDE_REF,
                ExifInterface.TAG_GPS_DEST_LONGITUDE,
                ExifInterface.TAG_GPS_DEST_LONGITUDE_REF,
                ExifInterface.TAG_GPS_DEST_BEARING,
                ExifInterface.TAG_GPS_DEST_BEARING_REF,
                ExifInterface.TAG_GPS_DEST_DISTANCE,
                ExifInterface.TAG_GPS_DEST_DISTANCE_REF,
                ExifInterface.TAG_GPS_DOP,
                ExifInterface.TAG_GPS_MEASURE_MODE,
                ExifInterface.TAG_GPS_SATELLITES,
                ExifInterface.TAG_GPS_STATUS,
                ExifInterface.TAG_GPS_MAP_DATUM,
                ExifInterface.TAG_GPS_DIFFERENTIAL,
                ExifInterface.TAG_GPS_H_POSITIONING_ERROR,
                // Device, owner, and personal metadata
                ExifInterface.TAG_MAKE,
                ExifInterface.TAG_MODEL,
                ExifInterface.TAG_DEVICE_SETTING_DESCRIPTION,
                ExifInterface.TAG_BODY_SERIAL_NUMBER,
                ExifInterface.TAG_CAMERA_OWNER_NAME,
                ExifInterface.TAG_ARTIST,
                ExifInterface.TAG_COPYRIGHT,
                ExifInterface.TAG_USER_COMMENT,
                ExifInterface.TAG_IMAGE_DESCRIPTION,
                ExifInterface.TAG_SOFTWARE,
                ExifInterface.TAG_LENS_MAKE,
                ExifInterface.TAG_LENS_MODEL,
                ExifInterface.TAG_LENS_SERIAL_NUMBER,
                ExifInterface.TAG_LENS_SPECIFICATION,
                ExifInterface.TAG_DATETIME,
                ExifInterface.TAG_DATETIME_ORIGINAL,
                ExifInterface.TAG_DATETIME_DIGITIZED,
                ExifInterface.TAG_SUBSEC_TIME,
                ExifInterface.TAG_SUBSEC_TIME_ORIGINAL,
                ExifInterface.TAG_SUBSEC_TIME_DIGITIZED,
                ExifInterface.TAG_OFFSET_TIME,
                ExifInterface.TAG_OFFSET_TIME_ORIGINAL,
                ExifInterface.TAG_OFFSET_TIME_DIGITIZED
            )
            var modified = false
            for (tag in tagsToStrip) {
                if (exif.getAttribute(tag) != null) {
                    exif.setAttribute(tag, null)
                    modified = true
                }
            }
            if (modified) {
                exif.saveAttributes()
            }
        } catch (e: Exception) {
            // Ignore formats or files that do not support EXIF editing
        }
    }

    private fun cleanupCache(context: Context, maxAgeMillis: Long) {
        val dirsToClean = listOf(
            File(context.cacheDir, "original_media"),
            File(context.cacheDir, "temp_upload"),
            File(context.cacheDir, "compressed")
        )
        val now = System.currentTimeMillis()
        for (parent in dirsToClean) {
            if (parent.exists() && parent.isDirectory) {
                parent.listFiles()?.forEach { sub ->
                    if (maxAgeMillis == 0L || (now - sub.lastModified() > maxAgeMillis)) {
                        try {
                            sub.deleteRecursively()
                        } catch (ignored: Exception) {}
                    }
                }
            }
        }
    }

    private fun getFileName(context: Context, uri: Uri): String? {
        var name: String? = null
        if (uri.scheme == ContentResolver.SCHEME_CONTENT) {
            try {
                context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        val nameIndex = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                        if (nameIndex != -1) {
                            name = cursor.getString(nameIndex)
                        }
                    }
                }
            } catch (e: Exception) {
                // Ignore and fallback
            }
        }
        if (name == null) {
            name = uri.lastPathSegment
        }
        return name
    }
}
