import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/api/api_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/common.dart';
import '../data/loan_repo.dart';

/// Computed EMI/disbursement breakdown shown on the preview screen — the mobile
/// equivalent of the web create wizard's "Review & Confirm" step. The numbers mirror
/// the backend's buildLoanDetails so what the user previews is what gets booked.
class LoanPreview {
  final double principal;
  final double totalInterest;
  final double processingFee;
  final double netDisbursed;
  final double totalPayable; // for upfront loans this is the principal-to-repay
  final double emiAmount;
  final int tenure;
  final String unitWord; // singular: day | week | month | year
  final bool upfront;
  final double upfrontInterest;
  final String rateSuffix; // e.g. ' (flat)', ' p.a.', ' / week (reducing)'
  final String installmentLabel; // 'Daily Installment' | 'Weekly Installment' | 'EMI Amount'

  const LoanPreview({
    required this.principal,
    required this.totalInterest,
    required this.processingFee,
    required this.netDisbursed,
    required this.totalPayable,
    required this.emiAmount,
    required this.tenure,
    required this.unitWord,
    required this.upfront,
    required this.upfrontInterest,
    required this.rateSuffix,
    required this.installmentLabel,
  });
}

double _r2(double x) => (x * 100).round() / 100;

LoanPreview computeLoanPreview({
  required String loanType,
  required String tenureType,
  required String interestType,
  required bool deductUpfront,
  required double amount,
  required double rate,
  required int tenure,
  required double processingFee,
}) {
  final isDailyType = loanType == 'DAILY' || loanType == 'WEEKLY';
  final isPeriod = !isDailyType && (tenureType == 'WEEKS' || tenureType == 'DAYS');
  final n = tenure < 1 ? 1 : tenure;

  // DAILY/WEEKLY product loans: flat interest deducted upfront, principal repaid per installment.
  if (isDailyType) {
    final upfront = _r2(amount * rate / 100);
    return LoanPreview(
      principal: amount,
      totalInterest: upfront,
      processingFee: processingFee,
      netDisbursed: _r2(amount - upfront - processingFee),
      totalPayable: amount,
      emiAmount: _r2(amount / n),
      tenure: tenure,
      unitWord: loanType == 'DAILY' ? 'day' : 'week',
      upfront: true,
      upfrontInterest: upfront,
      rateSuffix: ' (flat)',
      installmentLabel: loanType == 'DAILY' ? 'Daily Installment' : 'Weekly Installment',
    );
  }

  // Sub-monthly term loan (weeks/days) — honors the chosen method.
  if (isPeriod) {
    final unit = tenureType == 'WEEKS' ? 'week' : 'day';
    final instLabel = tenureType == 'WEEKS' ? 'Weekly Installment' : 'Daily Installment';
    if (interestType == 'REDUCING') {
      // Monthly rate → per-installment rate (× 12 / 52 per week, × 12 / 365 per day),
      // applied to the outstanding balance — mirrors the backend's periodReducingRate.
      final r = (rate / 100) * 12 / (tenureType == 'WEEKS' ? 52 : 365);
      final emi = _r2(r == 0 ? amount / n : (amount * r * pow(1 + r, n)) / (pow(1 + r, n) - 1));
      final totalPayable = _r2(emi * n);
      return LoanPreview(
        principal: amount, totalInterest: _r2(totalPayable - amount), processingFee: processingFee,
        netDisbursed: _r2(amount - processingFee), totalPayable: totalPayable, emiAmount: emi,
        tenure: tenure, unitWord: unit, upfront: false, upfrontInterest: 0,
        rateSuffix: ' / month (reducing)', installmentLabel: instLabel,
      );
    }
    final totalInterest = _r2(amount * rate / 100);
    if (deductUpfront) {
      return LoanPreview(
        principal: amount, totalInterest: totalInterest, processingFee: processingFee,
        netDisbursed: _r2(amount - totalInterest - processingFee), totalPayable: amount,
        emiAmount: _r2(amount / n), tenure: tenure, unitWord: unit, upfront: true,
        upfrontInterest: totalInterest, rateSuffix: ' (flat)', installmentLabel: instLabel,
      );
    }
    final totalPayable = _r2(amount + totalInterest);
    return LoanPreview(
      principal: amount, totalInterest: totalInterest, processingFee: processingFee,
      netDisbursed: _r2(amount - processingFee), totalPayable: totalPayable,
      emiAmount: _r2(totalPayable / n), tenure: tenure, unitWord: unit, upfront: false,
      upfrontInterest: 0, rateSuffix: ' (flat)', installmentLabel: instLabel,
    );
  }

  // Monthly / yearly term loan.
  final months = tenureType == 'YEARS' ? n * 12 : n;
  final unitWord = tenureType == 'YEARS' ? 'year' : 'month';
  if (interestType == 'FLAT') {
    final years = months / 12;
    final totalInterest = _r2(amount * rate / 100 * years);
    if (deductUpfront) {
      return LoanPreview(
        principal: amount, totalInterest: totalInterest, processingFee: processingFee,
        netDisbursed: _r2(amount - totalInterest - processingFee), totalPayable: amount,
        emiAmount: _r2(amount / months), tenure: tenure, unitWord: unitWord, upfront: true,
        upfrontInterest: totalInterest, rateSuffix: ' (flat)', installmentLabel: 'EMI Amount',
      );
    }
    final totalPayable = _r2(amount + totalInterest);
    return LoanPreview(
      principal: amount, totalInterest: totalInterest, processingFee: processingFee,
      netDisbursed: _r2(amount - processingFee), totalPayable: totalPayable,
      emiAmount: _r2(totalPayable / months), tenure: tenure, unitWord: unitWord, upfront: false,
      upfrontInterest: 0, rateSuffix: ' (flat)', installmentLabel: 'EMI Amount',
    );
  }
  // Reducing balance (annual rate / 12 per month).
  final r = rate / 12 / 100;
  final emi = _r2(r == 0 ? amount / months : (amount * r * pow(1 + r, months)) / (pow(1 + r, months) - 1));
  final totalPayable = _r2(emi * months);
  return LoanPreview(
    principal: amount, totalInterest: _r2(totalPayable - amount), processingFee: processingFee,
    netDisbursed: _r2(amount - processingFee), totalPayable: totalPayable, emiAmount: emi,
    tenure: tenure, unitWord: unitWord, upfront: false, upfrontInterest: 0,
    rateSuffix: ' p.a.', installmentLabel: 'EMI Amount',
  );
}

