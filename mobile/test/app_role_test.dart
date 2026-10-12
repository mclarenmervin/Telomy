import 'package:flutter_test/flutter_test.dart';
import 'package:telomy/app/role_routes.dart';
import 'package:telomy/features/roles/models/app_role.dart';

/// Which role a route belongs to, and what a role is when we are not sure.
///
/// This is the router's half of the gate and it is **not** a security
/// boundary. The database refuses a member reading an admin row (022) and the
/// gateway refuses serving one (`require_app_role`), both independently, and
/// both are tested where they live. What this prevents is a member who
/// deep-links to `/admin` seeing a half-rendered admin screen full of error
/// states — which is a product failure rather than a leak, and still worth
/// preventing.
void main() {
  group('parsing a role', () {
    test('reads the four', () {
      expect(AppRole.parse('member'), AppRole.member);
      expect(AppRole.parse('doctor'), AppRole.doctor);
      expect(AppRole.parse('centre'), AppRole.centre);
      expect(AppRole.parse('admin'), AppRole.admin);
    });

    test('an absent role is a member', () {
      // Somebody mid-signup, before the profile row exists. The same
      // coalesce the SQL function and the gateway both make, for the same
      // reason: the safe reading of "no row" is the least privileged role.
      expect(AppRole.parse(null), AppRole.member);
      expect(AppRole.parse(''), AppRole.member);
    });

    test('a role nobody designed is a member', () {
      // If the column is ever widened without this enum being updated, the
      // unknown value must not fall through as itself and get compared
      // against a route table somewhere that might admit it.
      expect(AppRole.parse('superuser'), AppRole.member);
      expect(AppRole.parse('ADMIN'), AppRole.admin, reason: 'case only');
    });
  });

  group('which role owns a route', () {
    test('the doctor, centre and admin trees are theirs alone', () {
      expect(routeRole('/doctor'), AppRole.doctor);
      expect(routeRole('/doctor/patients'), AppRole.doctor);
      expect(routeRole('/centre'), AppRole.centre);
      expect(routeRole('/centre/bookings'), AppRole.centre);
      expect(routeRole('/admin'), AppRole.admin);
      expect(routeRole('/admin/catalogue'), AppRole.admin);
    });

    test('everything else is the member app', () {
      for (final path in [
        '/home', '/trends', '/sinc', '/profile', '/labs', '/correlations',
        '/biological-age', '/genetics', '/environment', '/settings',
      ]) {
        expect(routeRole(path), AppRole.member, reason: path);
      }
    });

    test('a prefix that merely starts the same way is not theirs', () {
      // `/administration` and `/centre-research` are not admin and centre
      // routes. A `startsWith` check would hand both over.
      expect(routeRole('/administration'), AppRole.member);
      expect(routeRole('/centre-research'), AppRole.member);
      expect(routeRole('/doctors-note'), AppRole.member);
    });
  });

  group('the tabs', () {
    test('every role has tabs, and its home is the first of them', () {
      // The shell addresses branches by position, so the router's branch list
      // and the shell's destinations both come from `roleTabs`. If the home
      // were not the first tab, signing in would land on a shell whose
      // selected index pointed at a different screen.
      for (final role in AppRole.values) {
        final tabs = roleTabs(role);
        expect(tabs, isNotEmpty, reason: role.name);
        expect(tabs.first.path, roleHome(role), reason: role.name);
      }
    });

    test('every tab belongs to the role whose shell shows it', () {
      for (final role in AppRole.values) {
        for (final tab in roleTabs(role)) {
          expect(routeRole(tab.path), role, reason: '${role.name} ${tab.path}');
        }
      }
    });

    test('no two roles share a tab path', () {
      final seen = <String, AppRole>{};
      for (final role in AppRole.values) {
        for (final tab in roleTabs(role)) {
          expect(seen[tab.path], isNull,
              reason: '${tab.path} is also ${seen[tab.path]?.name}');
          seen[tab.path] = role;
        }
      }
    });

    test('only the member logs their own life', () {
      expect(logsTheirOwnLife(AppRole.member), isTrue);
      expect(logsTheirOwnLife(AppRole.doctor), isFalse);
      expect(logsTheirOwnLife(AppRole.centre), isFalse);
      expect(logsTheirOwnLife(AppRole.admin), isFalse);
    });
  });

  group('where a role lands', () {
    test('each role has a home of its own', () {
      expect(roleHome(AppRole.member), '/home');
      expect(roleHome(AppRole.doctor), '/doctor');
      expect(roleHome(AppRole.centre), '/centre');
      expect(roleHome(AppRole.admin), '/admin');
    });

    test('a role may enter its own tree', () {
      expect(redirectFor(AppRole.admin, '/admin/catalogue'), isNull);
      expect(redirectFor(AppRole.doctor, '/doctor/patients'), isNull);
      expect(redirectFor(AppRole.member, '/labs'), isNull);
    });

    test('a member deep-linking to a doctor or admin route is sent home', () {
      // The verification the phase asks for, from the router's side.
      expect(redirectFor(AppRole.member, '/doctor'), '/home');
      expect(redirectFor(AppRole.member, '/doctor/patients'), '/home');
      expect(redirectFor(AppRole.member, '/admin'), '/home');
      expect(redirectFor(AppRole.member, '/admin/audit'), '/home');
      expect(redirectFor(AppRole.member, '/centre'), '/home');
    });

    test('a doctor cannot wander into the admin or centre trees', () {
      expect(redirectFor(AppRole.doctor, '/admin'), '/doctor');
      expect(redirectFor(AppRole.doctor, '/centre'), '/doctor');
    });

    test('an admin cannot wander into the doctor tree either', () {
      // An admin is not a superuser of the other roles' screens. They read
      // operational rows; a patient panel is not one, and 022 gives them no
      // policy that would fill the screen anyway.
      expect(redirectFor(AppRole.admin, '/doctor'), '/admin');
      expect(redirectFor(AppRole.admin, '/centre'), '/admin');
    });

    test('a doctor, centre or admin is sent out of the member app', () {
      // Not a refusal of the member app so much as a statement that these
      // three are signed in to do a job. A doctor does not log a meal.
      expect(redirectFor(AppRole.doctor, '/home'), '/doctor');
      expect(redirectFor(AppRole.centre, '/trends'), '/centre');
      expect(redirectFor(AppRole.admin, '/labs'), '/admin');
    });
  });
}
