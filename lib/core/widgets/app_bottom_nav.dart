import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../auth/auth_controller.dart';
import '../theme/app_theme.dart';

class AppBottomNav extends ConsumerWidget {
  const AppBottomNav({super.key});

  // (route, outlined icon, filled icon, label, feature flag, permission).
  // A null feature/permission means the tab is always shown. Loans is gated so an
  // org with only chitfunds (enableLoans off) never shows it — mirrors the drawer.
  static const _items = <(String, IconData, IconData, String, String?, String?)>[
    ('/dashboard', Icons.home_outlined, Icons.home, 'Home', null, null),
    ('/loans', Icons.request_quote_outlined, Icons.request_quote, 'Loans', 'enableLoans', 'loans.view'),
    ('/collections', Icons.payments_outlined, Icons.payments, 'Collections', null, null),
    ('/profile', Icons.person_outline, Icons.person, 'Profile', null, null),
  ];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final items = _items.where((it) {
      if (it.$5 != null && auth.org?.feature(it.$5!) != true) return false;
      if (it.$6 != null && !auth.hasPermission(it.$6!)) return false;
      return true;
    }).toList();

    final location = GoRouter.of(context).routeInformationProvider.value.uri.path;
    int current = 0;
    for (var i = 0; i < items.length; i++) {
      if (location == items[i].$1 || location.startsWith('${items[i].$1}/')) {
        current = i;
        break;
      }
    }
    return BottomNavigationBar(
      currentIndex: current,
      type: BottomNavigationBarType.fixed,
      backgroundColor: Colors.white,
      selectedItemColor: AppColors.primary,
      unselectedItemColor: AppColors.textSecondary,
      selectedFontSize: 12,
      unselectedFontSize: 12,
      onTap: (i) {
        final route = items[i].$1;
        if (location != route) context.go(route);
      },
      items: items
          .map((it) => BottomNavigationBarItem(
                icon: Icon(it.$2),
                activeIcon: Icon(it.$3),
                label: it.$4,
              ))
          .toList(),
    );
  }
}
