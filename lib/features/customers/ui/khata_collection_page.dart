import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/common.dart';
import '../data/customer_repo.dart';
import '../../app_shell.dart';
import '../../../core/widgets/app_bottom_nav.dart';

/// The legacy SVRMMS "Collection" counter: pick a customer, their live
/// consolidated (khata) balance appears, take a lump payment — allocated across
/// chit dues then loan dues by the same engine as the balance sheet's P A.
class KhataCollectionPage extends ConsumerStatefulWidget {
  const KhataCollectionPage({super.key});
  @override
  ConsumerState<KhataCollectionPage> createState() => _KhataCollectionPageState();
}

class _KhataCollectionPageState extends ConsumerState<KhataCollectionPage> {
  final _amountCtrl = TextEditingController();
  final _searchCtrl = TextEditingController();
  Timer? _debounce;
  List<Map<String, dynamic>> _results = const [];
  Map<String, dynamic>? _customer; // {id, name, customerId, phone}
  Map<String, dynamic>? _statement;
  bool _balanceLoading = false;
  bool _saving = false;
  Map<String, dynamic>? _lastReceipt;
  String _mode = 'CASH';

  @override
  void dispose() {
    _debounce?.cancel();
    _amountCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSearch(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () async {
      final q = v.trim();
      if (q.isEmpty) {
        setState(() => _results = const []);
        return;
      }
      try {
        final res = await ref.read(customerRepoProvider).list(limit: 20, search: q);
        final data = (res['data'] as List?) ?? const [];
        if (mounted) setState(() => _results = data.map((e) => Map<String, dynamic>.from(e as Map)).toList());
      } catch (_) {}
    });
  }

  Future<void> _select(Map<String, dynamic> c) async {
    setState(() {
      _customer = c;
      _results = const [];
      _searchCtrl.text = '${c['firstName'] ?? ''} ${c['lastName'] ?? ''}'.trim();
      _statement = null;
      _lastReceipt = null;
      _balanceLoading = true;
    });
    try {
      final st = await ref.read(customerRepoProvider).sheetStatement(c['id'].toString());
      if (mounted) setState(() => _statement = st);
    } catch (e) {
      showToast(e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _balanceLoading = false);
    }
  }

  Future<void> _save() async {
    final c = _customer;
    if (c == null) {
      showToast('Select a customer', error: true);
      return;
    }
    final amount = num.tryParse(_amountCtrl.text.trim());
    if (amount == null || amount <= 0) {
      showToast('Enter a valid amount', error: true);
      return;
    }
    setState(() => _saving = true);
    try {
      final res = await ref.read(customerRepoProvider).sheetPayment(c['id'].toString(), amount, paymentMode: _mode);
      if (!mounted) return;
      setState(() {
        _lastReceipt = {
          ...res,
          'balanceBefore': _statement?['closingBalance'],
        };
        _amountCtrl.clear();
      });
      showToast('Received ${formatCurrency(amount)}');
      // refresh the balance after posting
      final st = await ref.read(customerRepoProvider).sheetStatement(c['id'].toString());
      if (mounted) setState(() => _statement = st);
    } catch (e) {
      showToast(e.toString(), error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bal = _statement == null ? null : toNum(_statement!['closingBalance']);
    return Scaffold(
      drawer: const AppDrawer(),
      bottomNavigationBar: const AppBottomNav(),
      appBar: AppBar(
        title: const Text('Khata Collection'),
        leading: Builder(
          builder: (ctx) => IconButton(icon: const Icon(Icons.menu), onPressed: () => Scaffold.of(ctx).openDrawer()),
        ),
        actions: [
          TextButton(
            onPressed: () => context.push('/collections'),
            child: const Text('All Collections'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          TextField(
            controller: _searchCtrl,
            decoration: InputDecoration(
              labelText: 'Customer *',
              hintText: 'Search by name or ID...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _customer == null
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () => setState(() {
                        _customer = null;
                        _statement = null;
                        _lastReceipt = null;
                        _searchCtrl.clear();
                      }),
                    ),
            ),
            onChanged: _onSearch,
          ),
          if (_results.isNotEmpty)
            Card(
              margin: const EdgeInsets.only(top: 4),
              child: Column(
                children: _results
                    .map((c) => ListTile(
                          dense: true,
                          title: Text('${c['firstName'] ?? ''} ${c['lastName'] ?? ''}'.trim()),
                          subtitle: Text(
                            '${c['customerId'] ?? ''}${(c['phone'] ?? '').toString().isEmpty ? '' : ' · ${c['phone']}'}',
                            style: const TextStyle(fontSize: 11),
                          ),
                          onTap: () => _select(c),
                        ))
                    .toList(),
              ),
            ),
          const SizedBox(height: 12),
          if (_balanceLoading) const Center(child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator())),
          if (!_balanceLoading && bal != null)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: bal > 0 ? const Color(0xFFFEF2F2) : const Color(0xFFF0FDF4),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: bal > 0 ? const Color(0xFFFECACA) : const Color(0xFFBBF7D0)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Consolidated Balance', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                  Text(
                    formatCurrency(bal),
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                      color: bal > 0 ? AppColors.danger : AppColors.accent,
                    ),
                  ),
                  Text(
                    bal > 0 ? 'customer owes' : bal < 0 ? 'business owes customer' : 'settled',
                    style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _amountCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Amount Paid *', prefixText: '₹ '),
                  onSubmitted: (_) => _save(),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: DropdownButtonFormField<String>(
                  initialValue: _mode,
                  decoration: const InputDecoration(labelText: 'Mode'),
                  items: const [
                    DropdownMenuItem(value: 'CASH', child: Text('Cash')),
                    DropdownMenuItem(value: 'UPI', child: Text('UPI')),
                    DropdownMenuItem(value: 'BANK_TRANSFER', child: Text('Bank')),
                  ],
                  onChanged: (v) => setState(() => _mode = v ?? 'CASH'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
                  onPressed: _saving ? null : _save,
                  child: _saving
                      ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Save'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: _customer == null ? null : () => context.push('/consolidated-balance/${_customer!['id']}'),
                  child: const Text('View Statement'),
                ),
              ),
            ],
          ),
          if (_lastReceipt != null) ...[
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.primarySoft,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Received ${formatCurrency(_lastReceipt!['received'])} · ${((_lastReceipt!['receipts'] as List?) ?? const []).join(', ')}',
                    style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                  const SizedBox(height: 4),
                  ...((_lastReceipt!['allocations'] as List?) ?? const []).map(
                    (a) => Text(
                      '${a['name'] ?? a['type']}: ${formatCurrency(a['amount'])}',
                      style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}
