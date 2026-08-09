import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/common.dart';
import '../data/customer_repo.dart';

const _typeLabels = {
  'OPENING': 'Opening',
  'CHIT_DUE': 'Chit due',
  'LOAN_PRINCIPAL': 'Principal',
  'LOAN_INTEREST': 'Loan interest',
  'AUCTION_WIN': 'Auction won',
  'PAYMENT': 'Payment',
  'PAYOUT_ISSUED': 'Issued',
};

final _statementProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>(
  (ref, id) => ref.read(customerRepoProvider).sheetStatement(id),
);

/// Full khata statement for one customer: every balance-affecting event across
/// chits and loans (dues, auction wins, payments, payout issues, loan interest)
/// with a running balance — the drill-down behind a balance-sheet row. Rows are
/// shown newest-first; the closing balance always equals the sheet's Balance.
/// Backend: GET /customers/:id/sheet-statement.
class CustomerStatementPage extends ConsumerWidget {
  final String customerId;
  const CustomerStatementPage({super.key, required this.customerId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(_statementProvider(customerId));
    return Scaffold(
      appBar: AppBar(title: const Text('Khata Statement')),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => ErrorView(message: e.toString(), onRetry: () => ref.invalidate(_statementProvider(customerId))),
        data: (d) {
          final customer = Map<String, dynamic>.from(d['customer'] ?? {});
          final rows = ((d['rows'] as List?) ?? const [])
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList()
              // Server builds oldest-first for the running balance; the
              // statement reads newest-first with the opening row last.
              .reversed
              .toList();
          final closing = toNum(d['closingBalance']);
          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(_statementProvider(customerId)),
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: rows.length + 1,
              itemBuilder: (ctx, i) {
                if (i == 0) return _header(customer, closing, rows.length);
                return _row(rows[i - 1]);
              },
            ),
          );
        },
      ),
    );
  }

  Widget _header(Map<String, dynamic> customer, num closing, int entries) {
    final owes = closing > 0;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(customer['name']?.toString() ?? '', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800)),
          Text(
            '${customer['customerId'] ?? ''}${(customer['phone'] ?? '').toString().isEmpty ? '' : ' · ${customer['phone']}'}',
            style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: owes ? const Color(0xFFFEF2F2) : const Color(0xFFF0FDF4),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: owes ? const Color(0xFFFECACA) : const Color(0xFFBBF7D0)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Current Balance', style: TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                Text(
                  formatCurrency(closing),
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: owes ? AppColors.danger : AppColors.accent,
                  ),
                ),
                Text(
                  closing > 0
                      ? 'customer owes'
                      : closing < 0
                          ? 'business owes customer'
                          : 'settled',
                  style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                ),
                const SizedBox(height: 4),
                Text('$entries entries · chits + loans', style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(Map<String, dynamic> r) {
    final info = r['info'] == true;
    final debit = toNum(r['debit']);
    final credit = toNum(r['credit']);
    final balance = r['balance'];
    final date = r['date']?.toString();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.border, width: 0.5))),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: AppColors.primarySoft,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        _typeLabels[r['type']] ?? r['type']?.toString() ?? '',
                        style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: AppColors.primaryDark),
                      ),
                    ),
                    const SizedBox(width: 6),
                    if (date != null && date.isNotEmpty)
                      Text(formatDate(date), style: const TextStyle(fontSize: 10, color: AppColors.textMuted)),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  r['description']?.toString() ?? '',
                  style: TextStyle(
                    fontSize: 12,
                    color: info ? AppColors.textMuted : AppColors.textPrimary,
                    fontStyle: info ? FontStyle.italic : null,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (debit > 0)
                Text('+ ${formatCurrency(debit)}',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: info ? AppColors.textMuted : AppColors.danger)),
              if (credit > 0)
                Text('− ${formatCurrency(credit)}',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.accent)),
              if (!info && balance != null)
                Text('bal ${formatCurrency(balance)}',
                    style: const TextStyle(fontSize: 10, color: AppColors.textSecondary)),
            ],
          ),
        ],
      ),
    );
  }
}
