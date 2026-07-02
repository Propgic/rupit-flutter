import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/common.dart';
import '../../chitfunds/ui/chitfund_profit_panel.dart';

// Per-chit returns report (a P&L for one chit fund): the foreman commission income from
// conducted auctions, netted against expenses booked under the chit, plus the operational
// cash-flow context (member collections in, winner payouts out — pass-through, not income).
// Backed by GET /chitfunds/:id/returns. Mirrors the web ChitfundReturnsReport.
const _chartColors = [
  Color(0xFF6366F1), Color(0xFF10B981), Color(0xFFF59E0B), Color(0xFFEF4444),
  Color(0xFF8B5CF6), Color(0xFF06B6D4), Color(0xFFEC4899), Color(0xFF84CC16),
];

class ChitfundReturnsReportPage extends ConsumerStatefulWidget {
  const ChitfundReturnsReportPage({super.key});
  @override
  ConsumerState<ChitfundReturnsReportPage> createState() => _ChitfundReturnsReportPageState();
}

class _ChitfundReturnsReportPageState extends ConsumerState<ChitfundReturnsReportPage> {
  List<Map<String, dynamic>> _chits = [];
  String? _selectedId;
  Map<String, dynamic>? _report;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadChits();
  }

  Future<void> _loadChits() async {
    try {
      final d = await ref.read(apiClientProvider).get('/chitfunds', query: {'limit': 200});
      if (mounted) setState(() => _chits = extractList(d).map((e) => Map<String, dynamic>.from(e as Map)).toList());
    } catch (_) {}
  }

  Future<void> _loadReport(String? id) async {
    if (id == null) { setState(() => _report = null); return; }
    setState(() => _loading = true);
    try {
      final d = await ref.read(apiClientProvider).get('/chitfunds/$id/returns');
      if (mounted) setState(() => _report = Map<String, dynamic>.from(d as Map));
    } catch (_) {
      if (mounted) setState(() => _report = null);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Chit Returns Report')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          SectionCard(
            title: 'Select a chit fund',
            child: DropdownButtonFormField<String?>(
              value: _selectedId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Chit fund'),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('Choose a chit fund…')),
                ..._chits.map((c) => DropdownMenuItem<String?>(
                      value: c['id'].toString(),
                      child: Text('${c['name']} (${c['chitNumber']}) — ${c['status']}', overflow: TextOverflow.ellipsis),
                    )),
              ],
              onChanged: (v) { setState(() => _selectedId = v); _loadReport(v); },
            ),
          ),
          if (_selectedId == null)
            const Padding(
              padding: EdgeInsets.only(top: 40),
              child: EmptyView(message: 'Select a chit fund above to see its complete returns report.', icon: Icons.pie_chart_outline),
            )
          else if (_loading)
            const Padding(padding: EdgeInsets.only(top: 40), child: LoadingView())
          else if (_report == null)
            const Padding(
              padding: EdgeInsets.only(top: 40),
              child: Center(child: Text("Could not load this chit's report.", style: TextStyle(color: AppColors.textSecondary))),
            )
          else
            ..._reportBody(_report!),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  List<Widget> _reportBody(Map<String, dynamic> r) {
    final c = Map<String, dynamic>.from(r['chitfund'] ?? {});
    final income = Map<String, dynamic>.from(r['income'] ?? {});
    final expenses = Map<String, dynamic>.from(r['expenses'] ?? {});
    final profit = Map<String, dynamic>.from(r['profit'] ?? {});
    final cashflow = Map<String, dynamic>.from(r['cashflow'] ?? {});
    final expCount = toNum(expenses['count']).toInt();

    // DIP chits earn no commission — profit is the cash left after paying winners
    // (collections − payouts − expenses), so the P&L reads from the cash flow.
    final isDip = c['dividendType'] == 'DIP';
    final collectedVal = toNum(cashflow['totalCollected']).toDouble();
    final payoutVal = toNum(cashflow['totalPaidOut']).toDouble() + toNum(cashflow['pendingPayout']).toDouble();
    final grossVal = collectedVal - payoutVal;

    return [
      const SizedBox(height: 4),
      _hero(c, income),
      const SizedBox(height: 12),
      // Headline P&L
      if (isDip)
        _statCard(Icons.monetization_on_outlined, AppColors.accent, 'Retained from chit',
            formatCurrency(grossVal),
            '${formatCurrency(collectedVal)} collected − ${formatCurrency(payoutVal)} paid to winners')
      else
        _statCard(Icons.monetization_on_outlined, AppColors.accent, 'Income (Commission)',
            formatCurrency(income['commissionRealized']),
            '${formatCurrency(income['commissionPerMonth'])}/mo · projected ${formatCurrency(income['commissionProjected'])}'),
      _statCard(Icons.trending_down, AppColors.danger, 'Expenses Booked',
          formatCurrency(expenses['total']),
          '$expCount ${expCount == 1 ? 'entry' : 'entries'} under this chit'),
      _profitCard(profit),
      // Income → Expense → Profit visual
      _flowCard(isDip, income, expenses, profit, cashflow),
      // Profit withdrawals — taking the realised profit out of the chit
      if (_selectedId != null)
        ChitfundProfitPanel(
          chitfundId: _selectedId!,
          canWithdraw: ref.read(authProvider).hasRole('ORG_ADMIN'),
          chitName: c['name']?.toString(),
        ),
      // Expense breakdown
      _expenseBreakdownCard(expenses),
      // Cash-flow context
      _cashflowCard(isDip, cashflow),
      // Expense line items
      _expenseItemsCard(expenses),
    ];
  }

  Widget _hero(Map<String, dynamic> c, Map<String, dynamic> income) {
    final status = c['status']?.toString() ?? '';
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF4F46E5), Color(0xFF7C3AED), Color(0xFF6D28D9)],
        ),
        borderRadius: BorderRadius.circular(18),
        boxShadow: [BoxShadow(color: const Color(0xFF7C3AED).withValues(alpha: 0.3), blurRadius: 14, offset: const Offset(0, 5))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(c['name']?.toString() ?? '', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: Colors.white)),
                    const SizedBox(height: 4),
                    Text('#${c['chitNumber'] ?? ''} · Started ${formatDate(c['startDate'])}',
                        style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.75))),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(6)),
                child: Text(status, style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.white)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text('Chit Value: ${formatCurrency(c['totalAmount'])}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: Colors.white)),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _heroFact('Members', '${c['totalMembers'] ?? 0}'),
              _heroFact('Duration', '${c['durationMonths'] ?? 0} mo'),
              _heroFact('Commission', '${c['commissionPercent'] ?? 0}%'),
              _heroFact('Auctions Done', '${income['auctionsConducted'] ?? 0} / ${c['durationMonths'] ?? 0}'),
            ],
          ),
        ],
      ),
    );
  }

  Widget _heroFact(String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.75))),
          const SizedBox(height: 2),
          Text(value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
        ],
      ),
    );
  }

  Widget _statCard(IconData icon, Color tone, String label, String value, String sub) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(color: tone, borderRadius: BorderRadius.circular(12)),
              child: Icon(icon, color: Colors.white, size: 20),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label, style: const TextStyle(fontSize: 13, color: AppColors.textSecondary, fontWeight: FontWeight.w600)),
                  Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                  Text(sub, style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _profitCard(Map<String, dynamic> profit) {
    final net = toNum(profit['netRealized']);
    final positive = net >= 0;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: positive ? const [Color(0xFF4F46E5), Color(0xFF7C3AED)] : const [Color(0xFFE11D48), Color(0xFFDC2626)],
        ),
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text('Net Profit', style: TextStyle(fontSize: 13, color: Colors.white.withValues(alpha: 0.85), fontWeight: FontWeight.w600))),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(10)),
                child: const Icon(Icons.trending_up, color: Colors.white, size: 18),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(formatCurrency(net), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: Colors.white)),
          const SizedBox(height: 6),
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(color: Colors.white.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(20)),
                child: Text('${profit['marginRealized'] ?? 0}% margin', style: const TextStyle(fontSize: 11, color: Colors.white)),
              ),
              const SizedBox(width: 8),
              Text('projected ${formatCurrency(profit['netProjected'])}', style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.75))),
            ],
          ),
        ],
      ),
    );
  }

  Widget _flowCard(bool isDip, Map<String, dynamic> income, Map<String, dynamic> expenses, Map<String, dynamic> profit, Map<String, dynamic> cashflow) {
    final incomeVal = toNum(income['commissionRealized']).toDouble();
    final expenseVal = toNum(expenses['total']).toDouble();
    final profitVal = toNum(profit['netRealized']).toDouble();
    final collectedVal = toNum(cashflow['totalCollected']).toDouble();
    final payoutVal = toNum(cashflow['totalPaidOut']).toDouble() + toNum(cashflow['pendingPayout']).toDouble();
    // Scale the bars to the largest inflow so nothing overflows.
    final base = [isDip ? collectedVal : incomeVal, expenseVal + payoutVal + (profitVal > 0 ? profitVal : 0), 1.0].reduce((a, b) => a > b ? a : b);
    double frac(double v) => (v / base).clamp(0.0, 1.0);
    return SectionCard(
      title: 'How the profit is made (realised so far)',
      child: Column(
        children: [
          if (isDip) ...[
            _flowBar('Collected from members', collectedVal, frac(collectedVal), AppColors.accent),
            _flowBar('Less: paid to winners', -payoutVal, frac(payoutVal), const Color(0xFFF59E0B)),
          ] else
            _flowBar('Commission income', incomeVal, frac(incomeVal), AppColors.accent),
          _flowBar('Less: expenses', -expenseVal, frac(expenseVal), const Color(0xFFFB7185)),
          const Divider(height: 18),
          _flowBar('Net profit', profitVal, frac(profitVal > 0 ? profitVal : 0),
              profitVal >= 0 ? AppColors.primary : AppColors.danger, bold: true),
        ],
      ),
    );
  }

  Widget _flowBar(String label, double amount, double fraction, Color color, {bool bold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          SizedBox(
            width: 110,
            child: Text(label, style: TextStyle(fontSize: 12, fontWeight: bold ? FontWeight.w700 : FontWeight.w500, color: bold ? AppColors.textPrimary : AppColors.textSecondary)),
          ),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: fraction,
                minHeight: 16,
                backgroundColor: AppColors.bg,
                valueColor: AlwaysStoppedAnimation(color),
              ),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 86,
            child: Text(
              '${amount < 0 ? '−' : ''}${formatCurrency(amount.abs())}',
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color),
            ),
          ),
        ],
      ),
    );
  }

  Widget _expenseBreakdownCard(Map<String, dynamic> expenses) {
    final byCategory = ((expenses['byCategory'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    final total = toNum(expenses['total']);
    return SectionCard(
      title: 'Expense Breakdown',
      child: byCategory.isEmpty
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Center(child: Text('No expenses booked under this chit yet.', style: TextStyle(color: AppColors.textSecondary))),
            )
          : Column(
              children: [
                SizedBox(
                  height: 160,
                  child: PieChart(
                    PieChartData(
                      sectionsSpace: 2,
                      centerSpaceRadius: 40,
                      sections: [
                        for (var i = 0; i < byCategory.length; i++)
                          PieChartSectionData(
                            value: toNum(byCategory[i]['amount']).toDouble(),
                            color: _chartColors[i % _chartColors.length],
                            radius: 38,
                            showTitle: false,
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                ...List.generate(byCategory.length, (i) {
                  final e = byCategory[i];
                  final amt = toNum(e['amount']);
                  final pct = total > 0 ? (amt / total * 100) : 0;
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Container(width: 10, height: 10, decoration: BoxDecoration(color: _chartColors[i % _chartColors.length], shape: BoxShape.circle)),
                        const SizedBox(width: 8),
                        Expanded(child: Text(e['category']?.toString() ?? '—', overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
                        Text(formatCurrency(amt), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                        const SizedBox(width: 8),
                        SizedBox(width: 38, child: Text('${pct.toStringAsFixed(0)}%', textAlign: TextAlign.right, style: const TextStyle(fontSize: 11, color: AppColors.textMuted))),
                      ],
                    ),
                  );
                }),
              ],
            ),
    );
  }

  Widget _cashflowCard(bool isDip, Map<String, dynamic> cashflow) {
    return SectionCard(
      title: 'Cash Flow Context',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              isDip
                  ? 'Member money through the chit — the gap between money in and money out is the profit above.'
                  : 'Member money flowing through the chit — pass-through, not profit.',
              style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
            ),
          ),
          _cashflowRow(Icons.south_west, AppColors.accent, 'Collected from members', formatCurrency(cashflow['totalCollected'])),
          _cashflowRow(Icons.north_east, AppColors.danger, 'Paid out to winners', formatCurrency(cashflow['totalPaidOut'])),
          _cashflowRow(Icons.schedule, AppColors.warning, 'Payout pending', formatCurrency(cashflow['pendingPayout'])),
        ],
      ),
    );
  }

  Widget _cashflowRow(IconData icon, Color tone, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(color: tone, borderRadius: BorderRadius.circular(9)),
            child: Icon(icon, color: Colors.white, size: 16),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(label, style: const TextStyle(fontSize: 13, color: AppColors.textSecondary))),
          Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
        ],
      ),
    );
  }

  Widget _expenseItemsCard(Map<String, dynamic> expenses) {
    final items = ((expenses['items'] as List?) ?? const []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    return SectionCard(
      title: 'Expenses Booked Under This Chit',
      child: items.isEmpty
          ? const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(child: Text('No expenses recorded for this chit.', style: TextStyle(color: AppColors.textSecondary))),
            )
          : Column(
              children: [
                ...items.map((e) {
                  final month = e['monthNumber'];
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Flexible(child: Text(e['category']?.toString() ?? '—', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
                                  if (month != null) ...[
                                    const SizedBox(width: 6),
                                    StatusChip(label: 'Month $month', color: AppColors.info),
                                  ],
                                ],
                              ),
                              Text(
                                '${formatDate(e['expenseDate'])} · ${e['paymentMode'] ?? ''}${(e['description']?.toString().isNotEmpty ?? false) ? ' · ${e['description']}' : ''}',
                                style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(formatCurrency(e['amount']), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.danger)),
                      ],
                    ),
                  );
                }),
                const Divider(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    const Text('Total Expenses: ', style: TextStyle(fontSize: 13, color: AppColors.textSecondary)),
                    Text(formatCurrency(expenses['total']), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: AppColors.danger)),
                  ],
                ),
              ],
            ),
    );
  }
}
