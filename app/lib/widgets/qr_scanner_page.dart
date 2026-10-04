import 'package:flutter/material.dart';
import 'package:flutter_zxing/flutter_zxing.dart';

import '../l10n/l10n.dart';
import '../theme/app_colors.g.dart';

/// Nodes -> + -> Scan QR code: a full-screen camera view that closes with the text of the first
/// QR code it reads (null when the user backs out). The reader is zxing-cpp over the `camera`
/// plugin (flutter_zxing): no Google Play Services, no ML Kit. Its own gallery button decodes a
/// picture the same way. The mockup has no camera, so this screen is the app's own.
class QrScannerPage extends StatefulWidget {
  const QrScannerPage({super.key});

  /// Opens the scanner over [context]'s navigator; the scanned text, or null.
  static Future<String?> open(BuildContext context) => Navigator.of(
    context,
  ).push<String>(MaterialPageRoute(builder: (_) => const QrScannerPage()));

  @override
  State<QrScannerPage> createState() => _QrScannerPageState();
}

class _QrScannerPageState extends State<QrScannerPage> {
  bool _done = false;

  void _onScan(Code code) {
    final text = code.text;
    if (_done || !code.isValid || text == null || text.isEmpty) return;
    _done = true;
    Navigator.of(context).pop(text);
  }

  void _onControllerCreated(CameraController? controller, Exception? error) {
    if (error == null && controller != null) return;
    if (_done || !mounted) return;
    _done = true;
    final text = context.l10n.theCameraIsNotAvailable;
    // the scanner route is gone after the pop, the toast goes to the page below it
    final messenger = ScaffoldMessenger.maybeOf(context);
    Navigator.of(context).pop();
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Scaffold(
      backgroundColor: c.bg,
      body: Stack(
        fit: StackFit.expand,
        children: [
          ReaderWidget(
            codeFormat: Format.qrCode,
            tryHarder: true,
            tryInverted: true,
            showFlashlight: true,
            showToggleCamera: false,
            actionButtonsBackgroundColor: c.card,
            scannerOverlay: ScannerOverlayBorder(
              cutOutSize: 0.7,
              borderColor: c.accent,
              overlayColor: c.bg.withValues(alpha: .6),
            ),
            loading: DecoratedBox(decoration: BoxDecoration(color: c.bg)),
            onScan: _onScan,
            onControllerCreated: _onControllerCreated,
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 16, 0),
                child: Row(
                  children: [
                    IconButton(
                      icon: Icon(Icons.close, color: c.t1),
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                    Expanded(
                      child: Text(
                        context.l10n.scanQrCode,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: c.t1,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
