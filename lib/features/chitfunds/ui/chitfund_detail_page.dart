import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/api/api_client.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/auth/auth_models.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/common.dart';
import '../data/chitfund_repo.dart';
import '../../customers/data/customer_repo.dart';
import 'field_officer_picker.dart';
import 'chitfund_timeline.dart';
import 'chitfund_profit_panel.dart';

final chitfundDetailProvider = FutureProvider.autoDispose.family<Map<String, dynamic>, String>((ref, id) async {
  return ref.read(chitfundRepoProvider).get(id);
});
final chitfundMembersProvider = FutureProvider.autoDispose.family<List<dynamic>, String>((ref, id) async {
  return ref.read(chitfundRepoProvider).members(id);
});
final chitfundAuctionsProvider = FutureProvider.autoDispose.family<List<dynamic>, String>((ref, id) async {
  return ref.read(chitfundRepoProvider).auctions(id);
});
final chitfundPaymentsProvider = FutureProvider.autoDispose.family<List<dynamic>, String>((ref, id) async {
  return ref.read(chitfundRepoProvider).payments(id);
});
final chitfundPayoutsProvider = FutureProvider.autoDispose.family<List<dynamic>, String>((ref, id) async {
  return ref.read(chitfundRepoProvider).payouts(id);
});

const _paymentModes = ['CASH', 'UPI', 'BANK_TRANSFER', 'CHEQUE', 'ONLINE'];
const _paymentModeLabels = {
  'CASH': 'Cash', 'UPI': 'UPI', 'BANK_TRANSFER': 'Bank Transfer', 'CHEQUE': 'Cheque', 'ONLINE': 'Online',
};

// Who may delete a chit collection from the Payments tab, and until when (the backend
// enforces the same rule in deletePayment):
//   • PENDING  — deletable by anyone who can record/manage payments.
//   • VERIFIED — only ORG_ADMIN / MANAGER, within 24h of verification.
//   • REJECTED — not deletable here.
const _deleteVerifiedWindowMs = 24 * 60 * 60 * 1000;
bool _canDeletePayment(Map<String, dynamic> row, String? role) {
  final status = row['verificationStatus']?.toString() ?? 'PENDING';
  if (status == 'PENDING') return true;
  if (status == 'VERIFIED' && (role == 'ORG_ADMIN' || role == 'MANAGER')) {
    final va = row['verifiedAt'];
    final t = va == null ? null : DateTime.tryParse(va.toString());
    if (t == null) return false;
    return DateTime.now().difference(t).inMilliseconds <= _deleteVerifiedWindowMs;
  }
  return false;
}

// The chit installment that belongs to the current calendar month. A monthly chit has one
// installment per calendar month, so the "current month" is just how many calendar months
// have elapsed since the start month (1-based) — regardless of the day-of-month or of whether
// that month's auction has already been held. This is what collectors mean by "this month",
// and it can lag chitfund.currentMonth, which advances the instant an auction is conducted
// (e.g. right after this month's auction, currentMonth points at NEXT month, not the one due).
int? currentChitMonth(dynamic startDate) {
  if (startDate == null) return null;
  final start = tryParseDate(startDate.toString());
  if (start == null) return null;
  final now = DateTime.now();
  return (now.year - start.year) * 12 + (now.month - start.month) + 1;
}

// Opens the chit-installment "Record Payment" sheet for [chitfund] (a full chitfund detail
// map, i.e. GET /chitfunds/:id). Shared by this page's Record-Payment action and the
// field-agent Record Collection form, so both drive the same month/member/dues flow and the
// same POST /chitfunds/:id/payments → Collection pipeline. [onRecorded] fires after each save.
Future<void> openChitCollectionSheet(
  BuildContext context,
  WidgetRef ref, {
  required Map<String, dynamic> chitfund,
  VoidCallback? onRecorded,
}) async {
  final chitfundId = chitfund['id'].toString();
  final members = await ref.read(chitfundRepoProvider).members(chitfundId);
  if (!context.mounted) return;
  final duration = toNum(chitfund['durationMonths']).toInt();
  final maxMonth = duration < 1 ? 1 : duration;
  // Land on the calendar-derived in-progress month, not the auction pointer (which
  // already names next month once this month's auction is recorded).
  final current = toNum(chitfund['calendarMonth'] ?? chitfund['currentMonth']).toInt();
  final initialMonth = current < 1 ? 1 : (current > maxMonth ? maxMonth : current);
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _PaymentSheet(
      chitfundId: chitfundId,
      chitfund: chitfund,
      members: members,
      initialMonth: initialMonth,
      onRecorded: onRecorded ?? () {},
    ),
  );
}

class ChitfundDetailPage extends ConsumerStatefulWidget {
  final String id;
  // Dashboard "To Be Collected" deep-link (?tab=members&member=<id>): land on the given
  // tab and pop that member's transactions popup once the member list has loaded.
  final String? initialTab;
  final String? initialMemberId;
  const ChitfundDetailPage({super.key, required this.id, this.initialTab, this.initialMemberId});
  @override
  ConsumerState<ChitfundDetailPage> createState() => _ChitfundDetailPageState();
}

class _ChitfundDetailPageState extends ConsumerState<ChitfundDetailPage> with SingleTickerProviderStateMixin {
  // Visible tabs in display order, with per-role hidden ones (Settings → Chitfund
  // Settings) filtered out. `info` is always shown; the rest gate on chitfund.tab.<key>.
  // Landing on the first visible tab gives web's "fall back to first visible tab".
  // Not `final`: the set is re-derived from the auth session (see _syncTabsWithAuth),
  // because initState's snapshot can predate the session load — which would otherwise
  // permanently drop the permission-gated Profits tab.
  late List<String> _tabKeys;
  late TabController _tabs;
  // Bumped on every refresh so the embedded ChitfundTimeline refetches.
  int _reloadKey = 0;

  // Payments-tab filters (client-side over the loaded list). Empty string = "All".
  final _paySearchC = TextEditingController();
  String _payType = '';
  String _payStatus = '';
  String _payMonth = '';
  String _payMode = '';
  bool _payMonthDefaulted = false;
  // One-shot guard for the dashboard deep-link: open the target member's popup once.
  bool _deepLinkOpened = false;

  @override
  void initState() {
    super.initState();
    // Initial tab set from the current auth snapshot. This can run before the auth
    // session has finished loading (the router lets pages build while auth.loading),
    // in which case the permission-gated Profits tab is absent here and is added by
    // the ref.listen(authProvider) re-sync in build() once the session arrives.
    _tabKeys = _computeTabKeys(ref.read(authProvider));
    // Deep-link: land on the requested (visible) tab; otherwise the first tab.
    final initialIndex = widget.initialTab != null ? _tabKeys.indexOf(widget.initialTab!) : -1;
    _tabs = TabController(length: _tabKeys.length, vsync: this, initialIndex: initialIndex >= 0 ? initialIndex : 0);
    _paySearchC.addListener(() => setState(() {}));
  }

  @override
  void dispose() { _tabs.dispose(); _paySearchC.dispose(); super.dispose(); }

  // Visible tab keys for the current auth session, in display order. `info` is always
  // shown; `returns` (Profits) follows the same gate as the Reports screen — the
  // reports.chitfund permission (the withdraw/reverse actions inside it are further
  // ORG_ADMIN-only, backend-enforced). Any tab the org hides for this role (Settings →
  // Chitfund Settings) is dropped.
  List<String> _computeTabKeys(AuthState auth) {
    final canViewProfit = auth.hasPermission('reports.chitfund');
    const order = ['timeline', 'info', 'members', 'auctions', 'payments', 'payouts', 'returns'];
    return order.where((k) {
      if (auth.isHidden('chitfund.tab.$k')) return false;
      if (k == 'returns' && !canViewProfit) return false;
      return true;
    }).toList();
  }

