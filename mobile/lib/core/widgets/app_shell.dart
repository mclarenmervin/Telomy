import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../app/role_routes.dart';
import '../../app/theme/app_colors.dart';
import '../../features/roles/models/app_role.dart';
import 'quick_log.dart';

/// One shell, four roles.
///
/// It takes the role rather than being forked per role, which is the whole
/// reason this file changed in F9. Three copies of a navigation shell is three
/// places to fix the rail breakpoint, three places the floating button drifts
/// apart, and by F11 nobody knows which is canonical.
///
/// Two things the role decides:
///
///   * **which tabs**, from [roleTabs] — the same list the router builds its
///     branches from, because `indexedStack` addresses branches by position
///     and two lists that can disagree eventually do;
///   * **whether there is a log button at all.** A doctor does not log a
///     meal. That sentence is the whole of [logsTheirOwnLife] and it is the
///     specific thing that would have been forked.
class AppShell extends StatelessWidget {
  const AppShell({
    super.key,
    required this.navigationShell,
    required this.role,
  });

  final StatefulNavigationShell navigationShell;
  final AppRole role;

  @override
  Widget build(BuildContext context) {
    final tabs = roleTabs(role);
    final wide = MediaQuery.sizeOf(context).width >= 760;
    final logs = logsTheirOwnLife(role);

    void select(int index) => navigationShell.goBranch(
          index,
          initialLocation: index == navigationShell.currentIndex,
        );

    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            if (wide)
              NavigationRail(
                selectedIndex: navigationShell.currentIndex,
                onDestinationSelected: select,
                labelType: NavigationRailLabelType.all,
                destinations: [
                  for (final tab in tabs)
                    NavigationRailDestination(
                      icon: Icon(tab.icon),
                      label: Text(tab.label),
                    ),
                ],
              ),
            Expanded(
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1200),
                  child: navigationShell,
                ),
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: logs
          ? FloatingActionButton(
              tooltip: 'Log something',
              onPressed: () => showQuickLog(context),
              shape: const CircleBorder(),
              child: const Icon(Icons.add),
            )
          : null,
      floatingActionButtonLocation: wide
          ? FloatingActionButtonLocation.endFloat
          : FloatingActionButtonLocation.centerDocked,
      bottomNavigationBar: wide
          ? null
          : BottomAppBar(
              height: 80,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xs),
              shape: logs ? const CircularNotchedRectangle() : null,
              notchMargin: 6,
              child: Row(
                children: [
                  for (var i = 0; i < tabs.length; i++) ...[
                    // The notch only exists where the button does, so the gap
                    // that makes room for it only belongs there too. Without
                    // this the doctor's four tabs sat around a hole.
                    if (logs && i == tabs.length ~/ 2)
                      const SizedBox(width: 64),
                    Expanded(
                      child: InkWell(
                        onTap: () => select(i),
                        borderRadius: BorderRadius.circular(AppRadii.small),
                        child: Semantics(
                          selected: navigationShell.currentIndex == i,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                tabs[i].icon,
                                color: navigationShell.currentIndex == i
                                    ? Theme.of(context).colorScheme.primary
                                    : Theme.of(context)
                                        .colorScheme
                                        .onSurfaceVariant,
                              ),
                              const SizedBox(height: AppSpacing.xxs),
                              Text(
                                tabs[i].label,
                                style: const TextStyle(fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}
