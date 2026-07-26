import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/api/api_client.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/common.dart';
import '../data/collection_repo.dart';

class ReceiptPage extends ConsumerStatefulWidget {
  final String id;
  const ReceiptPage({super.key, required this.id});
  @override
  ConsumerState<ReceiptPage> createState() => _ReceiptPageState();
}

class _ReceiptPageState extends ConsumerState<ReceiptPage> {
  Future<Map<String, dynamic>>? _future;

  @override
  void initState() {
    super.initState();
    _future = ref.read(collectionRepoProvider).getReceipt(widget.id);
  }

  Future<void> _editAmount(Map<String, dynamic> collection) async {
    final amountCtrl = TextEditingController(text: (collection['amount'] ?? '').toString());
    final alrCtrl = TextEditingController(text: (collection['alrAmount'] ?? '').toString());
    final notesCtrl = TextEditingController(text: collection['notes']?.toString() ?? '');
    // ALR is only editable when the loan was created with an ALR (or the collection
    // already carries one that may need correcting).
    final showAlr = (double.tryParse((collection['loan'] as Map?)?['alr']?.toString() ?? '') ?? 0) > 0 ||
        (double.tryParse(collection['alrAmount']?.toString() ?? '') ?? 0) > 0;
    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Amount'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: amountCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Amount', prefixText: '₹ '),
            ),
            if (showAlr) ...[
              const SizedBox(height: 10),
              TextField(
                controller: alrCtrl,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'ALR'),
              ),
            ],
            const SizedBox(height: 10),
            TextField(
              controller: notesCtrl,
              decoration: const InputDecoration(labelText: 'Notes (optional)'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (saved != true) return;
    final raw = amountCtrl.text.trim();
    if (raw.isEmpty) return showToast('Enter an amount', error: true);
    final amount = double.tryParse(raw);
    if (amount == null || amount < 0) return showToast('Enter a valid amount', error: true);
    final alrRaw = alrCtrl.text.trim();
    final alr = double.tryParse(alrRaw);
    if (alrRaw.isNotEmpty && (alr == null || alr < 0)) return showToast('Enter a valid ALR', error: true);
    // Amount 0 removes the collection entirely — confirm before the destructive action.
    if (amount == 0) {
      if (!mounted) return;
      final ok = await confirmDialog(
        context,
        title: 'Remove collection?',
        message: 'Setting the amount to 0 will remove this collection.',
        confirmText: 'Remove',
        destructive: true,
      );
      if (!ok) return;
    }
    try {
      final result = await ref.read(collectionRepoProvider).update(
            widget.id,
            amount: amount,
            alrAmount: alrRaw.isEmpty ? null : alr,
            // Only touch ALR when the field was shown; otherwise leave it unchanged.
            sendAlr: showAlr,
            notes: notesCtrl.text.trim().isEmpty ? null : notesCtrl.text.trim(),
          );
      if (result['deleted'] == true) {
        showToast('Collection removed');
        if (mounted) Navigator.of(context).pop();
        return;
      }
      showToast('Collection amount updated');
      if (mounted) setState(() => _future = ref.read(collectionRepoProvider).getReceipt(widget.id));
    } on ApiException catch (e) {
      showToast(e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Receipt')),
      body: FutureBuilder<Map<String, dynamic>>(
        future: _future,
        builder: (ctx, snap) {
          if (snap.connectionState == ConnectionState.waiting) return const LoadingView();
          if (snap.hasError) {
            return ErrorView(message: snap.error.toString(), onRetry: () {
              setState(() => _future = ref.read(collectionRepoProvider).getReceipt(widget.id));
            });
          }
          final r = snap.data ?? {};
          final collection = Map<String, dynamic>.from(r['collection'] ?? r);
          final cust = Map<String, dynamic>.from(collection['customer'] ?? {});
          final loan = Map<String, dynamic>.from(collection['loan'] ?? {});
          final isChit = collection['sourceType'] == 'CHITFUND';
          final chit = Map<String, dynamic>.from(collection['chitfund'] ?? {});
          final orgRaw = r['org'] ?? r['organization'];
          final org = Map<String, dynamic>.from(orgRaw is Map ? orgRaw : {});
          // The receipt payload carries the org's *current* settings. Prefer them over the
          // session copy: a mobile session can outlive a Loan Settings change by weeks, and
          // gating on the stale cache hides the Edit button until the next login.
          final orgSettings =
              Map<String, dynamic>.from(org['settings'] is Map ? org['settings'] as Map : {});
          final auth = ref.watch(authProvider);
          final role = auth.user?.role;
          final status = collection['verificationStatus']?.toString() ?? 'PENDING';
          // Mirrors the backend (collection.controller.js → updateCollection).
          // Editing requires the collections.edit permission for everyone.
          final canEditCollections = auth.hasPermission('collections.edit');
          bool canEdit;
          if (role == 'FIELD_OFFICER') {
            // A field agent owns their collection only until it's verified: they may
            // correct their OWN collection while it is still PENDING, and can no longer
            // touch it once it's verified. Gated only by its own Loan Settings toggle
            // (allowFieldOfficerCollectionEdit) — INDEPENDENT of allowCollectionEdit /
            // verifiedCollectionEditPolicy, which govern ADMIN edits of verified collections.
            // Prefer the receipt payload's fresh setting; fall back to the session copy.
            final foEditEnabled = orgSettings.containsKey('allowFieldOfficerCollectionEdit')
                ? orgSettings['allowFieldOfficerCollectionEdit'] != false
                : auth.org?.allowFieldOfficerCollectionEdit != false;
            canEdit = foEditEnabled &&
                canEditCollections &&
                collection['collectedById'] == auth.user?.id &&
                status == 'PENDING';
          } else {
            // ORG_ADMIN / MANAGER: governed by Loan Settings. The org master switch must be
            // on for any edit; a verified collection is subject to verifiedCollectionEditPolicy.
            final editingEnabled = orgSettings.containsKey('allowCollectionEdit')
                ? orgSettings['allowCollectionEdit'] == true
                : auth.org?.allowCollectionEdit == true;
            final verifiedEditPolicy = orgSettings['verifiedCollectionEditPolicy']?.toString() ??
                auth.org?.verifiedCollectionEditPolicy ??
                'WINDOW_24H';
            final verifiedAt = DateTime.tryParse(collection['verifiedAt']?.toString() ?? '');
            final withinVerifiedEditWindow = verifiedAt != null &&
                DateTime.now().difference(verifiedAt.toLocal()) <= const Duration(hours: 24);
            final verifiedEditable = verifiedEditPolicy == 'ALWAYS' ||
                (verifiedEditPolicy == 'WINDOW_24H' && withinVerifiedEditWindow);
            final statusEditable =
                status == 'PENDING' || (status == 'VERIFIED' && verifiedEditable);
            canEdit = editingEnabled && statusEditable && canEditCollections;
          }
          final canCreate = auth.hasPermission('collections.create');
          return ListView(
            padding: const EdgeInsets.all(14),
            children: [
              if (canEdit || canCreate)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Row(
                    children: [
                      if (canEdit)
                        Expanded(
                          child: OutlinedButton.icon(
                            onPressed: () => _editAmount(collection),
                            icon: const Icon(Icons.edit),
                            label: const Text('Edit Amount'),
                          ),
                        ),
                      if (canEdit && canCreate) const SizedBox(width: 10),
                      if (canCreate)
                        Expanded(
                          // Quick next-step CTA: jump straight into recording another collection.
                          child: ElevatedButton.icon(
                            onPressed: () => context.push('/collections/new'),
                            icon: const Icon(Icons.add),
                            label: const Text('New Collection'),
                          ),
                        ),
                    ],
                  ),
                ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    children: [
                      const Icon(Icons.verified, color: AppColors.accent, size: 48),
                      const SizedBox(height: 10),
                      Text(org['name']?.toString() ?? 'Organization', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 4),
                      const Divider(),
                      const SizedBox(height: 4),
                      Text('Receipt #${collection['receiptNumber'] ?? collection['id']}',
                          style: const TextStyle(fontSize: 14, color: AppColors.textSecondary)),
                      const SizedBox(height: 14),
                      Text(formatCurrency(collection['amount']), style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800, color: AppColors.primary)),
                      if ((double.tryParse(collection['alrAmount']?.toString() ?? '') ?? 0) > 0)
                        Text('+ ALR ${formatCurrency(collection['alrAmount'])}', style: const TextStyle(fontSize: 13)),
                    ],
                  ),
                ),
              ),
              SectionCard(
                title: 'Details',
                child: Column(
                  children: [
                    KeyValueRow(label: 'Customer', value: '${cust['firstName'] ?? ''} ${cust['lastName'] ?? ''}'.trim()),
                    if (isChit) ...[
                      KeyValueRow(label: 'Chit #', value: (chit['chitNumber'] ?? chit['name'])?.toString() ?? '-'),
                      if (collection['monthNumber'] != null)
                        KeyValueRow(label: 'Month', value: '#${collection['monthNumber']}'),
                    ] else
                      KeyValueRow(label: 'Loan #', value: loan['loanNumber']?.toString() ?? '-'),
                    KeyValueRow(label: 'Date', value: formatDateTime(collection['collectedAt'])),
                    KeyValueRow(label: 'Payment Mode', value: collection['paymentMode']?.toString() ?? '-'),
                    if (collection['paymentReference'] != null)
                      KeyValueRow(label: 'Reference', value: collection['paymentReference'].toString()),
                    KeyValueRow(label: 'Status', value: collection['verificationStatus']?.toString() ?? '-'),
                    KeyValueRow(label: 'Collected By', value: (collection['collectedBy'] is Map ? collection['collectedBy']['name']?.toString() : null) ?? '-'),
                    KeyValueRow(
                      label: isChit ? 'Total Paid by Member' : 'Total Paid on Loan',
                      value: formatCurrency(isChit ? r['totalPaidByMember'] : r['totalPaidOnLoan']),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