  // Re-derive the visible tabs when the auth session changes — most importantly when
  // it finishes loading and the permission-gated Profits tab becomes available. A
  // TabController's length is fixed at construction, so a changed set means a fresh
  // controller; the previous one is disposed after this frame so widgets still
  // referencing it can detach first. The currently-selected tab is preserved.
  void _syncTabsWithAuth(AuthState auth) {
    final desired = _computeTabKeys(auth);
    if (listEquals(desired, _tabKeys)) return;
    final old = _tabs;
    final currentKey = old.index < _tabKeys.length ? _tabKeys[old.index] : null;
    final targetIndex = currentKey != null ? desired.indexOf(currentKey) : -1;
    setState(() {
      _tabKeys = desired;
      _tabs = TabController(length: desired.length, vsync: this, initialIndex: targetIndex >= 0 ? targetIndex : 0);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => old.dispose());
  }

  bool get _canManage {
    final auth = ref.read(authProvider);
    return auth.hasPermission('chitfunds.create') || auth.hasRole('ORG_ADMIN') || auth.hasRole('MANAGER');
  }

  String _tabLabel(String k) => {
        'timeline': 'Timeline',
        'info': 'Info',
        'members': 'Members',
        'auctions': 'Auctions',
        'payments': 'Payments',
        'payouts': 'Payouts',
        'returns': 'Profits',
      }[k] ?? k;

  Widget _tabContent(String k, Map<String, dynamic> c) {
    switch (k) {
      case 'timeline':
        return ChitfundTimeline(chitfundId: widget.id, reloadKey: _reloadKey);
      case 'info':
        return _infoTab(c);
      case 'members':
        return _membersTab(c);
      case 'auctions':
        return _auctionsTab(c);
      case 'payments':
        return _paymentsTab(c);
      case 'payouts':
        return _payoutsTab(c);
      case 'returns':
        return ListView(
          padding: const EdgeInsets.all(14),
          children: [
            ChitfundProfitPanel(
              chitfundId: widget.id,
              canWithdraw: ref.read(authProvider).hasRole('ORG_ADMIN'),
              chitName: c['name']?.toString(),
              reloadKey: _reloadKey,
            ),
          ],
        );
    }
    return const SizedBox.shrink();
  }

  Map<String, Map<String, dynamic>> _memberById() {
    final map = <String, Map<String, dynamic>>{};
    ref.watch(chitfundMembersProvider(widget.id)).whenData((items) {
      for (final m in items) {
        final mm = Map<String, dynamic>.from(m as Map);
        map[mm['id'].toString()] = mm;
      }
    });
    return map;
  }

  void _refreshAll() {
    ref.invalidate(chitfundDetailProvider(widget.id));
    ref.invalidate(chitfundMembersProvider(widget.id));
    ref.invalidate(chitfundAuctionsProvider(widget.id));
    ref.invalidate(chitfundPaymentsProvider(widget.id));
    ref.invalidate(chitfundPayoutsProvider(widget.id));
    if (mounted) setState(() => _reloadKey++);
  }

  Future<void> _addMember() async {
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _CustPicker(ref: ref),
    );
    if (picked == null) return;
    try {
      await ref.read(chitfundRepoProvider).addMember(widget.id, picked['id'].toString());
      ref.invalidate(chitfundMembersProvider(widget.id));
      ref.invalidate(chitfundDetailProvider(widget.id));
      showToast('Member added');
    } on ApiException catch (e) { showToast(e.message, error: true); }
  }

  Future<void> _assignOfficer() async {
    final picked = await showFieldOfficerPicker(context, ref);
    if (picked == null) return;
    try {
      await ref.read(chitfundRepoProvider).assign(widget.id, picked['id'].toString());
      ref.invalidate(chitfundDetailProvider(widget.id));
      showToast('Field officer assigned');
    } on ApiException catch (e) { showToast(e.message, error: true); }
  }

  Future<void> _unassignOfficer() async {
    try {
      await ref.read(chitfundRepoProvider).assign(widget.id, null);
      ref.invalidate(chitfundDetailProvider(widget.id));
      showToast('Field officer unassigned');
    } on ApiException catch (e) { showToast(e.message, error: true); }
  }

  Future<void> _doAction(Future<void> Function() fn, String msg) async {
    try {
      await fn();
      _refreshAll();
      showToast(msg);
    } on ApiException catch (e) { showToast(e.message, error: true); }
  }

  // Dashboard deep-link: once the member list is available, pop the target member's
  // transactions popup exactly once (one-shot — a later reload won't reopen it).
  void _maybeOpenDeepLinkMember() {
    if (_deepLinkOpened || widget.initialMemberId == null) return;
    final async = ref.watch(chitfundMembersProvider(widget.id));
    async.whenData((items) {
      if (_deepLinkOpened) return;
      final target = items.cast<dynamic>().map((e) => Map<String, dynamic>.from(e as Map)).cast<Map<String, dynamic>?>().firstWhere(
            (m) => m?['id']?.toString() == widget.initialMemberId,
            orElse: () => null,
          );
      // members loaded — consume the intent whether or not the member was found, so we
      // don't keep retrying on every rebuild.
      _deepLinkOpened = true;
      if (target != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) showMemberTransactions(context, ref, chitfundId: widget.id, member: target);
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    // Keep the tab set in sync with the auth session. initState's snapshot may predate
    // the session load, which would otherwise permanently drop the Profits tab; this
    // re-derives (and re-labels) the tabs once permissions/visibility arrive.
    ref.listen(authProvider, (_, next) => _syncTabsWithAuth(next));
    final data = ref.watch(chitfundDetailProvider(widget.id));
    _maybeOpenDeepLinkMember();
    return Scaffold(
      appBar: AppBar(
        title: const Text('Chitfund'),
        bottom: TabBar(
          controller: _tabs,
          isScrollable: true,
          tabs: _tabKeys.map((k) => Tab(text: _tabLabel(k))).toList(),
        ),
        actions: [
          data.maybeWhen(
            data: (c) => _canManage ? _menu(c) : const SizedBox.shrink(),
            orElse: () => const SizedBox.shrink(),
          ),
        ],
      ),
      body: data.when(
        loading: () => const LoadingView(),
        error: (e, _) => ErrorView(message: e.toString()),
        data: (c) => TabBarView(
          controller: _tabs,
          children: _tabKeys.map((k) => _tabContent(k, c)).toList(),
        ),
      ),
    );
  }

  Widget _menu(Map<String, dynamic> c) {
    final auth = ref.read(authProvider);
    final status = c['status']?.toString();
    final dividendType = c['dividendType']?.toString() ?? 'SPLIT';
    final surplusOverflow = dividendType == 'ACCUMULATED' &&
        toNum(c['surplusPool']) >= toNum(c['totalAmount']);
    // Per-role action visibility (Settings → Chitfund Settings).
    final showEdit = !auth.isHidden('chitfund.edit');
    final showReassign = !auth.isHidden('chitfund.reassign');
    return PopupMenuButton<String>(
      onSelected: (v) {
        switch (v) {
          case 'start':
            _doAction(() => ref.read(chitfundRepoProvider).start(widget.id), 'Started');
            break;
          case 'complete':
            _doAction(() => ref.read(chitfundRepoProvider).complete(widget.id), 'Completed');
            break;
          case 'add_member':
            _addMember();
            break;
          case 'edit':
            _editChitfund(c);
            break;
          case 'assign':
            _assignOfficer();
            break;
          case 'unassign':
            _unassignOfficer();
            break;
          case 'record_payment':
            _openPayment(c);
            break;
          case 'final_dues':
            _openFinalDues(c);
            break;
          case 'extra_auction':
            _openExtraAuction(c);
            break;
        }
      },
      itemBuilder: (_) => [
        if (status == 'UPCOMING') const PopupMenuItem(value: 'start', child: Text('Start')),
        // Editable at any status; started chits get a warning in the dialog.
        if (showEdit) const PopupMenuItem(value: 'edit', child: Text('Edit chitfund')),
        if (showReassign)
          PopupMenuItem(value: 'assign', child: Text(c['assignedTo'] == null ? 'Assign field officer' : 'Reassign field officer')),
        if (showReassign && c['assignedTo'] != null) const PopupMenuItem(value: 'unassign', child: Text('Unassign field officer')),
        if (status == 'UPCOMING') const PopupMenuItem(value: 'add_member', child: Text('Add Member')),
        if (status == 'ACTIVE') const PopupMenuItem(value: 'record_payment', child: Text('Record Payment')),
        if (status == 'ACTIVE') const PopupMenuItem(value: 'final_dues', child: Text('Final Dues')),
        if (status == 'ACTIVE' && surplusOverflow)
          const PopupMenuItem(value: 'extra_auction', child: Text('Extra Auction')),
        if (status == 'ACTIVE') const PopupMenuItem(value: 'complete', child: Text('Complete')),
      ],
    );
  }

  Widget _infoTab(Map<String, dynamic> c) {
    final dividendType = c['dividendType']?.toString() ?? 'SPLIT';
    final showTotalCollected = !ref.read(authProvider).isHidden('chitfund.totalCollected');
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(c['name']?.toString() ?? '', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w700)),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    StatusChip(label: c['status']?.toString() ?? '', color: statusColor(c['status']?.toString())),
                    StatusChip(label: dividendType, color: AppColors.info),
                    if (toNum(c['pendingPayoutCount']) > 0)
                      StatusChip(
                        label: '${c['pendingPayoutCount']} payout(s) pending · ${formatCurrency(c['pendingPayoutAmount'] ?? 0)}',
                        color: AppColors.warning,
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
        SectionCard(
          title: 'Details',
          child: Column(
            children: [
              KeyValueRow(label: 'Total Amount', value: formatCurrency(c['totalAmount'])),
              KeyValueRow(label: 'Monthly Installment', value: formatCurrency(c['monthlyInstallment'])),
              KeyValueRow(label: 'Members', value: '${c['totalMembers']}'),
              KeyValueRow(label: 'Duration', value: '${c['durationMonths']} months'),
              KeyValueRow(label: 'Commission', value: '${c['commission'] ?? 0}%'),
              KeyValueRow(label: 'Start Date', value: formatDate(c['startDate'])),
              KeyValueRow(label: 'Current Month', value: '${c['calendarMonth'] ?? c['currentMonth'] ?? 0} / ${c['durationMonths']}'),
              if (showTotalCollected)
                KeyValueRow(label: 'Total Collected', value: formatCurrency(c['totalCollected'] ?? 0)),
              KeyValueRow(
                label: 'Dividend Type',
                value: dividendType +
                    (dividendType == 'SPLIT' ? ' (${c['splitAudience'] == 'NON_WINNERS' ? 'Non-winners' : 'All'})' : ''),
              ),
              KeyValueRow(
                label: 'Field Officer',
                value: Map<String, dynamic>.from(c['assignedTo'] ?? {})['name']?.toString() ?? 'Unassigned',
              ),
              if (dividendType == 'ACCUMULATED')
                KeyValueRow(label: 'Surplus Pool', value: formatCurrency(c['surplusPool'] ?? 0), valueColor: AppColors.warning),
            ],
          ),
        ),
      ],
    );
  }

