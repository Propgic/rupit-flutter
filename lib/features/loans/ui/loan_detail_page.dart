import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/api/api_client.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/common.dart';
import '../data/loan_dates.dart';
import '../data/loan_repo.dart';
import '../../loan_groups/data/loan_group_repo.dart';
import '../../team/data/team_repo.dart';
import 'emi_start_date_tile.dart';

final loanDetailProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, id) async {
  return ref.read(loanRepoProvider).get(id);
});

class LoanDetailPage extends ConsumerStatefulWidget {
  final String id;
  const LoanDetailPage({super.key, required this.id});
  @override
  ConsumerState<LoanDetailPage> createState() => _LoanDetailPageState();
}

class _LoanDetailPageState extends ConsumerState<LoanDetailPage> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  /// Whether the "Collect Payment" CTA shows for this loan — active loans only,
  /// for users who may record collections (mirrors the web detail page's button).
  bool _canCollect(Map<String, dynamic> l) =>
      l['status'] == 'ACTIVE' && ref.read(authProvider).hasPermission('collections.create');

  /// Room at the bottom of a scrolling tab so the extended FAB never covers the last row.
  EdgeInsets _tabPadding(Map<String, dynamic> l, double base) =>
      EdgeInsets.fromLTRB(base, base, base, _canCollect(l) ? base + 76 : base);

  Future<void> _doAction(Future<void> Function() fn, String msg) async {
    try {
      await fn();
      ref.invalidate(loanDetailProvider(widget.id));
      showToast(msg);
    } on ApiException catch (e) {
      showToast(e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(loanDetailProvider(widget.id));
    final auth = ref.watch(authProvider);
    final isMgr = auth.hasRole('ORG_ADMIN') || auth.hasRole('MANAGER');
    final isAdmin = auth.hasRole('ORG_ADMIN');
    final correctionEnabled = auth.org?.feature('enableLoanCorrection') == true;
    // Loan Settings → Loan Detail Actions. On by default; off hides the action here
    // and the API refuses the close as well.
    final closeEnabled = auth.org?.allowLoanClose != false;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Loan Details'),
        bottom: TabBar(
          controller: _tabs,
          // Accrual (khata) loans have no EMIs — the schedule is an account ledger.
          tabs: [
            const Tab(text: 'Details'),
            const Tab(text: 'Collections'),
            Tab(text: data.asData?.value['interestAccrual'] == true ? 'Account Ledger' : 'EMI Schedule'),
          ],
        ),
        actions: [
          data.maybeWhen(
            data: (l) => PopupMenuButton<String>(
              onSelected: (v) async {
                if (v == 'disburse') {
                  final ok = await confirmDialog(context, message: 'Disburse this loan?');
                  if (ok) _doAction(() => ref.read(loanRepoProvider).disburse(widget.id), 'Loan disbursed');
                }
                if (v == 'reject') {
                  final ok = await confirmDialog(context, message: 'Reject this loan?', destructive: true, confirmText: 'Reject');
                  if (ok) _doAction(() => ref.read(loanRepoProvider).reject(widget.id), 'Loan rejected');
                }
                if (v == 'close') {
                  await _openClose();
                }
                if (v == 'archive') {
                  final ok = await confirmDialog(context,
                      title: 'Archive Loan',
                      message: 'Archiving keeps the loan and its history but removes it from Outstanding, Overdue and Amount-in-Market totals. Nothing is marked paid or closed. You can unarchive it any time.',
                      confirmText: 'Archive');
                  if (ok) _doAction(() => ref.read(loanRepoProvider).archive(widget.id), 'Loan archived');
                }
                if (v == 'unarchive') {
                  final ok = await confirmDialog(context, message: 'Restore this loan to the active book?', confirmText: 'Unarchive');
                  if (ok) _doAction(() => ref.read(loanRepoProvider).unarchive(widget.id), 'Loan unarchived');
                }
                if (v == 'edit') {
                  await _openEdit(l);
                }
                if (v == 'correct') {
                  await _openCorrect(l);
                }
              },
              itemBuilder: (_) => [
                if (isAdmin && correctionEnabled)
                  const PopupMenuItem(value: 'edit', child: Text('Edit Loan')),
                if (isAdmin && correctionEnabled && l['status'] == 'ACTIVE')
                  const PopupMenuItem(value: 'correct', child: Text('Correct Terms')),
                if (isMgr && l['status'] == 'APPROVED') const PopupMenuItem(value: 'disburse', child: Text('Disburse')),
                if (isMgr && (l['status'] == 'PENDING' || l['status'] == 'APPROVED')) const PopupMenuItem(value: 'reject', child: Text('Reject')),
                if (isMgr && closeEnabled && l['status'] == 'ACTIVE') const PopupMenuItem(value: 'close', child: Text('Close Loan')),
                if (isMgr && l['archivedAt'] == null && (l['status'] == 'ACTIVE' || l['status'] == 'DEFAULTED'))
                  const PopupMenuItem(value: 'archive', child: Text('Archive')),
                if (isMgr && l['archivedAt'] != null)
                  const PopupMenuItem(value: 'unarchive', child: Text('Unarchive')),
              ],
            ),
            orElse: () => const SizedBox.shrink(),
          ),
        ],
      ),
      // Primary CTA for an active loan — same entry point as the web detail page's
      // "Collect Payment", opening the collection form with this loan preselected.
      floatingActionButton: data.maybeWhen(
        data: (l) => _canCollect(l)
            ? FloatingActionButton.extended(
                onPressed: () async {
                  await context.push('/collections/new?loanId=${widget.id}');
                  if (!mounted) return;
                  // A payment recorded from here changes the balance/EMI schedule.
                  ref.invalidate(loanDetailProvider(widget.id));
                },
                icon: const Icon(Icons.payments_outlined),
                label: const Text('Collect Payment'),
              )
            : null,
        orElse: () => null,
      ),
      body: data.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(message: e.toString(), onRetry: () => ref.invalidate(loanDetailProvider(widget.id))),
        data: (l) => TabBarView(
          controller: _tabs,
          children: [_infoTab(l), _collectionsTab(l), _emiTab(l)],
        ),
      ),
    );
  }

  Widget _infoTab(Map<String, dynamic> l) {
    final c = Map<String, dynamic>.from(l['customer'] ?? {});
    final assignee = Map<String, dynamic>.from(l['assignedTo'] ?? {});
    // Traditional accrual (khata) loan: no EMIs — the whole principal is owed
    // from disbursement and simple monthly interest is added to the balance as
    // each month arrives. The schedule rows are an account ledger, so every EMI
    // label/figure below switches presentation.
    final accrual = l['interestAccrual'] == true;

    // Payment overview: group Overdue, Due Amount and Total Due Payable together so the
    // amount the customer must pay now is never confused with individual figures.
    final nextEmi = Map<String, dynamic>.from(l['nextEMI'] ?? {});
    // Use the backend's authoritative figures (already net of partial payments and
    // applying the PENDING/PARTIALLY_PAID/overdue conventions) instead of re-deriving
    // from nextEMI — matches the web detail and fixes the edge case where a partially
    // paid (e.g. final) EMI's remaining amount wouldn't surface from nextEMI alone.
    final dueAmount = toNum(l['dueAmount']);
    final overdueEmis = toNum(l['overdueEMIs']);
    final showOverdue = overdueEmis > 0;
    final showDue = l['status'] == 'ACTIVE' && dueAmount > 0;
    // Total Due Payable = currently due EMI + overdue amount (what's payable right now).
    final totalDuePayable = toNum(l['totalDuePayable']);

    final overviewCards = <Widget>[];
    if (showOverdue) {
      overviewCards.add(_amountCard(
        label: accrual ? 'Outstanding Balance' : 'Overdue',
        value: formatCurrency(l['overdueAmount']),
        color: AppColors.danger,
        subtitle: accrual
            ? 'Principal + interest accrued to date, less payments'
            : '${overdueEmis.toInt()} installment${overdueEmis > 1 ? 's' : ''} overdue',
      ));
    }
    if (showDue) {
      overviewCards.add(_amountCard(
        label: 'Due Amount',
        value: formatCurrency(dueAmount),
        color: AppColors.warning,
        subtitle: nextEmi.isEmpty
            ? null
            : accrual
                ? 'Interest · ${formatDate(nextEmi['dueDate'])}'
                : 'EMI #${nextEmi['emiNumber']} · ${formatDate(nextEmi['dueDate'])}',
      ));
    }
    overviewCards.add(_amountCard(
      label: accrual ? 'Balance to Date' : 'Total Due Payable',
      value: formatCurrency(totalDuePayable),
      color: AppColors.primary,
      subtitle: accrual ? 'Payable/adjustable any time via the balance sheet' : 'Currently due + overdue',
    ));

    return ListView(
      padding: _tabPadding(l, 14),
      children: [
        if (accrual)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.primarySoft,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(
              'Traditional accrual loan. The full principal is owed from disbursement and '
              'simple monthly interest (${formatCurrency(l['emiAmount'])}/month) is added to the '
              'balance — there are no EMIs. Collected or adjusted through the balance sheet.',
              style: const TextStyle(fontSize: 12.5, color: AppColors.primaryDark),
            ),
          ),
        if (l['archivedAt'] != null)
          Container(
            margin: const EdgeInsets.only(bottom: 12),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.grey.shade300),
            ),
            child: Row(
              children: [
                Icon(Icons.archive_outlined, size: 18, color: Colors.grey.shade600),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Archived — excluded from Outstanding, Overdue and Amount-in-Market totals.'
                    '${(l['archiveReason']?.toString().isNotEmpty ?? false) ? '\n${l['archiveReason']}' : ''}',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade700),
                  ),
                ),
              ],
            ),
          ),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(l['loanNumber']?.toString() ?? '', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700))),
                    StatusChip(label: l['status']?.toString() ?? '', color: statusColor(l['status']?.toString())),
                  ],
                ),
                const SizedBox(height: 4),
                Text(l['loanType']?.toString() ?? '', style: const TextStyle(color: AppColors.textSecondary)),
              ],
            ),
          ),
        ),
        _pendingBanner(l),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < overviewCards.length; i++) ...[
                  if (i > 0) const SizedBox(width: 10),
                  Expanded(child: overviewCards[i]),
                ],
              ],
            ),
          ),
        ),
        _breakdownCard(l),
        SectionCard(
          title: 'Customer',
          actions: [
            TextButton(
              onPressed: () => context.push('/customers/${c['id']}'),
              child: const Text('View'),
            ),
          ],
          child: Column(
            children: [
              Row(
                children: [
                  () {
                    final photo = c['photo']?.toString();
                    final name = '${c['firstName'] ?? ''} ${c['lastName'] ?? ''}'.trim();
                    final avatar = Avatar(url: photo, name: name, size: 56);
                    return (photo != null && photo.isNotEmpty)
                        ? GestureDetector(onTap: () => showImageViewer(context, photo), child: avatar)
                        : avatar;
                  }(),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${c['firstName'] ?? ''} ${c['lastName'] ?? ''}'.trim().isEmpty
                              ? '-'
                              : '${c['firstName'] ?? ''} ${c['lastName'] ?? ''}'.trim(),
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                        if ((c['customerId']?.toString() ?? '').isNotEmpty)
                          Text(c['customerId'].toString(),
                              style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              KeyValueRow(label: 'Phone', value: c['phone']?.toString() ?? '-',
                  onTap: c['phone'] != null ? () => launchUrl(Uri.parse('tel:${c['phone']}')) : null),
              if ((c['alternatePhone']?.toString() ?? '').isNotEmpty)
                KeyValueRow(label: 'Alternate Phone', value: c['alternatePhone'].toString(),
                    onTap: () => launchUrl(Uri.parse('tel:${c['alternatePhone']}'))),
              if ((c['introducerName']?.toString() ?? '').isNotEmpty)
                KeyValueRow(
                  label: 'Introducer',
                  value: c['introducerName'].toString(),
                  trailing: (c['introducerPhoto']?.toString().isNotEmpty ?? false)
                      ? GestureDetector(
                          onTap: () => showImageViewer(context, c['introducerPhoto'].toString()),
                          child: Avatar(url: c['introducerPhoto'].toString(), name: c['introducerName'].toString(), size: 28),
                        )
                      : null,
                ),
              if ((c['introducerPhone']?.toString() ?? '').isNotEmpty)
                KeyValueRow(label: 'Introducer Phone', value: c['introducerPhone'].toString(),
                    onTap: () => launchUrl(Uri.parse('tel:${c['introducerPhone']}'))),
              if ((c['verifiedBy']?.toString() ?? '').isNotEmpty)
                KeyValueRow(label: 'Verified By', value: c['verifiedBy'].toString()),
              KeyValueRow(
                label: 'Total Loans',
                value: '${toNum(c['loansCount']).toInt()}',
                onTap: c['id'] != null ? () => context.push('/customers/${c['id']}') : null,
              ),
            ],
          ),
        ),
        SectionCard(
          title: 'Loan Terms',
          child: Column(
            children: [
              KeyValueRow(label: 'Principal', value: formatCurrency(l['principalAmount'])),
              if (!loanFieldHidden(l, 'interestRate'))
                KeyValueRow(label: 'Interest Rate', value: _interestRateLabel(l)),
              KeyValueRow(
                  label: 'Tenure',
                  value: accrual ? 'Open-ended (accrual)' : '${l['tenure'] ?? ''} ${l['tenureType'] ?? ''}'),
              KeyValueRow(
                  label: accrual
                      ? 'Monthly Interest'
                      : l['loanType'] == 'DAILY'
                          ? 'Daily Installment'
                          : 'EMI',
                  value: formatCurrency(l['emiAmount'])),
              if (!loanFieldHidden(l, 'totalPayable'))
                KeyValueRow(
                    label: accrual ? 'Total Charged to Date' : 'Total Payable',
                    value: formatCurrency(l['totalPayable'])),
              if (!loanFieldHidden(l, 'processingFee'))
                KeyValueRow(label: 'Processing Fee', value: formatCurrency(l['processingFee'])),
              if (l['alr'] != null && (double.tryParse(l['alr'].toString()) ?? 0) > 0)
                KeyValueRow(label: 'ALR', value: l['alr'].toString()),
              KeyValueRow(label: 'Start Date', value: formatDate(l['startDate'])),
              KeyValueRow(label: 'Disbursed', value: formatDate(l['disbursedDate'])),
              if (!accrual && l['emiSchedule'] is List && (l['emiSchedule'] as List).isNotEmpty)
                KeyValueRow(label: 'First EMI', value: formatDate(((l['emiSchedule'] as List).first as Map)['dueDate'])),
              KeyValueRow(label: accrual ? 'Interest Charged Through' : 'End Date', value: formatDate(l['endDate'])),
              if (l['disbursedDate'] != null)
                KeyValueRow(
                  label: l['loanType'] == 'WEEKLY' || l['loanType'] == 'GROUP' ? 'Week' : 'Day',
                  value: dayWeekLabel(l['disbursedDate'],
                      l['loanType']?.toString(), l['installmentsElapsed']),
                  valueColor: const Color(0xFFEA580C),
                ),
            ],
          ),
        ),
        SectionCard(
          title: 'Payment Status',
          child: Column(
            children: [
              KeyValueRow(label: 'Paid', value: formatCurrency(l['totalPaid']), valueColor: AppColors.accent),
              // Show `balance` (totalPayable − totalPaid) — the same figure the loan list shows.
              // The schedule-derived `outstanding` collapses to 0 once every EMI row is marked
              // paid (e.g. after an advance), so it can disagree with the list's balance.
              KeyValueRow(label: 'Outstanding', value: formatCurrency(l['balance']), valueColor: AppColors.danger),
              KeyValueRow(label: 'Due', value: formatCurrency(showDue ? dueAmount : 0), valueColor: AppColors.warning),
              KeyValueRow(label: 'Over Due', value: formatCurrency(l['overdueAmount']), valueColor: AppColors.danger),
            ],
          ),
        ),
        _closureCard(l),
        // The group a group loan belongs to — the same link the web detail page
        // carries, and where a move made from Edit Loan shows up.
        if (l['group'] is Map)
          SectionCard(
            title: 'Loan Group',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.groups_outlined),
              title: Text(l['group']['name']?.toString() ?? '-'),
              subtitle: Text(l['group']['groupNumber']?.toString() ?? ''),
              trailing: const Icon(Icons.chevron_right),
              onTap: l['group']['id'] == null ? null : () => context.push('/loan-groups/${l['group']['id']}'),
            ),
          ),
        if (assignee.isNotEmpty)
          SectionCard(
            title: 'Assigned To',
            child: KeyValueRow(label: assignee['name']?.toString() ?? '-', value: assignee['role']?.toString() ?? '-'),
          ),
        if (l['notes'] != null && l['notes'].toString().isNotEmpty)
          SectionCard(title: 'Notes', child: Text(l['notes'].toString())),
        _documentsSection(l),
      ],
    );
  }

  bool _isImageDoc(String? url) {
    final u = (url ?? '').toLowerCase();
    return u.endsWith('.jpg') || u.endsWith('.jpeg') || u.endsWith('.png') || u.endsWith('.webp') || u.endsWith('.gif');
  }

  Widget _documentsSection(Map<String, dynamic> l) {
    final auth = ref.watch(authProvider);
    final canManage = auth.hasPermission('loans.create') || auth.hasRole('ORG_ADMIN') || auth.hasRole('MANAGER');
    final docs = (l['documents'] is List) ? List<dynamic>.from(l['documents'] as List) : const <dynamic>[];

    return SectionCard(
      title: 'Documents',
      actions: [
        if (canManage)
          TextButton.icon(
            onPressed: _addDocument,
            icon: const Icon(Icons.upload_file, size: 18),
            label: const Text('Add'),
          ),
      ],
      child: docs.isEmpty
          ? const EmptyView(message: 'No documents uploaded', icon: Icons.description_outlined)
          : Column(
              children: [
                for (var i = 0; i < docs.length; i++) _documentTile(Map<String, dynamic>.from(docs[i] as Map), i, canManage),
              ],
            ),
    );
  }

  Widget _documentTile(Map<String, dynamic> doc, int index, bool canManage) {
    final url = (doc['url'] ?? doc['path'])?.toString();
    final title = (doc['title'] ?? doc['name'] ?? 'Document').toString();
    final isImage = _isImageDoc(url);
    final uploadedBy = doc['uploadedBy']?.toString();
    final uploadedAt = doc['uploadedAt'];
    final subtitleParts = <String>[
      if (uploadedBy != null && uploadedBy.isNotEmpty) 'By $uploadedBy',
      if (uploadedAt != null) formatDate(uploadedAt),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(isImage ? Icons.image_outlined : Icons.insert_drive_file_outlined, color: AppColors.primary),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: subtitleParts.isEmpty ? null : Text(subtitleParts.join(' · '), style: const TextStyle(fontSize: 12)),
        onTap: () => _openDocument(url, isImage),
        trailing: canManage
            ? IconButton(
                icon: const Icon(Icons.delete_outline, color: AppColors.danger),
                onPressed: () => _deleteDocument(index, title),
              )
            : Icon(isImage ? Icons.open_in_full : Icons.open_in_new, size: 18, color: AppColors.textSecondary),
      ),
    );
  }

  void _openDocument(String? url, bool isImage) {
    if (url == null || url.isEmpty) return;
    if (isImage) {
      showImageViewer(context, url);
    } else {
      final full = resolveUrl(url);
      if (full != null) launchUrl(Uri.parse(full), mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _addDocument() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Camera'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Gallery'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    final XFile? x;
    try {
      x = await ImagePicker().pickImage(source: source, maxWidth: 1600, imageQuality: 80);
    } catch (_) {
      showToast('Could not access ${source == ImageSource.camera ? 'camera' : 'gallery'}', error: true);
      return;
    }
    if (x == null) return;
    await _doAction(
      () => ref.read(loanRepoProvider).uploadDocuments(widget.id, [File(x!.path)]),
      'Document uploaded',
    );
  }

  Future<void> _deleteDocument(int index, String title) async {
    final ok = await confirmDialog(
      context,
      title: 'Delete Document',
      message: 'Delete "$title"?',
      confirmText: 'Delete',
      destructive: true,
    );
    if (!ok) return;
    await _doAction(() => ref.read(loanRepoProvider).deleteDocument(widget.id, index), 'Document deleted');
  }

  Widget _amountCard({required String label, required String value, required Color color, String? subtitle}) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, style: TextStyle(color: color, fontSize: 16, fontWeight: FontWeight.w700)),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 3),
            Text(
              subtitle,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: color.withValues(alpha: 0.85), fontSize: 10),
            ),
          ],
        ],
      ),
    );
  }

  // Interest rate label with its calculation method, mirroring the web summary card
  // (e.g. "12% · Reducing" or "10% · Flat · upfront").
  String _interestRateLabel(Map<String, dynamic> l) {
    final rate = '${l['interestRate'] ?? '-'}%';
    final type = l['interestType']?.toString();
    if (type == null || type.isEmpty) return rate;
    final label = type == 'FLAT' ? 'Flat' : 'Reducing';
    final upfront = l['deductInterestUpfront'] == true ? ' · upfront' : '';
    return '$rate · $label$upfront';
  }

  // Pending-verification notice (mirrors the web banner). When the org counts pending
  // collections in the balance the money is already folded into the figures above, so
  // we flag the unverified portion; otherwise we note it's awaiting verification.
  Widget _pendingBanner(Map<String, dynamic> l) {
    final pending = toNum(l['pendingCollections']);
    if (pending <= 0) return const SizedBox.shrink();
    final counted = l['pendingCounted'] == true;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          const Icon(Icons.hourglass_bottom, size: 18, color: AppColors.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              counted
                  ? '${formatCurrency(pending)} collected and counted as paid — awaiting org-admin verification.'
                  : '${formatCurrency(pending)} collected — awaiting verification (not yet counted in balances).',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  // Disbursement breakdown shown when interest was deducted upfront (daily/weekly
  // loans, or flat loans with "deduct upfront"). Mirrors the web breakdown card.
  Widget _breakdownCard(Map<String, dynamic> l) {
    if (toNum(l['upfrontInterestAmount']) <= 0) return const SizedBox.shrink();
    final type = l['loanType']?.toString();
    final title = type == 'DAILY'
        ? 'Daily Loan — Disbursement Breakdown'
        : type == 'WEEKLY'
            ? 'Weekly Loan — Disbursement Breakdown'
            : 'Disbursement Breakdown — Interest Deducted Upfront';
    final days = (l['collectionDays'] is List)
        ? (l['collectionDays'] as List).map((e) => toNum(e).toInt()).toList()
        : <int>[];
    return SectionCard(
      title: title,
      child: Column(
        children: [
          KeyValueRow(label: 'Principal', value: formatCurrency(l['principalAmount'])),
          KeyValueRow(
            label: 'Upfront Interest',
            value: '- ${formatCurrency(l['upfrontInterestAmount'])}',
            valueColor: const Color(0xFFEA580C),
          ),
          if (!loanFieldHidden(l, 'netDisbursedAmount'))
            KeyValueRow(label: 'Net Paid to Customer', value: formatCurrency(l['netDisbursedAmount']), valueColor: AppColors.accent),
          if (days.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Align(
              alignment: Alignment.centerLeft,
              child: Text('Collection Days', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
            ),
            const SizedBox(height: 6),
            Align(alignment: Alignment.centerLeft, child: _collectionDaysRow(days)),
          ],
        ],
      ),
    );
  }

  // Sun–Sat chips, highlighting the loan's collection days (JS weekday numbers, 0=Sun).
  Widget _collectionDaysRow(List<int> days) {
    const labels = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (var i = 0; i < 7; i++)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: days.contains(i) ? const Color(0xFFEA580C) : const Color(0xFFFEF3C7),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              labels[i],
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: days.contains(i) ? Colors.white : const Color(0xFFD97706),
              ),
            ),
          ),
      ],
    );
  }

  // Closure summary for closed/settled/written-off loans (mirrors the web card).
  Widget _closureCard(Map<String, dynamic> l) {
    final status = l['status']?.toString();
    if (!['CLOSED', 'SETTLED', 'DEFAULTED'].contains(status) || l['closureType'] == null) {
      return const SizedBox.shrink();
    }
    final ct = l['closureType']?.toString();
    final label = ct == 'FULL_PAYMENT'
        ? 'Fully Paid'
        : ct == 'SETTLEMENT'
            ? 'Settled'
            : 'Written Off';
    return SectionCard(
      title: 'Loan Closure Summary — $label',
      child: Column(
        children: [
          if (!loanFieldHidden(l, 'totalPayable'))
            KeyValueRow(label: 'Total Payable', value: formatCurrency(l['totalPayable'])),
          KeyValueRow(label: 'Total Recovered', value: formatCurrency(l['totalRecovered']), valueColor: AppColors.accent),
          KeyValueRow(label: 'Waived', value: formatCurrency(l['waiverAmount']), valueColor: AppColors.warning),
          KeyValueRow(label: 'Written Off (Loss)', value: formatCurrency(l['writeOffAmount']), valueColor: AppColors.danger),
          KeyValueRow(label: 'Closed On', value: formatDate(l['closedAt'])),
          // Absent on loans closed before closedById existed — those are only
          // attributable from the server access logs.
          if (l['closedBy']?['name'] != null)
            KeyValueRow(label: 'Closed By', value: l['closedBy']['name'].toString()),
          if ((l['closureNotes']?.toString() ?? '').isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Notes: ${l['closureNotes']}', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              ),
            ),
        ],
      ),
    );
  }

  // Opens the edit sheet (mirrors the web "Edit Loan" modal). On success the loan
  // is refetched — terms, schedule and the group it belongs to may all have moved.
  Future<void> _openEdit(Map<String, dynamic> l) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _EditLoanSheet(loanId: widget.id, loan: l),
    );
    if (saved == true) {
      ref.invalidate(loanDetailProvider(widget.id));
    }
  }

  // Opens the structural-correction sheet (mirrors the web "Correct Loan Terms"
  // modal). On success the loan (which carries the EMI schedule) is refetched.
  Future<void> _openCorrect(Map<String, dynamic> l) async {
    final saved = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CorrectTermsSheet(loanId: widget.id, loan: l),
    );
    if (saved == true) {
      ref.invalidate(loanDetailProvider(widget.id));
    }
  }

  // Loads the closure figures first so the sheet can show what is actually owed —
  // closing a loan with a balance is a decision (settle vs write off), not a
  // yes/no confirm.
  Future<void> _openClose() async {
    Map<String, dynamic> summary;
    try {
      summary = await ref.read(loanRepoProvider).closureSummary(widget.id);
    } on ApiException catch (e) {
      return showToast(e.message, error: true);
    }
    if (!mounted) return;
    final closed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CloseLoanSheet(loanId: widget.id, summary: summary),
    );
    if (closed == true) {
      ref.invalidate(loanDetailProvider(widget.id));
    }
  }

  // Recent collection history for this loan. The list is already included on the
  // loan detail payload (GET /loans/:id → collections, latest 20, non-rejected).
  Widget _collectionsTab(Map<String, dynamic> l) {
    final cols = (l['collections'] is List) ? List<dynamic>.from(l['collections'] as List) : const <dynamic>[];
    if (cols.isEmpty) {
      return const EmptyView(message: 'No collections yet', icon: Icons.receipt_long_outlined);
    }
    return ListView.builder(
      padding: _tabPadding(l, 12),
      itemCount: cols.length,
      itemBuilder: (ctx, i) {
        final cm = Map<String, dynamic>.from(cols[i] as Map);
        final vs = cm['verificationStatus']?.toString() ?? 'PENDING';
        final collectedBy = Map<String, dynamic>.from(cm['collectedBy'] ?? {});
        final mode = cm['paymentMode']?.toString();
        final receipt = cm['receiptNumber']?.toString();
        final emiNo = cm['emiNumber'];
        final meta = <String>[
          formatDate(cm['collectedAt']),
          if (mode != null && mode.isNotEmpty) mode,
          if ((collectedBy['name']?.toString() ?? '').isNotEmpty) 'by ${collectedBy['name']}',
        ];
        final hasReceipt = receipt != null && receipt.isNotEmpty;
        return Card(
          margin: const EdgeInsets.symmetric(vertical: 4),
          child: ListTile(
            onTap: cm['id'] != null ? () => context.push('/collections/${cm['id']}/receipt') : null,
            leading: CircleAvatar(
              backgroundColor: statusColor(vs).withValues(alpha: 0.15),
              child: Icon(Icons.payments_outlined, color: statusColor(vs), size: 20),
            ),
            title: Text(formatCurrency(cm['amount']), style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text(
              [if (hasReceipt) 'Receipt $receipt', meta.join(' • ')].join('\n'),
              style: const TextStyle(fontSize: 12),
            ),
            isThreeLine: hasReceipt,
            trailing: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                StatusChip(label: vs, color: statusColor(vs)),
                if (emiNo != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('EMI #$emiNo', style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  // EMI schedule reads from the loan detail payload (GET /loans/:id → emiSchedule),
  // the same source the web detail uses — so overdue recompute and redaction match.
  // Each row shows the principal/interest split (interest hidden alongside the loan's
  // Total Interest), plus paid amount and status.
  Widget _emiTab(Map<String, dynamic> l) {
    final items = (l['emiSchedule'] is List) ? List<dynamic>.from(l['emiSchedule'] as List) : const <dynamic>[];
    final accrual = l['interestAccrual'] == true;
    if (items.isEmpty) return EmptyView(message: accrual ? 'No ledger entries' : 'No EMI schedule');
    final showInterest = !loanFieldHidden(l, 'totalInterest');
    return ListView.builder(
      padding: _tabPadding(l, 0),
      itemCount: items.length,
      itemBuilder: (ctx, i) {
        final e = Map<String, dynamic>.from(items[i] as Map);
        final status = e['status']?.toString() ?? '';
        // Accrual ledger rows are either the principal (booked at disbursement)
        // or one month's interest — never an installment of both.
        final isPrincipalRow = toNum(e['principalComponent']) > 0;
        final parts = accrual
            ? <String>[
                isPrincipalRow
                    ? 'Principal ${formatCurrency(e['principalComponent'])}'
                    : 'Interest ${formatCurrency(e['interestComponent'])}',
                if (toNum(e['lateFee']) > 0) 'Late ${formatCurrency(e['lateFee'])}',
              ]
            : <String>[
                'EMI ${formatCurrency(e['emiAmount'])}',
                'P ${formatCurrency(e['principalComponent'])}',
                if (showInterest) 'I ${formatCurrency(e['interestComponent'])}',
                if (toNum(e['lateFee']) > 0) 'Late ${formatCurrency(e['lateFee'])}',
              ];
        return Card(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          child: ListTile(
            leading: CircleAvatar(
              backgroundColor: statusColor(status).withValues(alpha: 0.15),
              child: Text('${e['emiNumber']}', style: TextStyle(color: statusColor(status), fontWeight: FontWeight.bold)),
            ),
            title: Text(formatDate(e['dueDate'])),
            subtitle: Text(parts.join(' • ')),
            trailing: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                StatusChip(label: status, color: statusColor(status)),
                if (toNum(e['paidAmount']) > 0)
                  Text(formatCurrency(e['paidAmount']), style: const TextStyle(fontSize: 11, color: AppColors.accent)),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Loan closure form. Mirrors the web "Close Loan" modal.
///
/// When dues remain, closing is a decision about money the org is giving up, so the
/// sheet never picks a destructive default for the operator: Write Off is
/// pre-selected (it books the shortfall as a loss) and Settlement's waiver starts
/// EMPTY. It used to be possible on web to open this and confirm straight through,
/// waiving the entire live balance without typing anything — that produced a run of
/// wrongly-settled loans. The server enforces the same rule (closeLoan rejects a
/// SETTLEMENT with no explicit waiverAmount); this is the matching client guard.
class _CloseLoanSheet extends ConsumerStatefulWidget {
  final String loanId;
  final Map<String, dynamic> summary;
  const _CloseLoanSheet({required this.loanId, required this.summary});
  @override
  ConsumerState<_CloseLoanSheet> createState() => _CloseLoanSheetState();
}

class _CloseLoanSheetState extends ConsumerState<_CloseLoanSheet> {
  late String _type;
  final _waiver = TextEditingController();
  final _notes = TextEditingController();
  bool _saving = false;

  double get _outstanding => toNum(widget.summary['totalOutstanding']).toDouble();
  bool get _hasBalance => _outstanding > 0;

  @override
  void initState() {
    super.initState();
    _type = _hasBalance ? 'WRITE_OFF' : 'FULL_PAYMENT';
    _waiver.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _waiver.dispose();
    _notes.dispose();
    super.dispose();
  }

  /// Mirrors the server-side rule in closeLoan. Returns an error string, or null
  /// when the entry is usable.
  String? get _waiverError {
    if (_type != 'SETTLEMENT' || !_hasBalance) return null;
    final raw = _waiver.text.trim();
    if (raw.isEmpty) return 'Enter the amount being waived.';
    final n = double.tryParse(raw);
    if (n == null || n < 0) return 'Waiver must be a number of 0 or more.';
    if (n > _outstanding) return 'Waiver cannot exceed the outstanding of ${formatCurrency(_outstanding)}.';
    return null;
  }

  Future<void> _submit() async {
    if (_waiverError != null) return;
    setState(() => _saving = true);
    try {
      final body = <String, dynamic>{
        'closureType': _type,
        if (_type == 'SETTLEMENT') 'waiverAmount': double.tryParse(_waiver.text.trim()),
        if (_notes.text.trim().isNotEmpty) 'closureNotes': _notes.text.trim(),
      };
      await ref.read(loanRepoProvider).close(widget.loanId, body);
      if (!mounted) return;
      showToast(_type == 'SETTLEMENT'
          ? 'Loan settled and closed'
          : _type == 'WRITE_OFF'
              ? 'Loan written off and closed'
              : 'Loan closed');
      Navigator.pop(context, true);
    } on ApiException catch (e) {
      showToast(e.message, error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _figure(String label, dynamic value, {Color? color}) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
          Text(formatCurrency(value), style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: color)),
        ],
      );

  Widget _option(String value, String title, String subtitle, Color accent) {
    final selected = _type == value;
    return InkWell(
      onTap: () => setState(() => _type = value),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? accent.withValues(alpha: 0.08) : null,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? accent : AppColors.border),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
              size: 20,
              color: selected ? accent : AppColors.textSecondary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
                  Text(subtitle, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.summary;
    final err = _waiverError;
    final waiverNum = double.tryParse(_waiver.text.trim()) ?? 0;
    return DraggableScrollableSheet(
      initialChildSize: 0.9,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, ctrl) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: ListView(
          controller: ctrl,
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                const Expanded(child: Text('Close Loan', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
              ],
            ),
            Wrap(spacing: 24, runSpacing: 12, children: [
              _figure('Total Payable', s['totalPayable']),
              _figure('Total Recovered', s['totalPaid'], color: AppColors.accent),
              _figure('Outstanding', s['totalOutstanding'], color: AppColors.danger),
              _figure('Late Fees', s['totalLateFees'], color: AppColors.warning),
            ]),
            const SizedBox(height: 6),
            Text('EMIs paid ${s['paidEMIs'] ?? 0} / ${s['totalEMIs'] ?? 0}',
                style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
            const SizedBox(height: 14),
            if (_hasBalance) ...[
              const Text('Closure Type', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              _option('WRITE_OFF', 'Write Off',
                  'Write off the entire outstanding as a loss. Loan marked as defaulted.', AppColors.danger),
              _option('SETTLEMENT', 'Settlement',
                  'Waive a portion of the outstanding and close. Recorded as a settled loan.', AppColors.primary),
            ] else
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.accent.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.accent.withValues(alpha: 0.4)),
                ),
                child: const Text('All dues are fully paid. This loan will be marked as Closed.',
                    style: TextStyle(fontSize: 12)),
              ),
            if (_type == 'SETTLEMENT' && _hasBalance) ...[
              const SizedBox(height: 10),
              TextFormField(
                controller: _waiver,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Waiver Amount *',
                  hintText: 'Amount to waive',
                  prefixText: '₹ ',
                  errorText: err,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'Outstanding: ${formatCurrency(_outstanding)}. '
                'Customer pays: ${formatCurrency((_outstanding - waiverNum).clamp(0, _outstanding))}',
                style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
              if (err == null && waiverNum >= _outstanding)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text('This waives the entire outstanding balance — the customer pays nothing further.',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.danger)),
                ),
            ],
            if (_type == 'WRITE_OFF' && _hasBalance) ...[
              const SizedBox(height: 10),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.danger.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.danger.withValues(alpha: 0.4)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Loss Amount',
                        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: AppColors.danger)),
                    Text(formatCurrency(_outstanding),
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: AppColors.danger)),
                    const Text('This amount will be recorded as a write-off loss.',
                        style: TextStyle(fontSize: 11, color: AppColors.danger)),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 14),
            TextFormField(
              controller: _notes,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Closure Notes (optional)',
                hintText: 'Reason for closure...',
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(backgroundColor: AppColors.danger),
                onPressed: (_saving || err != null) ? null : _submit,
                child: _saving
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Text(_type == 'WRITE_OFF'
                        ? 'Write Off & Close'
                        : _type == 'SETTLEMENT'
                            ? 'Settle & Close'
                            : 'Close Loan'),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

/// Edit form for a booked loan (ORG_ADMIN + the `enableLoanCorrection` feature).
/// Mirrors the web "Edit Loan" modal, including its two modes: with no collections
/// recorded every term is editable and the EMI schedule is regenerated on save;
/// once money has come in — or on an account (khata) loan, whose ledger is
/// hand-built — only assignment, group, fees and notes are, which is exactly what
/// the API will accept. Structural fixes after collections go through Correct Terms.
class _EditLoanSheet extends ConsumerStatefulWidget {
  final String loanId;
  final Map<String, dynamic> loan;
  const _EditLoanSheet({required this.loanId, required this.loan});
  @override
  ConsumerState<_EditLoanSheet> createState() => _EditLoanSheetState();
}

class _EditLoanSheetState extends ConsumerState<_EditLoanSheet> {
  late String _loanType;
  late String _tenureType;
  late String _interestType;
  late bool _deductUpfront;
  late DateTime _startDate;
  late List<int> _collectionDays;
  // Explicit EMI start (first EMI due ON it); null = normal cycle — same as the web.
  DateTime? _emiStartDate;
  final _principal = TextEditingController();
  final _tenure = TextEditingController();
  final _rate = TextEditingController();
  final _fee = TextEditingController();
  final _alr = TextEditingController();
  final _lateFee = TextEditingController();
  final _notes = TextEditingController();
  Map<String, dynamic>? _group;
  Map<String, dynamic>? _assignee;
  // Picker lists, fetched on first tap and kept for the life of the sheet.
  List<Map<String, dynamic>>? _groups;
  List<Map<String, dynamic>>? _team;
  bool _loadingPicker = false;
  bool _saving = false;

  /// The loan's group as it stood when the sheet opened — the reference for "has
  /// the group changed" and for the rule that a group loan keeps a group.
  String? _originalGroupId;

  @override
  void initState() {
    super.initState();
    final l = widget.loan;
    _loanType = l['loanType']?.toString() ?? 'PERSONAL';
    _tenureType = l['tenureType']?.toString() ?? 'MONTHS';
    _interestType = l['interestType']?.toString() == 'FLAT' ? 'FLAT' : 'REDUCING';
    _deductUpfront = l['deductInterestUpfront'] == true;
    _startDate = DateTime.tryParse(l['startDate']?.toString() ?? '') ?? DateTime.now();
    // Null = normal cycle; a stored date (the start date itself included) is explicit.
    _emiStartDate = DateTime.tryParse(l['emiStartDate']?.toString() ?? '');
    final days = (l['collectionDays'] is List)
        ? (l['collectionDays'] as List).map((e) => toNum(e).toInt()).toList()
        : <int>[];
    _collectionDays = _seedDays(_loanType, days);
    _principal.text = _numText(l['principalAmount']);
    _tenure.text = _numText(l['tenure']);
    _rate.text = _numText(l['interestRate']);
    _fee.text = _numText(l['processingFee']);
    _alr.text = _numText(l['alr']);
    _lateFee.text = _numText(l['lateFeePerDay']);
    _notes.text = l['notes']?.toString() ?? '';
    if (l['group'] is Map) _group = Map<String, dynamic>.from(l['group'] as Map);
    if (l['assignedTo'] is Map) _assignee = Map<String, dynamic>.from(l['assignedTo'] as Map);
    _originalGroupId = _group?['id']?.toString();
  }

  @override
  void dispose() {
    _principal.dispose();
    _tenure.dispose();
    _rate.dispose();
    _fee.dispose();
    _alr.dispose();
    _lateFee.dispose();
    _notes.dispose();
    super.dispose();
  }

  // Mirrors web handleEditTypeChange: DAILY seeds the six working days, WEEKLY one.
  List<int> _seedDays(String type, List<int> days) {
    if (type == 'DAILY' && days.isEmpty) return [1, 2, 3, 4, 5, 6];
    if (type == 'WEEKLY' && days.length != 1) return [1];
    return List<int>.from(days);
  }

  String _numText(dynamic v) {
    if (v == null) return '';
    final n = toNum(v).toDouble();
    if (n == n.roundToDouble()) return n.toInt().toString();
    return n.toString();
  }

  /// Whether every term is editable. The API allows that only while no collection
  /// has been recorded and the loan is not an accrual (khata) account, whose
  /// hand-built ledger a regenerated EMI schedule would destroy — so the form
  /// offers exactly what the save will honour.
  bool get _fullEdit {
    final cols = (widget.loan['collections'] is List) ? widget.loan['collections'] as List : const [];
    return cols.isEmpty && widget.loan['interestAccrual'] != true;
  }

  bool get _isInstallment => _loanType == 'DAILY' || _loanType == 'WEEKLY';
  bool get _isPeriodUnit => _tenureType == 'WEEKS' || _tenureType == 'DAYS';
  String get _periodWord => _tenureType == 'WEEKS' ? 'week' : 'day';

  String get _rateLabel {
    if (_isInstallment) return 'Flat Interest Rate (% on principal)';
    if (_isPeriodUnit && _interestType == 'REDUCING') return 'Interest Rate (% per month)';
    if (_isPeriodUnit) return 'Flat Interest Rate (% on principal)';
    return 'Interest Rate (% p.a.)';
  }

  double? _num(TextEditingController c) => double.tryParse(c.text.trim());

  Future<List<T>> _withPickerLoading<T>(Future<List<T>> Function() fetch) async {
    setState(() => _loadingPicker = true);
    try {
      return await fetch();
    } on ApiException catch (e) {
      showToast(e.message, error: true);
      return <T>[];
    } finally {
      if (mounted) setState(() => _loadingPicker = false);
    }
  }

  Future<void> _pickGroup() async {
    // Cached only once it holds something: a failed or empty fetch must not stick,
    // or the next tap would report "no groups" without asking the server again.
    final groups = _groups ??
        await _withPickerLoading(() async {
          final r = await ref.read(loanGroupRepoProvider).list(limit: 500);
          final list = ((r['data'] as List?) ?? [])
              .map((e) => Map<String, dynamic>.from(e as Map))
              .where((g) => g['isActive'] == true)
              .toList();
          // Keep the loan's own group on offer even if it has since been deactivated,
          // so the current selection is visible rather than reading as unset.
          final own = _group;
          if (own != null && !list.any((g) => g['id'].toString() == own['id'].toString())) {
            list.insert(0, own);
          }
          return list;
        });
    if (!mounted) return;
    if (groups.isEmpty) return showToast('No active loan groups', error: true);
    _groups = groups;
    final picked = await showSearchableSelect<String>(
      context,
      title: 'Select Loan Group',
      searchHint: 'Search by group number or name',
      selected: _group?['id']?.toString(),
      options: groups
          .map((g) => SelectOption<String>(
                value: g['id'].toString(),
                label: '${g['groupNumber'] ?? ''} — ${g['name'] ?? ''}',
                searchText: '${g['groupNumber'] ?? ''} ${g['name'] ?? ''} ${g['leaderName'] ?? ''}',
              ))
          .toList(),
    );
    if (picked == null) return;
    setState(() => _group = groups.firstWhere((g) => g['id'].toString() == picked));
  }

  Future<void> _pickAssignee() async {
    final team = _team ??
        await _withPickerLoading(() async {
          final list = await ref.read(teamRepoProvider).list(limit: 500);
          return list
              .map((e) => Map<String, dynamic>.from(e as Map))
              .where((m) => m['isActive'] == true)
              .toList();
        });
    if (!mounted) return;
    if (team.isEmpty) return showToast('No active team members', error: true);
    _team = team;
    final picked = await showSearchableSelect<String>(
      context,
      title: 'Assigned To',
      searchHint: 'Search by name',
      selected: _assignee?['id']?.toString(),
      options: team
          .map((m) => SelectOption<String>(
                value: m['id'].toString(),
                label: '${m['name'] ?? ''} — ${m['role'] ?? ''}',
                searchText: '${m['name'] ?? ''} ${m['role'] ?? ''}',
              ))
          .toList(),
    );
    if (picked == null) return;
    setState(() => _assignee = team.firstWhere((m) => m['id'].toString() == picked));
  }

  Future<void> _submit() async {
    // A group loan must belong to a group (same rule loan creation enforces).
    // Legacy migrated group loans that never had one stay editable — don't strand them.
    final groupRequired = _loanType == 'GROUP' &&
        (widget.loan['loanType'] != 'GROUP' || _originalGroupId != null);
    if (groupRequired && _group == null) {
      return showToast('Select a loan group', error: true);
    }
    if (_fullEdit && emiStartError(_emiStartDate, _startDate) != null) {
      return showToast('EMI start date cannot be before the disbursement date', error: true);
    }
    setState(() => _saving = true);
    try {
      final body = <String, dynamic>{
        if (_assignee != null) 'assignedToId': _assignee!['id'],
        if (_rate.text.trim().isNotEmpty) 'interestRate': _num(_rate),
        if (_fee.text.trim().isNotEmpty) 'processingFee': _num(_fee),
        'alr': _alr.text.trim().isEmpty ? null : _num(_alr),
        if (_lateFee.text.trim().isNotEmpty) 'lateFeePerDay': _num(_lateFee),
        'notes': _notes.text.trim().isEmpty ? null : _notes.text.trim(),
        // The group can be changed in either mode — it is a reassignment, not a
        // term. Switching the type away from GROUP detaches the loan from its group.
        if (_loanType == 'GROUP') 'groupId': _group?['id'],
        if (_loanType != 'GROUP' && _fullEdit && _originalGroupId != null) 'groupId': null,
        if (_fullEdit) ...{
          'loanType': _loanType,
          if (_principal.text.trim().isNotEmpty) 'principalAmount': _num(_principal),
          if (_tenure.text.trim().isNotEmpty) 'tenure': int.tryParse(_tenure.text.trim()),
          'tenureType': _tenureType,
          'interestType': _interestType,
          'deductInterestUpfront': _interestType == 'FLAT' && _deductUpfront,
          'startDate': formatInputDate(_startDate),
          // Always sent (null = normal cycle) so an explicit EMI start can be cleared.
          'emiStartDate': _emiStartDate == null ? null : formatInputDate(_emiStartDate!),
          // Collection days only apply to DAILY/WEEKLY; null clears them for other
          // types so the backend rebuilds a standard schedule, not a day-filtered one.
          'collectionDays': _isInstallment ? _collectionDays : null,
        },
      };
      await ref.read(loanRepoProvider).update(widget.loanId, body);
      if (!mounted) return;
      showToast('Loan updated');
      Navigator.pop(context, true);
    } on ApiException catch (e) {
      showToast(e.message, error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final groupLoansEnabled = ref.watch(authProvider).org?.feature('enableGroupLoan') == true;
    return DraggableScrollableSheet(
      initialChildSize: 0.9,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, ctrl) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: ListView(
          controller: ctrl,
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                const Expanded(child: Text('Edit Loan', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
              ],
            ),
            if (!_fullEdit)
              Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.warning.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
                ),
                child: Text(
                  widget.loan['interestAccrual'] == true
                      ? 'This is an account (khata) loan — its ledger is kept by hand, so only assignment, group, fees and notes can be edited.'
                      : 'Collections have been recorded — only assignment, group, fees and notes can be edited. Use Correct Terms to fix the terms themselves.',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            if (_fullEdit) ...[
              DropdownButtonFormField<String>(
                initialValue: _loanType,
                decoration: const InputDecoration(labelText: 'Loan Type'),
                items: [
                  const DropdownMenuItem(value: 'PERSONAL', child: Text('Personal')),
                  const DropdownMenuItem(value: 'GOLD', child: Text('Gold')),
                  // Kept on offer for a loan that already is one, so an org that has
                  // since switched the feature off can still open its group loans.
                  if (groupLoansEnabled || _loanType == 'GROUP')
                    const DropdownMenuItem(value: 'GROUP', child: Text('Group')),
                  const DropdownMenuItem(value: 'VEHICLE', child: Text('Vehicle')),
                  const DropdownMenuItem(value: 'PROPERTY', child: Text('Property/Mortgage')),
                  const DropdownMenuItem(value: 'BUSINESS', child: Text('Business')),
                  const DropdownMenuItem(value: 'AGRICULTURE', child: Text('Agriculture')),
                  const DropdownMenuItem(value: 'EDUCATION', child: Text('Education')),
                  const DropdownMenuItem(value: 'DAILY', child: Text('Daily')),
                  const DropdownMenuItem(value: 'WEEKLY', child: Text('Weekly')),
                ],
                onChanged: (v) => setState(() {
                  _loanType = v ?? _loanType;
                  _collectionDays = _seedDays(_loanType, _collectionDays);
                }),
              ),
              const SizedBox(height: 10),
              TextFormField(
                controller: _principal,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: 'Loan Amount', prefixText: '₹ '),
              ),
              const SizedBox(height: 10),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: TextFormField(
                      controller: _tenure,
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(labelText: _isInstallment ? 'No. of Installments' : 'Tenure'),
                    ),
                  ),
                  if (!_isInstallment) ...[
                    const SizedBox(width: 10),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _tenureType,
                        decoration: const InputDecoration(labelText: 'Unit'),
                        items: const [
                          DropdownMenuItem(value: 'DAYS', child: Text('Days')),
                          DropdownMenuItem(value: 'WEEKS', child: Text('Weeks')),
                          DropdownMenuItem(value: 'MONTHS', child: Text('Months')),
                          DropdownMenuItem(value: 'YEARS', child: Text('Years')),
                        ],
                        onChanged: (v) => setState(() => _tenureType = v ?? 'MONTHS'),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 4),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('Disbursement / Start Date: ${formatDate(_startDate)}'),
                trailing: const Icon(Icons.calendar_today),
                onTap: () async {
                  final d = await showDatePicker(
                    context: context,
                    firstDate: DateTime(2015),
                    lastDate: DateTime.now().add(const Duration(days: 365)),
                    initialDate: _startDate,
                  );
                  if (d != null) setState(() => _startDate = d);
                },
              ),
              EmiStartDateTile(
                startDate: _startDate,
                emiStart: _emiStartDate,
                collectionDays: _collectionDays,
                onChanged: (d) => setState(() => _emiStartDate = d),
              ),
              // Interest method applies to every term loan; the DAILY/WEEKLY loan
              // types are fixed flat-upfront and the backend normalizes them.
              if (!_isInstallment) ...[
                DropdownButtonFormField<String>(
                  initialValue: _interestType,
                  decoration: const InputDecoration(labelText: 'Interest Calculation'),
                  items: const [
                    DropdownMenuItem(value: 'REDUCING', child: Text('Reducing Balance (interest on outstanding)')),
                    DropdownMenuItem(value: 'FLAT', child: Text('Flat Rate (interest on full principal)')),
                  ],
                  onChanged: (v) => setState(() {
                    _interestType = v ?? 'REDUCING';
                    if (_interestType != 'FLAT') _deductUpfront = false;
                  }),
                ),
                if (_isPeriodUnit && _interestType == 'REDUCING')
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      'Interest is charged on the outstanding balance each $_periodWord; '
                      'the rate is per month and is converted to a ${_tenureType == 'WEEKS' ? 'weekly' : 'daily'} charge automatically.',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                if (_interestType == 'FLAT')
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Deduct interest upfront'),
                    subtitle: const Text('Interest is taken out of the disbursed amount; EMIs repay principal only.'),
                    value: _deductUpfront,
                    onChanged: (v) => setState(() => _deductUpfront = v),
                  ),
              ],
              if (_loanType == 'DAILY') ...[
                const SizedBox(height: 14),
                const Text('Collection Days', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _weekDays.map((d) {
                    final v = d['v'] as int;
                    return FilterChip(
                      label: Text(d['l'] as String),
                      selected: _collectionDays.contains(v),
                      onSelected: (on) => setState(() {
                        _collectionDays = on
                            ? ([..._collectionDays, v]..sort())
                            : _collectionDays.where((x) => x != v).toList();
                      }),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 4),
                Text(
                  '${_collectionDays.isEmpty ? 7 : _collectionDays.length} day(s)/week — EMIs are scheduled only on these days',
                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                ),
              ],
              if (_loanType == 'WEEKLY') ...[
                const SizedBox(height: 14),
                const Text('Collection Day (one per week)', style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _weekDays.map((d) {
                    final v = d['v'] as int;
                    return ChoiceChip(
                      label: Text(d['l'] as String),
                      selected: _collectionDays.isNotEmpty && _collectionDays.first == v,
                      onSelected: (_) => setState(() => _collectionDays = [v]),
                    );
                  }).toList(),
                ),
              ],
              const SizedBox(height: 10),
            ],
            if (_loanType == 'GROUP') ...[
              SearchableSelectField(
                label: 'Loan Group',
                display: _group == null ? null : '${_group!['groupNumber'] ?? ''} — ${_group!['name'] ?? ''}',
                hint: _loadingPicker ? 'Loading groups...' : 'Select a group',
                onTap: _loadingPicker ? null : _pickGroup,
              ),
              // The schedule is only re-anchored to the new group's meeting day when it
              // is regenerated, which a loan with collections never does.
              if (!_fullEdit && _group?['id']?.toString() != _originalGroupId)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                    'The loan moves to the new group; its existing due dates are not changed.',
                    style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                  ),
                ),
              const SizedBox(height: 10),
            ],
            SearchableSelectField(
              label: 'Assigned To',
              display: _assignee?['name']?.toString(),
              hint: _loadingPicker ? 'Loading team...' : 'Select team member',
              onTap: _loadingPicker ? null : _pickAssignee,
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _rate,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: _rateLabel),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _fee,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Processing Fee', prefixText: '₹ '),
                  ),
                ),
                // ALR is a group-loan figure — offered only for GROUP loans, same as create.
                if (_loanType == 'GROUP') ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextFormField(
                      controller: _alr,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'ALR', prefixText: '₹ '),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _lateFee,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Late Fee / Day', prefixText: '₹ '),
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _notes,
              maxLines: 2,
              decoration: const InputDecoration(labelText: 'Notes'),
            ),
            if (_fullEdit)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Changing the loan type, amount, tenure, or start date will regenerate the EMI schedule.',
                  style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
                ),
              ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saving ? null : _submit,
                child: _saving
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Save Changes'),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

// Weekday options for DAILY/WEEKLY collection-day pickers (JS weekday numbers, 0=Sun).
const _weekDays = [
  {'v': 1, 'l': 'Mon'},
  {'v': 2, 'l': 'Tue'},
  {'v': 3, 'l': 'Wed'},
  {'v': 4, 'l': 'Thu'},
  {'v': 5, 'l': 'Fri'},
  {'v': 6, 'l': 'Sat'},
  {'v': 0, 'l': 'Sun'},
];

/// Structural-correction form shown for ACTIVE/CLOSED loans (ORG_ADMIN + the
/// `enableLoanCorrection` feature). Mirrors the web "Correct Loan Terms" modal:
/// type, amount, rate, tenure, start date, processing fee, and collection days
/// for DAILY/WEEKLY, plus a mandatory reason saved to the loan's notes.
class _CorrectTermsSheet extends ConsumerStatefulWidget {
  final String loanId;
  final Map<String, dynamic> loan;
  const _CorrectTermsSheet({required this.loanId, required this.loan});
  @override
  ConsumerState<_CorrectTermsSheet> createState() => _CorrectTermsSheetState();
}

class _CorrectTermsSheetState extends ConsumerState<_CorrectTermsSheet> {
  late String _loanType;
  late String _tenureType;
  late String _interestType;
  late bool _deductUpfront;
  late DateTime _startDate;
  late List<int> _collectionDays;
  // Explicit EMI start (first EMI due ON it); null = normal cycle — same as the web.
  DateTime? _emiStartDate;
  final _principal = TextEditingController();
  final _rate = TextEditingController();
  final _tenure = TextEditingController();
  final _fee = TextEditingController();
  final _reason = TextEditingController();
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final l = widget.loan;
    _loanType = l['loanType']?.toString() ?? 'PERSONAL';
    _tenureType = l['tenureType']?.toString() ?? 'MONTHS';
    _interestType = l['interestType']?.toString() == 'FLAT' ? 'FLAT' : 'REDUCING';
    _deductUpfront = l['deductInterestUpfront'] == true;
    _startDate = DateTime.tryParse(l['startDate']?.toString() ?? '') ?? DateTime.now();
    // Null = normal cycle; a stored date (the start date itself included) is explicit.
    _emiStartDate = DateTime.tryParse(l['emiStartDate']?.toString() ?? '');
    final days = (l['collectionDays'] is List)
        ? (l['collectionDays'] as List).map((e) => toNum(e).toInt()).toList()
        : <int>[];
    _collectionDays = _seedDays(_loanType, days);
    _principal.text = _numText(l['principalAmount']);
    _rate.text = _numText(l['interestRate']);
    _tenure.text = _numText(l['tenure']);
    _fee.text = _numText(l['processingFee']);
  }

  // Mirrors web openCorrect: DAILY defaults to the six working days, WEEKLY to one.
  List<int> _seedDays(String type, List<int> days) {
    if (type == 'DAILY' && days.isEmpty) return [1, 2, 3, 4, 5, 6];
    if (type == 'WEEKLY' && days.length != 1) return [1];
    return List<int>.from(days);
  }

  String _numText(dynamic v) {
    if (v == null) return '';
    final n = toNum(v).toDouble();
    if (n == n.roundToDouble()) return n.toInt().toString();
    return n.toString();
  }

  @override
  void dispose() {
    _principal.dispose();
    _rate.dispose();
    _tenure.dispose();
    _fee.dispose();
    _reason.dispose();
    super.dispose();
  }

  bool get _isInstallment => _loanType == 'DAILY' || _loanType == 'WEEKLY';
  bool get _isPeriodUnit => _tenureType == 'WEEKS' || _tenureType == 'DAYS';
  String get _periodWord => _tenureType == 'WEEKS' ? 'week' : 'day';

  String get _rateLabel {
    if (_isInstallment) return 'Flat Interest Rate (% on principal)';
    if (_isPeriodUnit && _interestType == 'REDUCING') return 'Interest Rate (% per month)';
    if (_isPeriodUnit) return 'Flat Interest Rate (% on principal)';
    return 'Interest Rate (% p.a.)';
  }

  void _onTypeChange(String? v) {
    if (v == null) return;
    setState(() {
      _loanType = v;
      _collectionDays = _seedDays(v, _collectionDays);
    });
  }

  Future<void> _submit() async {
    final reason = _reason.text.trim();
    if (reason.length < 5) {
      return showToast('Enter a reason (at least 5 characters)', error: true);
    }
    if (emiStartError(_emiStartDate, _startDate) != null) {
      return showToast('EMI start date cannot be before the disbursement date', error: true);
    }
    setState(() => _saving = true);
    try {
      final body = <String, dynamic>{
        'reason': reason,
        'loanType': _loanType,
        if (_principal.text.trim().isNotEmpty) 'principalAmount': double.tryParse(_principal.text.trim()),
        if (_rate.text.trim().isNotEmpty) 'interestRate': double.tryParse(_rate.text.trim()),
        if (_tenure.text.trim().isNotEmpty) 'tenure': int.tryParse(_tenure.text.trim()),
        if (!_isInstallment) 'tenureType': _tenureType,
        // Interest method applies to every term loan; backend normalizes DAILY/WEEKLY types.
        if (!_isInstallment) 'interestType': _interestType,
        if (!_isInstallment) 'deductInterestUpfront': _interestType == 'FLAT' && _deductUpfront,
        'startDate': formatInputDate(_startDate),
        'emiStartDate': _emiStartDate == null ? null : formatInputDate(_emiStartDate!),
        if (_fee.text.trim().isNotEmpty) 'processingFee': double.tryParse(_fee.text.trim()),
        // Collection days only apply to DAILY/WEEKLY; null clears them for other types.
        'collectionDays': _isInstallment ? _collectionDays : null,
      };
      await ref.read(loanRepoProvider).correct(widget.loanId, body);
      if (!mounted) return;
      showToast('Loan corrected — schedule rebuilt and payments re-applied');
      Navigator.pop(context, true);
    } on ApiException catch (e) {
      showToast(e.message, error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.9,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, ctrl) => Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
        child: ListView(
          controller: ctrl,
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                const Expanded(child: Text('Correct Loan Terms', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700))),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
              ],
            ),
            Container(
              margin: const EdgeInsets.only(bottom: 12),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppColors.warning.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.warning.withValues(alpha: 0.4)),
              ),
              child: const Text(
                'This rebuilds the EMI schedule from the corrected terms and re-applies the payments already recorded. Use only to fix a booking mistake (e.g. wrong tenure).',
                style: TextStyle(fontSize: 12),
              ),
            ),
            DropdownButtonFormField<String>(
              initialValue: _loanType,
              decoration: const InputDecoration(labelText: 'Loan Type'),
              items: const [
                DropdownMenuItem(value: 'PERSONAL', child: Text('Personal')),
                DropdownMenuItem(value: 'GOLD', child: Text('Gold')),
                DropdownMenuItem(value: 'VEHICLE', child: Text('Vehicle')),
                DropdownMenuItem(value: 'PROPERTY', child: Text('Property/Mortgage')),
                DropdownMenuItem(value: 'BUSINESS', child: Text('Business')),
                DropdownMenuItem(value: 'AGRICULTURE', child: Text('Agriculture')),
                DropdownMenuItem(value: 'EDUCATION', child: Text('Education')),
                DropdownMenuItem(value: 'DAILY', child: Text('Daily')),
                DropdownMenuItem(value: 'WEEKLY', child: Text('Weekly')),
              ],
              onChanged: _onTypeChange,
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _principal,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Loan Amount', prefixText: '₹ '),
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _rate,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(labelText: _rateLabel),
            ),
            const SizedBox(height: 10),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextFormField(
                    controller: _tenure,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(labelText: _isInstallment ? 'No. of Installments' : 'Tenure'),
                  ),
                ),
                if (!_isInstallment) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _tenureType,
                      decoration: const InputDecoration(labelText: 'Unit'),
                      items: const [
                        DropdownMenuItem(value: 'DAYS', child: Text('Days')),
                        DropdownMenuItem(value: 'WEEKS', child: Text('Weeks')),
                        DropdownMenuItem(value: 'MONTHS', child: Text('Months')),
                        DropdownMenuItem(value: 'YEARS', child: Text('Years')),
                      ],
                      onChanged: (v) => setState(() {
                        _tenureType = v ?? 'MONTHS';
                        // Sub-monthly collection is conventionally flat; monthly/yearly
                        // reducing. The admin can still override the method below.
                        _interestType = _isPeriodUnit ? 'FLAT' : 'REDUCING';
                        if (_interestType != 'FLAT') _deductUpfront = false;
                      }),
                    ),
                  ),
                ],
              ],
            ),
            if (!_isInstallment) ...[
              const SizedBox(height: 10),
              DropdownButtonFormField<String>(
                initialValue: _interestType,
                decoration: const InputDecoration(labelText: 'Interest Calculation'),
                items: const [
                  DropdownMenuItem(value: 'REDUCING', child: Text('Reducing Balance (interest on outstanding)')),
                  DropdownMenuItem(value: 'FLAT', child: Text('Flat Rate (interest on full principal)')),
                ],
                onChanged: (v) => setState(() {
                  _interestType = v ?? 'REDUCING';
                  if (_interestType != 'FLAT') _deductUpfront = false;
                }),
              ),
              if (_isPeriodUnit && _interestType == 'REDUCING')
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Interest is charged on the outstanding balance each $_periodWord; '
                    'the rate is per month and is converted to a ${_tenureType == 'WEEKS' ? 'weekly' : 'daily'} charge automatically.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              if (_interestType == 'FLAT')
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Deduct interest upfront'),
                  subtitle: const Text('Interest is taken out of the disbursed amount; EMIs repay principal only.'),
                  value: _deductUpfront,
                  onChanged: (v) => setState(() => _deductUpfront = v),
                ),
            ],
            const SizedBox(height: 4),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text('Start Date: ${formatDate(_startDate)}'),
              trailing: const Icon(Icons.calendar_today),
              onTap: () async {
                final d = await showDatePicker(
                  context: context,
                  firstDate: DateTime(2015),
                  lastDate: DateTime.now().add(const Duration(days: 365)),
                  initialDate: _startDate,
                );
                if (d != null) setState(() => _startDate = d);
              },
            ),
            EmiStartDateTile(
              startDate: _startDate,
              emiStart: _emiStartDate,
              collectionDays: _collectionDays,
              onChanged: (d) => setState(() => _emiStartDate = d),
            ),
            TextFormField(
              controller: _fee,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Processing Fee', prefixText: '₹ '),
            ),
            if (_loanType == 'DAILY') ...[
              const SizedBox(height: 14),
              const Text('Collection Days', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _weekDays.map((d) {
                  final v = d['v'] as int;
                  return FilterChip(
                    label: Text(d['l'] as String),
                    selected: _collectionDays.contains(v),
                    onSelected: (on) => setState(() {
                      if (on) {
                        _collectionDays = ([..._collectionDays, v]..sort());
                      } else {
                        _collectionDays = _collectionDays.where((x) => x != v).toList();
                      }
                    }),
                  );
                }).toList(),
              ),
              const SizedBox(height: 4),
              Text(
                '${_collectionDays.isEmpty ? 7 : _collectionDays.length} day(s)/week — EMIs are scheduled only on these days',
                style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
            ],
            if (_loanType == 'WEEKLY') ...[
              const SizedBox(height: 14),
              const Text('Collection Day (one per week)', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 6),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _weekDays.map((d) {
                  final v = d['v'] as int;
                  return ChoiceChip(
                    label: Text(d['l'] as String),
                    selected: _collectionDays.isNotEmpty && _collectionDays.first == v,
                    onSelected: (_) => setState(() => _collectionDays = [v]),
                  );
                }).toList(),
              ),
            ],
            const SizedBox(height: 14),
            TextFormField(
              controller: _reason,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Reason for correction *',
                hintText: 'e.g. Tenure entered as 14 by mistake, should be 100',
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              "The reason is saved to the loan's notes as an audit trail. Only verified collections are re-applied — verify any pending payment first.",
              style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saving ? null : _submit,
                child: _saving
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Apply Correction'),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}
