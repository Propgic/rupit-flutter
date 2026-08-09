import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../core/api/api_client.dart';
import '../core/auth/account_store.dart';
import '../core/auth/auth_controller.dart';
import '../core/theme/app_theme.dart';
import '../core/widgets/common.dart';
import 'dashboard/dashboard_page.dart';

// Orgs the *active login* belongs to. Drives the "switch organization" section
// of the account switcher (server-side org-switch folded into the same sheet).
final myOrgsProvider = FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) {
  return ref.read(authProvider.notifier).myOrgs();
});

// All locally-stored accounts (login x org), each with its own token bundle.
// Re-runs whenever auth state changes (login / switch / add / remove).
final accountsProvider = FutureProvider.autoDispose<List<StoredAccount>>((ref) {
  ref.watch(authProvider);
  return ref.read(authProvider.notifier).listAccounts();
});

class NavItem {
  final String label;
  final IconData icon;
  final String route;
  final String? featureFlag;
  // Visible when ANY of these feature flags is enabled (e.g. Collections serves
  // both loans and chitfunds). Takes precedence over featureFlag when set.
  final List<String>? featureAny;
  final String? permission;
  final String? role;
  const NavItem(this.label, this.icon, this.route, {this.featureFlag, this.featureAny, this.permission, this.role});
}

const _navItems = <NavItem>[
  NavItem('Dashboard', Icons.dashboard_outlined, '/dashboard'),
  NavItem('Customers', Icons.people_outline, '/customers', permission: 'customers.view'),
  NavItem('Loans', Icons.request_quote_outlined, '/loans', featureFlag: 'enableLoans', permission: 'loans.view'),
  NavItem('Assign Loans', Icons.manage_accounts_outlined, '/assign-loans', featureFlag: 'enableLoans', permission: 'loans.assign'),
  NavItem('Loan Groups', Icons.groups_outlined, '/loan-groups', featureFlag: 'enableGroupLoan', permission: 'loans.view'),
  NavItem('Collections', Icons.payments_outlined, '/collections', featureAny: ['enableLoans', 'enableChitfund'], permission: 'collections.view'),
  NavItem('Savings', Icons.savings_outlined, '/savings', featureFlag: 'enableSavings', permission: 'savings.view'),
  NavItem('Chitfunds', Icons.account_balance_wallet_outlined, '/chitfunds', featureFlag: 'enableChitfund', permission: 'chitfunds.view'),
  NavItem('Investors', Icons.trending_up, '/investors', featureFlag: 'enableInvestments', permission: 'investors.view'),
  NavItem('Expenses', Icons.receipt_long_outlined, '/expenses', featureFlag: 'enableExpenses', permission: 'expenses.view'),
  NavItem('Reports', Icons.bar_chart_outlined, '/reports', featureFlag: 'enableReports', permission: 'reports.view'),
  NavItem('Balance Sheet', Icons.account_balance_outlined, '/consolidated-balance', featureFlag: 'enableConsolidatedBalance', permission: 'reports.view'),
  NavItem('Team', Icons.group_outlined, '/team', permission: 'team.view'),
  NavItem('Settings', Icons.settings_outlined, '/settings', role: 'ORG_ADMIN'),
];

class AppShell extends StatelessWidget {
  final Widget child;
  const AppShell({super.key, required this.child});
  @override
  Widget build(BuildContext context) => child;
}

