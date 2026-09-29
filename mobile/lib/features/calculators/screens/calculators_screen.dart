import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../health/models/health_measurement.dart';
import '../../journal/providers/wellness_provider.dart';

class CalculatorsScreen extends ConsumerStatefulWidget {
  const CalculatorsScreen({super.key});
  @override
  ConsumerState<CalculatorsScreen> createState() => _CalculatorsScreenState();
}

class _CalculatorsScreenState extends ConsumerState<CalculatorsScreen> {
  final form = GlobalKey<FormState>();
  final fields = <String, TextEditingController>{};
  String sex = 'unspecified';
  String activity = 'moderate';
  bool calculated = false;

  @override
  void initState() {
    super.initState();
    final data = ref.read(wellnessProvider).asData?.value;
    final profile = data?.profile ?? const <String, String>{};
    final weights =
        data?.measurements
            .where((item) => item.measurementType == MeasurementType.weight)
            .toList() ??
        [];
    weights.sort((a, b) => a.recordedAt.compareTo(b.recordedAt));
    fields.addAll({
      'age': TextEditingController(
        text: _age(profile['dob'])?.toString() ?? '',
      ),
      'height': TextEditingController(text: profile['height'] ?? ''),
      'weight': TextEditingController(
        text: weights.isNotEmpty
            ? weights.last.value.toStringAsFixed(1)
            : profile['weight'] ?? '',
      ),
      'waist': TextEditingController(text: profile['waist'] ?? ''),
      'hip': TextEditingController(text: profile['hip'] ?? ''),
      'neck': TextEditingController(text: profile['neck'] ?? ''),
      'load': TextEditingController(),
      'reps': TextEditingController(),
    });
    final savedSex = (profile['sex'] ?? profile['gender'] ?? '').toLowerCase();
    if (savedSex.contains('female')) sex = 'female';
    if (savedSex.contains('male') && !savedSex.contains('female')) sex = 'male';
    final savedActivity = profile['activityLevel']?.toLowerCase();
    if (_activityFactors.containsKey(savedActivity)) activity = savedActivity!;
  }

