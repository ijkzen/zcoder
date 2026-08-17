import 'package:flutter/material.dart';

/// Non-scrollable state (empty list, error) hosted inside a pull-to-refresh
/// list. Fills the viewport but stays scrollable so the surrounding
/// RefreshIndicator can be triggered even when there is nothing to pull on.
class RefreshableEmptyState extends StatelessWidget {
  final Widget child;
  const RefreshableEmptyState({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Center(child: child),
        ),
      ),
    );
  }
}
