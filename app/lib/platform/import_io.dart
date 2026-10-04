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

/// What [ImportIo.pickFile] read: the [text] of the picked file, or - when the file was an image -
/// of the QR code in it ([qr]). [name] is the file name.
class PickedFile {
  const PickedFile(this.name, this.text, {this.qr = false});

  final String name;
  final String text;
  final bool qr;
}

/// The two ways of bringing text into Nodes -> + besides the clipboard: the camera and a file.
/// The camera's text and a QR image's go through the same path as a pasted link; any other file
/// becomes a local source. Tests put a fake into [current] (the real ones need a camera and the
/// system dialogs).
abstract class ImportIo {
  static ImportIo current = _PlatformImportIo();

  /// The text of the first QR code the camera reads; null when the user backed out. Throws
  /// nothing: a camera that cannot start tells the user itself.
  Future<String?> scan(BuildContext context);

  /// Asks for a file. An image is read as a QR code and gives its text ([PickedFile.qr]); any
  /// other file gives its text (UTF-8). Null when the user closed the dialog; throws
  /// [ImportException] otherwise.
  Future<PickedFile?> pickFile();
}

/// The extensions the image decoder (package `image` in flutter_zxing) reads.
const _imageExtensions = {'png', 'jpg', 'jpeg', 'webp', 'bmp', 'gif'};

/// A config is text of a few KB, a QR picture a few MB; anything bigger is not what we want.
const _maxFileBytes = 16 * 1024 * 1024;

class _PlatformImportIo implements ImportIo {
  @override
  Future<String?> scan(BuildContext context) => QrScannerPage.open(context);

  @override
  Future<PickedFile?> pickFile() async {
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
        return PickedFile(file.name, text, qr: true);
      }
      return PickedFile(
        file.name,
        utf8.decode(await file.readAsBytes(), allowMalformed: true),
      );
    } on ImportException {
      rethrow;
    } catch (_) {
      throw const ImportException(ImportFailure.unreadable);
    }
  }
}