  @override
  void dispose() {
    for (final controller in fields.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Form(
      key: form,
      child: ListView(
        padding: const EdgeInsets.all(22),
        children: [
          Text('Health calculators', style: theme.textTheme.headlineLarge),
          const SizedBox(height: 8),
          const Text(
            'Planning estimates from the values you provide. They are not diagnosis or personalized medical advice.',
          ),
          const SizedBox(height: 22),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(child: _numberField('age', 'Age', max: 130)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _numberField('height', 'Height (cm)', max: 300),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _numberField('weight', 'Weight (kg)', max: 700),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: sex,
                          decoration: const InputDecoration(
                            labelText: 'Sex for formulas',
                          ),
                          items: const [
                            DropdownMenuItem(
                              value: 'unspecified',
                              child: Text('Not specified'),
                            ),
                            DropdownMenuItem(
                              value: 'male',
                              child: Text('Male'),
                            ),
                            DropdownMenuItem(
                              value: 'female',
                              child: Text('Female'),
                            ),
                          ],
                          onChanged: (value) =>
                              setState(() => sex = value ?? 'unspecified'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: activity,
                    decoration: const InputDecoration(
                      labelText: 'Activity level',
                    ),
                    items: [
                      for (final item in _activityFactors.keys)
                        DropdownMenuItem(
                          value: item,
                          child: Text(_title(item)),
                        ),
                    ],
                    onChanged: (value) =>
                        setState(() => activity = value ?? 'moderate'),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: _numberField(
                          'waist',
                          'Waist (cm)',
                          max: 300,
                          optional: true,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _numberField(
                          'hip',
                          'Hip (cm)',
                          max: 300,
                          optional: true,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _numberField('neck', 'Neck (cm)', max: 150, optional: true),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: () {
                      if (form.currentState!.validate()) {
                        setState(() => calculated = true);
                      }
                    },
                    child: const Text('Calculate'),
                  ),
                ],
              ),
            ),
          ),
          if (calculated) ...[const SizedBox(height: 18), _results(context)],
          const SizedBox(height: 24),
          Text('One-rep max', style: theme.textTheme.titleLarge),
          const SizedBox(height: 10),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: _numberField(
                          'load',
                          'Lifted weight (kg)',
                          max: 1000,
                          optional: true,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _numberField(
                          'reps',
                          'Repetitions',
                          max: 30,
                          optional: true,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  _ResultTile(
                    'Estimated 1RM',
                    _oneRepMax == null
                        ? 'Enter load and 1–30 reps'
                        : '${_oneRepMax!.toStringAsFixed(1)} kg',
                    'Epley formula · training estimate',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _numberField(
    String key,
    String label, {
    required double max,
    bool optional = false,
  }) => TextFormField(
    controller: fields[key],
    decoration: InputDecoration(labelText: label),
    keyboardType: const TextInputType.numberWithOptions(decimal: true),
    onChanged: (_) => setState(() {}),
    validator: (value) {
      if (optional && (value == null || value.trim().isEmpty)) return null;
      final number = double.tryParse(value ?? '');
      return number == null || !number.isFinite || number <= 0 || number > max
          ? 'Enter 0–${max.round()}'
          : null;
    },
  );

  Widget _results(BuildContext context) {
    final height = _value('height')!;
    final weight = _value('weight')!;
    final age = _value('age')!;
    final bmi = weight / math.pow(height / 100, 2);
    final bmr = sex == 'unspecified'
        ? null
        : 10 * weight + 6.25 * height - 5 * age + (sex == 'male' ? 5 : -161);
    final tdee = bmr == null ? null : bmr * _activityFactors[activity]!;
    final protein = weight * 1.6;
    final fat = tdee == null ? null : tdee * 0.25 / 9;
    final carbs = tdee == null || fat == null
        ? null
        : (tdee - protein * 4 - fat * 9) / 4;
    return Column(
      children: [
        _ResultTile('BMI', bmi.toStringAsFixed(1), 'Body mass index'),
        _ResultTile(
          'BMR',
          bmr == null ? 'Sex required' : '${bmr.round()} kcal/day',
          'Mifflin–St Jeor estimate',
        ),
        _ResultTile(
          'TDEE',
          tdee == null ? 'Sex required' : '${tdee.round()} kcal/day',
          '${_title(activity)} activity estimate',
        ),
        _ResultTile(
          'Planning macros',
          tdee == null
              ? 'TDEE required'
              : '${protein.round()} g protein · ${fat!.round()} g fat · ${math.max(0, carbs!).round()} g carbs',
          'Generic maintenance estimate; adjust with a qualified professional',
        ),
        _ResultTile(
          'Body fat',
          _bodyFat == null
              ? 'Waist, neck${sex == 'female' ? ', hip' : ''} and sex required'
              : '${_bodyFat!.toStringAsFixed(1)}%',
          'US Navy circumference estimate',
        ),
        _ResultTile(
          'Waist / height',
          _ratio('waist', 'height'),
          'Calculated ratio',
        ),
        _ResultTile('Waist / hip', _ratio('waist', 'hip'), 'Calculated ratio'),
      ],
    );
  }

  double? get _bodyFat {
    final waist = _value('waist'),
        neck = _value('neck'),
        hip = _value('hip'),
        height = _value('height');
    if (sex == 'unspecified' ||
        waist == null ||
        neck == null ||
        height == null) {
      return null;
    }
    final h = height / 2.54, w = waist / 2.54, n = neck / 2.54;
    if (w <= n) return null;
    final density = sex == 'male'
        ? 1.0324 - 0.19077 * _log10(w - n) + 0.15456 * _log10(h)
        : hip == null
        ? null
        : 1.29579 - 0.35004 * _log10(w + hip / 2.54 - n) + 0.22100 * _log10(h);
    if (density == null || density <= 0) return null;
    return (495 / density - 450).clamp(0, 75).toDouble();
  }

  double? get _oneRepMax {
    final load = _value('load'), reps = _value('reps');
    return load == null || load <= 0 || reps == null || reps < 1 || reps > 30
        ? null
        : load * (1 + reps / 30);
  }

  String _ratio(String numerator, String denominator) {
    final first = _value(numerator), second = _value(denominator);
    return first == null || second == null || second == 0
        ? 'Inputs required'
        : (first / second).toStringAsFixed(2);
  }

  double? _value(String key) => double.tryParse(fields[key]?.text ?? '');
  double _log10(double value) => math.log(value) / math.ln10;
  static int? _age(String? dob) {
    final birth = DateTime.tryParse(dob ?? '');
    if (birth == null) return null;
    final now = DateTime.now();
    return now.year -
        birth.year -
        ((now.month < birth.month ||
                (now.month == birth.month && now.day < birth.day))
            ? 1
            : 0);
  }

  static String _title(String value) =>
      '${value[0].toUpperCase()}${value.substring(1)}';
  static const _activityFactors = <String, double>{
    'sedentary': 1.2,
    'light': 1.375,
    'moderate': 1.55,
    'very active': 1.725,
  };
}

class _ResultTile extends StatelessWidget {
  const _ResultTile(this.label, this.value, this.detail);
  final String label;
  final String value;
  final String detail;
  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 10),
    child: ListTile(
      title: Text(label),
      subtitle: Text(detail),
      trailing: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 190),
        child: Text(
          value,
          textAlign: TextAlign.end,
          style: Theme.of(context).textTheme.titleMedium,
        ),
      ),
    ),
  );
}
