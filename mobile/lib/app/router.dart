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
import '../features/admin/screens/audit_screen.dart';
import '../features/admin/screens/catalogue_screen.dart';
import '../features/admin/screens/platform_health_screen.dart';
import '../features/admin/screens/roles_screen.dart';
import '../features/roles/models/app_role.dart';
import '../features/roles/providers/role_provider.dart';
import '../features/roles/screens/coming_in_phase_screen.dart';
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
          routes: [
            GoRoute(path: tabs[i].path, builder: (_, _) => screens[i]),
          ],
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
      const public = ['/onboarding', '/login', '/signup', '/forgot-password'];
      if (auth.isLoading) {
        return public.contains(path) || path == '/splash' ? null : '/splash';
      }
      if (auth.hasError && path == '/splash') return null;
      final signedIn = auth.asData?.value != null;
      if (!signedIn) return public.contains(path) ? null : '/onboarding';

      // Signed in, and we do not yet know what they are. Held at the splash
      // rather than let through as a member: landing in the member app and
      // being thrown out of it a moment later is worse than waiting, and
      // guessing the other way would flash an admin shell at a member.
      final role = ref.read(roleProvider);
      if (role.isLoading) return path == '/splash' ? null : '/splash';
      final resolved = role.asData?.value ?? AppRole.member;

      if (public.contains(path) || path == '/splash') return roleHome(resolved);

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
        ComingInPhaseScreen(
          title: 'Today',
          phase: 'F10',
          what: 'Who needs attention, and the clinic consultations coming up. '
              'The queue behind it is already running — this is the first '
              'interface it will ever have had.',
          alreadyBuilt: 'The clinician spine from F5 and F6: the draft state '
              'machine, the signing trigger that checks a licence at signing '
              'time, the append-only review trail, and the delivery gate that '
              'binds a signature to the exact body that was signed. All of it '
              'is enforced in Postgres and tested; none of it has a screen.',
        ),
        ComingInPhaseScreen(
          title: 'Work',
          phase: 'F10',
          what: 'The work queue in five segments — reports, Sinc drafts, '
              'consults, therapy plans, Rx. Nothing will be signable without '
              'a note.',
          alreadyBuilt: 'The queue is swept every scheduler tick. Drafts are '
              'offered, stale claims returned, signatures delivered and '
              'deadlines expired, and the number of drafts nobody will ever '
              'hear about is on the platform dashboard.',
        ),
        ComingInPhaseScreen(
          title: 'Patients',
          phase: 'F10',
          what: 'The panel, in deterministic priority order, and each '
              'patient\'s detail.',
          alreadyBuilt: 'The scoped context loader, with one method per table '
              'and every query scoped by user id. A clinician reading another '
              'person\'s rows is a new loader rather than a widened one.',
        ),
        ComingInPhaseScreen(
          title: 'You',
          phase: 'F10',
          what: 'Your registration, your licence and what you have signed.',
          alreadyBuilt: 'Your registration already exists in `clinicians` and '
              'already decides whether you may sign. The platform dashboard '
              'warns on a licence sixty days before it lapses, so a refused '
              'signature mid-review should never be the first you hear of it.',
        ),
      ]),
      _shell(AppRole.centre, const [
        ComingInPhaseScreen(
          title: 'Centre',
          phase: 'F11',
          what: 'Revenue against last month, sessions, members, no-shows, '
              'utilisation per service, and the members at risk.',
          alreadyBuilt: 'Nothing yet, and deliberately: a centre is a new '
              'table, not a tenant of `clinics`. A clinic signs and a centre '
              'sells, and overloading the one would put the signing function '
              'in the booking path.',
        ),
        ComingInPhaseScreen(
          title: 'Floor',
          phase: 'F13',
          what: 'Who is in session, which phase, their vitals, the safety '
              'tier and the machines by room — refreshing every fifteen '
              'seconds.',
          alreadyBuilt: 'The honesty rule it will need: every simulated '
              'number is labelled simulated, and the `simulated` status token '
              'already exists so no phase has to invent one.',
        ),
        ComingInPhaseScreen(
          title: 'Bookings',
          phase: 'F11',
          what: 'Bookings and their status transitions, and taking a new one.',
          alreadyBuilt: 'Prices will render as indicative until a payments '
              'decision exists. That is decision 7, and the hardcoded ₹1499 '
              'in the marketplace catalogue is already a release blocker.',
        ),
        ComingInPhaseScreen(
          title: 'You',
          phase: 'F11',
          what: 'Your centre, its staff and its services.',
          alreadyBuilt: 'Two centres will have to prove they cannot see one '
              'row of each other\'s, by a test that runs as each of them. '
              'That is F11\'s definition of done.',
        ),
      ]),
      _shell(AppRole.admin, const [
        PlatformHealthScreen(),
        AdminCatalogueScreen(),
        AdminRolesScreen(),
        AdminAuditScreen(),
      ]),
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
