import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/theme/app_theme.dart';
import '../../app_shell.dart';
import '../../../core/widgets/app_bottom_nav.dart';

class ReportsIndexPage extends ConsumerWidget {
  const ReportsIndexPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final auth = ref.watch(authProvider);
    final org = auth.org;
    final items = <_ReportItem>[
      _ReportItem('Loan Report', Icons.request_quote_outlined, '/reports/loans', 'reports.loans'),
      _ReportItem('Collection Report', Icons.payments_outlined, '/reports/collections', 'reports.collections'),
      _ReportItem('Overdue Report', Icons.warning_amber_outlined, '/reports/overdue', 'reports.overdue'),
      if (org?.feature('enableSavings') == true)
        _ReportItem('Savings Report', Icons.savings_outlined, '/reports/savings', 'reports.savings'),
      _ReportItem('Daily Cash Report', Icons.account_balance_wallet_outlined, '/reports/daily-cash', 'reports.daily_cash'),
      _ReportItem('Portfolio Report', Icons.pie_chart_outline, '/reports/portfolio', 'reports.portfolio'),
      if (org?.feature('enableInvestments') == true)
        _ReportItem('Investment Report', Icons.trending_up, '/reports/investments', 'reports.investments'),
      _ReportItem('Customer Report', Icons.people_outline, '/reports/customer', 'reports.customer'),
      if (org?.feature('enableExpenses') == true)
        _ReportItem('Expense Report', Icons.receipt_long_outlined, '/reports/expenses', 'reports.expenses'),
      if (org?.feature('enableGroupLoan') == true)
        _ReportItem('Progress Report', Icons.insights_outlined, '/reports/progress', 'reports.progress'),
      if (org?.feature('enableGroupLoan') == true)
        _ReportItem('Group Collection Report', Icons.groups_outlined, '/reports/group-collection', 'reports.group_collection'),
      if (org?.feature('enableChitfund') == true)
        _ReportItem('Chit Returns Report', Icons.monetization_on_outlined, '/reports/chit-returns', 'reports.chitfund'),
    ];
    final visible = items.where((i) => auth.hasPermission(i.permission)).toList();
    return Scaffold(
      drawer: const AppDrawer(),
      bottomNavigationBar: const AppBottomNav(),
      appBar: AppBar(
        title: const Text('Reports'),
        leading: Builder(builder: (ctx) => IconButton(icon: const Icon(Icons.menu), onPressed: () => Scaffold.of(ctx).openDrawer())),
      ),
      body: GridView.count(
        crossAxisCount: 2,
        padding: const EdgeInsets.all(14),
        mainAxisSpacing: 10,
        crossAxisSpacing: 10,
        children: visible.map((i) => _tile(context, i)).toList(),
      ),
    );
  }

  Widget _tile(BuildContext context, _ReportItem i) {
    return InkWell(
      onTap: () => context.push(i.route),
      borderRadius: BorderRadius.circular(12),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(i.icon, size: 40, color: AppColors.primary),
              const SizedBox(height: 10),
              Text(i.title, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ReportItem {
  final String title;
  final IconData icon;
  final String route;
  final String permission;
  _ReportItem(this.title, this.icon, this.route, this.permission);
}
