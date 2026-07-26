import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/api/api_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/common.dart';
import '../data/loan_group_repo.dart';

// Prisma Decimals arrive as strings ("12.5"); show them without trailing ".0".
String _trimNum(dynamic v) {
  final n = double.tryParse(v?.toString() ?? '');
  if (n == null) return v?.toString() ?? '-';
  return n == n.roundToDouble() ? n.toInt().toString() : n.toString();
}

final groupDetailProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, id) async {
  return ref.read(loanGroupRepoProvider).get(id);
});
final groupLoansProvider = FutureProvider.autoDispose.family<List<dynamic>, String>((ref, id) async {
  return ref.read(loanGroupRepoProvider).loans(id);
});

class LoanGroupDetailPage extends ConsumerWidget {
  final String id;
  const LoanGroupDetailPage({super.key, required this.id});

  Future<void> _toggle(WidgetRef ref, BuildContext context) async {
    try {
      await ref.read(loanGroupRepoProvider).toggleStatus(id);
      ref.invalidate(groupDetailProvider(id));
      showToast('Status updated');
    } on ApiException catch (e) {
      showToast(e.message, error: true);
    }
  }

  // Promote a member to leader (or clear it when customerId is null). The backend copies
  // the member's name + phone into the group's leader fields, shown on the listing page.
  Future<void> _setLeader(WidgetRef ref, String? customerId) async {
    try {
      await ref.read(loanGroupRepoProvider).setLeader(id, customerId);
      ref.invalidate(groupDetailProvider(id));
      ref.invalidate(groupLoansProvider(id));
      showToast(customerId == null ? 'Group leader cleared' : 'Group leader updated');
    } on ApiException catch (e) {
      showToast(e.message, error: true);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(groupDetailProvider(id));
    final loans = ref.watch(groupLoansProvider(id));
    return Scaffold(
      appBar: AppBar(
        title: const Text('Loan Group'),
        actions: [
          IconButton(icon: const Icon(Icons.edit), onPressed: () => context.push('/loan-groups/$id/edit')),
          IconButton(icon: const Icon(Icons.toggle_on), tooltip: 'Toggle Status', onPressed: () => _toggle(ref, context)),
        ],
      ),
      body: data.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(message: e.toString()),
        data: (g) => ListView(
          padding: const EdgeInsets.all(14),
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(g['name']?.toString() ?? '', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                    const SizedBox(height: 4),
                    StatusChip(label: g['isActive'] == true ? 'ACTIVE' : 'INACTIVE', color: g['isActive'] == true ? AppColors.accent : AppColors.textSecondary),
                  ],
                ),
              ),
            ),
            SectionCard(
              title: 'Details',
              child: Column(
                children: [
                  KeyValueRow(label: 'Leader', value: g['leaderName']?.toString() ?? '-'),
                  KeyValueRow(label: 'Leader Phone', value: g['leaderPhone']?.toString() ?? '-'),
                  KeyValueRow(label: 'Members', value: g['memberCount']?.toString() ?? '-'),
                  KeyValueRow(label: 'Cycle', value: g['cycle']?.toString() ?? '-'),
                  KeyValueRow(label: 'Meeting Day', value: g['meetingDay']?.toString() ?? '-'),
                  KeyValueRow(label: 'Meeting Time', value: g['meetingTime']?.toString() ?? '-'),
                  KeyValueRow(label: 'Meeting Place', value: g['meetingPlace']?.toString() ?? '-'),
                  if (g['description'] != null) KeyValueRow(label: 'Description', value: g['description'].toString()),
                ],
              ),
            ),
            if (g['assignedTo'] != null || g['interestRate'] != null || g['tenure'] != null ||
                g['emiFrequency'] != null || g['interestType'] != null || g['processingFee'] != null ||
                g['alr'] != null)
              SectionCard(
                title: 'Loan Terms',
                child: Column(
                  children: [
                    if (g['assignedTo'] is Map)
                      KeyValueRow(label: 'Assigned To', value: (g['assignedTo'] as Map)['name']?.toString() ?? '-'),
                    if (g['interestRate'] != null)
                      KeyValueRow(label: 'Interest Rate', value: '${_trimNum(g['interestRate'])}%'),
                    if (g['tenure'] != null)
                      KeyValueRow(
                        label: 'Tenure',
                        value: '${g['tenure']} ${const {'DAILY': 'days', 'WEEKLY': 'weeks', 'MONTHLY': 'months'}[g['emiFrequency']] ?? ''}'.trim(),
                      ),
                    if (g['emiFrequency'] != null)
                      KeyValueRow(label: 'EMI Frequency', value: g['emiFrequency'].toString()),
                    if (g['interestType'] != null)
                      KeyValueRow(
                        label: 'Interest Calculation',
                        value: g['interestType'] == 'FLAT'
                            ? 'Flat Rate${g['deductInterestUpfront'] == true ? ' (interest upfront)' : ''}'
                            : 'Reducing Balance',
                      ),
                    if (g['processingFee'] != null && (double.tryParse(g['processingFee'].toString()) ?? 0) > 0)
                      KeyValueRow(label: 'Processing Fee', value: formatCurrency(g['processingFee'])),
                    if (g['alr'] != null && (double.tryParse(g['alr'].toString()) ?? 0) > 0)
                      KeyValueRow(label: 'ALR', value: _trimNum(g['alr'])),
                  ],
                ),
              ),
            SectionCard(
              title: 'Loans',
              child: loans.when(
                loading: () => const LoadingView(),
                error: (e, _) => ErrorView(message: e.toString()),
                data: (items) {
                  if (items.isEmpty) return const EmptyView(message: 'No loans assigned');
                  final leaderPhone = g['leaderPhone']?.toString() ?? '';
                  return Column(
                    children: items.map((l) {
                      final m = Map<String, dynamic>.from(l as Map);
                      final c = Map<String, dynamic>.from(m['customer'] ?? {});
                      final phone = c['phone']?.toString() ?? '';
                      final isLeader = leaderPhone.isNotEmpty && phone.isNotEmpty && phone == leaderPhone;
                      return ListTile(
                        contentPadding: EdgeInsets.zero,
                        onTap: () => context.push('/loans/${m['id']}'),
                        title: Row(
                          children: [
                            Flexible(child: Text(m['loanNumber']?.toString() ?? '')),
                            if (isLeader) ...[
                              const SizedBox(width: 6),
                              StatusChip(label: 'LEADER', color: AppColors.warning),
                            ],
                          ],
                        ),
                        subtitle: Text('${c['firstName'] ?? ''} ${c['lastName'] ?? ''} • ${formatCurrency(m['principalAmount'])}'),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            IconButton(
                              icon: Icon(isLeader ? Icons.star : Icons.star_border,
                                  color: isLeader ? AppColors.warning : AppColors.textSecondary),
                              tooltip: isLeader ? 'Remove as leader' : 'Make leader',
                              onPressed: () => _setLeader(ref, isLeader ? null : m['customerId']?.toString()),
                            ),
                            StatusChip(label: m['status']?.toString() ?? '-', color: statusColor(m['status']?.toString())),
                          ],
                        ),
                      );
                    }).toList(),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
