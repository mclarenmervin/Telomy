import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/widgets/app_shell.dart';
import '../features/dashboard/screens/today_screen.dart';
import '../features/journal/screens/journal_screen.dart';
import '../features/events/screens/timeline_screen.dart';
import '../features/journal/models/journal_entry.dart';
import '../features/reports/screens/reports_screen.dart';
import '../features/fitness/screens/fitness_screen.dart';
import '../features/settings/screens/settings_screen.dart';
import '../features/settings/screens/health_consent_screen.dart';
import '../features/ai_copilot/screens/insights_screen.dart';
import '../features/devices/screens/wearables_screen.dart';
import '../features/devices/screens/add_ring_screen.dart';
import '../features/devices/screens/activity_session_screen.dart';
import '../features/auth/providers/auth_provider.dart';
import '../features/auth/screens/auth_screen.dart';
import '../features/auth/screens/splash_screen.dart';
import '../features/onboarding/screens/onboarding_screen.dart';
import '../features/profile/screens/profile_screen.dart';
import '../features/dashboard/screens/dashboard_screen.dart';
import '../features/health/screens/vitals_screen.dart';
import '../features/sleep/screens/sleep_screen.dart';
import '../features/readiness/screens/readiness_screen.dart';
import '../features/stress/screens/stress_screen.dart';
import '../features/activity/screens/activity_screen.dart';
import '../features/body/screens/body_composition_screen.dart';
import '../features/calculators/screens/calculators_screen.dart';
import '../features/settings/screens/notifications_privacy_screen.dart';
import '../features/workouts/screens/workouts_screen.dart';
import '../features/labs/screens/labs_screen.dart';
import '../features/health/screens/longi_score_screen.dart';
import '../features/biological_age/screens/biological_age_screen.dart';
import '../features/correlations/screens/correlations_screen.dart';
import '../features/coach/screens/coach_screen.dart';
import '../features/medications/screens/medications_screen.dart';
import '../features/marketplace/screens/marketplace_screen.dart';
import '../features/consultations/screens/consultations_screen.dart';
import '../features/community/screens/community_screen.dart';
import '../features/nutrition/screens/nutrition_screen.dart';

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier<int>(0);
  ref.listen(authProvider, (_, next) => refresh.value++);
  final router = GoRouter(
    initialLocation: '/splash',
    refreshListenable: refresh,
    redirect: (context, state) {
      final auth = ref.read(authProvider);
      final path = state.uri.path;
      const public = ['/onboarding', '/login', '/signup', '/forgot-password'];
      if (auth.isLoading) {
        return public.contains(path) || path == '/splash' ? null : '/splash';
      }
      if (auth.hasError && path == '/splash') return null;
      final signedIn = auth.asData?.value != null;
      if (!signedIn) return public.contains(path) ? null : '/onboarding';
      return public.contains(path) || path == '/splash' ? '/home' : null;
    },
    routes: [
      GoRoute(path: '/splash', builder: (_, state) => const SplashScreen()),
      GoRoute(
        path: '/onboarding',
        builder: (_, state) => const OnboardingScreen(),
      ),
      GoRoute(
        path: '/login',
        builder: (_, state) => const AuthScreen(mode: AuthMode.login),
      ),
      GoRoute(
        path: '/signup',
        builder: (_, state) => const AuthScreen(mode: AuthMode.signup),
      ),
      GoRoute(
        path: '/forgot-password',
        builder: (_, state) => const AuthScreen(mode: AuthMode.forgot),
      ),
      StatefulShellRoute.indexedStack(
        builder: (context, state, shell) => AppShell(navigationShell: shell),
        branches: [
          for (final entry in const {
            'home': 'Home',
            'trends': 'Trends',
            'sinc': 'Sinc',
            'profile': 'Profile',
          }.entries)
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/${entry.key}',
                  builder: (context, state) => entry.key == 'home'
                      ? const TodayScreen()
                      : entry.key == 'trends'
                      ? const TrendsScreen()
                      : entry.key == 'sinc'
                      ? const InsightsScreen()
                      : entry.key == 'profile'
                      ? const ProfileScreen()
                      : entry.key == 'reports'
                      ? const ReportsScreen()
                      : const TimelineScreen(),
                ),
              ],
            ),
        ],
      ),
      GoRoute(path: '/add-ring', builder: (_, state) => const AddRingScreen()),
      GoRoute(
        path: '/activity-session',
        builder: (_, state) => const ActivitySessionScreen(),
      ),
      for (final entry in <String, Widget>{
        'health': const DashboardScreen(healthOnly: true),
        'vitals': const VitalsScreen(),
        'sleep': const SleepScreen(),
        'readiness': const ReadinessScreen(),
        'stress': const StressScreen(),
        'activity': const ActivityScreen(),
        'body': const BodyCompositionScreen(),
        'calculators': const CalculatorsScreen(),
        'timeline': const TimelineScreen(),
        'reports': const ReportsScreen(),
        'therapy': const JournalScreen(kind: EntryKind.therapy),
        'environment': const JournalScreen(kind: EntryKind.environment),
        'genetics': const JournalScreen(kind: EntryKind.genetics),
        'nutrition': const NutritionScreen(),
        'workouts': const WorkoutsScreen(),
        'labs': const LabsScreen(),
        'longiscore': const LongiScoreScreen(),
        'biological-age': const BiologicalAgeScreen(),
        'correlations': const CorrelationsScreen(),
        'coach': const CoachScreen(),
        'medications': const MedicationsScreen(),
        'marketplace': const MarketplaceScreen(),
        'consultations': const ConsultationsScreen(),
        'community': const CommunityScreen(),
        'hydration': const JournalScreen(kind: EntryKind.water),
        'plans': const JournalScreen(kind: EntryKind.plan),
        'check-ins': const JournalScreen(kind: EntryKind.checkIn),
        'fitness': const FitnessScreen(),
        'devices': const WearablesScreen(),
        'ai-copilot': const InsightsScreen(),
        'settings': const SettingsScreen(),
        'health-consent': const HealthConsentScreen(),
        'notifications-privacy': const NotificationsPrivacyScreen(),
      }.entries)
        GoRoute(
          path: '/${entry.key}',
          builder: (_, state) => Scaffold(
            appBar: AppBar(),
            body: SafeArea(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1000),
                  child: entry.value,
                ),
              ),
            ),
          ),
        ),
    ],
  );
  ref.onDispose(() {
    router.dispose();
    refresh.dispose();
  });
  return router;
});
