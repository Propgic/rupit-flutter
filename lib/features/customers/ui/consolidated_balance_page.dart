import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/common.dart';
import '../data/customer_repo.dart';
import '../../app_shell.dart';
import '../../../core/widgets/app_bottom_nav.dart';

const _monthNames = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

/// The monthly khata balance sheet (legacy SVRMMS structure), per calendar
/// month: P.M.C (chit dues), BD (auction bid), I.R (loan interest), OB (carry),
/// Grand Total, Paid, Issue and Balance per customer — with the legacy P A
/// (receive payment) / I A (issue against pending payouts) quick entry for
/// admins/managers, and row tap → the customer's full khata statement.
/// Backend: GET /customers/consolidated-balances ({ data, pagination, summary }).
class ConsolidatedBalanceSheetPage extends ConsumerStatefulWidget {
  const ConsolidatedBalanceSheetPage({super.key});
  @override
  ConsumerState<ConsolidatedBalanceSheetPage> createState() => _ConsolidatedBalanceSheetPageState();
}

class _ConsolidatedBalanceSheetPageState extends ConsumerState<ConsolidatedBalanceSheetPage> {
  final _scroll = ScrollController();
  final _searchCtrl = TextEditingController();
  final List<Map<String, dynamic>> _items = [];
  Map<String, dynamic> _summary = const {};
  int _page = 1;
  int _total = 0;
  bool _loading = false;
  bool _hasMore = true;
  String? _search;
  Object? _error;
  Timer? _debounce;
  late int _month;
  late int _year;

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _month = now.month;
    _year = now.year;
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 300 && !_loading && _hasMore) {
        _load();
      }
    });
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _scroll.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      if (reset) {
        _items.clear();
        _page = 1;
        _hasMore = true;
        _error = null;
      }
    });
    try {
      final res = await ref.read(customerRepoProvider).consolidatedBalances(params: {
        'page': _page,
        'limit': 20,
        'month': _month,
        'year': _year,
        if (_search != null && _search!.isNotEmpty) 'search': _search,
      });
      final data = (res['data'] as List?) ?? const [];
      final pagination = Map<String, dynamic>.from(res['pagination'] ?? {});
      setState(() {
        _items.addAll(data.map((e) => Map<String, dynamic>.from(e as Map)));
        _summary = (res['summary'] is Map) ? Map<String, dynamic>.from(res['summary'] as Map) : const {};
        _total = (pagination['total'] as num?)?.toInt() ?? _items.length;
        _page += 1;
        final totalPages = (pagination['totalPages'] as num?)?.toInt() ?? 1;
        _hasMore = _page <= totalPages;
      });
    } catch (e) {
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onSearchChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      _search = v.trim().isEmpty ? null : v.trim();
      _load(reset: true);
    });
  }

  // Legacy "P A" / "I A": receive a lump payment (auto-allocated across chit
  // then loan dues) or issue cash against pending auction payouts.
  Future<void> _quickEntry(Map<String, dynamic> c, {required bool isPay}) async {
    final amountCtrl = TextEditingController();
    String mode = 'CASH';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          title: Text('${isPay ? 'Receive Payment' : 'Issue Amount'} — ${c['customerName']}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: amountCtrl,
                autofocus: true,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(labelText: isPay ? 'Amount Paid' : 'Issue Amount', prefixText: '₹ '),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: mode,
                decoration: const InputDecoration(labelText: 'Mode'),
                items: const [
                  DropdownMenuItem(value: 'CASH', child: Text('Cash')),
                  DropdownMenuItem(value: 'UPI', child: Text('UPI')),
                  DropdownMenuItem(value: 'BANK_TRANSFER', child: Text('Bank Transfer')),
                ],
                onChanged: (v) => setDlg(() => mode = v ?? 'CASH'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              style: isPay ? null : FilledButton.styleFrom(backgroundColor: AppColors.danger),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(isPay ? 'P A — Save' : 'I A — Save'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final amount = num.tryParse(amountCtrl.text.trim());
    if (amount == null || amount <= 0) {
      showToast('Enter a valid amount', error: true);
      return;
    }
    try {
      final repo = ref.read(customerRepoProvider);
      final res = isPay
          ? await repo.sheetPayment(c['id'].toString(), amount, paymentMode: mode)
          : await repo.sheetIssue(c['id'].toString(), amount, paymentMode: mode);
      if (!mounted) return;
      final detail = isPay
          ? ((res['allocations'] as List?) ?? const [])
              .map((a) => '${a['name'] ?? a['type']}: ${formatCurrency(a['amount'])}')
              .join(', ')
          : ((res['settled'] as List?) ?? const [])
              .map((s) => 'M${s['monthNumber']}: ${formatCurrency(s['amount'])}')
              .join(', ');
      showToast('${isPay ? 'Received' : 'Issued'} ${formatCurrency(amount)}${detail.isEmpty ? '' : ' ($detail)'}');
      _load(reset: true);
    } catch (e) {
      showToast(e.toString(), error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final role = auth.user?.role;
    final canQuickEntry = role == 'ORG_ADMIN' || role == 'MANAGER';
    return Scaffold(
      drawer: const AppDrawer(),
      bottomNavigationBar: const AppBottomNav(),
      appBar: AppBar(
        title: const Text('Balance Sheet'),
        leading: Builder(
          builder: (ctx) => IconButton(icon: const Icon(Icons.menu), onPressed: () => Scaffold.of(ctx).openDrawer()),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: Row(
              children: [
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: _month,
                    isDense: true,
                    decoration: const InputDecoration(labelText: 'Month'),
                    items: [for (var i = 1; i <= 12; i++) DropdownMenuItem(value: i, child: Text(_monthNames[i - 1]))],
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() => _month = v);
                      _load(reset: true);
                    },
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 110,
                  child: DropdownButtonFormField<int>(
                    initialValue: _year,
                    isDense: true,
                    decoration: const InputDecoration(labelText: 'Year'),
                    items: [
                      for (var y = DateTime.now().year + 1; y >= 2015; y--) DropdownMenuItem(value: y, child: Text('$y'))
                    ],
                    onChanged: (v) {
                      if (v == null) return;
                      setState(() => _year = v);
                      _load(reset: true);
                    },
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchCtrl,
              decoration: InputDecoration(
                hintText: 'Search by customer name or ID...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchCtrl.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _searchCtrl.clear();
                          _search = null;
                          _load(reset: true);
                        },
                      ),
              ),
              onChanged: (v) {
                setState(() {});
                _onSearchChanged(v);
              },
            ),
          ),
          if (_items.isNotEmpty) _summaryBar(),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => _load(reset: true),
              child: _error != null && _items.isEmpty
                  ? ErrorView(message: _error.toString(), onRetry: () => _load(reset: true))
                  : _items.isEmpty && !_loading
                      ? const EmptyView(message: 'No customers found', icon: Icons.account_balance_outlined)
                      : ListView.builder(
                          controller: _scroll,
                          itemCount: _items.length + (_loading ? 1 : 0),
                          itemBuilder: (ctx, i) {
                            if (i >= _items.length) {
                              return const Padding(
                                padding: EdgeInsets.all(16),
                                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                              );
                            }
                            return _row(_items[i], canQuickEntry);
                          },
                        ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryBar() {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.primarySoft,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          _summaryItem('Customers', _total.toString()),
          _summaryItem('P.M.C', formatCurrency(_summary['pmcAmt'])),
          _summaryItem('Grand Total', formatCurrency(_summary['grandTotal'])),
          _summaryItem('Paid', formatCurrency(_summary['paidAmt']), color: AppColors.accent),
          _summaryItem('Balance', formatCurrency(_summary['monthBalance']), color: AppColors.danger),
        ],
      ),
    );
  }

  Widget _summaryItem(String label, String value, {Color? color}) {
    return Expanded(
      child: Column(
        children: [
          Text(label, style: const TextStyle(fontSize: 10, color: AppColors.textSecondary)),
          const SizedBox(height: 2),
          Text(
            value,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color),
          ),
        ],
      ),
    );
  }

  Widget _figure(String label, dynamic value, {Color? color, bool bold = false}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 10, color: AppColors.textSecondary)),
        Text(
          formatCurrency(value),
          style: TextStyle(fontSize: 12.5, fontWeight: bold ? FontWeight.w800 : FontWeight.w600, color: color),
        ),
      ],
    );
  }

  Widget _row(Map<String, dynamic> c, bool canQuickEntry) {
    final name = c['customerName']?.toString() ?? '';
    final phone = c['phone']?.toString() ?? '';
    final tg = toNum(c['tg']);
    final groups = c['groups']?.toString() ?? '';
    final balance = toNum(c['monthBalance']);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: InkWell(
        onTap: () => context.push('/consolidated-balance/${c['id']}'),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
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
                        Text(name, style: const TextStyle(fontWeight: FontWeight.w700)),
                        if (phone.isNotEmpty)
                          Text(phone, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                        if (groups.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              // Half tickets appear as "10L-E(0.5)" — legacy notation.
                              'TG ${tg % 1 == 0 ? tg.toInt() : tg} · $groups',
                              style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        formatCurrency(balance),
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: balance > 0 ? AppColors.danger : AppColors.accent,
                        ),
                      ),
                      const Text('Balance', style: TextStyle(fontSize: 10, color: AppColors.textSecondary)),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: _figure('P.M.C', c['pmcAmt'])),
                  Expanded(child: _figure('BD', c['bdAmt'])),
                  Expanded(child: _figure('I.R', c['irAmt'])),
                  Expanded(child: _figure('OB', c['ob'], color: toNum(c['ob']) < 0 ? AppColors.accent : null)),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Expanded(child: _figure('Grand Total', c['grandTotal'], bold: true)),
                  Expanded(child: _figure('Paid', c['paidAmt'], color: AppColors.accent)),
                  Expanded(child: _figure('Issue', c['issueAmt'], color: AppColors.warning)),
                  if (canQuickEntry)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          height: 30,
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: AppColors.accent,
                              padding: const EdgeInsets.symmetric(horizontal: 10),
                              visualDensity: VisualDensity.compact,
                            ),
                            onPressed: () => _quickEntry(c, isPay: true),
                            child: const Text('P A', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
                          ),
                        ),
                        const SizedBox(width: 6),
                        SizedBox(
                          height: 30,
                          child: FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: AppColors.danger,
                              padding: const EdgeInsets.symmetric(horizontal: 10),
                              visualDensity: VisualDensity.compact,
                            ),
                            onPressed: () => _quickEntry(c, isPay: false),
                            child: const Text('I A', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800)),
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
