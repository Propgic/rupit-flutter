import 'dart:async';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/api/api_client.dart';
import '../../core/auth/auth_controller.dart';
import '../../core/auth/auth_models.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/formatters.dart';
import '../../core/widgets/app_bottom_nav.dart';
import '../../core/widgets/common.dart';
import '../app_shell.dart';

final dashboardProvider = FutureProvider.autoDispose<Map<String, dynamic>>((ref) async {
  final api = ref.read(apiClientProvider);
  // Refresh user/org/permissions on every dashboard load so role updates take effect.
  unawaited(ref.read(authProvider.notifier).refreshMe());
  final res = await api.get('/dashboard');
  return Map<String, dynamic>.from(res as Map);
});

class DashboardPage extends ConsumerWidget {
  const DashboardPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(dashboardProvider);
    final auth = ref.watch(authProvider);
    return Scaffold(
      drawer: const AppDrawer(),
      bottomNavigationBar: const AppBottomNav(),
      appBar: AppBar(
        title: const Text('Dashboard'),
        leading: Builder(
          builder: (ctx) => IconButton(icon: const Icon(Icons.menu), onPressed: () => Scaffold.of(ctx).openDrawer()),
        ),
        actions: [
          IconButton(
            tooltip: 'Search',
            icon: const Icon(Icons.search),
            onPressed: () => context.push('/search'),
          ),
          _NotificationsBell(),
          IconButton(
            tooltip: 'Profile',
            onPressed: () => context.push('/profile'),
            icon: Avatar(url: auth.user?.photo, name: auth.user?.name ?? '', size: 30),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.refresh(dashboardProvider.future),
        child: data.when(
          loading: () => const LoadingView(),
          error: (e, _) => ErrorView(message: e.toString(), onRetry: () => ref.invalidate(dashboardProvider)),
          data: (d) => _buildBody(context, d, auth),
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, Map<String, dynamic> d, AuthState auth) {
    final role = auth.user?.role;
    final isFieldOfficer = role == 'FIELD_OFFICER';
    final isAdmin = role == 'ORG_ADMIN' || role == 'MANAGER';
    final features = auth.org?.features ?? const {};

    final chitEnabled = features['enableChitfund'] == true && d['chitfund'] != null;
    // Chit-only orgs (no loan module) have no separate generic Day Summary / Day Report,
    // so the chit cards own the full org-cash position and the generic copies would just
    // duplicate them. Suppress those when the chit section owns the day cash.
    final chitOwnsDayCash = chitEnabled && features['enableLoans'] != true;

    // Layout mirrors the web dashboard's mobile-responsive view exactly:
    // a 2-column gradient stat grid followed by single-column stacked cards.
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        if (isFieldOfficer) ...[
          // Loan/cash daily snapshot — hidden when the loan module is off (mirrors web's
          // `showLoans` gate). For chit-only orgs the Chit Funds section owns the cash
          // position, so these loan-centric cards would just show empty/duplicate figures.
          if (features['enableLoans'] == true) _fieldOfficerStats(context, d),
          _PendingVerificationListCard(d: d),
          _overdueLoansList(context, d),
          if (chitEnabled) _chitfundSection(context, d, auth, features),
          _dailyCollectionChart(d),
        ] else ...[
          // Top gradient stat cards (Today's Loans / Total Overdue / Closing Balance) are
          // a loan/cash snapshot — hidden when the loan module is off (mirrors web). The
          // Chit Funds section below owns the org-cash position for chit-only orgs.
          if (features['enableLoans'] == true) _adminTopCards(context, d),
          if (!chitOwnsDayCash) _daySummaryCard(d),
          if ((features['enableLoans'] == true) && role == 'ORG_ADMIN') _outstandingCard(d),
          if (!chitOwnsDayCash) _dayReportCard(d),
          if (features['enableSavings'] == true) _savingsPoolGradientCard(d),
          if (features['enableLoans'] == true) _upcomingOverdueCard(context, d, isAdmin),
          if (isAdmin) _PendingVerificationByAgentCard(d: d),
          if (features['enableLoans'] == true) ...[
            _loansByTypeCard(d),
            _loansByStatusCard(d),
            _monthlyCollectionsChart(d),
            _monthlyDisbursementsChart(d),
          ],
          if (chitEnabled) _chitfundSection(context, d, auth, features),
        ],
        const SizedBox(height: 24),
      ],
    );
  }

  // === Chit Funds section — mirrors the web ChitfundDashboard. Headline stat cards,
  // then Day Summary / Member Dues / Day Report and Auctions / Payouts lists, each
  // gated per-role via isHidden('dashboard.*'). For chit-only orgs the cash cards
  // reflect full org cash (expenses + investments + chit flows); otherwise chit cash only.
  Widget _chitfundSection(BuildContext context, Map<String, dynamic> d, AuthState auth, Map features) {
    final c = Map<String, dynamic>.from(d['chitfund'] ?? const {});
    final showDaySummary = !auth.isHidden('dashboard.daySummary');
    final showMemberDues = !auth.isHidden('dashboard.memberDues');
    final showDayReport = !auth.isHidden('dashboard.dayReport');
    final showAuctionsToConduct = !auth.isHidden('dashboard.auctionsToConduct');
    final showAuctionPayouts = !auth.isHidden('dashboard.auctionPayouts');
    final enableLoans = features['enableLoans'] == true;
    final enableExpenses = features['enableExpenses'] == true;
    final enableInvestments = features['enableInvestments'] == true;
    final showOrgCash = !enableLoans;

    final dayOpen = showOrgCash ? toNum(d['openBalance']) : toNum(c['openBalance']);
    final dayClosing = showOrgCash ? toNum(d['closingBalance']) : toNum(c['closingBalance']);
    final dayInflow = showOrgCash
        ? toNum(d['totalCollectionsToday']) + toNum(d['todayInvestmentAmount']) + toNum(d['todayChitCollectionAmount'])
        : toNum(c['dayCollectionAmount']);
    final dayOutflow = showOrgCash
        ? toNum(d['todayDisbursedAmount']) + toNum(d['todayExpensesAmount']) + toNum(d['todayInvestmentWithdrawalsAmount']) + toNum(d['todayChitPayoutAmount'])
        : toNum(c['dayPayoutAmount']);

    final auctions = ((c['auctionsToConduct'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    final payouts = ((c['pendingAuctionPayments'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 10),
        Row(
          children: [
            Container(
              padding: const EdgeInsets.all(7),
              decoration: BoxDecoration(color: const Color(0xFF14B8A6).withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
              child: const Icon(Icons.monetization_on_outlined, size: 18, color: Color(0xFF0D9488)),
            ),
            const SizedBox(width: 10),
            const Text('Chit Funds', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const Spacer(),
            TextButton(onPressed: () => context.push('/chitfunds'), child: const Text('View All')),
          ],
        ),
        const SizedBox(height: 8),
        GridView.count(
          crossAxisCount: 2,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 10,
          crossAxisSpacing: 10,
          childAspectRatio: 1.3,
          children: [
            _gradientStatTile('Active Chits', '${c['activeCount'] ?? 0}',
                subtitle: '${formatCurrency(c['totalValue'])} total value', icon: Icons.monetization_on,
                gradient: const LinearGradient(colors: [Color(0xFF14B8A6), Color(0xFF059669)]),
                onTap: () => context.push('/chitfunds')),
            _gradientStatTile('Active Members', '${c['activeMembers'] ?? 0}',
                subtitle: 'across active chits', icon: Icons.groups,
                gradient: const LinearGradient(colors: [Color(0xFF3B82F6), Color(0xFF4F46E5)])),
            _gradientStatTile('Auctions To Conduct', '${c['auctionsDueCount'] ?? 0}',
                subtitle: '${c['auctionsTodayCount'] ?? 0} due today', icon: Icons.gavel,
                gradient: const LinearGradient(colors: [Color(0xFF8B5CF6), Color(0xFF7C3AED)]),
                onTap: () => showModalBottomSheet(
                      context: context,
                      isScrollControlled: true,
                      backgroundColor: Colors.transparent,
                      builder: (_) => AuctionsSheet(auctions: auctions),
                    )),
            _gradientStatTile('To Be Collected', formatCurrency(c['totalToCollect']),
                subtitle: 'Old ${formatCurrency(c['oldDues'])} · This month ${formatCurrency(c['currentMonthDue'])}',
                icon: Icons.account_balance_wallet,
                gradient: const LinearGradient(colors: [Color(0xFFF43F5E), Color(0xFFDC2626)]),
                onTap: () => showModalBottomSheet(
                      context: context,
                      isScrollControlled: true,
                      backgroundColor: Colors.transparent,
                      builder: (_) => const ChitDuesSheet(),
                    )),
          ],
        ),
        if (showDaySummary) _chitDaySummaryCard(c, d, showOrgCash: showOrgCash, enableExpenses: enableExpenses, enableInvestments: enableInvestments),
        if (showMemberDues) _chitMemberDuesCard(c),
        if (showDayReport) _chitDayReportCard(d, dayOpen, dayInflow, dayOutflow, dayClosing, showOrgCash),
        if (showAuctionsToConduct) _chitAuctionsCard(context, auctions),
        if (showAuctionPayouts) _chitPayoutsCard(context, c, payouts),
      ],
    );
  }

  Widget _chitDaySummaryCard(Map<String, dynamic> c, Map<String, dynamic> d,
      {required bool showOrgCash, required bool enableExpenses, required bool enableInvestments}) {
    return SectionCard(
      title: 'Day Summary',
      child: Column(
        children: [
          _kvRow('Collection${toNum(c['dayCollectionCount']) > 0 ? ' (${toNum(c['dayCollectionCount']).toInt()})' : ''}',
              formatCurrency(c['dayCollectionAmount']), color: AppColors.accent),
          const Divider(height: 1),
          _kvRow('Payouts${toNum(c['dayPayoutCount']) > 0 ? ' (${toNum(c['dayPayoutCount']).toInt()})' : ''}',
              formatCurrency(c['dayPayoutAmount']), color: AppColors.danger),
          if (showOrgCash && enableExpenses) ...[
            const Divider(height: 1),
            _kvRow('Expenses', formatCurrency(d['todayExpensesAmount']), color: AppColors.danger),
          ],
          if (showOrgCash && enableInvestments) ...[
            const Divider(height: 1),
            _kvRow('Investment', formatCurrency(d['todayInvestmentAmount'])),
          ],
        ],
      ),
    );
  }

  Widget _chitMemberDuesCard(Map<String, dynamic> c) {
    return SectionCard(
      title: 'Member Dues',
      child: Column(
        children: [
          _kvRow('Old Dues', formatCurrency(c['oldDues']), color: AppColors.danger),
          const Divider(height: 1),
          _kvRow('Current Month Due', formatCurrency(c['currentMonthDue']), color: AppColors.warning),
          const Divider(height: 1),
          _kvRow('Total To Collect', formatCurrency(c['totalToCollect']), bold: true),
        ],
      ),
    );
  }

  Widget _chitDayReportCard(Map<String, dynamic> d, num open, num inflow, num outflow, num closing, bool showOrgCash) {
    final expenses = toNum(d['todayExpensesAmount']);
    final withdrawals = toNum(d['todayInvestmentWithdrawalsAmount']);
    return SectionCard(
      title: 'Day Report',
      child: Column(
        children: [
          _kvRow('Open Balance', formatCurrency(open), color: open < 0 ? AppColors.danger : null),
          const Divider(height: 1),
          _kvRow('Inflow', formatCurrency(inflow), color: AppColors.accent),
          const Divider(height: 1),
          _kvRow('Outflow', formatCurrency(outflow), color: AppColors.danger),
          if (showOrgCash && expenses > 0)
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 2, bottom: 2),
              child: Row(children: [
                const Expanded(child: Text('Expenses', style: TextStyle(fontSize: 12, color: AppColors.textSecondary))),
                Text(formatCurrency(expenses), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.danger)),
              ]),
            ),
          if (showOrgCash && withdrawals > 0)
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 2, bottom: 2),
              child: Row(children: [
                const Expanded(child: Text('Investment Withdrawals', style: TextStyle(fontSize: 12, color: AppColors.textSecondary))),
                Text(formatCurrency(withdrawals), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.danger)),
              ]),
            ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(10)),
            child: Row(children: [
              const Expanded(child: Text('Closing Balance', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800))),
              Text(formatCurrency(closing),
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: closing < 0 ? AppColors.danger : AppColors.accent)),
            ]),
          ),
        ],
      ),
    );
  }

  Widget _chitAuctionsCard(BuildContext context, List<Map<String, dynamic>> auctions) {
    return SectionCard(
      title: 'Auctions To Conduct (${auctions.length})',
      child: auctions.isEmpty
          ? const EmptyView(message: 'No auctions due', icon: Icons.gavel_outlined)
          : Column(
              children: auctions.map((a) {
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  onTap: () => context.push('/chitfunds/${a['chitfundId']}'),
                  title: Text('${a['chitName'] ?? ''}${a['chitNumber'] != null ? '  #${a['chitNumber']}' : ''}'),
                  subtitle: Text('Month ${a['monthNumber']} · ${formatDate(a['auctionDate'])}', style: const TextStyle(fontSize: 11)),
                  trailing: StatusChip(
                    label: a['overdue'] == true ? 'Overdue' : 'Today',
                    color: a['overdue'] == true ? AppColors.danger : AppColors.warning,
                  ),
                );
              }).toList(),
            ),
    );
  }

  Widget _chitPayoutsCard(BuildContext context, Map<String, dynamic> c, List<Map<String, dynamic>> payouts) {
    return SectionCard(
      title: 'Auction Payouts',
      actions: [StatusChip(label: '${toNum(c['pendingPayoutCount']).toInt()} to pay', color: AppColors.danger)],
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('To Pay', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                    Text(formatCurrency(c['pendingPayoutAmount']), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: AppColors.danger)),
                    Text('${toNum(c['pendingPayoutCount']).toInt()} winners', style: const TextStyle(fontSize: 10, color: AppColors.textMuted)),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Paid', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                    Text(formatCurrency(c['paidPayoutAmount']), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: AppColors.accent)),
                    Text('${toNum(c['paidPayoutCount']).toInt()} settled', style: const TextStyle(fontSize: 10, color: AppColors.textMuted)),
                  ],
                ),
              ),
            ],
          ),
          if (payouts.isNotEmpty) const Divider(height: 16),
          ...payouts.map((p) {
            return ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              onTap: () => context.push('/chitfunds/${p['chitfundId']}'),
              title: Text('${p['winnerName'] ?? 'Winner'}${p['ticketNumber'] != null ? ' · #${p['ticketNumber']}' : ''}'),
              subtitle: Text('${p['chitName'] ?? ''} · Month ${p['monthNumber']}', style: const TextStyle(fontSize: 11)),
              trailing: Text(formatCurrency(p['amount']), style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.danger)),
            );
          }),
        ],
      ),
    );
  }

  // === Field officer: 4 gradient stat cards ===
  Widget _fieldOfficerStats(BuildContext context, Map<String, dynamic> d) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 1.3,
      children: [
        _gradientStatTile("Today's Loan Issues", formatCurrency(d['todayLoanIssuedAmount'] ?? d['todayDisbursedAmount']),
            subtitle: '${d['todayDisbursedCount'] ?? 0} loans', icon: Icons.payments,
            gradient: const LinearGradient(colors: [Color(0xFF10B981), Color(0xFF059669)]),
            onTap: () { final t = formatInputDate(DateTime.now()); context.push('/loans?fromDate=$t&toDate=$t'); }),
        _gradientStatTile("Today's Collection", formatCurrency(d['totalCollectionsToday']),
            subtitle: '${d['todayCollectionsCount'] ?? 0} collected', icon: Icons.receipt_long,
            gradient: const LinearGradient(colors: [Color(0xFFF59E0B), Color(0xFFF97316)]),
            onTap: () => context.push('/collections')),
        _gradientStatTile('Due to Company', formatCurrency(d['companyAmountInMarket']),
            subtitle: 'outstanding balance', icon: Icons.trending_up,
            gradient: const LinearGradient(colors: [Color(0xFFF43F5E), Color(0xFFDC2626)]),
            onTap: () => context.push('/collections/verify')),
        _gradientStatTile('Active Customers', '${d['activeCustomers'] ?? 0}',
            subtitle: 'assigned to you', icon: Icons.people,
            gradient: const LinearGradient(colors: [Color(0xFF3B82F6), Color(0xFF4F46E5)]),
            onTap: () => context.push('/customers?status=active')),
      ],
    );
  }

  Widget _gradientStatTile(String label, String value, {String? subtitle, required IconData icon, required LinearGradient gradient, VoidCallback? onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: gradient,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: gradient.colors.last.withValues(alpha: 0.3), blurRadius: 12, offset: const Offset(0, 4))],
        ),
        child: Stack(
          children: [
            Positioned(right: -10, top: -10, child: Container(width: 60, height: 60, decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.1)))),
            Positioned(right: -4, bottom: -12, child: Container(width: 40, height: 40, decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.1)))),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.all(7),
                  decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(10)),
                  child: Icon(icon, color: Colors.white, size: 16),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.85))),
                    const SizedBox(height: 2),
                    Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Colors.white)),
                    if (subtitle != null) Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 10, color: Colors.white.withValues(alpha: 0.7))),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _dailyCollectionChart(Map<String, dynamic> d) {
    final trend = ((d['dailyCollectionTrend'] as List?) ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    if (trend.isEmpty) return const SizedBox.shrink();
    final maxAmt = trend.fold<double>(0, (s, e) => s > toNum(e['amount']).toDouble() ? s : toNum(e['amount']).toDouble());
    return SectionCard(
      title: 'Daily Collections (Last 7 Days)',
      child: SizedBox(
        height: 160,
        child: LineChart(
          LineChartData(
            gridData: FlGridData(show: true, drawVerticalLine: false, horizontalInterval: maxAmt > 0 ? maxAmt / 4 : 1),
            titlesData: FlTitlesData(
              topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              bottomTitles: AxisTitles(sideTitles: SideTitles(showTitles: true, reservedSize: 22, getTitlesWidget: (v, _) {
                final i = v.toInt();
                if (i < 0 || i >= trend.length) return const SizedBox.shrink();
                return Text(trend[i]['day']?.toString().substring(0, 2) ?? '', style: const TextStyle(fontSize: 10, color: AppColors.textSecondary));
              })),
              leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            ),
            borderData: FlBorderData(show: false),
            lineBarsData: [
              LineChartBarData(
                spots: List.generate(trend.length, (i) => FlSpot(i.toDouble(), toNum(trend[i]['amount']).toDouble())),
                isCurved: true,
                color: AppColors.accent,
                barWidth: 2.5,
                dotData: FlDotData(show: trend.length <= 7),
                belowBarData: BarAreaData(show: true, color: AppColors.accent.withValues(alpha: 0.12)),
              ),
            ],
            lineTouchData: LineTouchData(
              touchTooltipData: LineTouchTooltipData(
                getTooltipItems: (spots) => spots.map((s) {
                  final i = s.spotIndex;
                  return LineTooltipItem('${trend[i]['day']}\n${formatCurrency(s.y)}', const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w600));
                }).toList(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // === Admin: 4 gradient top cards ===
  Widget _adminTopCards(BuildContext context, Map<String, dynamic> d) {
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 1.3,
      children: [
        _gradientStatTile("Today's Collection", formatCurrency(d['totalCollectionsToday']),
            subtitle: '${d['todayCollectionsCount'] ?? 0} collections', icon: Icons.receipt_long,
            gradient: const LinearGradient(colors: [Color(0xFF10B981), Color(0xFF059669)]),
            onTap: () => context.push('/collections')),
        _gradientStatTile("Today's Loans", formatCurrency(d['todayLoanIssuedAmount'] ?? d['todayDisbursedAmount']),
            subtitle: '${d['todayDisbursedCount'] ?? 0} disbursed', icon: Icons.payments,
            gradient: const LinearGradient(colors: [Color(0xFF3B82F6), Color(0xFF2563EB)]),
            onTap: () { final t = formatInputDate(DateTime.now()); context.push('/loans?fromDate=$t&toDate=$t'); }),
        _gradientStatTile('Total Overdue', formatCurrency(d['totalOverdue']),
            subtitle: 'outstanding', icon: Icons.warning_amber,
            gradient: const LinearGradient(colors: [Color(0xFFF43F5E), Color(0xFFDC2626)]),
            onTap: () => context.push('/loans/overdue')),
        _gradientStatTile('Closing Balance', formatCurrency(d['closingBalance']),
            subtitle: "today's P&L", icon: Icons.account_balance_wallet,
            gradient: const LinearGradient(colors: [Color(0xFF8B5CF6), Color(0xFF7C3AED)]),
            onTap: () => context.push('/reports/daily-cash')),
      ],
    );
  }

  Widget _savingsPoolGradientCard(Map<String, dynamic> d) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFFA855F7), Color(0xFFC026D3)]),
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: const Color(0xFFA855F7).withValues(alpha: 0.3), blurRadius: 12, offset: const Offset(0, 4))],
      ),
      child: Stack(
        children: [
          Positioned(right: -10, top: -10, child: Container(width: 60, height: 60, decoration: BoxDecoration(shape: BoxShape.circle, color: Colors.white.withValues(alpha: 0.1)))),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(10)),
                child: const Icon(Icons.savings, color: Colors.white),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Savings Pool', style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.85))),
                    const SizedBox(height: 2),
                    Text(formatCurrency(d['totalSavingsBalance']),
                        style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: Colors.white)),
                    Text('${d['totalSavingsAccounts'] ?? 0} active accounts',
                        style: TextStyle(fontSize: 10, color: Colors.white.withValues(alpha: 0.7))),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // === Day summary card ===
  Widget _daySummaryCard(Map<String, dynamic> d) {
    return SectionCard(
      title: 'Day Summary',
      child: Column(
        children: [
          _kvRow('Collection', formatCurrency(d['totalCollectionsToday']), color: AppColors.accent),
          const Divider(height: 1),
          _kvRow('Loans Issued', formatCurrency(d['todayLoanIssuedAmount'] ?? d['todayDisbursedAmount']), color: AppColors.primary),
          const Divider(height: 1),
          _kvRow('Expenses', formatCurrency(d['todayExpensesAmount']), color: AppColors.danger),
          const Divider(height: 1),
          _kvRow('Investment', formatCurrency(d['todayInvestmentAmount'])),
        ],
      ),
    );
  }

  Widget _outstandingCard(Map<String, dynamic> d) {
    return SectionCard(
      title: 'Outstanding',
      child: Column(
        children: [
          _kvRow('Total Loans Issued', formatCurrency(d['totalActiveLoansIssued'])),
          const Divider(height: 1),
          _kvRow('Total Collected', formatCurrency(d['totalActiveLoansCollected']), color: AppColors.accent),
          const Divider(height: 1),
          _kvRow('Amount In Market', formatCurrency(d['companyAmountInMarket']), color: AppColors.danger),
        ],
      ),
    );
  }

  // _savingsPoolCard removed — replaced by _savingsPoolGradientCard

  Widget _dayReportCard(Map<String, dynamic> d) {
    final openBal = toNum(d['openBalance']);
    final closing = toNum(d['closingBalance']);
    final withdrawals = toNum(d['todayInvestmentWithdrawalsAmount']);
    final inflow = toNum(d['totalCollectionsToday']) + toNum(d['todayInvestmentAmount']) + toNum(d['todayChitCollectionAmount']);
    final outflow = toNum(d['todayDisbursedAmount']) + toNum(d['todayExpensesAmount']) + withdrawals + toNum(d['todayChitPayoutAmount']);
    return SectionCard(
      title: 'Day Report',
      child: Column(
        children: [
          _kvRow('Open Balance', formatCurrency(openBal), color: openBal < 0 ? AppColors.danger : null),
          const Divider(height: 1),
          _kvRow('Inflow', formatCurrency(inflow), color: AppColors.accent),
          const Divider(height: 1),
          _kvRow('Outflow', formatCurrency(outflow), color: AppColors.danger),
          if (withdrawals > 0)
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 2, bottom: 2),
              child: Row(
                children: [
                  Expanded(child: Text('Investment Withdrawals', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary))),
                  Text(formatCurrency(withdrawals), style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.danger)),
                ],
              ),
            ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(10)),
            child: Row(
              children: [
                const Expanded(child: Text('Closing Balance', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800))),
                Text(formatCurrency(closing),
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: closing < 0 ? AppColors.danger : AppColors.accent)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _kvRow(String label, String value, {Color? color, bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13, color: AppColors.textSecondary))),
          Text(value,
              style: TextStyle(
                fontSize: 13,
                fontWeight: bold ? FontWeight.w800 : FontWeight.w700,
                color: color,
              )),
        ],
      ),
    );
  }

  // === Lists ===
  Widget _overdueLoansList(BuildContext context, Map<String, dynamic> d) {
    final list = ((d['overdueLoans'] as List?) ?? const []).take(10).toList();
    if (list.isEmpty) return const SizedBox.shrink();
    return SectionCard(
      title: 'Overdue Loans (${(d['overdueLoans'] as List).length})',
      actions: [TextButton(onPressed: () => context.push('/loans/overdue'), child: const Text('View all'))],
      child: Column(
        children: [
          ...list.map((l) {
            final m = Map<String, dynamic>.from(l as Map);
            final cust = Map<String, dynamic>.from(m['customer'] ?? {});
            final count = toNum(m['overdueCount']).toInt();
            return ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              onTap: () => context.push('/loans/${m['id']}'),
              leading: const Icon(Icons.warning_amber, color: AppColors.danger),
              title: Text('${cust['firstName'] ?? ''} ${cust['lastName'] ?? ''}'.trim()),
              subtitle: Text('${m['loanNumber'] ?? ''} · ${m['loanType'] ?? ''} · $count EMI${count == 1 ? '' : 's'} overdue', style: const TextStyle(fontSize: 11)),
              trailing: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(formatCurrency(m['overdueAmount']), style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.danger)),
                  Text('Since ${formatDate(m['oldestDueDate'])}', style: const TextStyle(fontSize: 10, color: AppColors.textSecondary)),
                ],
              ),
            );
          }),
          const Divider(),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              const Text('Total overdue: ', style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
              Text(formatCurrency(d['totalOverdue']), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: AppColors.danger)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _upcomingOverdueCard(BuildContext context, Map<String, dynamic> d, bool isAdmin) {
    final upcoming = Map<String, dynamic>.from(d['upcomingEMIs'] ?? {});
    final pendingCount = toNum(d['pendingVerificationCount']);
    return SectionCard(
      title: 'Upcoming & Overdue',
      child: Column(
        children: [
          _iconRow(
            icon: Icons.warning_amber,
            iconColor: AppColors.danger,
            label: 'Total Overdue',
            value: formatCurrency(d['totalOverdue']),
            valueColor: AppColors.danger,
            trailing: OutlinedButton(onPressed: () => context.push('/loans/overdue'), child: const Text('View')),
          ),
          _iconRow(
            icon: Icons.currency_rupee,
            iconColor: AppColors.primary,
            label: "This Month's Collections",
            value: formatCurrency(d['totalCollectionsThisMonth']),
          ),
          if (isAdmin && pendingCount > 0)
            _iconRow(
              icon: Icons.shield_outlined,
              iconColor: AppColors.warning,
              label: 'Pending Verification',
              value: '${pendingCount.toInt()} collections · ${formatCurrency(d['pendingVerificationAmount'])}',
              trailing: OutlinedButton(onPressed: () => context.push('/collections/verify'), child: const Text('Verify')),
            ),
          _iconRow(
            icon: Icons.arrow_upward,
            iconColor: Colors.orange,
            label: 'Upcoming EMIs (next 7 days)',
            value: '${upcoming['count'] ?? 0} EMIs',
            trailing: Text(formatCurrency(upcoming['totalAmount']), style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  Widget _iconRow({required IconData icon, required Color iconColor, required String label, required String value, Color? valueColor, Widget? trailing}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: iconColor.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
            child: Icon(icon, size: 18, color: iconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                Text(value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: valueColor)),
              ],
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }

  Widget _loansByTypeCard(Map<String, dynamic> d) {
    final items = ((d['loansByType'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    final maxCount = items.isEmpty ? 1 : items.map((e) => toNum(e['count'])).reduce((a, b) => a > b ? a : b);
    return SectionCard(
      title: 'Loans by Type',
      child: items.isEmpty
          ? const EmptyView(message: 'No loan data yet', icon: Icons.request_quote_outlined)
          : Column(
              children: items.map((item) {
                final count = toNum(item['count']);
                final ratio = maxCount > 0 ? (count / maxCount).toDouble() : 0.0;
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Expanded(child: Text(item['type']?.toString() ?? '', style: const TextStyle(fontWeight: FontWeight.w500))),
                          Text('${count.toInt()}', style: const TextStyle(fontWeight: FontWeight.w700)),
                          const SizedBox(width: 8),
                          SizedBox(width: 80, child: Text(formatCurrency(item['amount']), textAlign: TextAlign.right, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary))),
                        ],
                      ),
                      const SizedBox(height: 4),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: ratio,
                          minHeight: 6,
                          backgroundColor: AppColors.bg,
                          valueColor: const AlwaysStoppedAnimation(AppColors.primary),
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
    );
  }

  Widget _loansByStatusCard(Map<String, dynamic> d) {
    final items = ((d['loansByStatus'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    return SectionCard(
      title: 'Loans by Status',
      child: items.isEmpty
          ? const EmptyView(message: 'No loan data yet', icon: Icons.request_quote_outlined)
          : Column(
              children: items.map((item) {
                final status = item['status']?.toString() ?? '';
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(10)),
                    child: Row(
                      children: [
                        StatusChip(label: status, color: statusColor(status)),
                        const Spacer(),
                        Text('${toNum(item['count']).toInt()}', style: const TextStyle(fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
    );
  }

  Widget _monthlyCollectionsChart(Map<String, dynamic> d) {
    final items = ((d['monthlyCollectionTrend'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    return SectionCard(
      title: 'Monthly Collections',
      child: SizedBox(
        height: 200,
        child: items.isEmpty
            ? const EmptyView(message: 'No collection data yet', icon: Icons.trending_up)
            : LineChart(
                LineChartData(
                  gridData: const FlGridData(show: true, drawVerticalLine: false),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 40,
                        getTitlesWidget: (v, _) => Text(_shortNum(v), style: const TextStyle(fontSize: 10, color: AppColors.textSecondary)),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        interval: 1,
                        getTitlesWidget: (v, _) {
                          final i = v.toInt();
                          if (i < 0 || i >= items.length) return const SizedBox.shrink();
                          final month = items[i]['month']?.toString() ?? '';
                          return Padding(padding: const EdgeInsets.only(top: 6), child: Text(month.split(' ').first, style: const TextStyle(fontSize: 10, color: AppColors.textSecondary)));
                        },
                      ),
                    ),
                  ),
                  lineBarsData: [
                    LineChartBarData(
                      spots: [for (var i = 0; i < items.length; i++) FlSpot(i.toDouble(), toNum(items[i]['amount']).toDouble())],
                      isCurved: true,
                      color: AppColors.primary,
                      barWidth: 2.5,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(show: true, color: AppColors.primary.withValues(alpha: 0.15)),
                    ),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _monthlyDisbursementsChart(Map<String, dynamic> d) {
    final items = ((d['monthlyDisbursementTrend'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    return SectionCard(
      title: 'Total Loan Disbursed',
      child: SizedBox(
        height: 200,
        child: items.isEmpty
            ? const EmptyView(message: 'No disbursement data yet', icon: Icons.account_balance_wallet_outlined)
            : BarChart(
                BarChartData(
                  alignment: BarChartAlignment.spaceAround,
                  gridData: const FlGridData(show: true, drawVerticalLine: false),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 40,
                        getTitlesWidget: (v, _) => Text(_shortNum(v), style: const TextStyle(fontSize: 10, color: AppColors.textSecondary)),
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        interval: 1,
                        getTitlesWidget: (v, _) {
                          final i = v.toInt();
                          if (i < 0 || i >= items.length) return const SizedBox.shrink();
                          final month = items[i]['month']?.toString() ?? '';
                          return Padding(padding: const EdgeInsets.only(top: 6), child: Text(month.split(' ').first, style: const TextStyle(fontSize: 10, color: AppColors.textSecondary)));
                        },
                      ),
                    ),
                  ),
                  barGroups: [
                    for (var i = 0; i < items.length; i++)
                      BarChartGroupData(x: i, barRods: [
                        BarChartRodData(
                          toY: toNum(items[i]['amount']).toDouble(),
                          color: AppColors.primary,
                          width: 16,
                          borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                        ),
                      ])
                  ],
                ),
              ),
      ),
    );
  }

  String _shortNum(double v) {
    if (v.abs() >= 10000000) return '${(v / 10000000).toStringAsFixed(1)}Cr';
    if (v.abs() >= 100000) return '${(v / 100000).toStringAsFixed(1)}L';
    if (v.abs() >= 1000) return '${(v / 1000).toStringAsFixed(0)}K';
    return v.toStringAsFixed(0);
  }
}

// Drill-down behind the chit "To Be Collected" card: who still owes and which chit.
// Lazy-loads GET /dashboard/chit-dues on open (the backend scopes a field officer's
// view to the chits assigned to them). Tapping a chit/member jumps to that chit.
class ChitDuesSheet extends ConsumerStatefulWidget {
  const ChitDuesSheet({super.key});
  @override
  ConsumerState<ChitDuesSheet> createState() => _ChitDuesSheetState();
}

class _ChitDuesSheetState extends ConsumerState<ChitDuesSheet> {
  bool _loading = true;
  bool _error = false;
  Map<String, dynamic>? _data;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = false; });
    try {
      final d = await ref.read(apiClientProvider).get('/dashboard/chit-dues');
      if (mounted) setState(() { _data = Map<String, dynamic>.from(d as Map); _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _error = true; _loading = false; });
    }
  }

  void _goChit(String id) {
    final router = GoRouter.of(context);
    Navigator.of(context).pop();
    router.push('/chitfunds/$id');
  }

  // Deep-link straight to a member's payment history: open the chit's Members tab and pop
  // that member's transactions popup (consumed by ChitfundDetailPage via query params).
  void _goMember(String chitfundId, String memberId) {
    final router = GoRouter.of(context);
    Navigator.of(context).pop();
    router.push('/chitfunds/$chitfundId?tab=members&member=$memberId');
  }

  @override
  Widget build(BuildContext context) {
    final chits = ((_data?['chits'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          Container(margin: const EdgeInsets.only(top: 10), width: 40, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
            child: Row(
              children: [
                const Expanded(child: Text('To Be Collected', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const LoadingView()
                : _error
                    ? ErrorView(message: "Couldn't load dues. Please try again.", onRetry: _load)
                    : chits.isEmpty
                        ? const EmptyView(message: "Everyone's paid up — nothing to collect.", icon: Icons.verified_outlined)
                        : ListView(
                            padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
                            children: [
                              _totals(),
                              const SizedBox(height: 12),
                              ...chits.map(_chitGroup),
                            ],
                          ),
          ),
        ],
      ),
    );
  }

  Widget _totals() {
    final d = _data!;
    final memberCount = toNum(d['memberCount']).toInt();
    return Row(
      children: [
        Expanded(child: _totalTile('Old Dues', formatCurrency(d['oldDues']), AppColors.danger)),
        const SizedBox(width: 8),
        Expanded(child: _totalTile('This Month', formatCurrency(d['currentMonthDue']), AppColors.warning)),
        const SizedBox(width: 8),
        Expanded(child: _totalTile('Total · $memberCount', formatCurrency(d['totalToCollect']), AppColors.danger)),
      ],
    );
  }

  Widget _totalTile(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
      decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(12)),
      child: Column(
        children: [
          Text(label, style: const TextStyle(fontSize: 10, color: AppColors.textSecondary), textAlign: TextAlign.center),
          const SizedBox(height: 4),
          Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: color), textAlign: TextAlign.center),
        ],
      ),
    );
  }

  Widget _chitGroup(Map<String, dynamic> g) {
    final members = ((g['members'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    final id = g['chitfundId'].toString();
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: () => _goChit(id),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: const BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
              child: Row(
                children: [
                  const Icon(Icons.account_balance_wallet_outlined, size: 18, color: Color(0xFF14B8A6)),
                  const SizedBox(width: 8),
                  Expanded(child: Text('${g['chitName'] ?? ''}  #${g['chitNumber'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis)),
                  Text(formatCurrency(g['totalDue']), style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.danger)),
                  const Icon(Icons.chevron_right, size: 18, color: AppColors.textMuted),
                ],
              ),
            ),
          ),
          ...members.map((m) {
            final old = toNum(m['oldDues']);
            final cur = toNum(m['currentMonthDue']);
            final sub = <String>[];
            if (old > 0) sub.add('Old ${formatCurrency(old)}');
            if (cur > 0) sub.add('This month ${formatCurrency(cur)}');
            final name = m['customerName']?.toString() ?? '';
            final ticket = m['ticketNumber'];
            final avatarLabel = ticket != null ? '$ticket' : (name.isEmpty ? '?' : name[0].toUpperCase());
            return ListTile(
              dense: true,
              onTap: () => _goMember(id, m['memberId'].toString()),
              leading: CircleAvatar(
                radius: 15,
                backgroundColor: AppColors.danger.withValues(alpha: 0.1),
                child: Text(avatarLabel, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.danger)),
              ),
              title: Text(name.isEmpty ? 'Member' : name, style: const TextStyle(fontSize: 13)),
              subtitle: sub.isEmpty ? null : Text(sub.join(' · '), style: const TextStyle(fontSize: 11)),
              trailing: Text(formatCurrency(m['totalDue']), style: const TextStyle(fontWeight: FontWeight.w700)),
            );
          }),
        ],
      ),
    );
  }
}

// Drill-down behind the "Auctions To Conduct" chit stat tile: which chits have an
// auction scheduled for today or overdue. Reuses the auctions already in the dashboard
// payload (the same list as the Auctions To Conduct card) — no extra fetch needed.
// Tapping a row jumps to that chit, where the auction is conducted. Shown to every
// persona since the stat tile is role-agnostic; the backend scopes the payload per role.
class AuctionsSheet extends StatelessWidget {
  const AuctionsSheet({super.key, required this.auctions});
  final List<Map<String, dynamic>> auctions;

  void _goChit(BuildContext context, String id) {
    final router = GoRouter.of(context);
    Navigator.of(context).pop();
    router.push('/chitfunds/$id');
  }

  @override
  Widget build(BuildContext context) {
    final overdue = auctions.where((a) => a['overdue'] == true).length;
    final today = auctions.length - overdue;
    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        children: [
          Container(margin: const EdgeInsets.only(top: 10), width: 40, height: 4, decoration: BoxDecoration(color: AppColors.border, borderRadius: BorderRadius.circular(2))),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 6),
            child: Row(
              children: [
                const Expanded(child: Text('Auctions To Conduct', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800))),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.of(context).pop()),
              ],
            ),
          ),
          Expanded(
            child: auctions.isEmpty
                ? const EmptyView(message: "No auctions due — you're all caught up.", icon: Icons.gavel_outlined)
                : ListView(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 24),
                    children: [
                      Row(
                        children: [
                          Expanded(child: _totalTile('Due Today', '$today', AppColors.warning)),
                          const SizedBox(width: 8),
                          Expanded(child: _totalTile('Overdue', '$overdue', AppColors.danger)),
                          const SizedBox(width: 8),
                          Expanded(child: _totalTile('Total', '${auctions.length}', const Color(0xFF7C3AED))),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Card(
                        margin: EdgeInsets.zero,
                        child: Column(
                          children: auctions.map((a) {
                            final isOverdue = a['overdue'] == true;
                            return ListTile(
                              dense: true,
                              onTap: () => _goChit(context, a['chitfundId'].toString()),
                              leading: CircleAvatar(
                                radius: 16,
                                backgroundColor: const Color(0xFF7C3AED).withValues(alpha: 0.1),
                                child: const Icon(Icons.gavel, size: 16, color: Color(0xFF7C3AED)),
                              ),
                              title: Text('${a['chitName'] ?? ''}${a['chitNumber'] != null ? '  #${a['chitNumber']}' : ''}',
                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                              subtitle: Text('Month ${a['monthNumber']} · ${formatDate(a['auctionDate'])}', style: const TextStyle(fontSize: 11)),
                              trailing: StatusChip(
                                label: isOverdue ? 'Overdue' : 'Today',
                                color: isOverdue ? AppColors.danger : AppColors.warning,
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _totalTile(String label, String value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
      decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(12)),
      child: Column(
        children: [
          Text(label, style: const TextStyle(fontSize: 10, color: AppColors.textSecondary), textAlign: TextAlign.center),
          const SizedBox(height: 4),
          Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: color), textAlign: TextAlign.center),
        ],
      ),
    );
  }
}

final unreadCountProvider = FutureProvider.autoDispose<int>((ref) async {
  try {
    final api = ref.read(apiClientProvider);
    final d = await api.get('/notifications/unread-count');
    if (d is Map) return (d['count'] as num?)?.toInt() ?? 0;
    return 0;
  } catch (_) { return 0; }
});

class _NotificationsBell extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(unreadCountProvider).maybeWhen(data: (v) => v, orElse: () => 0);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(
          tooltip: 'Notifications',
          icon: const Icon(Icons.notifications_outlined),
          onPressed: () => context.push('/notifications'),
        ),
        if (count > 0)
          Positioned(
            right: 6,
            top: 6,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: AppColors.danger,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white, width: 1.5),
              ),
              constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
              child: Text(
                count > 99 ? '99+' : '$count',
                style: const TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.w700),
                textAlign: TextAlign.center,
              ),
            ),
          ),
      ],
    );
  }
}

// Today/All scope pill for the Pending Verification cards. 'all' shows the full
// pending backlog; 'today' narrows to collections made today (the API sends both
// slices, so switching never refetches).
class _PvScopeToggle extends StatelessWidget {
  final String scope;
  final ValueChanged<String> onChanged;
  const _PvScopeToggle({required this.scope, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(8)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (value, label) in const [('today', 'Today'), ('all', 'All')])
            GestureDetector(
              onTap: () => onChanged(value),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: scope == value ? Colors.white : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                  boxShadow: scope == value
                      ? [BoxShadow(color: Colors.black.withValues(alpha: 0.08), blurRadius: 2)]
                      : null,
                ),
                child: Text(label, style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: scope == value ? AppColors.textPrimary : AppColors.textSecondary,
                )),
              ),
            ),
        ],
      ),
    );
  }
}

// Field officer's Pending Verification list with the Today/All scope toggle.
class _PendingVerificationListCard extends StatefulWidget {
  final Map<String, dynamic> d;
  const _PendingVerificationListCard({required this.d});
  @override
  State<_PendingVerificationListCard> createState() => _PendingVerificationListCardState();
}

class _PendingVerificationListCardState extends State<_PendingVerificationListCard> {
  String _scope = 'all';

  bool _collectedToday(Map<String, dynamic> m) {
    final x = DateTime.tryParse(m['collectedAt']?.toString() ?? '')?.toLocal();
    if (x == null) return false;
    final n = DateTime.now();
    return x.year == n.year && x.month == n.month && x.day == n.day;
  }

  // Field officers don't receive the pre-combined pending-verification total (it's
  // computed admin-only server-side), so sum the per-source loan + chit figures; fall
  // back to the combined field when the per-source figures aren't present.
  num get _count {
    final d = widget.d;
    if (_scope == 'today') {
      return toNum(d['pendingVerificationLoanTodayCount']) + toNum(d['pendingVerificationChitTodayCount']);
    }
    final loan = toNum(d['pendingVerificationLoanCount']);
    final chit = toNum(d['pendingVerificationChitCount']);
    if (loan > 0 || chit > 0) return loan + chit;
    return toNum(d['pendingVerificationCount']);
  }

  num get _amount {
    final d = widget.d;
    if (_scope == 'today') {
      return toNum(d['pendingVerificationLoanTodayAmount']) + toNum(d['pendingVerificationChitTodayAmount']);
    }
    final loan = toNum(d['pendingVerificationLoanAmount']);
    final chit = toNum(d['pendingVerificationChitAmount']);
    if (loan > 0 || chit > 0) return loan + chit;
    return toNum(d['pendingVerificationAmount']);
  }

  @override
  Widget build(BuildContext context) {
    final all = ((widget.d['pendingCollections'] as List?) ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
    // Card visibility follows the full backlog so toggling to an empty Today
    // view never hides the toggle itself.
    if (all.isEmpty) return const SizedBox.shrink();
    final rows = _scope == 'today' ? all.where(_collectedToday).toList() : all;
    // True count from the API (uncapped); the list below shows only the most recent.
    final count = _count;
    final amount = _amount;
    final badgeCount = count > 0 ? count.toInt() : rows.length;
    return SectionCard(
      title: 'Pending Verification ($badgeCount)',
      actions: [_PvScopeToggle(scope: _scope, onChanged: (v) => setState(() => _scope = v))],
      child: Column(
        children: [
          if (rows.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Text(
                'Nothing collected today is pending verification',
                style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
            ),
          ...rows.map((m) {
            final cust = Map<String, dynamic>.from(m['customer'] ?? {});
            final loan = Map<String, dynamic>.from(m['loan'] ?? {});
            final isChit = m['sourceType'] == 'CHITFUND';
            final chit = Map<String, dynamic>.from(m['chitfund'] ?? {});
            final ref = isChit
                ? 'Chit ${chit['chitNumber'] ?? chit['name'] ?? ''}${m['monthNumber'] != null ? ' · M${m['monthNumber']}' : ''}'
                : 'Loan #${loan['loanNumber'] ?? '-'}';
            return ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              leading: const Icon(Icons.shield_outlined, color: AppColors.warning),
              title: Text('${cust['firstName'] ?? ''} ${cust['lastName'] ?? ''}'.trim()),
              subtitle: Text('$ref · ${m['receiptNumber'] ?? '-'}', style: const TextStyle(fontSize: 11)),
              trailing: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(formatCurrency(m['amount']), style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text(formatDate(m['collectedAt']), style: const TextStyle(fontSize: 10, color: AppColors.textSecondary)),
                ],
              ),
            );
          }),
          // Running total of everything awaiting verification in this scope
          // (uncapped) — mirrors the admin card so field officers see it too.
          if (amount > 0) ...[
            const Divider(),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  const Text('Total: ', style: TextStyle(fontSize: 13, color: AppColors.warning)),
                  Text(formatCurrency(amount), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: AppColors.warning)),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// Admin Pending Verification card grouped by field agent, with the Today/All
// scope toggle. Each pendingByAgent entry carries both the all-time and the
// today-collected slice, so switching scopes never refetches.
class _PendingVerificationByAgentCard extends StatefulWidget {
  final Map<String, dynamic> d;
  const _PendingVerificationByAgentCard({required this.d});
  @override
  State<_PendingVerificationByAgentCard> createState() => _PendingVerificationByAgentCardState();
}

class _PendingVerificationByAgentCardState extends State<_PendingVerificationByAgentCard> {
  String _scope = 'all';

  @override
  Widget build(BuildContext context) {
    final today = _scope == 'today';
    // Use server-grouped pendingByAgent for accurate totals.
    final agents = ((widget.d['pendingByAgent'] as List?) ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .map((a) => (
              agent: a,
              count: toNum(a[today ? 'todayCount' : 'count']),
              total: toNum(a[today ? 'todayTotal' : 'total']),
            ))
        .where((s) => s.count > 0)
        .toList();
    final headline = today
        ? toNum(widget.d['pendingVerificationLoanTodayCount']) + toNum(widget.d['pendingVerificationChitTodayCount'])
        : toNum(widget.d['pendingVerificationCount']);
    return SectionCard(
      title: 'Pending Verification (${headline.toInt()})',
      actions: [
        _PvScopeToggle(scope: _scope, onChanged: (v) => setState(() => _scope = v)),
        if (agents.isNotEmpty)
          TextButton(onPressed: () => context.push('/collections/verify'), child: const Text('Verify all')),
      ],
      child: agents.isEmpty
          ? EmptyView(
              message: today ? 'Nothing collected today is pending verification' : 'No collections pending verification',
              icon: Icons.shield_outlined,
            )
          : Column(
              children: agents.map((s) {
                final a = s.agent;
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  onTap: () => context.push('/collections/verify?collectedById=${a['id']}&name=${Uri.encodeComponent(a['name']?.toString() ?? '')}'),
                  leading: Avatar(url: a['photo']?.toString(), name: a['name']?.toString() ?? 'U', size: 32),
                  title: Text(a['name']?.toString() ?? 'Unknown'),
                  subtitle: Text('${s.count.toInt()} collection${s.count.toInt() == 1 ? '' : 's'}', style: const TextStyle(fontSize: 11)),
                  trailing: Text(formatCurrency(s.total), style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.warning)),
                );
              }).toList(),
            ),
    );
  }
}

