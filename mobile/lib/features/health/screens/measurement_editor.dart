import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:intl/intl.dart';
import '../../../core/widgets/async_action.dart';
import '../../auth/providers/auth_provider.dart';
import '../../journal/providers/wellness_provider.dart';
import '../../dashboard/widgets/metric_card.dart';
import '../models/health_measurement.dart';

const measurementUnits = {
  MeasurementType.heartRate: 'BPM',
  MeasurementType.spo2: '%',
  MeasurementType.bloodPressure: 'mmHg',
  MeasurementType.temperature: '°C',
  MeasurementType.respiratoryRate: '/min',
  MeasurementType.weight: 'kg',
  MeasurementType.bmi: 'kg/m²',
  MeasurementType.sleep: 'h',
  MeasurementType.steps: 'steps',
  MeasurementType.activity: 'min',
  MeasurementType.stress: '/100',
  MeasurementType.calories: 'kcal',
  MeasurementType.restingHeartRate: 'BPM',
  MeasurementType.hrv: 'ms',
  MeasurementType.distance: 'km',
  MeasurementType.sedentaryTime: 'min',
  MeasurementType.bodyFat: '%',
  MeasurementType.muscleMass: 'kg',
  MeasurementType.sleepInBed: 'h',
  MeasurementType.sleepLight: 'h',
  MeasurementType.sleepDeep: 'h',
  MeasurementType.sleepRem: 'h',
  MeasurementType.sleepAwake: 'h',
  MeasurementType.waistCircumference: 'cm',
  MeasurementType.hipCircumference: 'cm',
};

class MeasurementEditor extends ConsumerStatefulWidget {
  const MeasurementEditor({super.key, this.initialType});
  final MeasurementType? initialType;
  @override
  ConsumerState<MeasurementEditor> createState() => _MeasurementEditorState();
}

