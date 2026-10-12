import 'package:flutter/material.dart';

class LicenceVerificationScreen extends StatelessWidget {
  const LicenceVerificationScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Licence verification')),
    body: const Padding(
      padding: EdgeInsets.all(16),
      child: Text(
        'Review a Doctor’s registration and record a verified, rejected, or expired decision. Every decision is retained in the audit history.',
      ),
    ),
  );
}
