import 'package:flutter/material.dart';
import 'package:flutter_miuix/miuix.dart';

/// Shared visual layout for local hints and classroom events; no event handling.
class ClassroomTimelineCard extends StatelessWidget {
  const ClassroomTimelineCard({
    super.key,
    required this.icon,
    required this.color,
    required this.child,
    this.onPressed,
    this.iconAlignment = CrossAxisAlignment.start,
  });

  final IconData icon;
  final Color color;
  final Widget child;
  final VoidCallback? onPressed;
  final CrossAxisAlignment iconAlignment;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Row(
      crossAxisAlignment: iconAlignment,
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: color, size: 24),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: MiuixCard(
            cornerRadius: 22,
            insideMargin: const EdgeInsets.all(16),
            onPressed: onPressed,
            child: child,
          ),
        ),
      ],
    ),
  );
}
