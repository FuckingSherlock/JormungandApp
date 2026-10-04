import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_zxing/flutter_zxing.dart';

import '../widgets/qr_scanner_page.dart';

/// Why [ImportIo.pickFile] gave nothing to import.
enum ImportFailure {
  /// An image without a readable QR code.
  noQr,

  /// The file could not be read (or is too big to be a config).
  unreadable,
}

class ImportException implements Exception {
  const ImportException(this.failure);

  final ImportFailure failure;

  @override
  String toString() => 'ImportException($failure)';
}

/// The two ways of bringing text into Nodes -> + besides the clipboard: the camera and a file.
/// Both end in text that goes through the same path as a pasted link. Tests put a fake into
/// [current] (the real ones need a camera and the system dialogs).
abstract class ImportIo {
  static ImportIo current = _PlatformImportIo();

  /// The text of the first QR code the camera reads; null when the user backed out. Throws
  /// nothing: a camera that cannot start tells the user itself.
  Future<String?> scan(BuildContext context);

  /// Asks for a file. An image is read as a QR code and gives its text; any other file gives its
  /// text (UTF-8). Null when the user closed the dialog; throws [ImportException] otherwise.
  Future<String?> pickFile();
}

/// The extensions the image decoder (package `image` in flutter_zxing) reads.
const _imageExtensions = {'png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif'};

/// A config is text of a few KB, a QR picture a few MB; anything bigger is not what we want.
const _maxFileBytes = 16 * 1024 * 1024;

class _PlatformImportIo implements ImportIo {
  @override
  Future<String?> scan(BuildContext context) => QrScannerPage.open(context);

  @override
  Future<String?> pickFile() async {
    final file = await FilePicker.pickFile();
    if (file == null) return null;
    try {
      final size = await file.length();
      if (size != null && size > _maxFileBytes) {
        throw const ImportException(ImportFailure.unreadable);
      }
      if (_imageExtensions.contains(file.extension?.toLowerCase())) {
        final code = await zx.readBarcodeImagePath(
          file.xFile,
          DecodeParams(
            format: Format.qrCode,
            tryHarder: true,
            tryInverted: true,
            maxSize: 2048,
          ),
        );
        final text = code.text;
        if (!code.isValid || text == null || text.isEmpty) {
          throw const ImportException(ImportFailure.noQr);
        }
        return text;
      }
      return utf8.decode(await file.readAsBytes(), allowMalformed: true);
    } on ImportException {
      rethrow;
    } catch (_) {
      throw const ImportException(ImportFailure.unreadable);
    }
  }
}