class AppDrawer extends ConsumerWidget {
  const AppDrawer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    // Khata mode swaps the Collections destination to the khata counter screen
    // (customer → consolidated balance → lump receipt) for admins/managers;
    // field officers always keep the collections list.
    final khataMode = auth.org?.khataCollectionMode == true &&
        auth.org?.feature('enableConsolidatedBalance') == true &&
        (auth.hasRole('ORG_ADMIN') || auth.hasRole('MANAGER'));
    final items = _navItems.where((it) {
      if (it.featureAny != null && !it.featureAny!.any((f) => auth.org?.feature(f) == true)) return false;
      if (it.featureFlag != null && auth.org?.feature(it.featureFlag!) != true) return false;
      if (it.permission != null && !auth.hasPermission(it.permission!)) return false;
      if (it.role != null && !auth.hasRole(it.role!)) return false;
      return true;
    }).map((it) {
      if (khataMode && it.route == '/collections') {
        return const NavItem('Khata Collection', Icons.point_of_sale_outlined, '/khata-collection');
      }
      return it;
    }).toList();
    final location = GoRouter.of(context).routeInformationProvider.value.uri.path;

    return Drawer(
      child: SafeArea(
        child: Column(
          children: [
            InkWell(
              // Always tappable: even with a single account the sheet offers
              // "Add another account" and any other orgs of this login.
              onTap: () {
                // Capture the page Scaffold so we can close the drawer after the
                // sheet (whose context is gone once it pops).
                final scaffold = Scaffold.of(context);
                showModalBottomSheet(
                  context: context,
                  showDragHandle: true,
                  isScrollControlled: true,
                  builder: (_) => AccountSwitcherSheet(onDone: scaffold.closeDrawer),
                );
              },
              child: Container(
                padding: const EdgeInsets.all(16),
                width: double.infinity,
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: AppColors.border)),
                ),
                child: Row(
                  children: [
                    Avatar(url: auth.org?.logo, name: auth.org?.name ?? 'Org', size: 48),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(auth.org?.name ?? '-',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                          Text(
                              [auth.user?.name, auth.user?.role.replaceAll('_', ' ')]
                                  .where((s) => s != null && s.isNotEmpty)
                                  .join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                        ],
                      ),
                    ),
                    const Icon(Icons.unfold_more, color: AppColors.textSecondary),
                  ],
                ),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: items.map((it) {
                  final selected = location == it.route || location.startsWith('${it.route}/');
                  return ListTile(
                    leading: Icon(it.icon, color: selected ? AppColors.primary : AppColors.textSecondary),
                    title: Text(it.label,
                        style: TextStyle(
                          color: selected ? AppColors.primary : AppColors.textPrimary,
                          fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                        )),
                    selected: selected,
                    selectedTileColor: AppColors.primary.withValues(alpha: 0.08),
                    onTap: () {
                      Navigator.pop(context);
                      context.go(it.route);
                    },
                  );
                }).toList(),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

// Outlook-style account switcher. Lists every locally-stored account (login x
// org) with the active one checked, folds in the server-side "switch
// organization" flow for the active login, and offers "Add another account".
class AccountSwitcherSheet extends ConsumerStatefulWidget {
  final VoidCallback onDone; // closes the drawer behind the sheet
  const AccountSwitcherSheet({super.key, required this.onDone});

  @override
  ConsumerState<AccountSwitcherSheet> createState() => _AccountSwitcherSheetState();
}

class _AccountSwitcherSheetState extends ConsumerState<AccountSwitcherSheet> {
  String? _busy; // account id, or "org:<id>" while a server switch is in flight

  Future<void> _finishSwitch(Future<void> Function() action, String successMsg) async {
    final router = GoRouter.of(context);
    try {
      await action();
      // Refetch org-scoped data for the now-active account.
      ref.invalidate(dashboardProvider);
      ref.invalidate(myOrgsProvider);
      ref.invalidate(accountsProvider);
      if (!mounted) return;
      Navigator.pop(context); // close the sheet
      widget.onDone(); // close the drawer
      router.go('/dashboard');
      showToast(successMsg);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _busy = null);
      showToast(e.message, error: true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _busy = null);
      showToast('Could not switch account', error: true);
    }
  }

  Future<void> _switchLocal(StoredAccount a, bool isCurrent) async {
    if (isCurrent) {
      Navigator.pop(context);
      return;
    }
    setState(() => _busy = a.id);
    await _finishSwitch(
      () => ref.read(authProvider.notifier).switchToAccount(a.id),
      'Switched to ${a.orgName}',
    );
  }

  Future<void> _switchOrgServer(Map<String, dynamic> org) async {
    final id = org['id'].toString();
    setState(() => _busy = 'org:$id');
    await _finishSwitch(
      () => ref.read(authProvider.notifier).switchOrg(id),
      'Switched to ${org['name'] ?? 'organization'}',
    );
  }

  Future<void> _remove(StoredAccount a) async {
    final ok = await confirmDialog(
      context,
      title: 'Remove account',
      message: 'Remove ${a.orgName} (${a.userName}) from this device? You can sign back in anytime.',
      destructive: true,
      confirmText: 'Remove',
    );
    if (!ok) return;
    await ref.read(authProvider.notifier).logoutAccount(a.id);
    ref.invalidate(accountsProvider);
    if (mounted) showToast('Account removed');
  }

  void _addAccount() {
    final router = GoRouter.of(context);
    Navigator.pop(context); // close the sheet
    widget.onDone(); // close the drawer
    router.push('/add-account');
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final accounts = ref.watch(accountsProvider).maybeWhen(
          data: (v) => v,
          orElse: () => const <StoredAccount>[],
        );
    final orgs = ref.watch(myOrgsProvider).maybeWhen(
          data: (v) => v,
          orElse: () => const <Map<String, dynamic>>[],
        );
    final currentAccountId = auth.accountId ?? '';
    final currentUserId = auth.user?.id ?? '';

    // Orgs of the active login not already stored as their own account.
    final storedOrgsForLogin =
        accounts.where((a) => a.userId == currentUserId).map((a) => a.orgId).toSet();
    final otherOrgs = orgs.where((o) => !storedOrgsForLogin.contains(o['id'].toString())).toList();

    return SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text('Accounts', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            ),
            ...accounts.map((a) {
              final isCurrent = a.id == currentAccountId;
              final busy = _busy == a.id;
              return ListTile(
                leading: Avatar(url: a.orgLogo, name: a.orgName, size: 40),
                title: Text(a.orgName, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text(
                  [a.userName, a.role.replaceAll('_', ' ')].where((s) => s.isNotEmpty).join(' · '),
                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                ),
                trailing: busy
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : isCurrent
                        ? const Icon(Icons.check_circle, color: AppColors.primary)
                        : PopupMenuButton<String>(
                            icon: const Icon(Icons.more_vert, color: AppColors.textMuted),
                            onSelected: (v) {
                              if (v == 'switch') _switchLocal(a, false);
                              if (v == 'remove') _remove(a);
                            },
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: 'switch', child: Text('Switch to this account')),
                              PopupMenuItem(value: 'remove', child: Text('Remove from device')),
                            ],
                          ),
                onTap: _busy != null ? null : () => _switchLocal(a, isCurrent),
              );
            }),
            if (otherOrgs.isNotEmpty) ...[
              const Divider(height: 1),
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 12, 20, 4),
                child: Text('Switch organization',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
              ),
              ...otherOrgs.map((o) {
                final id = o['id'].toString();
                final busy = _busy == 'org:$id';
                return ListTile(
                  leading: Avatar(url: o['logo']?.toString(), name: o['name']?.toString() ?? 'Org', size: 40),
                  title: Text(o['name']?.toString() ?? '-', style: const TextStyle(fontWeight: FontWeight.w600)),
                  subtitle: Text((o['role']?.toString() ?? '').replaceAll('_', ' '),
                      style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                  trailing: busy
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.add, color: AppColors.textMuted),
                  onTap: _busy != null ? null : () => _switchOrgServer(o),
                );
              }),
            ],
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.person_add_alt_1, color: AppColors.primary),
              title: const Text('Add another account',
                  style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.primary)),
              onTap: _busy != null ? null : _addAccount,
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
