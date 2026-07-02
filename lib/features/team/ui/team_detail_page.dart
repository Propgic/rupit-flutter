import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/api/api_client.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/common.dart';
import '../../loans/data/loan_repo.dart';
import '../data/team_repo.dart';

final teamDetailProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, id) async {
  return ref.read(teamRepoProvider).get(id);
});

class TeamDetailPage extends ConsumerWidget {
  final String id;
  const TeamDetailPage({super.key, required this.id});

  Future<void> _toggle(WidgetRef ref) async {
    try { await ref.read(teamRepoProvider).toggleStatus(id); ref.invalidate(teamDetailProvider(id)); showToast('Status updated'); }
    on ApiException catch (e) { showToast(e.message, error: true); }
  }

  Future<void> _reset(BuildContext context, WidgetRef ref) async {
    final memberName = ref.read(teamDetailProvider(id)).value?['name']?.toString() ?? 'this member';
    final pw = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset Password'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Set a new password for $memberName.', style: const TextStyle(fontSize: 13, color: AppColors.textSecondary)),
            const SizedBox(height: 12),
            TextField(controller: pw, obscureText: true, decoration: const InputDecoration(labelText: 'New Password')),
          ],
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')), ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Reset'))],
      ),
    );
    // Clear the entered password once the modal closes (cancel or submit),
    // mirroring the web onClose that resets newPassword.
    final password = pw.text;
    pw.dispose();
    if (ok != true) return;
    try { await ref.read(teamRepoProvider).resetPassword(id, password); showToast('Password reset'); }
    on ApiException catch (e) { showToast(e.message, error: true); }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final ok = await confirmDialog(context, message: 'Delete member?', destructive: true, confirmText: 'Delete');
    if (!ok) return;
    try { await ref.read(teamRepoProvider).delete(id); if (context.mounted) context.go('/team'); showToast('Deleted'); }
    on ApiException catch (e) { showToast(e.message, error: true); }
  }

  // Hand this member's entire live workload (loans, optionally customers) over to
  // another member — the one-tap path when someone resigns.
  Future<void> _reassign(BuildContext context, WidgetRef ref) async {
    final member = ref.read(teamDetailProvider(id)).value;
    final fromName = member?['name']?.toString() ?? 'this member';
    final stats = member?['stats'] is Map ? Map<String, dynamic>.from(member!['stats'] as Map) : const {};

    List<Map<String, dynamic>> targets;
    try {
      targets = (await ref.read(teamRepoProvider).list(limit: 500))
          .map((e) => Map<String, dynamic>.from(e as Map))
          .where((m) => m['isActive'] == true && m['id'].toString() != id)
          .toList();
    } on ApiException catch (e) { showToast(e.message, error: true); return; }
    if (targets.isEmpty) { showToast('No other active member to reassign to', error: true); return; }
    if (!context.mounted) return;

    String? toId;
    bool includeCustomers = true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Reassign Work'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Move ${stats['loanCount'] ?? 0} loan(s)${includeCustomers ? ' and ${stats['customerCount'] ?? 0} customer(s)' : ''} from $fromName to another member. Closed loans and past collections stay as history.',
                  style: const TextStyle(fontSize: 13, color: AppColors.textSecondary),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: toId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Reassign to', border: OutlineInputBorder()),
                  items: targets
                      .map((m) => DropdownMenuItem(value: m['id'].toString(), child: Text(m['name']?.toString() ?? '-', overflow: TextOverflow.ellipsis)))
                      .toList(),
                  onChanged: (v) => setLocal(() => toId = v),
                ),
                CheckboxListTile(
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: includeCustomers,
                  onChanged: (v) => setLocal(() => includeCustomers = v ?? true),
                  title: const Text('Also move their customers'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(onPressed: toId == null ? null : () => Navigator.pop(ctx, true), child: const Text('Reassign')),
          ],
        ),
      ),
    );
    if (ok != true || toId == null) return;
    try {
      final msg = await ref.read(loanRepoProvider).reassignFrom(toUserId: toId!, fromUserId: id, includeCustomers: includeCustomers);
      ref.invalidate(teamDetailProvider(id));
      showToast(msg);
    } on ApiException catch (e) { showToast(e.message, error: true); }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(teamDetailProvider(id));
    final auth = ref.watch(authProvider);
    final isAdmin = auth.hasRole('ORG_ADMIN');
    final showReassign = auth.hasPermission('loans.assign') && auth.user?.id != id;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Team Member'),
        actions: [
          IconButton(icon: const Icon(Icons.edit), onPressed: () => context.push('/team/$id/edit')),
          if (isAdmin || showReassign)
            PopupMenuButton<String>(
              onSelected: (v) {
                if (v == 'reassign') _reassign(context, ref);
                if (v == 'toggle') _toggle(ref);
                if (v == 'reset') _reset(context, ref);
                if (v == 'delete') _delete(context, ref);
              },
              itemBuilder: (_) => [
                if (showReassign) const PopupMenuItem(value: 'reassign', child: Text('Reassign Work')),
                if (isAdmin) const PopupMenuItem(value: 'toggle', child: Text('Toggle Active')),
                if (isAdmin) const PopupMenuItem(value: 'reset', child: Text('Reset Password')),
                if (isAdmin) const PopupMenuItem(value: 'delete', child: Text('Delete')),
              ],
            ),
        ],
      ),
      body: data.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(message: e.toString()),
        data: (u) => ListView(
          padding: const EdgeInsets.all(14),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  children: [
                    Avatar(url: u['photo']?.toString(), name: u['name']?.toString() ?? '', size: 64),
                    const SizedBox(height: 8),
                    Text(u['name']?.toString() ?? '', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                    Text(u['role']?.toString() ?? '', style: const TextStyle(color: AppColors.textSecondary)),
                    const SizedBox(height: 6),
                    StatusChip(label: u['isActive'] == true ? 'ACTIVE' : 'INACTIVE', color: u['isActive'] == true ? AppColors.accent : AppColors.textSecondary),
                  ],
                ),
              ),
            ),
            SectionCard(
              title: 'Contact',
              child: Column(
                children: [
                  KeyValueRow(label: 'Email', value: u['email']?.toString() ?? '-'),
                  KeyValueRow(label: 'Phone', value: u['phone']?.toString() ?? '-',
                      onTap: u['phone'] != null ? () => launchUrl(Uri.parse('tel:${u['phone']}')) : null),
                ],
              ),
            ),
            SectionCard(
              title: 'Compensation',
              child: Column(
                children: [
                  KeyValueRow(label: 'Mode', value: u['salaryMode']?.toString() ?? '-'),
                  KeyValueRow(label: 'Salary', value: formatCurrency(u['salary'])),
                  KeyValueRow(label: 'Salary Type', value: u['salaryType']?.toString() ?? '-'),
                  KeyValueRow(label: 'Commission', value: '${u['commissionPercentage'] ?? 0}%'),
                ],
              ),
            ),
            SectionCard(
              title: 'Bank',
              child: Column(
                children: [
                  KeyValueRow(label: 'Bank', value: u['bankName']?.toString() ?? '-'),
                  KeyValueRow(label: 'Account', value: u['bankAccountNumber']?.toString() ?? '-'),
                  KeyValueRow(label: 'IFSC', value: u['bankIfsc']?.toString() ?? '-'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
