import 'package:flutter/material.dart';

class WorkQueueSegment extends StatelessWidget {
  const WorkQueueSegment({
    super.key,
    required this.label,
    required this.items,
    required this.emptyMessage,
    this.onOpen,
  });
  final String label, emptyMessage;
  final List<Map<String, dynamic>> items;
  final ValueChanged<Map<String, dynamic>>? onOpen;
  @override
  Widget build(BuildContext context) => ExpansionTile(
    title: Text(label),
    trailing: Text('${items.length}'),
    children: items.isEmpty
        ? [ListTile(title: Text(emptyMessage))]
        : [
            for (final item in items)
              ListTile(
                title: Text(
                  item['title']?.toString() ??
                      item['period_start']?.toString() ??
                      'Clinical work item',
                ),
                subtitle: Text(item['status']?.toString() ?? 'pending'),
                onTap: onOpen == null ? null : () => onOpen!(item),
              ),
          ],
  );
}
