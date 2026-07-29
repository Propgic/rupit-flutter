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
import '../data/loan_repo.dart';

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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Loan Details'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [Tab(text: 'Details'), Tab(text: 'Collections'), Tab(text: 'EMI Schedule')],
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
                  final ok = await confirmDialog(context, message: 'Close this loan?');
                  if (ok) _doAction(() => ref.read(loanRepoProvider).close(widget.id), 'Loan closed');
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
                if (v == 'correct') {
                  await _openCorrect(l);
                }
              },
              itemBuilder: (_) => [
                if (isAdmin && correctionEnabled && l['status'] == 'ACTIVE')
                  const PopupMenuItem(value: 'correct', child: Text('Correct Terms')),
                if (isMgr && l['status'] == 'APPROVED') const PopupMenuItem(value: 'disburse', child: Text('Disburse')),
                if (isMgr && (l['status'] == 'PENDING' || l['status'] == 'APPROVED')) const PopupMenuItem(value: 'reject', child: Text('Reject')),
                if (isMgr && l['status'] == 'ACTIVE') const PopupMenuItem(value: 'close', child: Text('Close Loan')),
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
        label: 'Overdue',
        value: formatCurrency(l['overdueAmount']),
        color: AppColors.danger,
        subtitle: '${overdueEmis.toInt()} installment${overdueEmis > 1 ? 's' : ''} overdue',
      ));
    }
    if (showDue) {
      overviewCards.add(_amountCard(
        label: 'Due Amount',
        value: formatCurrency(dueAmount),
        color: AppColors.warning,
        subtitle: nextEmi.isEmpty ? null : 'EMI #${nextEmi['emiNumber']} · ${formatDate(nextEmi['dueDate'])}',
      ));
    }
    overviewCards.add(_amountCard(
      label: 'Total Due Payable',
      value: formatCurrency(totalDuePayable),
      color: AppColors.primary,
      subtitle: 'Currently due + overdue',
    ));

    return ListView(
      padding: _tabPadding(l, 14),
      children: [
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
              KeyValueRow(label: 'Tenure', value: '${l['tenure'] ?? ''} ${l['tenureType'] ?? ''}'),
              KeyValueRow(label: l['loanType'] == 'DAILY' ? 'Daily Installment' : 'EMI', value: formatCurrency(l['emiAmount'])),
              if (!loanFieldHidden(l, 'totalPayable'))
                KeyValueRow(label: 'Total Payable', value: formatCurrency(l['totalPayable'])),
              if (!loanFieldHidden(l, 'processingFee'))
                KeyValueRow(label: 'Processing Fee', value: formatCurrency(l['processingFee'])),
              if (l['alr'] != null && (double.tryParse(l['alr'].toString()) ?? 0) > 0)
                KeyValueRow(label: 'ALR', value: l['alr'].toString()),
              KeyValueRow(label: 'Start Date', value: formatDate(l['startDate'])),
              KeyValueRow(label: 'Disbursed', value: formatDate(l['disbursedDate'])),
              KeyValueRow(label: 'End Date', value: formatDate(l['endDate'])),
              if (l['disbursedDate'] != null)
                KeyValueRow(
                  label: 'Day',
                  value: () {
                    final disbursed = DateTime.tryParse(l['disbursedDate'].toString());
                    if (disbursed == null) return '-';
                    final days = DateTime.now().difference(disbursed).inDays + 1;
                    if (days <= 0) return '-';
                    if (l['loanType'] == 'WEEKLY') {
                      final weeks = days ~/ 7;
                      return weeks < 1 ? '-' : 'Week $weeks';
                    }
                    return 'Day $days';
                  }(),
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
    if (items.isEmpty) return const EmptyView(message: 'No EMI schedule');
    final showInterest = !loanFieldHidden(l, 'totalInterest');
    return ListView.builder(
      padding: _tabPadding(l, 0),
      itemCount: items.length,
      itemBuilder: (ctx, i) {
        final e = Map<String, dynamic>.from(items[i] as Map);
        final status = e['status']?.toString() ?? '';
        final parts = <String>[
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
