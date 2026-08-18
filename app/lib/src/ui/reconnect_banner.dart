import 'package:flutter/material.dart';

import '../app_controller.dart';

/// Thin top banner shown while the connection is down and the app is trying
/// to reconnect ("连接已断开，正在尝试重连…"). Rendered on the project list,
/// session list, and conversation pages; driven entirely by
/// [AppController.isReconnecting], so it appears the moment the relay drops
/// (or the bridge degrades) and disappears on its own once the connection is
/// healthy again.
class ReconnectBanner extends StatelessWidget {
  final AppController app;
  const ReconnectBanner({super.key, required this.app});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: app,
      builder: (context, _) {
        if (!app.isReconnecting) return const SizedBox.shrink();
        return Material(
          color: scheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: scheme.onErrorContainer,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    '连接已断开，正在尝试重连…',
                    style: TextStyle(
                      color: scheme.onErrorContainer,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