/// Full-screen review shown before the loans are actually created. On confirm it
/// posts the prepared [body] once per customer and routes to the loans list.
/// More than one customer only occurs for group loans, where the whole batch
/// shares the terms on [body].
class LoanPreviewPage extends ConsumerStatefulWidget {
  final Map<String, dynamic> body; // shared terms — customerId is added per customer
  final LoanPreview preview;
  final List<Map<String, dynamic>> customers; // {id, label} — one loan each
  final String loanTypeLabel;
  final String? assigneeLabel;
  final DateTime startDate;
  final String rateText;
  const LoanPreviewPage({
    super.key,
    required this.body,
    required this.preview,
    required this.customers,
    required this.loanTypeLabel,
    required this.assigneeLabel,
    required this.startDate,
    required this.rateText,
  });

  @override
  ConsumerState<LoanPreviewPage> createState() => _LoanPreviewPageState();
}

class _LoanPreviewPageState extends ConsumerState<LoanPreviewPage> {
  bool _saving = false;
  // Customers still awaiting creation — each success is removed as it posts, so
  // retrying after a partial failure never books the same loan twice.
  late final List<Map<String, dynamic>> _pending = [...widget.customers];

  DateTime get _endDate {
    final p = widget.preview;
    final s = widget.startDate;
    switch (p.unitWord) {
      case 'day':
        return s.add(Duration(days: p.tenure));
      case 'week':
        return s.add(Duration(days: p.tenure * 7));
      case 'year':
        return DateTime(s.year + p.tenure, s.month, s.day);
      default: // month
        return DateTime(s.year, s.month + p.tenure, s.day);
    }
  }

