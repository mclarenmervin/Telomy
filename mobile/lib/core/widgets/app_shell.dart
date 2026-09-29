import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'quick_log.dart';

class AppShell extends StatelessWidget {
  const AppShell({super.key, required this.navigationShell});
  final StatefulNavigationShell navigationShell;
  static const labels = ['Today', 'Trends', 'Sinc', 'You'];
  static const icons = [
    Icons.home_outlined,
    Icons.timeline_rounded,
    Icons.auto_awesome_outlined,
    Icons.person_outline_rounded,
  ];
  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 760;
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
                destinations: List.generate(
                  labels.length,
                  (i) => NavigationRailDestination(
                    icon: Icon(icons[i]),
                    label: Text(labels[i]),
                  ),
                ),
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
      floatingActionButton: FloatingActionButton(
        tooltip: 'Log something',
        onPressed: () => showQuickLog(context),
        shape: const CircleBorder(),
        child: const Icon(Icons.add),
      ),
      floatingActionButtonLocation: wide
          ? FloatingActionButtonLocation.endFloat
          : FloatingActionButtonLocation.centerDocked,
      bottomNavigationBar: wide
          ? null
          : BottomAppBar(
              height: 80,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              shape: const CircularNotchedRectangle(),
              notchMargin: 6,
              child: Row(
                children: [
                  for (var i = 0; i < labels.length; i++) ...[
                    if (i == 2) const SizedBox(width: 64),
                    Expanded(
                      child: InkWell(
                        onTap: () => select(i),
                        borderRadius: BorderRadius.circular(12),
                        child: Semantics(
                          selected: navigationShell.currentIndex == i,
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                icons[i],
                                color: navigationShell.currentIndex == i
                                    ? Theme.of(context).colorScheme.primary
                                    : Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                labels[i],
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
