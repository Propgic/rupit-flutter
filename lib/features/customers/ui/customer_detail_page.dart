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
import '../data/customer_repo.dart';

final customerDetailProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, id) async {
  return ref.read(customerRepoProvider).get(id);
});

class CustomerDetailPage extends ConsumerStatefulWidget {
  final String id;
  const CustomerDetailPage({super.key, required this.id});
  @override
  ConsumerState<CustomerDetailPage> createState() => _CustomerDetailPageState();
}

class _CustomerDetailPageState extends ConsumerState<CustomerDetailPage> with SingleTickerProviderStateMixin {
  late final bool _showBalanceTab = ref.read(authProvider).org?.feature('enableConsolidatedBalance') ?? false;
  late final List<String> _tabKeys = [
    'info',
    'loans',
    'savings',
    'ledger',
    if (_showBalanceTab) 'balance',
    'documents',
  ];
  late final TabController _tabs = TabController(length: _tabKeys.length, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  Future<void> _toggleStatus() async {
    try {
      await ref.read(customerRepoProvider).toggleStatus(widget.id);
      ref.invalidate(customerDetailProvider(widget.id));
      showToast('Status updated');
    } on ApiException catch (e) {
      showToast(e.message, error: true);
    }
  }

  Future<void> _delete() async {
    final ok = await confirmDialog(context, message: 'Delete this customer?', destructive: true, confirmText: 'Delete');
    if (!ok) return;
    try {
      await ref.read(customerRepoProvider).delete(widget.id);
      if (mounted) context.go('/customers');
      showToast('Customer deleted');
    } on ApiException catch (e) {
      showToast(e.message, error: true);
    }
  }

  // Set/reset the customer portal login password.
  Future<void> _setPassword(Map<String, dynamic> c) async {
    final hasPassword = c['password'] != null;
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: Text(hasPassword ? 'Reset Customer Password' : 'Set Customer Password'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                hasPassword
                    ? 'Reset the portal login password. Share it with the customer.'
                    : 'Set a portal login password to enable customer portal access.',
                style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: ctrl,
                autofocus: true,
                onChanged: (_) => setLocal(() {}),
                decoration: const InputDecoration(
                  labelText: 'New Password',
                  hintText: 'Min 6 characters',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            TextButton(
              onPressed: ctrl.text.trim().length >= 6 ? () => Navigator.pop(ctx, true) : null,
              child: const Text('Set Password'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final password = ctrl.text.trim();
    if (password.length < 6) {
      showToast('Password must be at least 6 characters', error: true);
      return;
    }
    try {
      await ref.read(customerRepoProvider).setPassword(widget.id, password);
      ref.invalidate(customerDetailProvider(widget.id));
      showToast('Customer password set successfully');
    } on ApiException catch (e) {
      showToast(e.message, error: true);
    }
  }

  // Update the interest-free opening balance.
  Future<void> _updateOpeningBalance(Map<String, dynamic> c) async {
    final ctrl = TextEditingController(text: toNum(c['openingBalance']).toString());
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Set Opening Balance'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Set the interest-free opening balance. This represents a prior balance owed before any new loan is issued.',
              style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: ctrl,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Opening Balance', hintText: 'Enter amount'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true) return;
    final amount = num.tryParse(ctrl.text.trim());
    if (amount == null || amount < 0) {
      showToast('Please enter a valid amount', error: true);
      return;
    }
    try {
      await ref.read(customerRepoProvider).updateOpeningBalance(widget.id, amount);
      ref.invalidate(customerDetailProvider(widget.id));
      showToast('Opening balance updated successfully');
    } on ApiException catch (e) {
      showToast(e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(customerDetailProvider(widget.id));
    final auth = ref.watch(authProvider);
    final canEdit = auth.hasPermission('customers.edit');
    final isAdmin = auth.hasRole('ORG_ADMIN');
    final isManager = auth.hasRole('MANAGER');
    // Set-password is ORG_ADMIN/MANAGER on the backend; opening-balance too.
    final canManagePortal = isAdmin || isManager;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Customer'),
        actions: [
          if (canEdit)
            IconButton(icon: const Icon(Icons.edit), onPressed: () => context.push('/customers/${widget.id}/edit')),
          PopupMenuButton<String>(
            onSelected: (v) {
              final c = data.asData?.value;
              if (v == 'toggle') _toggleStatus();
              if (v == 'delete') _delete();
              if (v == 'password' && c != null) _setPassword(c);
              if (v == 'openingBalance' && c != null) _updateOpeningBalance(c);
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'toggle', child: Text('Toggle Active')),
              if (canEdit && canManagePortal)
                PopupMenuItem(
                  value: 'password',
                  child: Text(data.asData?.value['password'] != null ? 'Reset Portal Password' : 'Set Portal Password'),
                ),
              if (canEdit && canManagePortal && _showBalanceTab)
                const PopupMenuItem(value: 'openingBalance', child: Text('Update Opening Balance')),
              if (isAdmin) const PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ],
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabs: [
            for (final k in _tabKeys) Tab(text: _tabLabel(k)),
          ],
        ),
      ),
      body: data.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(message: e.toString(), onRetry: () => ref.invalidate(customerDetailProvider(widget.id))),
        data: (c) => TabBarView(
          controller: _tabs,
          children: [
            for (final k in _tabKeys) _tabBody(k, c),
          ],
        ),
      ),
    );
  }

  String _tabLabel(String key) {
    switch (key) {
      case 'info':
        return 'Info';
      case 'loans':
        return 'Loans';
      case 'savings':
        return 'Savings';
      case 'ledger':
        return 'Ledger';
      case 'balance':
        return 'Balance Sheet';
      case 'documents':
        return 'Documents';
    }
    return key;
  }

  Widget _tabBody(String key, Map<String, dynamic> c) {
    switch (key) {
      case 'info':
        return _infoTab(c);
      case 'loans':
        return _loansTab();
      case 'savings':
        return _savingsTab();
      case 'ledger':
        return _ledgerTab();
      case 'balance':
        return _balanceTab(c);
      case 'documents':
        return _documentsTab(c);
    }
    return const SizedBox.shrink();
  }

  Widget _infoTab(Map<String, dynamic> c) {
    final fullName = '${c['firstName'] ?? ''} ${c['lastName'] ?? ''}'.trim();
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        Center(
          child: Column(
            children: [
              Avatar(url: c['photo']?.toString(), name: fullName, size: 72),
              const SizedBox(height: 10),
              Text(fullName, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
              Text('${c['customerId'] ?? ''}', style: const TextStyle(color: AppColors.textSecondary)),
              const SizedBox(height: 6),
              StatusChip(
                label: c['isActive'] == true ? 'ACTIVE' : 'INACTIVE',
                color: c['isActive'] == true ? AppColors.accent : AppColors.textSecondary,
              ),
            ],
          ),
        ),
        SectionCard(
          title: 'Personal',
          child: Column(
            children: [
              KeyValueRow(label: 'Father', value: c['fatherName']?.toString() ?? '-'),
              KeyValueRow(label: 'Gender', value: c['gender']?.toString() ?? '-'),
              KeyValueRow(label: 'Date of Birth', value: formatDate(c['dateOfBirth'])),
              KeyValueRow(label: 'Phone', value: c['phone']?.toString() ?? '-',
                  onTap: c['phone'] != null ? () => launchUrl(Uri.parse('tel:${c['phone']}')) : null),
              KeyValueRow(label: 'Alt Phone', value: c['alternatePhone']?.toString() ?? '-',
                  onTap: c['alternatePhone'] != null ? () => launchUrl(Uri.parse('tel:${c['alternatePhone']}')) : null),
              KeyValueRow(label: 'Email', value: c['email']?.toString() ?? '-'),
              KeyValueRow(label: 'Aadhaar', value: c['aadhaarNumber']?.toString() ?? '-'),
              KeyValueRow(label: 'PAN', value: c['panNumber']?.toString() ?? '-'),
              // The agent this customer belongs to — and the only field officer
              // who can see them in the app.
              KeyValueRow(
                label: 'Assigned Agent',
                value: (c['assignedTo'] is Map ? c['assignedTo']['name']?.toString() : null) ?? 'Unassigned',
              ),
            ],
          ),
        ),
        SectionCard(
          title: 'Address',
          child: Column(
            children: [
              KeyValueRow(label: 'Address', value: c['address']?.toString() ?? '-'),
              KeyValueRow(label: 'City', value: c['city']?.toString() ?? '-'),
              KeyValueRow(label: 'District', value: c['district']?.toString() ?? '-'),
              KeyValueRow(label: 'State', value: c['state']?.toString() ?? '-'),
              KeyValueRow(label: 'Pincode', value: c['pincode']?.toString() ?? '-'),
            ],
          ),
        ),
        SectionCard(
          title: 'Employment & Banking',
          child: Column(
            children: [
              KeyValueRow(label: 'Occupation', value: c['occupation']?.toString() ?? '-'),
              KeyValueRow(label: 'Monthly Income', value: formatCurrency(c['monthlyIncome'])),
              KeyValueRow(label: 'Bank', value: c['bankName']?.toString() ?? '-'),
              KeyValueRow(label: 'Account', value: c['accountNumber']?.toString() ?? '-'),
              KeyValueRow(label: 'IFSC', value: c['ifscCode']?.toString() ?? '-'),
            ],
          ),
        ),
        if (c['nomineeName'] != null)
          SectionCard(
            title: 'Nominee',
            child: Column(
              children: [
                KeyValueRow(label: 'Name', value: c['nomineeName']?.toString() ?? '-'),
                KeyValueRow(label: 'Relation', value: c['nomineeRelation']?.toString() ?? '-'),
                KeyValueRow(label: 'Phone', value: c['nomineePhone']?.toString() ?? '-',
                    onTap: c['nomineePhone'] != null ? () => launchUrl(Uri.parse('tel:${c['nomineePhone']}')) : null),
              ],
            ),
          ),
      ],
    );
  }

  Widget _loansTab() {
    return FutureBuilder<List<dynamic>>(
      future: ref.read(customerRepoProvider).loans(widget.id),
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) return const LoadingView();
        if (snap.hasError) return ErrorView(message: snap.error.toString());
        final loans = snap.data ?? [];
        if (loans.isEmpty) return const EmptyView(message: 'No loans yet', icon: Icons.request_quote_outlined);
        return ListView.builder(
          itemCount: loans.length,
          itemBuilder: (ctx, i) {
            final l = Map<String, dynamic>.from(loans[i] as Map);
            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: ListTile(
                onTap: () => context.push('/loans/${l['id']}'),
                title: Text(l['loanNumber']?.toString() ?? 'Loan'),
                subtitle: Text('${l['loanType'] ?? ''} • ${formatCurrency(l['principalAmount'])}'),
                trailing: StatusChip(label: l['status']?.toString() ?? '-', color: statusColor(l['status']?.toString())),
              ),
            );
          },
        );
      },
    );
  }

