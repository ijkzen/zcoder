import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

/// Full-screen QR scanner styled after WeChat's 扫一扫: darkened camera view
/// with a rounded-square cutout, green corner brackets, a sweeping scan line,
/// a close button, torch toggle, and a hint under the frame.
///
/// Pops with the scanned string (or null when closed without a scan).
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage>
    with SingleTickerProviderStateMixin {
  late final MobileScannerController _controller;
  late final AnimationController _lineController;
  bool _handled = false;

  static const _wechatGreen = Color(0xFF07C160);

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
    );
    _lineController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _lineController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    final raw =
        capture.barcodes.map((b) => b.rawValue).whereType<String>().firstOrNull;
    if (raw == null) return;
    _handled = true;
    Navigator.of(context).pop(raw);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          final windowSide = math.min(size.width * 0.68, 320.0);
          final scanRect = Rect.fromCenter(
            center: Offset(size.width / 2, size.height * 0.40),
            width: windowSide,
            height: windowSide,
          );
          return Stack(
            fit: StackFit.expand,
            children: [
              MobileScanner(
                controller: _controller,
                scanWindow: scanRect,
                onDetect: _onDetect,
              ),
              CustomPaint(
                painter: _ScanOverlayPainter(scanRect: scanRect),
              ),
              // Sweeping scan line inside the window. The Positioned must be
              // a direct Stack child — Positioned nested inside the
              // AnimatedBuilder silently loses its position in release builds.
              Positioned.fromRect(
                rect: scanRect,
                child: ClipRect(
                  child: AnimatedBuilder(
                    animation: _lineController,
                    builder: (context, _) {
                      return Align(
                        alignment:
                            Alignment(0, -0.96 + 1.92 * _lineController.value),
                        child: Padding(
                          padding:
                              const EdgeInsets.symmetric(horizontal: 8),
                          child: Container(
                            height: 2.5,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(2),
                              gradient: LinearGradient(
                                colors: [
                                  _wechatGreen.withValues(alpha: 0),
                                  _wechatGreen,
                                  _wechatGreen.withValues(alpha: 0),
                                ],
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: _wechatGreen.withValues(alpha: 0.6),
                                  blurRadius: 8,
                                  spreadRadius: 1,
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              // Top bar: close + title. Must be Positioned — with
              // StackFit.expand a loose child fills the whole stack and its
              // contents end up vertically centered.
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: SafeArea(
                  child: SizedBox(
                    height: kToolbarHeight,
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                        const Expanded(
                          child: Text(
                            '扫一扫',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                        const SizedBox(width: 48), // balance the close button
                      ],
                    ),
                  ),
                ),
              ),
              // Hint + torch under the window.
              Positioned(
                left: 0,
                right: 0,
                top: scanRect.bottom + 28,
                child: Column(
                  children: [
                    const Text(
                      '将二维码放入框内，即可自动扫描',
                      style: TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      '桌面端 ZCode → 移动端远程控制',
                      style: TextStyle(color: Colors.white38, fontSize: 12),
                    ),
                    const SizedBox(height: 20),
                    ValueListenableBuilder<MobileScannerState>(
                      valueListenable: _controller,
                      builder: (context, state, _) {
                        final torchOn = state.torchState == TorchState.on;
                        return IconButton(
                          tooltip: torchOn ? '关闭手电筒' : '打开手电筒',
                          icon: Icon(
                            torchOn ? Icons.flash_on : Icons.flash_off,
                            color: torchOn ? _wechatGreen : Colors.white70,
                            size: 28,
                          ),
                          onPressed: () => _controller.toggleTorch(),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// Darkens everything except a rounded-square window, and draws the four
/// green corner brackets around it.
class _ScanOverlayPainter extends CustomPainter {
  final Rect scanRect;
  const _ScanOverlayPainter({required this.scanRect});

  static const _green = Color(0xFF07C160);

  @override
  void paint(Canvas canvas, Size size) {
    final window =
        RRect.fromRectAndRadius(scanRect, const Radius.circular(12));

    // Dim layer with the window punched out.
    final dimPaint = Paint()..color = Colors.black54;
    final dimPath = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addRRect(window);
    canvas.drawPath(dimPath, dimPaint);

    // Corner brackets.
    final bracketPaint = Paint()
      ..color = _green
      ..style = PaintingStyle.stroke
      ..strokeWidth = 4
      ..strokeCap = StrokeCap.round;
    const arm = 22.0;
    const pad = 3.0;
    final r = scanRect.inflate(pad);
    final path = Path()
      // top-left
      ..moveTo(r.left, r.top + arm)
      ..lineTo(r.left, r.top)
      ..lineTo(r.left + arm, r.top)
      // top-right
      ..moveTo(r.right - arm, r.top)
      ..lineTo(r.right, r.top)
      ..lineTo(r.right, r.top + arm)
      // bottom-right
      ..moveTo(r.right, r.bottom - arm)
      ..lineTo(r.right, r.bottom)
      ..lineTo(r.right - arm, r.bottom)
      // bottom-left
      ..moveTo(r.left + arm, r.bottom)
      ..lineTo(r.left, r.bottom)
      ..lineTo(r.left, r.bottom - arm);
    canvas.drawPath(path, bracketPaint);
  }

  @override
  bool shouldRepaint(_ScanOverlayPainter oldDelegate) =>
      oldDelegate.scanRect != scanRect;
}
