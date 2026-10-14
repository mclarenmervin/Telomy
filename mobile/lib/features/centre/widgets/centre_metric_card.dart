import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../app/theme/app_colors.dart';
import '../../../core/vocabulary/surfaces.dart';

class CentreMetricCard extends StatelessWidget {
  const CentreMetricCard({
    super.key,
    required this.label,
    required this.value,
    this.detail,
  });

  factory CentreMetricCard.comparison({
    required String label,
    required int value,
    required int comparison,
  }) => CentreMetricCard(
    label: label,
    value: '$value',
    detail: '$comparison previous month',
  );

  factory CentreMetricCard.money({
    required String label,
    required String currencyCode,
    required int valueMinor,
    required int comparisonMinor,
  }) {
    final format = NumberFormat.simpleCurrency(name: currencyCode);
    return CentreMetricCard(
      label: label,
      value: format.format(valueMinor / 100),
      detail: '${format.format(comparisonMinor / 100)} previous month',
    );
  }

  final String label;
  final String value;
  final String? detail;

  @override
  Widget build(BuildContext context) => AppCard(
    padding: const EdgeInsets.all(AppSpacing.sm),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelLarge),
        const SizedBox(height: AppSpacing.xs),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(value, style: Theme.of(context).textTheme.headlineMedium),
        ),
        if (detail != null) ...[
          const SizedBox(height: AppSpacing.xxs),
          Text(
            detail!,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ],
    ),
  );
}
