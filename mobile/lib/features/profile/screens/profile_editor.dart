import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/widgets/async_action.dart';
import '../../journal/providers/wellness_provider.dart';

const profileFields = <String, String>{
  'fullName': 'Full name',
  'dob': 'Date of birth (YYYY-MM-DD)',
  'gender': 'Gender',
  'height': 'Height (cm)',
  'weight': 'Current weight (kg)',
  'waist': 'Waist circumference (cm)',
  'neck': 'Neck circumference (cm)',
  'hip': 'Hip circumference (cm)',
  'sex': 'Sex at birth',
  'bloodGroup': 'Blood group',
  'activityLevel': 'Activity level',
  'sleepSchedule': 'Usual sleep schedule',
  'dietaryPreference': 'Dietary preference',
  'smoking': 'Smoking (optional)',
  'alcohol': 'Alcohol use (optional)',
  'primaryGoal': 'Primary health goal',
  'targetTimeline': 'Target timeline',
  'targetWeight': 'Target weight (kg)',
  'stepsGoal': 'Daily steps goal',
  'sleepGoal': 'Sleep goal (hours)',
  'activityGoal': 'Activity goal (minutes)',
  'waterGoal': 'Water goal (ml)',
  'calorieGoal': 'Food energy goal (kcal)',
  'proteinGoal': 'Protein goal (g)',
  'carbGoal': 'Carbohydrate goal (g)',
  'fatGoal': 'Fat goal (g)',
  'wellnessGoals': 'Wellness goals',
  'conditions': 'Conditions / previous diseases',
  'allergies': 'Allergies',
  'surgeries': 'Surgeries',
  'medications': 'Medications',
  'familyHistory': 'Family medical history',
};
const profileLimits = <String, double>{
  'height': 300,
  'weight': 700,
  'waist': 300,
  'neck': 150,
  'hip': 300,
  'targetWeight': 700,
  'stepsGoal': 200000,
  'sleepGoal': 24,
  'activityGoal': 1440,
  'waterGoal': 20000,
  'calorieGoal': 20000,
  'proteinGoal': 2000,
  'carbGoal': 3000,
  'fatGoal': 2000,
};

class ProfileEditor extends ConsumerStatefulWidget {
  const ProfileEditor({super.key});
  @override
  ConsumerState<ProfileEditor> createState() => _ProfileEditorState();
}

class _ProfileEditorState extends ConsumerState<ProfileEditor> {
  final _form = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _controllers;
  late final Map<String, String> _originalProfile;
  bool _saving = false;
  @override
  void initState() {
    super.initState();
    final profile = ref.read(wellnessProvider).asData?.value.profile ?? {};
    _originalProfile = Map<String, String>.from(profile);
    _controllers = {
      for (final key in profileFields.keys)
        key: TextEditingController(text: profile[key]),
    };
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Profile & goals')),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 650),
          child: Form(
            key: _form,
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const Text(
                  'All fields are optional. Goals are set by you; they are not a medical or nutrition prescription.',
                ),
                const SizedBox(height: 16),
                for (final f in profileFields.entries)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 16),
                    child: TextFormField(
                      controller: _controllers[f.key],
                      enabled: !_saving,
                      maxLength: profileLimits.containsKey(f.key) ? 12 : 500,
                      decoration: InputDecoration(labelText: f.value),
                      keyboardType: profileLimits.containsKey(f.key)
                          ? const TextInputType.numberWithOptions(decimal: true)
                          : TextInputType.text,
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) return null;
                        if (f.key == 'dob') {
                          final date = DateTime.tryParse(v);
                          return date == null ||
                                  date.isAfter(DateTime.now()) ||
                                  date.year < 1900 ||
                                  date.toIso8601String().substring(0, 10) != v
                              ? 'Use a valid YYYY-MM-DD date'
                              : null;
                        }
                        if (!profileLimits.containsKey(f.key)) return null;
                        final n = double.tryParse(v);
                        return n == null ||
                                !n.isFinite ||
                                n <= 0 ||
                                n > profileLimits[f.key]!
                            ? 'Enter a positive value up to ${profileLimits[f.key]}'
                            : null;
                      },
                    ),
                  ),
                FilledButton(
                  onPressed: _saving
                      ? null
                      : () async {
                          if (!_form.currentState!.validate()) return;
                          setState(() => _saving = true);
                          final saved = await runAction(
                            context,
                            () => ref
                                .read(wellnessProvider.notifier)
                                .saveProfile({
                                  ..._originalProfile,
                                  for (final c in _controllers.entries)
                                    c.key: c.value.text.trim(),
                                }),
                          );
                          if (!context.mounted) return;
                          if (saved) {
                            Navigator.pop(context);
                          } else {
                            setState(() => _saving = false);
                          }
                        },
                  child: Text(_saving ? 'Saving…' : 'Save profile'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
