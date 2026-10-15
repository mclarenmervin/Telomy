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
import '../features/auth/screens/update_password_screen.dart';
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
import '../features/admin/screens/audit_screen.dart';
import '../features/admin/screens/catalogue_screen.dart';
import '../features/admin/screens/platform_health_screen.dart';
import '../features/admin/screens/roles_screen.dart';
import '../features/roles/models/app_role.dart';
import '../features/roles/providers/role_provider.dart';
import '../features/accounts/screens/pending_invitation_screen.dart';
import '../features/admin/screens/centres_screen.dart';
import '../features/admin/screens/licence_verification_screen.dart';
import '../features/admin/screens/patient_viewer_screen.dart';
import '../features/centre/screens/centre_dashboard_screen.dart';
import '../features/centre/screens/patients_screen.dart';
import '../features/centre/screens/centre_profile_screen.dart';
import '../features/centre/screens/bookings_screen.dart';
import '../features/centre/screens/services_screen.dart';
import '../features/doctor/screens/doctor_today_screen.dart';
import '../features/doctor/screens/doctor_patients_screen.dart';
import '../features/doctor/screens/doctor_patient_detail_screen.dart';
import '../features/doctor/screens/doctor_work_queue_screen.dart';
import '../features/doctor/screens/doctor_profile_screen.dart';
import '../features/therapies/models/therapy_catalogue.dart';
import '../features/therapies/screens/therapy_catalogue_screen.dart';
import '../features/therapies/screens/therapy_detail_screen.dart';
import 'role_routes.dart';

/// One role's shell, its tabs taken from [roleTabs] so the branch order and
/// the destination order cannot drift apart.
StatefulShellRoute _shell(AppRole role, List<Widget> screens) {
  final tabs = roleTabs(role);
  assert(
    tabs.length == screens.length,
    'the ${role.name} shell has ${tabs.length} tabs and ${screens.length} '
    'screens, so one of its branches would show the wrong one',
  );
  return StatefulShellRoute.indexedStack(
    builder: (context, state, shell) =>
        AppShell(navigationShell: shell, role: role),
    branches: [
      for (var i = 0; i < tabs.length; i++)
        StatefulShellBranch(
          routes: [GoRoute(path: tabs[i].path, builder: (_, _) => screens[i])],
        ),
    ],
  );
}

final routerProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier<int>(0);
  ref.listen(authProvider, (_, next) => refresh.value++);
  // The role decides which shell a person gets, so a change to it has to
  // re-run the redirect exactly as a change to the session does. Without
  // this, somebody granted the admin role mid-session keeps the member app
  // until they restart.
  ref.listen(roleProvider, (_, next) => refresh.value++);
  final router = GoRouter(
    initialLocation: '/splash',
    refreshListenable: refresh,
    redirect: (context, state) {
      final auth = ref.read(authProvider);
      final path = state.uri.path;
      const public = [
        '/onboarding',
        '/login',
        '/signup',
        '/forgot-password',
        '/reset-password',
      ];
      if (auth.isLoading) {
        return public.contains(path) || path == '/splash' ? null : '/splash';
      }
      if (auth.hasError && path == '/splash') return null;
      final signedIn = auth.asData?.value != null;
      if (!signedIn) return public.contains(path) ? null : '/onboarding';

      // A recovery link establishes a short-lived Supabase session before
      // the person has chosen their new password. Keep that session on the
      // recovery form instead of redirecting it into a role shell.
      if (path == '/reset-password') return null;

      // Signed in, and we do not yet know what they are. Held at the splash
      // rather than let through as a member: landing in the member app and
      // being thrown out of it a moment later is worse than waiting, and
      // guessing the other way would flash an admin shell at a member.
      final role = ref.read(roleProvider);
      if (role.isLoading) return path == '/splash' ? null : '/splash';
      final resolved = role.asData?.value ?? AppRole.member;

      if (public.contains(path) || path == '/splash') return roleHome(resolved);
      if (path == '/invitations') return null;

      // Not a security boundary — see role_routes.dart. The gateway refuses
      // to serve another role's data and no policy admits it, both
      // independently. This stops the ordinary version: a stale link landing
      // somebody on a screen of error states.
      return redirectFor(resolved, path);
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
      GoRoute(
        path: '/reset-password',
        builder: (_, state) => const UpdatePasswordScreen(),
      ),
      GoRoute(
        path: '/invitations',
        builder: (_, state) => const PendingInvitationScreen(),
      ),
      // One shell route per role, each with its own branch list.
      //
      // Separate routes rather than one shell with the union of every tab:
      // `indexedStack` addresses branches by position, and a single shell
      // would have to map a role onto a subset of indices — which is four
      // offset calculations that are all valid indices when wrong, so they
      // fail by showing the wrong screen rather than by crashing.
      //
      // Every branch list is built from `roleTabs`, which is also what the
      // shell draws its destinations from.
      _shell(AppRole.member, const [
        TodayScreen(),
        TrendsScreen(),
        InsightsScreen(),
        ProfileScreen(),
      ]),
      _shell(AppRole.doctor, const [
        DoctorTodayScreen(),
        DoctorWorkQueueScreen(),
        DoctorPatientsScreen(),
        DoctorProfileScreen(),
      ]),
      _shell(AppRole.centre, const [
        CentreDashboardScreen(),
        BookingsScreen(),
        PatientsScreen(),
        ServicesScreen(),
        CentreProfileScreen(),
      ]),
      _shell(AppRole.admin, const [
        PlatformHealthScreen(),
        AdminCatalogueScreen(),
        AdminRolesScreen(),
        AdminAuditScreen(),
      ]),
      GoRoute(path: '/add-ring', builder: (_, state) => const AddRingScreen()),
      GoRoute(
        path: '/admin/centres',
        builder: (_, state) => const CentresScreen(),
      ),
      GoRoute(
        path: '/admin/licences',
        builder: (_, state) => const LicenceVerificationScreen(),
      ),
      GoRoute(
        path: '/admin/patients/:patientId',
        builder: (_, state) =>
            PatientViewerScreen(patientId: state.pathParameters['patientId']!),
      ),
      GoRoute(
        path: '/doctor/:centreId/patients/:patientId',
        builder: (_, state) => DoctorPatientDetailScreen(
          centreId: state.pathParameters['centreId']!,
          patientId: state.pathParameters['patientId']!,
        ),
      ),
      GoRoute(
        path: '/activity-session',
        builder: (_, state) => const ActivitySessionScreen(),
      ),
      GoRoute(path: '/therapies', builder: (_, state) => const TherapyCatalogueScreen()),
      GoRoute(
        path: '/therapies/:catalogueId',
        builder: (_, state) => TherapyDetailScreen(
          item: state.extra is TherapyCatalogueItem
              ? state.extra! as TherapyCatalogueItem
              : TherapyCatalogueItem(
                  id: state.pathParameters['catalogueId']!, slug: '', name: 'Therapy',
                  category: '', summary: 'Open the catalogue to load this therapy.',
                  intendedExperience: '', contraindicationRuleIds: const [], doseSchema: const {},
                ),
        ),
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
