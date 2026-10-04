import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../theme/app_colors.g.dart';

/// The code of a share sheet (`.qr-box`, 36-qr.js `QR.svg`): byte mode, error correction M, a
/// quiet zone of 4 modules, dark on light in every theme (`colors.qrDark` / `qrLight`) or phones
/// would not read it. Up to 240 px wide, square, corners 12.
class QrBox extends StatelessWidget {
  const QrBox._(this._qr);

  final QrCode _qr;

  /// The box for [text], null when it does not fit into a QR code (the mockup says "Too long").
  static QrBox? of(String text) {
    try {
      final qr = QrCode.fromData(
        data: text,
        errorCorrectLevel: QrErrorCorrectLevel.M,
      );
      // `fromData` is lazy: the length check fires when the modules are made, so make them here
      // and not while the sheet builds
      QrImage(qr);
      return QrBox._(qr);
    } on InputTooLongException {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 240),
      child: AspectRatio(
        aspectRatio: 1,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: ColoredBox(
            color: c.qrLight,
            child: LayoutBuilder(
              builder: (context, box) => Padding(
                // the quiet zone: 4 modules of the (size + 8) the box is divided into
                padding: EdgeInsets.all(
                  box.maxWidth * 4 / (_qr.moduleCount + 8),
                ),
                child: QrImageView.withQr(
                  qr: _qr,
                  padding: EdgeInsets.zero,
                  gapless: true,
                  backgroundColor: c.qrLight,
                  eyeStyle: QrEyeStyle(
                    eyeShape: QrEyeShape.square,
                    color: c.qrDark,
                  ),
                  dataModuleStyle: QrDataModuleStyle(
                    dataModuleShape: QrDataModuleShape.square,
                    color: c.qrDark,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
