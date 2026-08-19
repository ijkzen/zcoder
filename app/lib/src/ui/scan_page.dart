import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../protocol/relay/relay_frame.dart';
import '../protocol/zlog.dart';

/// Full-screen QR scanner styled after WeChat's 扫一扫: darkened camera view
/// with a rounded-square cutout, green corner brackets, a sweeping scan line,
/// a close button, torch toggle, and a hint under the frame.
///
/// Pops with the scanned string (or null when closed without a scan). Codes
/// that are not pairing links are rejected in place so the user can rescan
/// right away.
class ScanPage extends StatefulWidget {
  const ScanPage({super.key});

  @override
  State<ScanPage> createState() => _ScanPageState();
}

class _ScanPageState extends State<ScanPage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final MobileScannerController _controller;
  late final AnimationController _lineController;
  bool _handled = false;
  bool _invalidHint = false;
  Timer? _invalidHintTimer;

  /// True when the Activity was paused (e.g. by the permission dialog) while
  /// the controller's first [start] was still in flight. On resume, the camera
  /// needs to be rebound so that CameraX's [ImageAnalysis] analyzer is
  /// activated from a STARTED lifecycle state — binding it during the pause
  /// → resume transition leaves the analyzer dormant (preview works, but
  /// barcode detection never fires). See [_onControllerChanged].
  bool _startInFlightOnPause = false;

  static const _wechatGreen = Color(0xFF07C160);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = MobileScannerController(
      detectionSpeed: DetectionSpeed.noDuplicates,
    );
    _controller.addListener(_onControllerChanged);
    _lineController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    // Never leave the torch burning after the page goes away.
    if (_controller.value.torchState == TorchState.on) {
      unawaited(_controller.toggleTorch());
    }
    WidgetsBinding.instance.removeObserver(this);
    _controller.removeListener(_onControllerChanged);
    _invalidHintTimer?.cancel();
    _lineController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    // The in-flight start() has settled. If it was interrupted by a pause
    // (permission dialog), rebind the camera so ImageAnalysis activates.
    if (!_startInFlightOnPause || !mounted) return;
    if (_controller.value.isStarting) return; // still in flight
    _startInFlightOnPause = false;
    _rebindCamera();
  }

  /// Stop and restart the camera so that CameraX rebinds ImageAnalysis from
  /// a STARTED lifecycle state, activating the barcode analyzer.
  void _rebindCamera() {
    if (!mounted) return;
    unawaited(_controller.stop().then((_) {
      if (mounted) unawaited(_controller.start());
    }));
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      // The Activity is being paused. If the controller's first start() is
      // still in flight (e.g. the permission dialog just appeared), flag it
      // so we can rebind on resume.
      if (_controller.value.isStarting) {
        _startInFlightOnPause = true;
      }
      return;
    }
    if (state != AppLifecycleState.resumed) return;
    if (!mounted) return;

    if (_startInFlightOnPause) {
      // The first start() was interrupted by the permission dialog. If it has
      // already settled by now, rebind immediately; otherwise the listener
      // ([_onControllerChanged]) will rebind once it settles.
      if (!_controller.value.isStarting) {
        _startInFlightOnPause = false;
        _rebindCamera();
      }
      return;
    }

    // Normal resume: restart the camera if it is not running (e.g. returning
    // from system settings after manually granting permission).
    if (!_controller.value.isRunning) {
      unawaited(_controller.start());
    }
  }

  void _onDetect(BarcodeCapture capture) {
    if (_handled) return;
    final raw = capture.barcodes
        .map((b) => b.rawValue)
        .whereType<String>()
        .firstOrNull;
    if (raw == null) return;
    if (PairingCredential.fromUrl(raw) == null) {
      // Not a pairing link: stay on the page and say so (noDuplicates keeps
      // the same code from re-firing the hint in a loop).
      _invalidHintTimer?.cancel();
      setState(() => _invalidHint = true);
      _invalidHintTimer = Timer(const Duration(milliseconds: 2500), () {
        if (mounted) setState(() => _invalidHint = false);
      });
      return;
    }
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
                errorBuilder: (context, error) {
                  if (error.errorCode ==
                      MobileScannerErrorCode.permissionDenied) {
                    return _PermissionPlaceholder(
                      onOpenSettings: _openAppSettings,
                    );
                  }
                  return Center(
                    child: Text(
                      '相机不可用：${error.errorCode}',
                      style: const TextStyle(color: Colors.white70),
                    ),
                  );
                },
              ),
              CustomPaint(painter: _ScanOverlayPainter(scanRect: scanRect)),
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
                        alignment: Alignment(
                          0,
                          -0.96 + 1.92 * _lineController.value,
                        ),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
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
                    if (_invalidHint)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: Text(
                          '不是有效的配对码',
                          style: TextStyle(
                            color: Colors.orangeAccent,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
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

  /// 跳转系统设置页让用户手动授予被拒的权限（替代 permission_handler 的
  /// openAppSettings，走 MainActivity 的 device_info 通道）。
  Future<void> _openAppSettings() async {
    const channel = MethodChannel('dev.ijkzen.zcode_remote/device_info');
    try {
      await channel.invokeMethod('openAppSettings');
    } on PlatformException catch (e) {
      zlog('[scan] 打开设置失败: $e');
    }
  }
}

/// Shown when the camera permission was denied: explains why and offers a
/// jump to the system settings. Granting it revives the preview on resume
/// (see _ScanPageState.didChangeAppLifecycleState).
class _PermissionPlaceholder extends StatelessWidget {
  final VoidCallback onOpenSettings;
  const _PermissionPlaceholder({required this.onOpenSettings});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(
            Icons.no_photography_outlined,
            size: 56,
            color: Colors.white38,
          ),
          const SizedBox(height: 16),
          const Text(
            '扫码需要相机权限',
            style: TextStyle(color: Colors.white70, fontSize: 15),
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: onOpenSettings,
            child: const Text('去设置'),
          ),
        ],
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
    final window = RRect.fromRectAndRadius(scanRect, const Radius.circular(12));

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
