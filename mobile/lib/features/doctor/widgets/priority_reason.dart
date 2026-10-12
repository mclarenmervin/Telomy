import 'package:flutter/material.dart';

class PriorityReason extends StatelessWidget {
  const PriorityReason({super.key, required this.reason});
  final String reason;
  @override
  Widget build(BuildContext context) => Chip(
    avatar: const Icon(Icons.info_outline, size: 16),
    label: Text(reason),
  );
}
