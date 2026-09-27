import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key});
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(28),
            children: [
              Text(
                'TELOMY',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(letterSpacing: 4),
              ),
              const SizedBox(height: 48),
              Container(
                height: 200,
                decoration: BoxDecoration(
                  color: const Color(0xFF123F3A),
                  borderRadius: BorderRadius.circular(40),
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(40),
                  child: Image.asset(
                    'assets/branding/telomy-icon.png',
                    fit: BoxFit.contain,
                  ),
                ),
              ),
              const SizedBox(height: 36),
              Text(
                'See what shapes\nyour everyday.',
                style: Theme.of(context).textTheme.headlineLarge,
              ),
              const SizedBox(height: 16),
              const Text(
                'Bring your daily rhythms into focus. Connect the dots between rest, movement, and how you feel.',
              ),
              const SizedBox(height: 28),
              const ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.insights_outlined),
                title: Text('Your health, over time'),
                subtitle: Text('Clear trends. Thoughtful daily context.'),
              ),
              const ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.lock_outline),
                title: Text('Built with privacy in mind'),
                subtitle: Text('Your records stay on this device.'),
              ),
              const SizedBox(height: 28),
              FilledButton(
                onPressed: () => context.go('/login'),
                child: const Text('Get started'),
              ),
              TextButton(
                onPressed: () => context.go('/signup'),
                child: const Text('Create an account'),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
