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
        // AnimatedSwitcher cross-fades between the two states; SizeTransition
        // makes the banner roll out from under the app bar instead of
        // popping in/out instantly.
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          switchInCurve: Curves.easeOut,
          switchOutCurve: Curves.easeIn,
          transitionBuilder: (child, animation) => SizeTransition(
            sizeFactor: animation,
            alignment: Alignment.topCenter,
            child: FadeTransition(opacity: animation, child: child),
          ),
          child: app.isReconnecting
              ? Material(
                  key: const ValueKey('reconnecting'),
                  color: scheme.errorContainer,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
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
                )
              : const SizedBox.shrink(key: ValueKey('connected')),
        );
      },
    );
  }
}
