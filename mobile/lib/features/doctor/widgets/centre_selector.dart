import 'package:flutter/material.dart';
import '../models/doctor_models.dart';

class CentreSelector extends StatelessWidget {
  const CentreSelector({
    super.key,
    required this.centres,
    required this.selectedId,
    required this.onSelected,
  });
  final List<DoctorCentre> centres;
  final String? selectedId;
  final ValueChanged<String> onSelected;
  @override
  Widget build(BuildContext context) => DropdownButton<String>(
    value: selectedId ?? centres.firstOrNull?.id,
    isExpanded: true,
    hint: const Text('Select centre'),
    items: [
      for (final c in centres)
        DropdownMenuItem(value: c.id, child: Text(c.name)),
    ],
    onChanged: (v) {
      if (v != null) onSelected(v);
    },
  );
}