class _MeasurementEditorState extends ConsumerState<MeasurementEditor> {
  final _form = GlobalKey<FormState>();
  final _value = TextEditingController(), _secondary = TextEditingController();
  MeasurementType _type = MeasurementType.weight;
  DateTime _at = DateTime.now();
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _type = widget.initialType ?? MeasurementType.weight;
  }

  @override
  void dispose() {
    _value.dispose();
    _secondary.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Add a measurement')),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Form(
            key: _form,
            child: ListView(
              padding: const EdgeInsets.all(24),
              children: [
                const Text(
                  'Enter a reading from your measurement or health device. Source will be recorded as manual.',
                ),
                const SizedBox(height: 24),
                DropdownButtonFormField<MeasurementType>(
                  initialValue: _type,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Measurement'),
                  items: MeasurementType.values
                      .map(
                        (t) => DropdownMenuItem(
                          value: t,
                          child: Text(metricLabel(t)),
                        ),
                      )
                      .toList(),
                  onChanged: _busy
                      ? null
                      : (t) {
                          if (t != null) {
                            setState(() {
                              _type = t;
                              _value.clear();
                            });
                          }
                        },
                ),
                const SizedBox(height: 20),
                TextFormField(
                  controller: _value,
                  enabled: !_busy,
                  decoration: InputDecoration(
                    labelText: _type == MeasurementType.bloodPressure
                        ? 'Systolic (mmHg)'
                        : 'Value (${measurementUnits[_type]})',
                  ),
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  validator: (v) {
                    final n = double.tryParse(v ?? '');
                    final max = switch (_type) {
                      MeasurementType.spo2 || MeasurementType.stress => 100,
                      MeasurementType.sleep ||
                      MeasurementType.sleepInBed ||
                      MeasurementType.sleepLight ||
                      MeasurementType.sleepDeep ||
                      MeasurementType.sleepRem ||
                      MeasurementType.sleepAwake => 24,
                      MeasurementType.temperature => 60,
                      MeasurementType.weight => 700,
                      MeasurementType.bmi => 200,
                      MeasurementType.heartRate ||
                      MeasurementType.restingHeartRate ||
                      MeasurementType.bloodPressure => 350,
                      MeasurementType.hrv => 1000,
                      MeasurementType.bodyFat => 100,
                      MeasurementType.muscleMass => 700,
                      MeasurementType.sedentaryTime => 1440,
                      MeasurementType.waistCircumference ||
                      MeasurementType.hipCircumference => 300,
                      MeasurementType.respiratoryRate => 150,
                      MeasurementType.activity => 1440,
                      _ => 200000,
                    };
                    return n == null || !n.isFinite || n < 0 || n > max
                        ? 'Enter a value from 0 to $max'
                        : null;
                  },
                ),
                if (_type == MeasurementType.bloodPressure)
                  Padding(
                    padding: const EdgeInsets.only(top: 20),
                    child: TextFormField(
                      controller: _secondary,
                      decoration: const InputDecoration(
                        labelText: 'Diastolic (mmHg)',
                      ),
                      keyboardType: TextInputType.number,
                      validator: (v) {
                        final n = double.tryParse(v ?? '');
                        return n == null ||
                                !n.isFinite ||
                                n <= 0 ||
                                n >= (double.tryParse(_value.text) ?? 0)
                            ? 'Enter a positive value below systolic'
                            : null;
                      },
                    ),
                  ),
                const SizedBox(height: 20),
                ListTile(
                  title: const Text('Recorded at'),
                  subtitle: Text(DateFormat.yMMMd().add_jm().format(_at)),
                  trailing: const Icon(Icons.edit_calendar),
                  onTap: _busy
                      ? null
                      : () async {
                          final date = await showDatePicker(
                            context: context,
                            initialDate: _at,
                            firstDate: DateTime(1900),
                            lastDate: DateTime.now(),
                          );
                          if (date == null || !context.mounted) return;
                          final time = await showTimePicker(
                            context: context,
                            initialTime: TimeOfDay.fromDateTime(_at),
                          );
                          if (time != null && mounted) {
                            setState(
                              () => _at = DateTime(
                                date.year,
                                date.month,
                                date.day,
                                time.hour,
                                time.minute,
                              ),
                            );
                          }
                        },
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          if (!_form.currentState!.validate()) return;
                          if (_at.isAfter(DateTime.now())) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Measurements cannot be in the future.',
                                ),
                              ),
                            );
                            return;
                          }
                          setState(() => _busy = true);
                          final id = ref.read(authProvider).asData?.value?.id;
                          if (id == null) return;
                          final saved = await runAction(context, () async {
                            final current = ref
                                .read(wellnessProvider)
                                .asData!
                                .value;
                            await ref
                                .read(wellnessProvider.notifier)
                                .saveProfile({
                                  ...current.profile,
                                  'consentManual': 'true',
                                });
                            await ref
                                .read(wellnessProvider.notifier)
                                .addMeasurements([
                                  HealthMeasurement(
                                    id: const Uuid().v4(),
                                    userId: id,
                                    measurementType: _type,
                                    value: double.parse(_value.text),
                                    secondaryValue:
                                        _type == MeasurementType.bloodPressure
                                        ? double.parse(_secondary.text)
                                        : null,
                                    unit: measurementUnits[_type]!,
                                    recordedAt: _at,
                                    endedAt:
                                        {
                                          MeasurementType.sleep,
                                          MeasurementType.sleepInBed,
                                          MeasurementType.sleepLight,
                                          MeasurementType.sleepDeep,
                                          MeasurementType.sleepRem,
                                          MeasurementType.sleepAwake,
                                        }.contains(_type)
                                        ? _at.add(
                                            Duration(
                                              minutes:
                                                  (double.parse(_value.text) *
                                                          60)
                                                      .round(),
                                            ),
                                          )
                                        : null,
                                    source: MeasurementSource.manual,
                                  ),
                                ]);
                          });
                          if (!context.mounted) return;
                          if (saved) {
                            Navigator.pop(context);
                          } else {
                            setState(() => _busy = false);
                          }
                        },
                  child: Text(_busy ? 'Saving…' : 'Save measurement'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