  Widget _membersTab(Map<String, dynamic> c) {
    final m = ref.watch(chitfundMembersProvider(widget.id));
    final isUpcoming = c['status'] == 'UPCOMING';
    return m.when(
      loading: () => const LoadingView(),
      error: (e, _) => ErrorView(message: e.toString()),
      data: (items) {
        if (items.isEmpty) return const EmptyView(message: 'No members yet');
        // A customer may hold more than one ticket in this chit. Build memberId -> "Chit x of y"
        // so duplicate-customer rows announce how many chits that person holds here.
        final byCustomer = <String, List<Map<String, dynamic>>>{};
        for (final it in items) {
          final mm = Map<String, dynamic>.from(it as Map);
          (byCustomer[mm['customerId']?.toString() ?? ''] ??= []).add(mm);
        }
        final holding = <String, String>{};
        for (final list in byCustomer.values) {
          if (list.length < 2) continue;
          list.sort((a, b) => toNum(a['ticketNumber']).compareTo(toNum(b['ticketNumber'])));
          for (var k = 0; k < list.length; k++) {
            holding[list[k]['id'].toString()] = 'Chit ${k + 1} of ${list.length}';
          }
        }
        return ListView.builder(
          itemCount: items.length,
          itemBuilder: (ctx, i) {
            final mem = Map<String, dynamic>.from(items[i] as Map);
            final cust = Map<String, dynamic>.from(mem['customer'] ?? {});
            final hasWon = mem['hasWonAuction'] == true;
            final holdingTag = holding[mem['id'].toString()];
            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              // Tint the auction winner's row so it stands out (mirrors web).
              color: hasWon ? AppColors.orange.withValues(alpha: 0.10) : null,
              child: ListTile(
                // Tap a member to see their full transaction history + pending dues.
                onTap: () => showMemberTransactions(context, ref, chitfundId: widget.id, member: mem),
                leading: Avatar(url: cust['photo']?.toString(), name: '${cust['firstName'] ?? ''} ${cust['lastName'] ?? ''}'),
                title: Row(
                  children: [
                    Expanded(child: Text('#${mem['ticketNumber'] ?? '-'} ${cust['firstName'] ?? ''} ${cust['lastName'] ?? ''}'.trim())),
                    if (holdingTag != null) ...[
                      const SizedBox(width: 6),
                      StatusChip(label: holdingTag, color: AppColors.purple),
                    ],
                  ],
                ),
                subtitle: Text(
                  '${cust['phone'] ?? ''}'
                  '${hasWon ? ' · Won month ${mem['wonMonth'] ?? '-'}' : ''}',
                ),
                trailing: (isUpcoming && _canManage)
                    ? IconButton(
                        icon: const Icon(Icons.delete_outline, color: AppColors.danger),
                        onPressed: () async {
                          final ok = await confirmDialog(context, message: 'Remove ticket #${mem['ticketNumber']} from this chitfund?', destructive: true, confirmText: 'Remove');
                          if (!ok) return;
                          try {
                            await ref.read(chitfundRepoProvider).removeMember(widget.id, mem['id'].toString());
                            ref.invalidate(chitfundMembersProvider(widget.id));
                            ref.invalidate(chitfundDetailProvider(widget.id));
                          } on ApiException catch (e) { showToast(e.message, error: true); }
                        },
                      )
                    : (toNum(mem['totalPaid']) > 0
                        ? Text(formatCurrency(mem['totalPaid']), style: const TextStyle(fontWeight: FontWeight.w600))
                        : null),
              ),
            );
          },
        );
      },
    );
  }

  Widget _auctionsTab(Map<String, dynamic> c) {
    final a = ref.watch(chitfundAuctionsProvider(widget.id));
    final status = c['status']?.toString();
    final currentMonth = toNum(c['currentMonth']).toInt();
    return a.when(
      loading: () => const LoadingView(),
      error: (e, _) => ErrorView(message: e.toString()),
      data: (items) {
        if (items.isEmpty) return const EmptyView(message: 'No auctions');
        return ListView.builder(
          itemCount: items.length,
          itemBuilder: (ctx, i) {
            final au = Map<String, dynamic>.from(items[i] as Map);
            final isCompleted = au['status'] == 'COMPLETED';
            final isExtra = au['isExtra'] == true;
            final monthNumber = toNum(au['monthNumber']).toInt();
            // Latest completed auction (this month's, or any extra) can be reversed.
            final canReverse = _canManage && isCompleted && status == 'ACTIVE' &&
                (isExtra || monthNumber == currentMonth - 1);
            // The current month's pending auction can be conducted.
            final canConduct = _canManage && !isCompleted && status == 'ACTIVE' && monthNumber == currentMonth;
            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: ListTile(
                title: Row(
                  children: [
                    Text('Month ${au['monthNumber']}'),
                    if (isExtra) ...[
                      const SizedBox(width: 8),
                      const StatusChip(label: 'Extra', color: AppColors.warning),
                    ],
                  ],
                ),
                subtitle: Text(
                  isCompleted ? formatDate(au['auctionDate']) : 'Not conducted',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      toNum(au['bidAmount']) > 0 ? formatCurrency(au['bidAmount']) : '-',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    if (canConduct)
                      IconButton(
                        tooltip: 'Conduct auction',
                        icon: const Icon(Icons.gavel, color: AppColors.primary),
                        onPressed: () => _recordAuction(c, au['id'].toString()),
                      ),
                    if (canReverse)
                      IconButton(
                        tooltip: 'Reverse auction',
                        icon: const Icon(Icons.undo, color: AppColors.danger),
                        onPressed: () => _reverseAuction(au),
                      ),
                    const Icon(Icons.chevron_right, color: AppColors.textSecondary),
                  ],
                ),
                onTap: () => context.push('/chitfunds/${widget.id}/auctions/${au['id']}'),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _reverseAuction(Map<String, dynamic> au) async {
    final isExtra = au['isExtra'] == true;
    final ok = await confirmDialog(
      context,
      title: 'Reverse Auction',
      message: 'Reverse ${isExtra ? 'extra auction' : 'month ${au['monthNumber']}'}? The winner will be cleared, '
          'dividends/pool updated, and the auto-created payout deleted. This will fail if any collections already '
          'exist for this month or the payout is already settled.',
      confirmText: 'Reverse',
      destructive: true,
    );
    if (!ok) return;
    try {
      await ref.read(chitfundRepoProvider).reverseAuction(widget.id, au['id'].toString());
      _refreshAll();
      showToast('Auction reversed');
    } on ApiException catch (e) { showToast(e.message, error: true); }
  }

  Future<void> _recordAuction(Map<String, dynamic> c, String auctionId) async {
    final members = await ref.read(chitfundRepoProvider).members(widget.id);
    // Only members who have not yet won are eligible.
    final eligible = members.where((m) => (m as Map)['hasWonAuction'] != true).toList();
    if (eligible.isEmpty || !mounted) {
      if (mounted) showToast('No eligible members', error: true);
      return;
    }
    final isDip = (c['dividendType']?.toString() ?? 'SPLIT') == 'DIP';
    final chitValue = toNum(c['totalAmount']).toDouble();
    Map<String, dynamic>? selected;
    final bidController = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setState) => AlertDialog(
            title: const Text('Record Auction'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<Map<String, dynamic>>(
                    initialValue: selected,
                    decoration: const InputDecoration(labelText: 'Winner'),
                    items: eligible.map((m) {
                      final mm = Map<String, dynamic>.from(m as Map);
                      final cust = Map<String, dynamic>.from(mm['customer'] ?? {});
                      return DropdownMenuItem(value: mm, child: Text('#${mm['ticketNumber']} ${cust['firstName'] ?? ''} ${cust['lastName'] ?? ''}'.trim()));
                    }).toList(),
                    onChanged: (v) => setState(() => selected = v),
                  ),
                  const SizedBox(height: 10),
                  // For DIP the field is the GROSS payout the winner receives (read off the
                  // fixed dip schedule); otherwise it's the winning bid (amount forgone).
                  TextField(
                    controller: bidController,
                    keyboardType: TextInputType.number,
                    decoration: InputDecoration(
                      labelText: isDip ? 'Payout Amount (optional)' : 'Winning Bid Amount',
                      hintText: isDip
                          ? 'Defaults to chit value (${formatCurrency(chitValue)}) — can exceed it'
                          : 'Amount the winner forgoes',
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
              ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Record')),
            ],
          ),
        );
      },
    );
    if (ok != true || selected == null) return;

    // The backend takes a SIGNED bid where payout = chitValue - bid.
    final rawText = bidController.text.trim();
    double bid;
    if (isDip) {
      // Blank → pay the full chit value (pure lottery). A payout above chit value
      // (month 13+) yields a negative bid, which the backend accepts.
      final payout = rawText.isEmpty ? chitValue : (double.tryParse(rawText) ?? -1);
      if (payout <= 0) { showToast('Enter a valid payout amount', error: true); return; }
      if (payout > 2 * chitValue) { showToast("Payout can't exceed ${formatCurrency(2 * chitValue)}", error: true); return; }
      bid = chitValue - payout;
    } else {
      // SPLIT / ACCUMULATED: the field is the winning bid (amount the winner forgoes).
      if (rawText.isEmpty) { showToast('Enter bid amount', error: true); return; }
      bid = double.tryParse(rawText) ?? -1;
      if (bid < 0 || bid > chitValue) {
        showToast('Bid must be between 0 and ${formatCurrency(chitValue)}', error: true);
        return;
      }
    }
    try {
      await ref.read(chitfundRepoProvider).recordAuction(
        widget.id,
        auctionId,
        winnerMemberId: selected!['id'].toString(),
        bidAmount: bid,
      );
      _refreshAll();
      showToast('Auction recorded');
    } on ApiException catch (e) { showToast(e.message, error: true); }
  }

  Future<void> _openExtraAuction(Map<String, dynamic> c) async {
    final members = await ref.read(chitfundRepoProvider).members(widget.id);
    final eligible = members.where((m) => (m as Map)['hasWonAuction'] != true).toList();
    if (eligible.isEmpty || !mounted) {
      if (mounted) showToast('No eligible members', error: true);
      return;
    }
    Map<String, dynamic>? selected;
    final bidController = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: const Text('Extra Auction'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Surplus pool ${formatCurrency(c['surplusPool'] ?? 0)} · Chit value ${formatCurrency(c['totalAmount'])}',
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                const SizedBox(height: 10),
                DropdownButtonFormField<Map<String, dynamic>>(
                  initialValue: selected,
                  decoration: const InputDecoration(labelText: 'Winner'),
                  items: eligible.map((m) {
                    final mm = Map<String, dynamic>.from(m as Map);
                    final cust = Map<String, dynamic>.from(mm['customer'] ?? {});
                    return DropdownMenuItem(value: mm, child: Text('#${mm['ticketNumber']} ${cust['firstName'] ?? ''} ${cust['lastName'] ?? ''}'.trim()));
                  }).toList(),
                  onChanged: (v) => setState(() => selected = v),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: bidController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'Bid Amount (optional)', hintText: 'Leave blank to pay full chit value'),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Record')),
          ],
        ),
      ),
    );
    if (ok != true || selected == null) return;
    try {
      await ref.read(chitfundRepoProvider).extraAuction(
        widget.id,
        winnerMemberId: selected!['id'].toString(),
        bidAmount: double.tryParse(bidController.text) ?? 0,
      );
      _refreshAll();
      showToast('Extra auction recorded');
    } on ApiException catch (e) { showToast(e.message, error: true); }
  }

  Widget _paymentsTab(Map<String, dynamic> c) {
    final p = ref.watch(chitfundPaymentsProvider(widget.id));
    final role = ref.read(authProvider).user?.role;
    final notCompleted = c['status'] != 'COMPLETED';
    final memberById = _memberById();
    return p.when(
      loading: () => const LoadingView(),
      error: (e, _) => ErrorView(message: e.toString()),
      data: (raw) {
        final all = raw.map((e) => Map<String, dynamic>.from(e as Map)).toList();

        // Default the month filter to the active collection month on first load (once),
        // so the tab opens on the month being collected rather than the whole history.
        // That's the calendar-derived `calendarMonth` — NOT `currentMonth`, the auction
        // pointer that already names next month once this month's auction is recorded.
        // Fall back to the latest auctioned month (currentMonth - 1) on older payloads.
        if (!_payMonthDefaulted) {
          final cal = toNum(c['calendarMonth']).toInt();
          final cur = toNum(c['currentMonth']).toInt();
          _payMonthDefaulted = true;
          final activeMonth = cal > 0 ? cal : (cur > 0 ? (cur - 1 < 1 ? 1 : cur - 1) : 0);
          if (activeMonth > 0) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() => _payMonth = '$activeMonth');
            });
          }
        }

        // Distinct months / modes present, for the filter dropdowns. Always offer the
        // active collection month (and the in-progress month) even with no payments yet,
        // so the default selection below always resolves to a real option.
        final months = <int>{};
        for (final r in all) {
          if (r['monthNumber'] != null) months.add(toNum(r['monthNumber']).toInt());
        }
        final cur = toNum(c['calendarMonth'] ?? c['currentMonth']).toInt();
        if (cur > 0) {
          months.add(cur);                  // in-progress (calendar) month we default to
          if (cur > 1) months.add(cur - 1); // previous month
        }
        final monthList = months.toList()..sort((a, b) => b.compareTo(a));
        final modes = <String>{};
        for (final r in all) {
          final m = r['paymentMode']?.toString();
          if (m != null && m.isNotEmpty) modes.add(m);
        }

        final q = _paySearchC.text.trim().toLowerCase();
        final filtered = all.where((row) {
          if (_payType.isNotEmpty && (row['type']?.toString() ?? 'COLLECTION') != _payType) return false;
          final status = (row['verificationStatus'] ?? row['status'] ?? 'PENDING').toString();
          if (_payStatus.isNotEmpty && status != _payStatus) return false;
          if (_payMonth.isNotEmpty && '${toNum(row['monthNumber']).toInt()}' != _payMonth) return false;
          if (_payMode.isNotEmpty && (row['paymentMode']?.toString() ?? '') != _payMode) return false;
          if (q.isNotEmpty) {
            final mem = memberById[row['chitfundMemberId']?.toString()];
            final cust = mem != null && mem['customer'] is Map ? Map<String, dynamic>.from(mem['customer'] as Map) : const {};
            final name = '${cust['firstName'] ?? ''} ${cust['lastName'] ?? ''}';
            final ticket = mem != null ? '#${mem['ticketNumber']}' : '';
            final hay = '$name $ticket ${row['reference'] ?? ''} ${row['receiptNumber'] ?? ''}'.toLowerCase();
            if (!hay.contains(q)) return false;
          }
          return true;
        }).toList();
        final filtersActive = _paySearchC.text.isNotEmpty || _payType.isNotEmpty
            || _payStatus.isNotEmpty || _payMonth.isNotEmpty || _payMode.isNotEmpty;

        return Column(
          children: [
            _paymentsFilterBar(monthList, modes.toList(), filtered.length, all.length, filtersActive),
            Expanded(
              child: all.isEmpty
                  ? const EmptyView(message: 'No payments yet')
                  : filtered.isEmpty
                      ? EmptyView(message: filtersActive ? 'No payments match the filters' : 'No payments yet')
                      : ListView.builder(
                          itemCount: filtered.length,
                          itemBuilder: (ctx, i) {
                            final pm = filtered[i];
                            final type = pm['type']?.toString() ?? 'COLLECTION';
                            // listPayments returns raw rows (no relation) — resolve the name from members.
                            final mem = memberById[pm['chitfundMemberId']?.toString()];
                            final cust = mem != null && mem['customer'] != null ? Map<String, dynamic>.from(mem['customer'] as Map) : {};
                            final ticket = mem != null ? '#${mem['ticketNumber']} ' : '';
                            final name = '$ticket${cust['firstName'] ?? ''} ${cust['lastName'] ?? ''}'.trim();
                            final isCollection = type == 'COLLECTION';
                            final status = (pm['verificationStatus'] ?? pm['status'] ?? 'PENDING').toString();
                            final showDelete = isCollection && notCompleted && _canManage && _canDeletePayment(pm, role);
                            // Field officer who recorded the collection (null for payouts).
                            final officer = pm['collectedByName']?.toString();
                            return Card(
                              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                              child: ListTile(
                                title: Row(
                                  children: [
                                    Expanded(child: Text('Month ${pm['monthNumber']}${name.isNotEmpty ? ' - $name' : ''}')),
                                    StatusChip(label: type, color: type == 'PAYOUT' ? AppColors.info : AppColors.primary),
                                  ],
                                ),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      '$status · ${pm['paymentMode'] ?? '-'} · ${formatDateTime(pm['paidDate'] ?? pm['paymentDate'])}'
                                      '${pm['reference'] != null ? ' · ${pm['reference']}' : ''}',
                                    ),
                                    if (officer != null && officer.isNotEmpty)
                                      Text(
                                        'Field officer: $officer',
                                        style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                                      ),
                                  ],
                                ),
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(formatCurrency(pm['amount']), style: const TextStyle(fontWeight: FontWeight.w600)),
                                    if (showDelete)
                                      IconButton(
                                        icon: const Icon(Icons.delete_outline, color: AppColors.danger, size: 20),
                                        onPressed: () => _deletePayment(pm),
                                      ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
            ),
          ],
        );
      },
    );
  }

  Widget _paymentsFilterBar(List<int> months, List<String> modes, int shown, int total, bool filtersActive) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _paySearchC,
            decoration: InputDecoration(
              isDense: true,
              prefixIcon: const Icon(Icons.search, size: 20),
              hintText: 'Search member, ticket, reference…',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
            ),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _payFilter('Type', _payType, [
                  const DropdownMenuItem(value: '', child: Text('All types')),
                  const DropdownMenuItem(value: 'COLLECTION', child: Text('Collection')),
                  const DropdownMenuItem(value: 'PAYOUT', child: Text('Payout')),
                ], (v) => setState(() => _payType = v ?? '')),
                const SizedBox(width: 8),
                _payFilter('Status', _payStatus, [
                  const DropdownMenuItem(value: '', child: Text('All statuses')),
                  const DropdownMenuItem(value: 'VERIFIED', child: Text('Verified')),
                  const DropdownMenuItem(value: 'PENDING', child: Text('Pending')),
                  const DropdownMenuItem(value: 'REJECTED', child: Text('Rejected')),
                  const DropdownMenuItem(value: 'PAID', child: Text('Paid')),
                ], (v) => setState(() => _payStatus = v ?? '')),
                const SizedBox(width: 8),
                _payFilter('Month', _payMonth, [
                  const DropdownMenuItem(value: '', child: Text('All months')),
                  ...months.map((m) => DropdownMenuItem(value: '$m', child: Text('Month $m'))),
                ], (v) => setState(() => _payMonth = v ?? '')),
                if (modes.length > 1) ...[
                  const SizedBox(width: 8),
                  _payFilter('Mode', _payMode, [
                    const DropdownMenuItem(value: '', child: Text('All modes')),
                    ...modes.map((m) => DropdownMenuItem(value: m, child: Text(_paymentModeLabels[m] ?? m))),
                  ], (v) => setState(() => _payMode = v ?? '')),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                Text('$shown of $total', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                const Spacer(),
                if (filtersActive)
                  TextButton(
                    style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 0), tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                    onPressed: () => setState(() {
                      _paySearchC.clear();
                      _payType = '';
                      _payStatus = '';
                      _payMonth = '';
                      _payMode = '';
                    }),
                    child: const Text('Clear'),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _payFilter(String label, String value, List<DropdownMenuItem<String>> items, ValueChanged<String?> onChanged) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: value.isNotEmpty ? AppColors.primarySoft : AppColors.bg,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: value.isNotEmpty ? AppColors.primary.withValues(alpha: 0.4) : AppColors.border),
      ),
      child: DropdownButton<String>(
        value: value,
        underline: const SizedBox.shrink(),
        isDense: true,
        icon: const Icon(Icons.arrow_drop_down, size: 18),
        style: const TextStyle(fontSize: 13, color: AppColors.textPrimary),
        items: items,
        onChanged: onChanged,
      ),
    );
  }

  Future<void> _deletePayment(Map<String, dynamic> pm) async {
    final ok = await confirmDialog(
      context,
      title: 'Delete Payment',
      message: "Delete this ${formatCurrency(pm['amount'])} payment for month ${pm['monthNumber']}? The member's total paid will be decreased.",
      confirmText: 'Delete',
      destructive: true,
    );
    if (!ok) return;
    try {
      await ref.read(chitfundRepoProvider).deletePayment(widget.id, pm['id'].toString());
      _refreshAll();
      showToast('Payment deleted');
    } on ApiException catch (e) { showToast(e.message, error: true); }
  }

  Widget _payoutsTab(Map<String, dynamic> c) {
    final p = ref.watch(chitfundPayoutsProvider(widget.id));
    final memberById = _memberById();
    return p.when(
      loading: () => const LoadingView(),
      error: (e, _) => ErrorView(message: e.toString()),
      data: (items) {
        if (items.isEmpty) return const EmptyView(message: 'No payouts yet');
        return ListView.builder(
          itemCount: items.length,
          itemBuilder: (ctx, i) {
            final po = Map<String, dynamic>.from(items[i] as Map);
            final isPaid = po['status'] == 'PAID';
            final mem = memberById[po['chitfundMemberId']?.toString()];
            final cust = mem != null && mem['customer'] != null ? Map<String, dynamic>.from(mem['customer'] as Map) : {};
            final winnerLabel = mem != null
                ? '#${mem['ticketNumber']} ${cust['firstName'] ?? ''} ${cust['lastName'] ?? ''}'.trim()
                : '-';
            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: ListTile(
                title: Row(
                  children: [
                    Expanded(child: Text('Month ${po['monthNumber']} · $winnerLabel')),
                    StatusChip(label: po['status']?.toString() ?? 'PENDING', color: statusColor(po['status']?.toString())),
                  ],
                ),
                subtitle: Text(
                  isPaid
                      ? '${po['paymentMode'] ?? '-'} · ${formatDate(po['paidDate'])}${po['reference'] != null ? ' · ${po['reference']}' : ''}'
                      : 'Pending settlement',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(formatCurrency(po['amount']), style: const TextStyle(fontWeight: FontWeight.w600)),
                    if (_canManage)
                      isPaid
                          ? IconButton(
                              tooltip: 'Unsettle',
                              icon: const Icon(Icons.restart_alt, color: AppColors.danger, size: 22),
                              onPressed: () => _unsettlePayout(po),
                            )
                          : IconButton(
                              tooltip: 'Pay winner',
                              icon: const Icon(Icons.payments, color: AppColors.primary, size: 22),
                              onPressed: () => _settlePayout(c, po),
                            ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Future<void> _unsettlePayout(Map<String, dynamic> po) async {
    final ok = await confirmDialog(
      context,
      title: 'Unsettle Payout',
      message: 'Mark this payout of ${formatCurrency(po['amount'])} back to PENDING? The settlement details (mode, reference, date) will be cleared.',
      confirmText: 'Unsettle',
      destructive: true,
    );
    if (!ok) return;
    try {
      await ref.read(chitfundRepoProvider).unsettlePayout(widget.id, po['id'].toString());
      _refreshAll();
      showToast('Payout unsettled');
    } on ApiException catch (e) { showToast(e.message, error: true); }
  }

  Future<void> _settlePayout(Map<String, dynamic> c, Map<String, dynamic> po) async {
    final amountController = TextEditingController(text: po['amount'] != null ? po['amount'].toString() : '');
    final refController = TextEditingController();
    final shareController = TextEditingController();
    String mode = 'CASH';
    bool collectShare = false;
    DateTime paidDate = DateTime.now();

    // Look up the winner's expected share for the month + whether collection already exists.
    num shareExpected = toNum(c['monthlyInstallment']);
    bool shareAlreadyPaid = false;
    try {
      final dues = await ref.read(chitfundRepoProvider).monthlyDues(widget.id, toNum(po['monthNumber']).toInt());
      final list = (dues['dues'] as List?) ?? const [];
      final winnerDue = list.cast<Map?>().firstWhere(
            (d) => d?['memberId']?.toString() == po['chitfundMemberId']?.toString(),
            orElse: () => null,
          );
      if (winnerDue != null) shareExpected = toNum(winnerDue['expectedAmount']);
      final pays = await ref.read(chitfundRepoProvider).payments(
            widget.id,
            monthNumber: toNum(po['monthNumber']).toInt(),
            memberId: po['chitfundMemberId']?.toString(),
            type: 'COLLECTION',
          );
      shareAlreadyPaid = pays.isNotEmpty;
    } catch (_) {}
    shareController.text = (shareExpected).toStringAsFixed(2);

    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text('Pay Winner — Month ${po['monthNumber']}'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(controller: amountController, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Amount Paid')),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  initialValue: mode,
                  decoration: const InputDecoration(labelText: 'Payment Mode'),
                  items: _paymentModes.map((m) => DropdownMenuItem(value: m, child: Text(titleCase(m)))).toList(),
                  onChanged: (v) => setState(() => mode = v ?? 'CASH'),
                ),
                const SizedBox(height: 10),
                InkWell(
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: ctx,
                      initialDate: paidDate,
                      firstDate: DateTime(2015),
                      lastDate: DateTime.now().add(const Duration(days: 1)),
                    );
                    if (picked != null) setState(() => paidDate = picked);
                  },
                  child: InputDecorator(
                    decoration: const InputDecoration(labelText: 'Paid Date'),
                    child: Text(formatDate(paidDate)),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(controller: refController, decoration: const InputDecoration(labelText: 'Reference', hintText: 'Txn ID / cheque #')),
                const SizedBox(height: 10),
                if (shareAlreadyPaid)
                  Text('Collection for month ${po['monthNumber']} is already recorded for this member.',
                      style: const TextStyle(fontSize: 12, color: AppColors.textSecondary))
                else ...[
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: collectShare,
                    title: Text("Also collect winner's share for month ${po['monthNumber']}", style: const TextStyle(fontSize: 13)),
                    onChanged: (v) => setState(() => collectShare = v ?? false),
                  ),
                  if (collectShare)
                    TextField(controller: shareController, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Share Amount')),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: Text(collectShare ? 'Settle & Collect' : 'Mark as Paid')),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final amt = double.tryParse(amountController.text) ?? 0;
    if (amt <= 0) { showToast('Enter a positive amount', error: true); return; }
    final body = <String, dynamic>{
      'amount': amt,
      'paymentMode': mode,
      'reference': refController.text.isEmpty ? null : refController.text,
      'paidDate': formatInputDate(paidDate),
      'collectShare': collectShare,
    };
    if (collectShare) {
      final shareAmt = double.tryParse(shareController.text) ?? 0;
      if (shareAmt <= 0) { showToast('Enter a positive share amount', error: true); return; }
      body['shareAmount'] = shareAmt;
    }
    try {
      await ref.read(chitfundRepoProvider).settlePayout(widget.id, po['id'].toString(), body);
      _refreshAll();
      showToast(collectShare ? 'Payout settled & share collected' : 'Payout settled');
    } on ApiException catch (e) { showToast(e.message, error: true); }
  }

  Future<void> _openPayment(Map<String, dynamic> c) =>
      openChitCollectionSheet(context, ref, chitfund: c, onRecorded: _refreshAll);

  Future<void> _openFinalDues(Map<String, dynamic> c) async {
    Map<String, dynamic>? dues;
    String? error;
    try {
      dues = await ref.read(chitfundRepoProvider).finalDues(widget.id);
    } on ApiException catch (e) {
      error = e.message;
    }
    if (!mounted) return;
    if (error != null) { showToast(error, error: true); return; }
    final d = dues!;
    final dividendType = d['dividendType']?.toString() ?? 'SPLIT';
    final list = (d['dues'] as List?) ?? const [];
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.85,
        expand: false,
        builder: (_, ctrl) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(14),
              child: Row(
                children: [
                  const Expanded(child: Text('Final Installment Dues', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600))),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  dividendType +
                      (dividendType == 'SPLIT' ? ' (${d['splitAudience'] == 'NON_WINNERS' ? 'Non-winners' : 'All'})' : '') +
                      (dividendType == 'ACCUMULATED' ? ' · Pool leftover ${formatCurrency(d['surplusPool'])}' : ''),
                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                controller: ctrl,
                itemCount: list.length,
                itemBuilder: (ctx, i) {
                  final due = Map<String, dynamic>.from(list[i] as Map);
                  return ListTile(
                    dense: true,
                    leading: Text('#${due['ticketNumber']}', style: const TextStyle(color: AppColors.textSecondary)),
                    title: Text(due['customerName']?.toString() ?? '-'),
                    subtitle: Text(
                      'Base ${formatCurrency(due['baseInstallment'])}'
                      '${dividendType == 'SPLIT' && toNum(due['dividendCredited']) > 0 ? ' · Credited ${formatCurrency(due['dividendCredited'])}' : ''}'
                      '${dividendType == 'ACCUMULATED' && toNum(due['poolShare']) > 0 ? ' · Pool share ${formatCurrency(due['poolShare'])}' : ''}',
                    ),
                    trailing: Text(formatCurrency(due['finalAmount']), style: const TextStyle(fontWeight: FontWeight.w700)),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editChitfund(Map<String, dynamic> c) async {
    final nameC = TextEditingController(text: c['name']?.toString() ?? '');
    final totalC = TextEditingController(text: c['totalAmount']?.toString() ?? '');
    final instC = TextEditingController(text: c['monthlyInstallment']?.toString() ?? '');
    final commC = TextEditingController(text: c['commission']?.toString() ?? '');
    final started = c['status'] != 'UPCOMING';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit Chitfund'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (started) ...[
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: AppColors.warning.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: AppColors.warning.withValues(alpha: 0.5)),
                  ),
                  child: Text(
                    'This chitfund has started. Changing total amount, installment or commission '
                    'can make existing auctions, dues and payouts inconsistent.',
                    style: const TextStyle(fontSize: 12),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              TextField(controller: nameC, decoration: const InputDecoration(labelText: 'Name')),
              const SizedBox(height: 8),
              TextField(controller: totalC, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Total Amount')),
              const SizedBox(height: 8),
              TextField(controller: instC, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Monthly Installment')),
              const SizedBox(height: 8),
              TextField(controller: commC, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Commission (%)')),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true) return;
    final body = <String, dynamic>{
      'name': nameC.text.trim(),
      'totalAmount': num.tryParse(totalC.text) ?? c['totalAmount'],
      'monthlyInstallment': num.tryParse(instC.text) ?? c['monthlyInstallment'],
      'commission': num.tryParse(commC.text) ?? c['commission'],
    };
    try {
      await ref.read(chitfundRepoProvider).update(widget.id, body);
      ref.invalidate(chitfundDetailProvider(widget.id));
      showToast('Chitfund updated');
    } on ApiException catch (e) { showToast(e.message, error: true); }
  }
}

// Record-payment sheet with month picker + per-member monthly dues.
class _PaymentSheet extends ConsumerStatefulWidget {
  final String chitfundId;
  final Map<String, dynamic> chitfund;
  final List<dynamic> members;
  final int initialMonth;
  final VoidCallback onRecorded;
  const _PaymentSheet({
    required this.chitfundId,
    required this.chitfund,
    required this.members,
    required this.initialMonth,
    required this.onRecorded,
  });
  @override
  ConsumerState<_PaymentSheet> createState() => _PaymentSheetState();
}

class _PaymentSheetState extends ConsumerState<_PaymentSheet> {
  late int _month = widget.initialMonth;
  bool _loading = false;
  bool _saving = false;
  Map<String, dynamic>? _dues; // monthly-dues (or mapped final-dues) response
  List<dynamic> _monthPayments = const [];
  // Auctioned (+ current) months that still have dues outstanding. When loaded, the
  // month picker offers these instead of every elapsed month. Empty = fall back to the
  // generated month list (e.g. the summary endpoint failed).
  List<Map<String, dynamic>> _collectable = const [];
  // The chit's in-progress calendar month — the collector's default landing month. Derived
  // from the start date, so it can lag chitfund.currentMonth (which jumps to the next month
  // the instant an auction is conducted).
  late final int? _chitCurrentMonth = currentChitMonth(widget.chitfund['startDate']);
  String? _selectedMemberId;
  final _amountC = TextEditingController();
  final _refC = TextEditingController();
  String _mode = 'CASH';
  DateTime _paidDate = DateTime.now();

  int get _duration => toNum(widget.chitfund['durationMonths']).toInt();
  // Only let the user record payments up to the month currently in progress — future
  // months haven't happened yet, so showing all `_duration` months is misleading. "In
  // progress" is the calendar-derived calendarMonth, not the auction pointer (which
  // already names next month once this month's auction is recorded); currentMonth - 1
  // still counts in case an auction was recorded ahead of its calendar month.
  int get _visibleMonths {
    final lastAuctioned = toNum(widget.chitfund['currentMonth']).toInt() - 1;
    final cal = toNum(widget.chitfund['calendarMonth'] ?? widget.chitfund['currentMonth']).toInt();
    final cm = cal > lastAuctioned ? cal : lastAuctioned;
    final v = cm <= 0 ? _duration : (cm < _duration ? cm : _duration);
    return v < 1 ? 1 : v;
  }
  bool get _isFinalAccum => widget.chitfund['dividendType'] == 'ACCUMULATED' && _month == _duration;

  @override
  void initState() {
    super.initState();
    _loadCollectable();
    _load(_month);
  }

  // Restrict the month picker to months that still have dues (auctioned, or the current
  // in-progress month). Mirrors the web Record-Collection month picker.
  Future<void> _loadCollectable() async {
    try {
      final list = await ref.read(chitfundRepoProvider).collectionSummary(widget.chitfundId);
      if (!mounted) return;
      final cm = _chitCurrentMonth;
      // Show every month that still has dues, plus the current calendar month itself even
      // when it's already fully collected — the current cycle is the collector's default
      // landing spot, so it must stay selectable. Fully-collected PAST months stay hidden.
      final months = list
          .map((e) => Map<String, dynamic>.from(e as Map))
          .where((m) => m['fullyCollected'] != true || toNum(m['monthNumber']).toInt() == cm)
          .toList();
      setState(() {
        _collectable = months;
        // Keep the month we opened on if it's still collectable. Otherwise default to the
        // chit's current (in-progress) month whenever it's selectable; only fall back to the
        // latest collectable month if the current month is out of range (e.g. the chit has run
        // past its duration and there's no current month to land on).
        if (months.isNotEmpty && !months.any((m) => toNum(m['monthNumber']).toInt() == _month)) {
          final hasCurrent = cm != null && months.any((m) => toNum(m['monthNumber']).toInt() == cm);
          _month = hasCurrent ? cm : toNum(months.last['monthNumber']).toInt();
          _load(_month);
        }
      });
    } catch (_) {/* keep the generated month list */}
  }

  Future<void> _load(int month) async {
    setState(() {
      _loading = true;
      _dues = null;
      _monthPayments = const [];
      _selectedMemberId = null;
      _amountC.text = '';
    });
    try {
      final repo = ref.read(chitfundRepoProvider);
      final isFinalAccum = widget.chitfund['dividendType'] == 'ACCUMULATED' && month == _duration;
      final duesRaw = isFinalAccum ? await repo.finalDues(widget.chitfundId) : await repo.monthlyDues(widget.chitfundId, month);
      final pays = await repo.payments(widget.chitfundId, monthNumber: month);
      Map<String, dynamic> dues;
      if (isFinalAccum) {
        // Map final-dues shape to the monthly-dues structure used by the form.
        final list = (duesRaw['dues'] as List?) ?? const [];
        dues = {
          'monthNumber': month,
          'dividendType': duesRaw['dividendType'],
          'splitAudience': duesRaw['splitAudience'],
          'auctionCompleted': true,
          'dividendPerMember': 0,
          'surplusPool': duesRaw['surplusPool'],
          'dues': list.map((raw) {
            final d = Map<String, dynamic>.from(raw as Map);
            return {...d, 'expectedAmount': d['finalAmount'], 'dividendCredit': 0, 'poolShare': d['poolShare']};
          }).toList(),
        };
      } else {
        dues = duesRaw;
      }
      if (!mounted) return;
      setState(() {
        _dues = dues;
        _monthPayments = pays;
      });
    } on ApiException catch (e) {
      if (mounted) showToast(e.message, error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onSelectMember(String? memberId) {
    setState(() {
      _selectedMemberId = memberId;
      final list = (_dues?['dues'] as List?) ?? const [];
      final due = list.cast<Map?>().firstWhere((d) => d?['memberId']?.toString() == memberId, orElse: () => null);
      if (due == null) { _amountC.text = ''; return; }
      // Pre-fill the remaining balance, not the full expected amount — a member may have
      // already made a partial payment this month, in which case they only owe the rest.
      // Prefer the backend's waterfall remaining so the prefill reflects spillover from
      // earlier overpayments; fall back to expected − literal month payments otherwise.
      final remaining = _remainingForDue(Map<String, dynamic>.from(due));
      _amountC.text = (remaining < 0 ? 0 : remaining).toStringAsFixed(2);
    });
  }

  Future<void> _submit() async {
    if (_selectedMemberId == null) { showToast('Select a member', error: true); return; }
    final amt = double.tryParse(_amountC.text) ?? 0;
    if (amt <= 0) { showToast('Enter a positive amount', error: true); return; }
    setState(() => _saving = true);
    try {
      await ref.read(chitfundRepoProvider).recordPayment(widget.chitfundId, {
        'chitfundMemberId': _selectedMemberId,
        'monthNumber': _month,
        'amount': amt,
        'paymentMode': _mode,
        'reference': _refC.text.isEmpty ? null : _refC.text,
        'paidDate': formatInputDate(_paidDate),
      });
      showToast('Payment recorded — pending verification');
      widget.onRecorded();
      _refC.text = '';
      await _load(_month); // refresh so the paid member drops off the list
    } on ApiException catch (e) {
      showToast(e.message, error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // Literal amount credited to THIS month for a member from the (non-rejected, non-payout)
  // month payments — the fallback when the backend didn't send waterfall-allocated fields.
  double _literalPaidFor(String? memberId) => _monthPayments
      .map((p) => p as Map)
      .where((p) => p['chitfundMemberId']?.toString() == memberId
          && (p['type']?.toString() ?? 'COLLECTION') != 'PAYOUT'
          && p['verificationStatus']?.toString() != 'REJECTED')
      .fold<double>(0, (sum, p) => sum + toNum(p['amount']).toDouble());

  // Amount already credited to this month for a member via the backend's waterfall
  // allocation (verified + pending, incl. spillover from earlier overpayments). Falls back
  // to the literal month payments only when the allocated fields aren't present.
  double _paidForDue(Map<String, dynamic> due) {
    if (due['paidVerified'] != null) {
      return toNum(due['paidVerified']).toDouble() + toNum(due['paidPending']).toDouble();
    }
    return _literalPaidFor(due['memberId']?.toString());
  }

  // Remaining balance for the member+month. Prefer the backend's waterfall `remaining` so
  // the prefill/labels reflect spillover; otherwise expected − literal month payments.
  double _remainingForDue(Map<String, dynamic> due) {
    if (due['remaining'] != null) return toNum(due['remaining']).toDouble();
    return toNum(due['expectedAmount']).toDouble() - _literalPaidFor(due['memberId']?.toString());
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.chitfund;
    // "Paid this month" is COLLECTION money only (winner PAYOUT records are excluded) and,
    // when the backend sends it, the waterfall allocation incl. spillover — see _paidForDue /
    // _remainingForDue, which the picker label, prefill and selectable filter all route through.
    final allDues = (_dues?['dues'] as List?) ?? const [];
    // A member is only "done" once they've paid at least their expected amount for the
    // month. Members who paid a partial amount still owe a balance, so keep them in the
    // picker so the remaining due can be collected. Prefer the backend's waterfall
    // paid/remaining (spillover-aware); fall back to expected − literal month payments.
    double remainingFor(Map d) => _remainingForDue(Map<String, dynamic>.from(d));
    final selectable = allDues.where((d) => remainingFor(d as Map) > 0.01).toList();
    final fullyPaidCount = allDues.length - selectable.length;
    final selectedDue = allDues.cast<Map?>().firstWhere(
          (d) => d?['memberId']?.toString() == _selectedMemberId,
          orElse: () => null,
        );

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        initialChildSize: 0.85,
        expand: false,
        builder: (_, ctrl) => ListView(
          controller: ctrl,
          padding: const EdgeInsets.all(16),
          children: [
            Row(
              children: [
                const Expanded(child: Text('Record Payment', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600))),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
              ],
            ),
            const SizedBox(height: 8),
            DropdownButtonFormField<int>(
              // Re-seed the field when _month is switched programmatically (e.g. after the
              // collectable-months load drops a fully-collected current month).
              key: ValueKey('chit-pay-month-$_month'),
              initialValue: _month,
              decoration: const InputDecoration(labelText: 'Month'),
              items: _collectable.isNotEmpty
                  ? _collectable.map((mm) {
                      final m = toNum(mm['monthNumber']).toInt();
                      final tags = <String>[];
                      if (m == toNum(c['calendarMonth'] ?? c['currentMonth']).toInt()) tags.add('current');
                      if (m == _duration) tags.add('final');
                      if (mm['auctioned'] == false) tags.add('auction pending');
                      return DropdownMenuItem(value: m, child: Text('Month $m${tags.isNotEmpty ? ' — ${tags.join(', ')}' : ''}'));
                    }).toList()
                  : List.generate(_visibleMonths, (i) {
                      final m = i + 1;
                      final tags = <String>[];
                      if (m == toNum(c['calendarMonth'] ?? c['currentMonth']).toInt()) tags.add('current');
                      if (m == _duration) tags.add('final');
                      return DropdownMenuItem(value: m, child: Text('Month $m${tags.isNotEmpty ? ' — ${tags.join(', ')}' : ''}'));
                    }),
              onChanged: (v) { if (v != null) { setState(() => _month = v); _load(v); } },
            ),
            const SizedBox(height: 12),
            if (_dues != null && !_isFinalAccum)
              Text(
                (_dues!['auctionCompleted'] == true)
                    ? 'Auction done · dividend ${formatCurrency(_dues!['dividendPerMember'] ?? 0)}/eligible member'
                    : 'Auction for this month is not completed — expected = base installment',
                style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
            if (_isFinalAccum && _dues != null)
              Text('Final month · pool ${formatCurrency(_dues!['surplusPool'] ?? 0)} split across ${c['totalMembers']} members',
                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
            const SizedBox(height: 12),
            if (_loading)
              const LoadingView()
            else if (_dues != null) ...[
              DropdownButtonFormField<String>(
                initialValue: _selectedMemberId,
                decoration: const InputDecoration(labelText: 'Member'),
                isExpanded: true,
                items: selectable.map((raw) {
                  final d = Map<String, dynamic>.from(raw as Map);
                  // Waterfall-aware paid (verified + pending incl. spillover) for the label.
                  final paid = _paidForDue(d);
                  final name = '#${d['ticketNumber']} ${d['customerName'] ?? 'Member'}${d['hasWonAuction'] == true ? ' (won)' : ''}';
                  final label = paid > 0
                      ? '$name — ${formatCurrency(remainingFor(d))} due (paid ${formatCurrency(paid)} of ${formatCurrency(d['expectedAmount'])})'
                      : '$name — ${formatCurrency(d['expectedAmount'])}';
                  return DropdownMenuItem(
                    value: d['memberId'].toString(),
                    child: Text(label, overflow: TextOverflow.ellipsis),
                  );
                }).toList(),
                onChanged: selectable.isEmpty ? null : _onSelectMember,
              ),
              if (selectable.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('All members have paid for this month', style: TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                ),
              if (selectedDue != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(color: AppColors.info.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8)),
                  child: Column(
                    children: [
                      KeyValueRow(label: 'Base installment', value: formatCurrency(selectedDue['baseInstallment'])),
                      if (toNum(selectedDue['dividendCredit']) > 0)
                        KeyValueRow(label: 'Dividend credit', value: '− ${formatCurrency(selectedDue['dividendCredit'])}'),
                      if (toNum(selectedDue['poolShare']) > 0)
                        KeyValueRow(label: 'Pool share', value: '− ${formatCurrency(selectedDue['poolShare'])}'),
                      KeyValueRow(label: 'Expected', value: formatCurrency(selectedDue['expectedAmount'])),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 12),
              TextField(controller: _amountC, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Amount Collected')),
              const SizedBox(height: 12),
              InkWell(
                onTap: () async {
                  final picked = await showDatePicker(
                    context: context,
                    initialDate: _paidDate,
                    firstDate: DateTime(2015),
                    lastDate: DateTime.now().add(const Duration(days: 1)),
                  );
                  if (picked != null) setState(() => _paidDate = picked);
                },
                child: InputDecorator(
                  decoration: const InputDecoration(labelText: 'Payment Date'),
                  child: Text(formatDate(_paidDate)),
                ),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _mode,
                decoration: const InputDecoration(labelText: 'Payment Mode'),
                items: _paymentModes.map((m) => DropdownMenuItem(value: m, child: Text(titleCase(m)))).toList(),
                onChanged: (v) => setState(() => _mode = v ?? 'CASH'),
              ),
              const SizedBox(height: 12),
              TextField(controller: _refC, decoration: const InputDecoration(labelText: 'Reference', hintText: 'Txn ID / cheque #')),
              const SizedBox(height: 12),
              Text('$fullyPaidCount of ${widget.members.length} members paid for month $_month',
                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: (_saving || _selectedMemberId == null) ? null : _submit,
                  child: Text(_saving ? 'Saving...' : 'Record Payment'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CustPicker extends StatefulWidget {
  final WidgetRef ref;
  const _CustPicker({required this.ref});
  @override
  State<_CustPicker> createState() => _CustPickerState();
}

class _CustPickerState extends State<_CustPicker> {
  final _search = TextEditingController();
  List<Map<String, dynamic>> _items = [];
  bool _loading = false;

  @override
  void initState() { super.initState(); _load(''); }

  Future<void> _load(String q) async {
    setState(() => _loading = true);
    try {
      final r = await widget.ref.read(customerRepoProvider).list(page: 1, search: q.isEmpty ? null : q);
      setState(() => _items = ((r['data'] as List?) ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList());
    } catch (e) {
      showToast('Failed: $e', error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.8,
      expand: false,
      builder: (_, ctrl) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const Expanded(child: Text('Add Member', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600))),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
              ],
            ),
          ),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: TextField(controller: _search, decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search by ID or name...'), onSubmitted: _load)),
          const SizedBox(height: 8),
          Expanded(
            child: _loading
                ? const LoadingView()
                : ListView.builder(
                    controller: ctrl,
                    itemCount: _items.length,
                    itemBuilder: (ctx, i) {
                      final c = _items[i];
                      return ListTile(
                        title: Text('${c['firstName'] ?? ''} ${c['lastName'] ?? ''}'.trim()),
                        subtitle: Text('${c['customerId']} • ${c['phone']}'),
                        onTap: () => Navigator.pop(context, c),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// Opens a member's full transaction history (collections + payout) plus their pending-dues
// ledger — the same popup the dashboard "To Be Collected" drill-down deep-links into.
Future<void> showMemberTransactions(
  BuildContext context,
  WidgetRef ref, {
  required String chitfundId,
  required Map<String, dynamic> member,
}) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppColors.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
    builder: (_) => _MemberTransactionsSheet(chitfundId: chitfundId, member: member),
  );
}

class _MemberTransactionsSheet extends ConsumerStatefulWidget {
  final String chitfundId;
  final Map<String, dynamic> member;
  const _MemberTransactionsSheet({required this.chitfundId, required this.member});
  @override
  ConsumerState<_MemberTransactionsSheet> createState() => _MemberTransactionsSheetState();
}

class _MemberTransactionsSheetState extends ConsumerState<_MemberTransactionsSheet> {
  bool _loading = true;
  List<dynamic> _txns = const [];
  Map<String, dynamic>? _dues; // per-month waterfall dues ledger (months[], totalPending)

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final repo = ref.read(chitfundRepoProvider);
      final memberId = widget.member['id'].toString();
      // Transactions + the member's dues ledger in parallel (same as the web modal).
      final results = await Future.wait([
        repo.payments(widget.chitfundId, memberId: memberId),
        repo.memberDues(widget.chitfundId, memberId),
      ]);
      if (!mounted) return;
      setState(() {
        _txns = results[0] as List;
        _dues = results[1] as Map<String, dynamic>;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() { _txns = const []; _dues = null; _loading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.member;
    final cust = Map<String, dynamic>.from(m['customer'] ?? {});
    final name = '${cust['firstName'] ?? ''} ${cust['lastName'] ?? ''}'.trim();
    // Reverse-chronological ledger: newest month first, payout before collections same month.
    final rows = _txns.map((e) => Map<String, dynamic>.from(e as Map)).toList()
      ..sort((a, b) {
        final ma = toNum(a['monthNumber']).toInt();
        final mb = toNum(b['monthNumber']).toInt();
        if (ma != mb) return mb - ma;
        int ord(Map t) => (t['type']?.toString() ?? 'COLLECTION') == 'PAYOUT' ? 1 : 0;
        return ord(b) - ord(a);
      });
    final totalCollected = rows
        .where((t) => (t['type']?.toString() ?? 'COLLECTION') != 'PAYOUT')
        .fold<double>(0, (s, t) => s + toNum(t['amount']).toDouble());
    final totalPayout = rows
        .where((t) => t['type']?.toString() == 'PAYOUT')
        .fold<double>(0, (s, t) => s + toNum(t['amount']).toDouble());
    final totalPending = toNum(_dues?['totalPending']).toDouble();
    final pendingMonths = ((_dues?['months'] as List?) ?? const [])
        .map((e) => Map<String, dynamic>.from(e as Map))
        .where((mm) => mm['status'] != 'PAID')
        .toList();

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        initialChildSize: 0.85,
        expand: false,
        builder: (_, ctrl) => ListView(
          controller: ctrl,
          padding: const EdgeInsets.all(16),
          children: [
            Row(children: [
              Expanded(
                child: Text('#${m['ticketNumber'] ?? '-'} ${name.isEmpty ? 'Member' : name} — Transactions',
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
              IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: _summaryCell('Customer ID', cust['customerId']?.toString() ?? '-')),
              const SizedBox(width: 8),
              Expanded(child: _summaryCell('Phone', cust['phone']?.toString() ?? '-')),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: _summaryCell('Total Collected', formatCurrency(totalCollected), color: AppColors.accent)),
              const SizedBox(width: 8),
              Expanded(child: _summaryCell('Payout Received', totalPayout > 0 ? formatCurrency(totalPayout) : '—', color: AppColors.purple)),
            ]),
            if (m['hasWonAuction'] == true) ...[
              const SizedBox(height: 10),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: AppColors.purple.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(8)),
                child: Text(
                  'Won the auction in month ${m['wonMonth'] ?? '-'}'
                  '${m['wonAmount'] != null ? ' · payout ${formatCurrency(m['wonAmount'])}' : ''}',
                  style: const TextStyle(fontSize: 13, color: AppColors.purple),
                ),
              ),
            ],
            if (!_loading && _dues != null) ...[
              const SizedBox(height: 12),
              _pendingPanel(totalPending, pendingMonths),
            ],
            const SizedBox(height: 12),
            if (_loading)
              const Padding(padding: EdgeInsets.symmetric(vertical: 30), child: LoadingView())
            else if (rows.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 30),
                child: Center(child: Text('No transactions recorded yet.', style: TextStyle(color: AppColors.textSecondary))),
              )
            else
              Card(
                margin: EdgeInsets.zero,
                child: Column(children: [
                  for (var i = 0; i < rows.length; i++) ...[
                    if (i > 0) const Divider(height: 1),
                    _txnRow(rows[i]),
                  ],
                ]),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _summaryCell(String label, String value, {Color? color}) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(12)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontSize: 10, color: AppColors.textSecondary)),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: color ?? AppColors.textPrimary)),
          ),
        ],
      ),
    );
  }

  Widget _pendingPanel(double totalPending, List<Map<String, dynamic>> pendingMonths) {
    final owing = totalPending > 0.009;
    return Container(
      decoration: BoxDecoration(border: Border.all(color: AppColors.border), borderRadius: BorderRadius.circular(10)),
      child: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: const BoxDecoration(
              color: AppColors.bg,
              borderRadius: BorderRadius.vertical(top: Radius.circular(10)),
            ),
            child: Row(children: [
              const Expanded(child: Text('Pending payments', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
              Text(
                owing ? '${formatCurrency(totalPending)} outstanding' : 'All dues cleared',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: owing ? AppColors.warning : AppColors.accent),
              ),
            ]),
          ),
          for (final mm in pendingMonths)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(children: [
                Expanded(child: Text('Month ${mm['monthNumber']}', style: const TextStyle(fontSize: 13, color: AppColors.textSecondary))),
                Text(
                  '${formatCurrency(mm['pendingAmount'])}${mm['status'] == 'PARTIAL' ? ' left' : ''}',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.warning),
                ),
              ]),
            ),
        ],
      ),
    );
  }

  Widget _txnRow(Map<String, dynamic> t) {
    final type = t['type']?.toString() ?? 'COLLECTION';
    final isPayout = type == 'PAYOUT';
    final status = t['status']?.toString() ?? 'PAID';
    final officer = t['collectedByName']?.toString();
    final meta = [
      t['paymentMode']?.toString() ?? '-',
      formatDate(t['paidDate'] ?? t['createdAt']),
      if (officer != null && officer.isNotEmpty) officer,
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 30, child: Text('M${t['monthNumber']}', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary))),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                StatusChip(label: isPayout ? 'Payout' : 'Collection', color: isPayout ? AppColors.purple : AppColors.accent),
                const SizedBox(height: 3),
                Text(meta, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                isPayout ? '− ${formatCurrency(t['amount'])}' : formatCurrency(t['amount']),
                style: TextStyle(fontWeight: FontWeight.w700, color: isPayout ? AppColors.purple : AppColors.textPrimary),
              ),
              const SizedBox(height: 3),
              StatusChip(label: status, color: status == 'PAID' ? AppColors.accent : AppColors.warning),
            ],
          ),
        ],
      ),
    );
  }
}