  Widget _savingsTab() {
    return FutureBuilder<List<dynamic>>(
      future: ref.read(customerRepoProvider).savings(widget.id),
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) return const LoadingView();
        if (snap.hasError) return ErrorView(message: snap.error.toString());
        final items = snap.data ?? [];
        if (items.isEmpty) return const EmptyView(message: 'No savings accounts', icon: Icons.savings_outlined);
        return ListView.builder(
          itemCount: items.length,
          itemBuilder: (ctx, i) {
            final s = Map<String, dynamic>.from(items[i] as Map);
            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: ListTile(
                onTap: () => context.push('/savings/${s['id']}'),
                title: Text(s['accountNumber']?.toString() ?? 'Account'),
                subtitle: Text(s['accountType']?.toString() ?? ''),
                trailing: Text(formatCurrency(s['balance']), style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            );
          },
        );
      },
    );
  }

  Widget _ledgerTab() {
    return FutureBuilder<List<dynamic>>(
      future: ref.read(customerRepoProvider).ledger(widget.id),
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) return const LoadingView();
        if (snap.hasError) return ErrorView(message: snap.error.toString());
        final entries = snap.data ?? const [];
        if (entries.isEmpty) return const EmptyView(message: 'No ledger entries');
        return ListView.builder(
          itemCount: entries.length,
          itemBuilder: (ctx, i) {
            final m = Map<String, dynamic>.from(entries[i] as Map);
            final type = m['type']?.toString() ?? '';
            final isDebit = type == 'WITHDRAWAL';
            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: ListTile(
                leading: Icon(
                  isDebit ? Icons.arrow_upward : Icons.arrow_downward,
                  color: isDebit ? AppColors.danger : AppColors.accent,
                ),
                title: Text(type),
                subtitle: Text('${m['ref'] ?? ''} • ${formatDateTime(m['date'])}'),
                trailing: Text(
                  formatCurrency(m['amount']),
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: isDebit ? AppColors.danger : AppColors.accent,
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  // ─── Documents tab ───
  Widget _documentsTab(Map<String, dynamic> c) {
    final auth = ref.watch(authProvider);
    final canManage = auth.hasPermission('customers.edit') || auth.hasRole('ORG_ADMIN') || auth.hasRole('MANAGER');
    final docs = (c['documents'] is List) ? List<dynamic>.from(c['documents'] as List) : const <dynamic>[];
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        SectionCard(
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
                    for (var i = 0; i < docs.length; i++)
                      _documentTile(Map<String, dynamic>.from(docs[i] as Map), i, canManage),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _documentTile(Map<String, dynamic> doc, int index, bool canManage) {
    final url = (doc['url'] ?? doc['path'])?.toString();
    final title = (doc['name'] ?? doc['title'] ?? 'Document').toString();
    final isImage = _isImageDoc(url);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(isImage ? Icons.image_outlined : Icons.insert_drive_file_outlined, color: AppColors.primary),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
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

  bool _isImageDoc(String? url) {
    if (url == null) return false;
    final lower = url.toLowerCase();
    return lower.endsWith('.png') || lower.endsWith('.jpg') || lower.endsWith('.jpeg') || lower.endsWith('.webp') || lower.endsWith('.gif');
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
    try {
      final x = await ImagePicker().pickImage(source: source, maxWidth: 1600, imageQuality: 80);
      if (x == null) return;
      await ref.read(customerRepoProvider).uploadDocuments(widget.id, [File(x.path)]);
      ref.invalidate(customerDetailProvider(widget.id));
      showToast('Document uploaded');
    } on ApiException catch (e) {
      showToast(e.message, error: true);
    }
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
    try {
      await ref.read(customerRepoProvider).deleteDocument(widget.id, index);
      ref.invalidate(customerDetailProvider(widget.id));
      showToast('Document deleted');
    } on ApiException catch (e) {
      showToast(e.message, error: true);
    }
  }

  // ─── Consolidated Balance Sheet tab ───
  Widget _balanceTab(Map<String, dynamic> c) {
    return FutureBuilder<Map<String, dynamic>>(
      future: ref.read(customerRepoProvider).consolidatedBalance(widget.id),
      builder: (ctx, snap) {
        if (snap.connectionState == ConnectionState.waiting) return const LoadingView();
        if (snap.hasError) return ErrorView(message: snap.error.toString());
        final data = snap.data ?? const {};
        final summary = (data['summary'] is Map) ? Map<String, dynamic>.from(data['summary'] as Map) : null;
        if (summary == null) return const EmptyView(message: 'No data available');
        final loansByType = (data['loansByType'] is List) ? List<dynamic>.from(data['loansByType'] as List) : const <dynamic>[];
        final auth = ref.watch(authProvider);
        final canSettle = auth.hasRole('ORG_ADMIN') || auth.hasRole('MANAGER');
        final grandTotal = toNum(summary['grandTotal']);
        return ListView(
          padding: const EdgeInsets.all(14),
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text('Consolidated Balance Sheet', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                ),
                if (canSettle)
                  FilledButton.icon(
                    onPressed: () => _settle(summary),
                    icon: const Icon(Icons.handshake_outlined, size: 18),
                    label: const Text('Settle All'),
                    style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            if (loansByType.isEmpty)
              const SectionCard(child: EmptyView(message: 'No active loans'))
            else
              for (final t in loansByType) _loanTypeCard(Map<String, dynamic>.from(t as Map)),
            SectionCard(
              title: 'Summary',
              child: Column(
                children: [
                  KeyValueRow(label: 'Total Principal', value: formatCurrency(summary['totalPrincipal'])),
                  KeyValueRow(label: 'Total Payable', value: formatCurrency(summary['totalPayable'])),
                  KeyValueRow(label: 'Total Paid', value: formatCurrency(summary['totalPaid']), valueColor: AppColors.accent),
                  KeyValueRow(label: 'Late Fees', value: formatCurrency(summary['totalLateFees']), valueColor: AppColors.warning),
                  if (toNum(summary['openingBalance']) > 0)
                    KeyValueRow(label: 'Opening Balance', value: formatCurrency(summary['openingBalance']), valueColor: AppColors.warning),
                  const Divider(),
                  KeyValueRow(
                    label: 'Final Balance',
                    value: formatCurrency(grandTotal),
                    valueColor: AppColors.danger,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _loanTypeCard(Map<String, dynamic> group) {
    final loans = (group['loans'] is List) ? List<dynamic>.from(group['loans'] as List) : const <dynamic>[];
    return SectionCard(
      title: '${titleCase((group['loanType'] ?? '').toString())} (${loans.length})',
      child: Column(
        children: [
          for (final l in loans) _balanceLoanRow(Map<String, dynamic>.from(l as Map)),
          const Divider(),
          KeyValueRow(label: 'Type Balance', value: formatCurrency(group['typeBalance'])),
          KeyValueRow(label: 'Type Late Fees', value: formatCurrency(group['typeLateFees']), valueColor: AppColors.warning),
          KeyValueRow(label: 'Type Outstanding', value: formatCurrency(group['typeTotalOutstanding']), valueColor: AppColors.danger),
        ],
      ),
    );
  }

  Widget _balanceLoanRow(Map<String, dynamic> loan) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(loan['loanNumber']?.toString() ?? 'Loan', style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 2),
          Text(
            'Payable ${formatCurrency(loan['totalPayable'])} • Paid ${formatCurrency(loan['totalPaid'])} • Outstanding ${formatCurrency(loan['totalOutstanding'])}',
            style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
        ],
      ),
    );
  }

  // Bulk-settle all active loans.
  Future<void> _settle(Map<String, dynamic> summary) async {
    final grandTotal = toNum(summary['grandTotal']);
    final activeLoansCount = toNum(summary['activeLoansCount']).toInt();
    final amountCtrl = TextEditingController();
    final notesCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) {
          final entered = num.tryParse(amountCtrl.text.trim());
          final waiver = entered == null ? null : (grandTotal - entered);
          return AlertDialog(
            title: const Text('Bulk Settlement'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Enter the amount to settle and close all $activeLoansCount active loan(s). The waiver is calculated automatically.',
                  style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
                ),
                const SizedBox(height: 12),
                KeyValueRow(label: 'Total Outstanding', value: formatCurrency(grandTotal)),
                const SizedBox(height: 8),
                TextField(
                  controller: amountCtrl,
                  autofocus: true,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (_) => setLocal(() {}),
                  decoration: const InputDecoration(labelText: 'Settlement Amount', hintText: 'Enter amount'),
                ),
                if (waiver != null && waiver > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: KeyValueRow(label: 'Waiver Amount', value: formatCurrency(waiver), valueColor: AppColors.accent),
                  ),
                const SizedBox(height: 8),
                TextField(
                  controller: notesCtrl,
                  decoration: const InputDecoration(labelText: 'Notes (Optional)', hintText: 'Reason / discount details'),
                ),
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              FilledButton(
                onPressed: (entered != null && entered > 0) ? () => Navigator.pop(ctx, true) : null,
                style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
                child: const Text('Confirm Settlement'),
              ),
            ],
          );
        },
      ),
    );
    if (ok != true) return;
    final amount = num.tryParse(amountCtrl.text.trim());
    if (amount == null || amount <= 0) {
      showToast('Please enter a valid settlement amount', error: true);
      return;
    }
    if (amount > grandTotal) {
      showToast('Settlement amount cannot exceed total outstanding', error: true);
      return;
    }
    final notes = notesCtrl.text.trim();
    try {
      await ref.read(customerRepoProvider).consolidatedSettle(widget.id, {
        'settlementAmount': amount,
        'notes': notes.isEmpty ? null : notes,
      });
      ref.invalidate(customerDetailProvider(widget.id));
      if (mounted) setState(() {});
      showToast('Loans settled successfully');
    } on ApiException catch (e) {
      showToast(e.message, error: true);
    }
  }
}
