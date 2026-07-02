import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/common.dart';
import '../data/chitfund_repo.dart';

const _profitPaymentModes = ['CASH', 'UPI', 'BANK_TRANSFER', 'CHEQUE', 'ONLINE'];

String _paymentModeLabel(String? m) {
  switch (m) {
    case 'CASH':
      return 'Cash';
    case 'UPI':
      return 'UPI';
    case 'BANK_TRANSFER':
      return 'Bank Transfer';
    case 'CHEQUE':
      return 'Cheque';
    case 'ONLINE':
      return 'Online';
    default:
      return m ?? '-';
  }
}

// Realised/withdrawn/available profit + the withdrawal ledger for one chit.
final chitfundProfitProvider =
    FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, id) async {
  return ref.read(chitfundRepoProvider).profitWithdrawals(id);
});

/// Profit position + withdrawal ledger for a single chit. Mirrors the web
/// ChitfundProfitPanel: pulls /chitfunds/:id/profit-withdrawals, which returns the
/// realised / withdrawn / available figures alongside the ledger rows.
///
/// Withdrawing and reversing are ORG_ADMIN-only — the caller passes [canWithdraw]
/// (mirrors the backend write gate). Merely viewing this panel is gated upstream by
/// the reports.chitfund permission. Bumping [reloadKey] forces a refetch (e.g. when
/// the parent screen refreshes after a payment changes realised profit).
class ChitfundProfitPanel extends ConsumerStatefulWidget {
  final String chitfundId;
  final bool canWithdraw;
  final String? chitName;
  final int reloadKey;
  const ChitfundProfitPanel({
    super.key,
    required this.chitfundId,
    this.canWithdraw = false,
    this.chitName,
    this.reloadKey = 0,
  });

  @override
  ConsumerState<ChitfundProfitPanel> createState() => _ChitfundProfitPanelState();
}

class _ChitfundProfitPanelState extends ConsumerState<ChitfundProfitPanel> {
  @override
  void didUpdateWidget(covariant ChitfundProfitPanel old) {
    super.didUpdateWidget(old);
    if (old.reloadKey != widget.reloadKey) {
      ref.invalidate(chitfundProfitProvider(widget.chitfundId));
    }
  }

  Future<void> _withdraw(double available) async {
    final ok = await showWithdrawProfitSheet(
      context,
      ref,
      chitId: widget.chitfundId,
      chitName: widget.chitName,
      available: available,
    );
    if (ok == true) ref.invalidate(chitfundProfitProvider(widget.chitfundId));
  }

  Future<void> _reverse(Map<String, dynamic> w) async {
    final ok = await confirmDialog(
      context,
      title: 'Reverse profit withdrawal',
      message:
          'Reverse the withdrawal of ${formatCurrency(w['amount'])} dated ${formatDate(w['withdrawalDate'])}? '
          'The amount goes back to available profit.',
      confirmText: 'Reverse',
      destructive: true,
    );
    if (!ok) return;
    try {
      await ref.read(chitfundRepoProvider).deleteProfitWithdrawal(widget.chitfundId, w['id'].toString());
      showToast('Profit withdrawal reversed');
      ref.invalidate(chitfundProfitProvider(widget.chitfundId));
    } on ApiException catch (e) {
      showToast(e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(chitfundProfitProvider(widget.chitfundId));
    return async.when(
      loading: () => const Padding(padding: EdgeInsets.symmetric(vertical: 24), child: LoadingView()),
      error: (e, _) => SectionCard(
        title: 'Profit Withdrawals',
        child: Text(
          'Could not load profit. ${e is ApiException ? e.message : ''}',
          style: const TextStyle(color: AppColors.textSecondary),
        ),
      ),
      data: (data) {
        final netRealized = toNum(data['netRealized']);
        final withdrawnProfit = toNum(data['withdrawnProfit']);
        final availableProfit = toNum(data['availableProfit']);
        final withdrawals = ((data['withdrawals'] as List?) ?? const [])
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        return SectionCard(
          title: 'Profit Withdrawals',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Profit the business has taken out of this chit. Drawn from realised profit — never from member money.',
                style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: _miniStat('Realised profit', formatCurrency(netRealized), AppColors.primary)),
                  const SizedBox(width: 8),
                  Expanded(child: _miniStat('Withdrawn', formatCurrency(withdrawnProfit), AppColors.textPrimary)),
                  const SizedBox(width: 8),
                  Expanded(child: _miniStat('Available', formatCurrency(availableProfit), AppColors.accent, highlight: true)),
                ],
              ),
              if (widget.canWithdraw) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: availableProfit <= 0 ? null : () => _withdraw(availableProfit.toDouble()),
                    icon: const Icon(Icons.upload, size: 18),
                    style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent),
                    label: const Text('Withdraw Profit'),
                  ),
                ),
              ],
              const SizedBox(height: 8),
              const Divider(height: 20),
              if (withdrawals.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 12),
                  child: Text('No profit withdrawn from this chit yet.',
                      textAlign: TextAlign.center, style: TextStyle(color: AppColors.textMuted)),
                )
              else ...[
                ...withdrawals.map(_withdrawalRow),
                const Divider(height: 20),
                Row(
                  children: [
                    const Expanded(child: Text('Total Withdrawn', textAlign: TextAlign.right, style: TextStyle(fontWeight: FontWeight.w600, color: AppColors.textSecondary))),
                    const SizedBox(width: 8),
                    Text(formatCurrency(withdrawnProfit), style: const TextStyle(fontWeight: FontWeight.w800, color: AppColors.accent)),
                    if (widget.canWithdraw) const SizedBox(width: 44),
                  ],
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _miniStat(String label, String value, Color color, {bool highlight = false}) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: highlight ? AppColors.accent.withValues(alpha: 0.08) : AppColors.bg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: highlight ? AppColors.accent.withValues(alpha: 0.3) : AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 10, color: AppColors.textSecondary)),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: color)),
          ),
        ],
      ),
    );
  }

  Widget _withdrawalRow(Map<String, dynamic> w) {
    final by = Map<String, dynamic>.from(w['withdrawnBy'] ?? {})['name']?.toString();
    final note = w['note']?.toString();
    final meta = <String>[
      _paymentModeLabel(w['paymentMode']?.toString()),
      if (by != null && by.isNotEmpty) 'by $by',
      if (note != null && note.isNotEmpty) note,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(formatDate(w['withdrawalDate']), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(formatCurrency(w['amount']), style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.accent)),
          if (widget.canWithdraw)
            IconButton(
              icon: const Icon(Icons.delete_outline, size: 20, color: AppColors.textMuted),
              tooltip: 'Reverse this withdrawal',
              onPressed: () => _reverse(w),
            ),
        ],
      ),
    );
  }
}

