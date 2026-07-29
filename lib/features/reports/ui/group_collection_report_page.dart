import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/common.dart';
import '../../loan_groups/data/loan_group_repo.dart';
import '../../team/data/team_repo.dart';
import '_report_scaffold.dart';

class GroupCollectionReportPage extends ConsumerStatefulWidget {
  const GroupCollectionReportPage({super.key});
  @override
  ConsumerState<GroupCollectionReportPage> createState() => _GroupCollectionReportPageState();
}

class _GroupCollectionReportPageState extends ConsumerState<GroupCollectionReportPage> {
  List<Map<String, dynamic>> _groups = [];
  List<Map<String, dynamic>> _collectors = [];
  String? _collectorId;
  String? _groupId;
  DateTime? _from;
  DateTime? _to;
  Map<String, dynamic>? _report;
  bool _loading = false;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _loadCollectors();
    _loadGroups();
  }

  Future<void> _loadCollectors() async {
    try {
      final list = await ref.read(teamRepoProvider).list(limit: 500);
      if (!mounted) return;
      setState(() => _collectors = list
          .map((e) => Map<String, dynamic>.from(e as Map))
          .where((m) => m['isActive'] == true)
          .toList());
    } catch (_) {}
  }

  // Groups are narrowed to the selected collector's assigned groups.
  Future<void> _loadGroups() async {
    try {
      final res = await ref.read(loanGroupRepoProvider).list(limit: 500, assignedTo: _collectorId);
      final data = res['data'];
      if (!mounted) return;
      setState(() => _groups = (data is List ? data : const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList());
    } catch (_) {
      if (mounted) setState(() => _groups = []);
    }
  }

  Future<void> _fetch() async {
    if (_collectorId == null && _groupId == null) {
      setState(() => _report = null);
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final q = <String, dynamic>{};
      if (_groupId != null) q['groupId'] = _groupId;
      if (_collectorId != null) q['collectorId'] = _collectorId;
      if (_from != null) q['fromDate'] = formatInputDate(_from!);
      if (_to != null) q['toDate'] = formatInputDate(_to!);
      final d = await ref.read(apiClientProvider).get('/reports/group-collection', query: q);
      if (!mounted) return;
      setState(() => _report = Map<String, dynamic>.from(d as Map));
    } catch (e) {
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onCollectorChanged(String? v) {
    setState(() { _collectorId = v; _groupId = null; });
    _loadGroups();
    _fetch();
  }

  String _collectorName(String? id) =>
      _collectors.firstWhere((c) => c['id'] == id, orElse: () => const {})['name']?.toString() ?? '';

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Group Collection Report')),
      body: Column(
        children: [
          _filters(),
          if (_collectorId == null && _groupId == null)
            const Expanded(child: EmptyView(message: 'Select a collector or a group to view the report'))
          else if (_loading)
            const Expanded(child: LoadingView())
          else if (_error != null)
            Expanded(child: ErrorView(message: _error.toString(), onRetry: _fetch))
          else
            Expanded(child: _resultBody(_report ?? const {})),
        ],
      ),
    );
  }

  Widget _filters() {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.all(10),
      child: Wrap(spacing: 8, runSpacing: 8, children: [
        SizedBox(width: 180, child: DropdownButtonFormField<String?>(
          initialValue: _collectorId,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Collector', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10)),
          items: [
            const DropdownMenuItem(value: null, child: Text('All Collectors')),
            ..._collectors.map((c) => DropdownMenuItem(value: c['id'].toString(), child: Text(c['name']?.toString() ?? '', overflow: TextOverflow.ellipsis))),
          ],
          onChanged: _onCollectorChanged,
        )),
        SizedBox(width: 180, child: DropdownButtonFormField<String?>(
          // Rebuild (and reset) when the collector changes so the narrowed list applies cleanly.
          key: ValueKey('grp-${_collectorId ?? "all"}'),
          initialValue: _groupId,
          isExpanded: true,
          decoration: InputDecoration(labelText: 'Group', isDense: true, contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10), hintText: _collectorId != null ? 'All Assigned Groups' : 'All Groups'),
          items: [
            DropdownMenuItem(value: null, child: Text(_collectorId != null ? 'All Assigned Groups' : 'All Groups')),
            ..._groups.map((g) => DropdownMenuItem(value: g['id'].toString(), child: Text('${g['name']} (${g['groupNumber']})', overflow: TextOverflow.ellipsis))),
          ],
          onChanged: (v) { setState(() => _groupId = v); _fetch(); },
        )),
        OutlinedButton.icon(
          onPressed: () async {
            final d = await showDatePicker(context: context, firstDate: DateTime(2020), lastDate: DateTime.now(), initialDate: _from ?? DateTime.now());
            if (d != null) { setState(() => _from = d); _fetch(); }
          },
          icon: const Icon(Icons.calendar_today, size: 14),
          label: Text('From: ${_from == null ? "-" : formatDate(_from)}', style: const TextStyle(fontSize: 12)),
        ),
        OutlinedButton.icon(
          onPressed: () async {
            final d = await showDatePicker(context: context, firstDate: DateTime(2020), lastDate: DateTime.now(), initialDate: _to ?? DateTime.now());
            if (d != null) { setState(() => _to = d); _fetch(); }
          },
          icon: const Icon(Icons.calendar_today, size: 14),
          label: Text('To: ${_to == null ? "-" : formatDate(_to)}', style: const TextStyle(fontSize: 12)),
        ),
        if (_from != null || _to != null)
          TextButton(onPressed: () { setState(() { _from = null; _to = null; }); _fetch(); }, child: const Text('Clear dates')),
      ]),
    );
  }

  Widget _resultBody(Map<String, dynamic> r) {
    final group = r['group'] is Map ? Map<String, dynamic>.from(r['group']) : null;
    final members = (r['members'] as List?) ?? const [];
    final collections = (r['collections'] as List?) ?? const [];
    final summary = Map<String, dynamic>.from(r['summary'] ?? {});
    final hasPeriod = r['fromDate'] != null || r['toDate'] != null;
    final hasCollector = r['collectorId'] != null;
    final isFiltered = hasPeriod || hasCollector;
    final scopedLabel = hasCollector && !hasPeriod ? 'By Collector' : 'In Period';
    final showGroup = group == null;

    final headerTitle = group != null
        ? (group['name']?.toString() ?? 'Group')
        : (hasCollector ? '${_collectorName(r['collectorId']?.toString())} — Group Collections' : 'All Groups');
    final headerSub = group != null
        ? [group['groupNumber'], if (group['leaderName'] != null) 'Leader: ${group['leaderName']}', if (group['cycle'] != null) 'Cycle: ${group['cycle']}'].where((e) => e != null).join('  •  ')
        : 'Across all groups • ${summary['memberCount'] ?? 0} members';

    return RefreshIndicator(
      onRefresh: _fetch,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          // Header
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(headerTitle, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(headerSub, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                if (isFiltered) ...[
                  const SizedBox(height: 8),
                  Wrap(spacing: 6, runSpacing: 6, children: [
                    if (hasCollector) StatusChip(label: 'Collector: ${_collectorName(r['collectorId']?.toString())}', color: AppColors.purple),
                    if (hasPeriod) StatusChip(label: '${formatDate(r['fromDate']) } — ${formatDate(r['toDate'])}', color: AppColors.primary),
                  ]),
                ],
              ]),
            ),
          ),
          const SizedBox(height: 8),
          // Summary
          ReportSummaryGrid(items: [
            MapEntry('Members', '${summary['memberCount'] ?? 0}'),
            MapEntry('Active Loans', '${summary['activeLoans'] ?? 0}'),
            MapEntry('EMI Due', formatCurrency(summary['totalEmiDue'])),
            MapEntry(isFiltered ? scopedLabel : 'Total Collected', formatCurrency(isFiltered ? summary['periodCollected'] : summary['totalCollected'])),
            MapEntry('Total Collected', formatCurrency(summary['totalCollected'])),
            MapEntry('Pending Collection', formatCurrency(summary['totalPendingDue'])),
            MapEntry('Outstanding', formatCurrency(summary['totalOutstanding'])),
          ]),
          const SizedBox(height: 8),
          // Members
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Text('Members (${members.length})', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          ),
          if (members.isEmpty) const EmptyView(message: 'No members')
          else ...members.map((e) => _memberTile(Map<String, dynamic>.from(e as Map), showGroup, scopedLabel, isFiltered)),
          const SizedBox(height: 12),
          // Collection entries
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: Text('Collection Entries (${collections.length})${hasPeriod ? "" : " — all time"}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
          ),
          if (collections.isEmpty) const EmptyView(message: 'No collections found')
          else ...collections.map((e) => _entryTile(Map<String, dynamic>.from(e as Map), showGroup)),
          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _memberTile(Map<String, dynamic> m, bool showGroup, String scopedLabel, bool isFiltered) {
    final outstanding = toNum(m['outstanding']);
    final pendingDue = toNum(m['pendingDue']);
    final sub = <String>[
      m['loanNumber']?.toString() ?? '',
      if (showGroup && m['groupName'] != null) m['groupName'].toString(),
      'EMI ${formatCurrency(m['emiAmount'])}',
      if (pendingDue > 0) 'Pending ${formatCurrency(pendingDue)}',
      if (m['lastPaymentDate'] != null) 'Last: ${m['lastPaymentDate']}',
    ];
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: ListTile(
        dense: true,
        title: Row(children: [
          Expanded(child: Text(m['customer']?.toString() ?? '', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
          StatusChip(label: m['status']?.toString() ?? '', color: statusColor(m['status']?.toString())),
        ]),
        subtitle: Text(sub.join(' • '), style: const TextStyle(fontSize: 11)),
        trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('Coll ${formatCurrency(isFiltered ? m['periodCollected'] : m['totalCollected'])}', style: const TextStyle(fontSize: 12, color: AppColors.accent, fontWeight: FontWeight.w700)),
          Text('Out ${formatCurrency(outstanding)}', style: TextStyle(fontSize: 11, color: outstanding > 0 ? AppColors.danger : AppColors.textSecondary)),
        ]),
      ),
    );
  }

  Widget _entryTile(Map<String, dynamic> c, bool showGroup) {
    final sub = <String>[
      c['date']?.toString() ?? '',
      c['receiptNumber']?.toString() ?? '',
      if (showGroup && c['groupName'] != null) c['groupName'].toString(),
      c['paymentMode']?.toString() ?? '',
      if (c['collectorName'] != null) c['collectorName'].toString(),
    ];
    final status = c['verificationStatus']?.toString();
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 3),
      child: ListTile(
        dense: true,
        leading: const Icon(Icons.receipt_long_outlined, color: AppColors.accent, size: 20),
        title: Text(c['customer']?.toString() ?? '', style: const TextStyle(fontSize: 13)),
        subtitle: Text(sub.where((s) => s.isNotEmpty).join(' • '), style: const TextStyle(fontSize: 11)),
        trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(formatCurrency(c['amount']), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
          StatusChip(
            label: status == 'VERIFIED' ? 'Accepted' : status == 'REJECTED' ? 'Rejected' : 'Pending',
            color: statusColor(status),
          ),
        ]),
      ),
    );
  }
}