  Future<void> _confirm() async {
    setState(() => _saving = true);
    final failures = <String>[];
    for (final c in List.of(_pending)) {
      try {
        await ref.read(loanRepoProvider).create({...widget.body, 'customerId': c['id']});
        _pending.remove(c);
      } on ApiException catch (e) {
        failures.add('${c['label']}: ${e.message}');
      }
    }
    final total = widget.customers.length;
    if (_pending.isEmpty) {
      showToast(total == 1 ? 'Loan created' : '$total loans created');
      if (mounted) context.go('/loans');
      return;
    }
    showToast(
      'Created ${total - _pending.length} of $total loans. ${failures.first}',
      error: true,
    );
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.preview;
    final n = widget.customers.length;
    return Scaffold(
      appBar: AppBar(title: const Text('Review & Confirm')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          SectionCard(
            title: 'Summary',
            child: Column(
              children: [
                if (n == 1)
                  KeyValueRow(label: 'Customer', value: widget.customers.first['label'].toString())
                else
                  KeyValueRow(label: 'Customers', value: '$n — one loan each'),
                KeyValueRow(label: 'Loan Type', value: widget.loanTypeLabel),
                if ((widget.assigneeLabel ?? '').isNotEmpty)
                  KeyValueRow(label: 'Assigned To', value: widget.assigneeLabel!),
                KeyValueRow(label: 'Principal', value: formatCurrency(p.principal)),
                KeyValueRow(label: 'Interest Rate', value: '${widget.rateText}%${p.rateSuffix}'),
                KeyValueRow(label: 'Tenure', value: '${p.tenure} ${p.unitWord}${p.tenure == 1 ? '' : 's'}'),
                KeyValueRow(label: 'Start Date', value: formatDate(widget.startDate.toIso8601String())),
                KeyValueRow(label: 'End Date', value: formatDate(_endDate.toIso8601String())),
                KeyValueRow(
                  label: p.upfront ? 'Upfront Interest (deducted)' : 'Total Interest',
                  value: formatCurrency(p.totalInterest),
                ),
                // ALR rides along informationally — it is not part of the disbursement math.
                if ((double.tryParse(widget.body['alr']?.toString() ?? '') ?? 0) > 0)
                  KeyValueRow(label: 'ALR', value: widget.body['alr'].toString()),
              ],
            ),
          ),
          if (n > 1)
            SectionCard(
              title: 'Borrowers ($n)',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final c in widget.customers)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text('• ${c['label']}'),
                    ),
                ],
              ),
            ),
          SectionCard(
            title: n > 1 ? 'Disbursement (per loan)' : 'Disbursement',
            child: Column(
              children: [
                _amountRow('Principal Amount', p.principal),
                if (p.upfront) _amountRow('Upfront Interest Deducted', -p.upfrontInterest, negative: true),
                if (p.processingFee > 0) _amountRow('Processing Fee Deducted', -p.processingFee, negative: true),
                const Divider(),
                _amountRow('Net Amount to Customer', p.netDisbursed, bold: true, color: AppColors.accent),
                if (n > 1) ...[
                  const Divider(),
                  _amountRow('Total Principal ($n loans)', p.principal * n),
                  _amountRow('Total Disbursed ($n loans)', p.netDisbursed * n, bold: true),
                ],
              ],
            ),
          ),
          SectionCard(
            title: n > 1 ? 'Per Loan' : null,
            child: Row(
              children: [
                Expanded(
                  child: _stat(p.upfront ? 'Total Principal to Repay' : 'Total Repayable', formatCurrency(p.totalPayable)),
                ),
                Expanded(child: _stat(p.installmentLabel, formatCurrency(p.emiAmount))),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _saving ? null : () => Navigator.pop(context),
                  child: const Text('Back'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: ElevatedButton(
                  onPressed: _saving ? null : _confirm,
                  child: _saving
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : Text(_pending.length < n
                          ? 'Retry ${_pending.length} Failed'
                          : n == 1
                              ? 'Confirm & Create'
                              : 'Confirm & Create $n Loans'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  Widget _amountRow(String label, double value, {bool negative = false, bool bold = false, Color? color}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: TextStyle(fontWeight: bold ? FontWeight.w700 : FontWeight.w400)),
          Text(
            '${negative ? '- ' : ''}${formatCurrency(value.abs())}',
            style: TextStyle(
              fontWeight: bold ? FontWeight.w700 : FontWeight.w600,
              color: color ?? (negative ? AppColors.warning : null),
            ),
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
        const SizedBox(height: 4),
        Text(value, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
      ],
    );
  }
}
