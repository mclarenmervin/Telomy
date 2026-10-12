import 'package:flutter/material.dart';

import '../features/roles/models/app_role.dart';

/// Which role each route tree belongs to.
///
/// **This is not a security boundary and must never be mistaken for one.** A
/// member who edits this file, or who patches the APK, reaches `/admin` and
/// finds a screen whose every request comes back 403 and whose every query
/// returns zero rows — because the gateway refuses to serve it
/// (`require_app_role`) and no policy admits the rows (022), both
/// independently of anything here.
///
/// What this does prevent is the ordinary version of the same event: somebody
/// following a stale link, or a notification tapped by the wrong account,
/// landing on a half-rendered screen full of error states. That is a product
/// failure rather than a leak, and it is still worth preventing.
///
/// Trees rather than a list of paths, because F10 through F13 will add dozens
/// of routes under each and a per-route table would be a table somebody
/// forgets to add to. The cost is that the prefix match has to be exact about
/// segment boundaries — see [routeRole].
const _trees = {
  AppRole.doctor: '/doctor',
  AppRole.centre: '/centre',
  AppRole.admin: '/admin',
};

/// Where each role lands when it signs in, and where it is sent back to.
String roleHome(AppRole role) => switch (role) {
      AppRole.member => '/home',
      AppRole.doctor => '/doctor',
      AppRole.centre => '/centre',
      AppRole.admin => '/admin',
    };

/// Which role owns this path.
///
/// Matched on segment boundaries, not with `startsWith`. `/centre-research` is
/// a member-facing screen in the prototype's inventory and `/administration`
/// is nobody's, and a naive prefix check would hand both to a role that
/// cannot render them.
AppRole routeRole(String path) {
  for (final tree in _trees.entries) {
    if (path == tree.value || path.startsWith('${tree.value}/')) {
      return tree.key;
    }
  }
  // Everything else is the member app, which is most of the product and is
  // the right default: a new member screen should not have to be registered
  // anywhere to be reachable.
  return AppRole.member;
}

/// Where to send this role if the path they asked for is not theirs.
///
/// Null means let them through.
///
/// Note what this does **not** do: it does not let an admin into the doctor
/// tree. An admin is not a superuser of the other roles' screens — they read
/// operational rows, and a patient panel is not one. Treating admin as a
/// superset is how a support tool becomes the God account the programme's
/// risk table names.
String? redirectFor(AppRole role, String path) {
  final owner = routeRole(path);
  if (owner == role) return null;
  return roleHome(role);
}


/// One tab in a role's shell.
class RoleTab {
  const RoleTab({required this.path, required this.label, required this.icon});

  final String path;
  final String label;
  final IconData icon;
}

/// The tabs each role's shell shows, in order.
///
/// **One list, read by both the shell and the router.** `StatefulShellRoute.
/// indexedStack` addresses its branches by position, so a tab list and a
/// branch list that could disagree is a tab list that will eventually send
/// somebody to the wrong screen — silently, because both are valid indices.
/// The router builds its branches from this and the shell draws its
/// destinations from this.
List<RoleTab> roleTabs(AppRole role) => switch (role) {
      AppRole.member => const [
          RoleTab(path: '/home', label: 'Today', icon: Icons.home_outlined),
          RoleTab(path: '/trends', label: 'Trends', icon: Icons.timeline_rounded),
          RoleTab(path: '/sinc', label: 'Sinc', icon: Icons.auto_awesome_outlined),
          RoleTab(path: '/profile', label: 'You', icon: Icons.person_outline_rounded),
        ],
      // F10's surface. The tabs are named here so the role spine can be
      // verified for all four roles now, and so F10 fills screens rather
      // than inventing navigation.
      AppRole.doctor => const [
          RoleTab(path: '/doctor', label: 'Today', icon: Icons.today_outlined),
          RoleTab(path: '/doctor/work', label: 'Work', icon: Icons.inbox_outlined),
          RoleTab(path: '/doctor/patients', label: 'Patients', icon: Icons.groups_outlined),
          RoleTab(path: '/doctor/you', label: 'You', icon: Icons.person_outline_rounded),
        ],
      // F11's.
      AppRole.centre => const [
          RoleTab(path: '/centre', label: 'Centre', icon: Icons.storefront_outlined),
          RoleTab(path: '/centre/floor', label: 'Floor', icon: Icons.sensors_outlined),
          RoleTab(path: '/centre/bookings', label: 'Bookings', icon: Icons.event_outlined),
          RoleTab(path: '/centre/you', label: 'You', icon: Icons.person_outline_rounded),
        ],
      AppRole.admin => const [
          RoleTab(path: '/admin', label: 'Health', icon: Icons.monitor_heart_outlined),
          RoleTab(path: '/admin/catalogue', label: 'Catalogue', icon: Icons.fact_check_outlined),
          RoleTab(path: '/admin/roles', label: 'People', icon: Icons.badge_outlined),
          RoleTab(path: '/admin/audit', label: 'Audit', icon: Icons.history_outlined),
        ],
    };

/// Does this role log their own meals and workouts?
///
/// Only the member. The shell's floating log button is the whole reason this
/// is a question: a doctor does not log a meal, and a shell that showed it to
/// them would be a shell somebody forks rather than fixes — which is how
/// there come to be three of them by F11.
bool logsTheirOwnLife(AppRole role) => role == AppRole.member;