/// Draw realised business profit out of a chit. The amount is capped at the chit's
/// available (realised − already-withdrawn) profit — the same guard the API enforces.
/// Returns true when a withdrawal succeeded. ORG_ADMIN only (the caller gates access).
Future<bool?> showWithdrawProfitSheet(
  BuildContext context,
  WidgetRef ref, {
  required String chitId,
  String? chitName,
  required double available,
}) {
  return showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => _WithdrawProfitSheet(chitId: chitId, chitName: chitName, available: available),
  );
}

class _WithdrawProfitSheet extends ConsumerStatefulWidget {
  final String chitId;
  final String? chitName;
  final double available;
  const _WithdrawProfitSheet({required this.chitId, this.chitName, required this.available});
  @override
  ConsumerState<_WithdrawProfitSheet> createState() => _WithdrawProfitSheetState();
}

class _WithdrawProfitSheetState extends ConsumerState<_WithdrawProfitSheet> {
  final _amountC = TextEditingController();
  final _noteC = TextEditingController();
  String _mode = 'CASH';
  DateTime? _date;
  bool _saving = false;

  @override
  void dispose() {
    _amountC.dispose();
    _noteC.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final amt = double.tryParse(_amountC.text.trim()) ?? 0;
    // 1e-9 slack so "Withdraw all" (the exact available figure) is never rejected by
    // floating-point dust — mirrors the web modal's guard.
    if (amt <= 0 || amt > widget.available + 1e-9) {
      showToast(
        amt > widget.available
            ? 'Amount exceeds available profit (${formatCurrency(widget.available)})'
            : 'Enter a valid amount',
        error: true,
      );
      return;
    }
    setState(() => _saving = true);
    try {
      final body = <String, dynamic>{'amount': amt, 'paymentMode': _mode};
      if (_date != null) body['withdrawalDate'] = formatInputDate(_date!);
      if (_noteC.text.trim().isNotEmpty) body['note'] = _noteC.text.trim();
      await ref.read(chitfundRepoProvider).withdrawProfit(widget.chitId, body);
      showToast('Profit withdrawn');
      if (mounted) Navigator.pop(context, true);
    } on ApiException catch (e) {
      showToast(e.message, error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final avail = widget.available;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        initialChildSize: 0.7,
        expand: false,
        builder: (_, ctrl) => ListView(
          controller: ctrl,
          padding: const EdgeInsets.all(16),
          children: [
            Row(children: [
              const Expanded(child: Text('Withdraw profit', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600))),
              IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
            ]),
            const SizedBox(height: 8),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.accent.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppColors.accent.withValues(alpha: 0.3)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('AVAILABLE TO WITHDRAW',
                      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: AppColors.accent)),
                  const SizedBox(height: 2),
                  Text(formatCurrency(avail), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
                  if (widget.chitName != null)
                    Text('from ${widget.chitName}', style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                const Expanded(child: Text('Amount to withdraw', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
                TextButton(
                  onPressed: avail <= 0 ? null : () => setState(() => _amountC.text = avail.toStringAsFixed(2)),
                  child: const Text('Withdraw all'),
                ),
              ],
            ),
            TextField(
              controller: _amountC,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(hintText: '0.00'),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _mode,
              decoration: const InputDecoration(labelText: 'Payment mode'),
              items: _profitPaymentModes.map((m) => DropdownMenuItem(value: m, child: Text(_paymentModeLabel(m)))).toList(),
              onChanged: (v) => setState(() => _mode = v ?? 'CASH'),
            ),
            const SizedBox(height: 12),
            InkWell(
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _date ?? DateTime.now(),
                  firstDate: DateTime(2015),
                  lastDate: DateTime.now().add(const Duration(days: 1)),
                );
                if (picked != null) setState(() => _date = picked);
              },
              child: InputDecorator(
                decoration: const InputDecoration(labelText: 'Date (optional)'),
                child: Text(_date == null ? 'Today' : formatDate(_date)),
              ),
            ),
            const SizedBox(height: 12),
            TextField(controller: _noteC, decoration: const InputDecoration(labelText: 'Note (optional)', hintText: "e.g. owner's drawing")),
            if (avail <= 0) ...[
              const SizedBox(height: 12),
              const Text('There is no realised profit available to withdraw yet.',
                  style: TextStyle(fontSize: 13, color: AppColors.warning)),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent),
                onPressed: (_saving || avail <= 0) ? null : _submit,
                child: Text(_saving ? 'Saving...' : 'Withdraw'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
