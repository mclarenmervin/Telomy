import 'package:flutter/material.dart';

import '../../../app/theme/app_colors.dart';

class ServiceDraft {
  const ServiceDraft({
    required this.name,
    required this.durationMinutes,
    required this.indicativePriceMinor,
    required this.currencyCode,
    this.description,
  });
  final String name;
  final String? description;
  final int durationMinutes;
  final int indicativePriceMinor;
  final String currencyCode;
}

class ServiceEditorScreen extends StatefulWidget {
  const ServiceEditorScreen({super.key, required this.onCreate});
  final Future<void> Function(ServiceDraft draft) onCreate;

  @override
  State<ServiceEditorScreen> createState() => _ServiceEditorScreenState();
}

class _ServiceEditorScreenState extends State<ServiceEditorScreen> {
  final name = TextEditingController();
  final description = TextEditingController();
  final duration = TextEditingController();
  final price = TextEditingController();
  final currency = TextEditingController(text: 'INR');
  bool saving = false;

  int? get minutes => int.tryParse(duration.text);
  double? get amount => double.tryParse(price.text);
  bool get valid =>
      !saving &&
      name.text.trim().isNotEmpty &&
      (minutes ?? 0) >= 5 &&
      (amount ?? -1) >= 0 &&
      RegExp(r'^[A-Za-z]{3}$').hasMatch(currency.text.trim());

  @override
  void dispose() {
    name.dispose();
    description.dispose();
    duration.dispose();
    price.dispose();
    currency.dispose();
    super.dispose();
  }

  Future<void> save() async {
    if (!valid) return;
    setState(() => saving = true);
    try {
      await widget.onCreate(
        ServiceDraft(
          name: name.text.trim(),
          description: description.text.trim().isEmpty
              ? null
              : description.text.trim(),
          durationMinutes: minutes!,
          indicativePriceMinor: (amount! * 100).round(),
          currencyCode: currency.text.trim().toUpperCase(),
        ),
      );
      if (mounted) Navigator.maybePop(context);
    } finally {
      if (mounted) setState(() => saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Create service')),
    body: ListView(
      padding: const EdgeInsets.all(AppSpacing.md),
      children: [
        _field(name, 'Name'),
        _field(description, 'Description'),
        _field(duration, 'Duration (minutes)', numeric: true),
        _field(price, 'Indicative price', numeric: true),
        _field(currency, 'Currency'),
        const Text(
          'Prices are indicative planning values, not payment revenue.',
        ),
        const SizedBox(height: AppSpacing.lg),
        FilledButton(
          onPressed: valid ? save : null,
          child: Text(saving ? 'Creating…' : 'Create service'),
        ),
      ],
    ),
  );

  Widget _field(
    TextEditingController controller,
    String label, {
    bool numeric = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
    child: TextField(
      controller: controller,
      keyboardType: numeric
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.text,
      onChanged: (_) => setState(() {}),
      decoration: InputDecoration(labelText: label),
    ),
  );
}
