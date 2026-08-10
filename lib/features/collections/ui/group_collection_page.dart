import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/utils/location.dart';
import '../../../core/widgets/common.dart';
import '../data/collection_repo.dart';
import '../../loan_groups/data/loan_group_repo.dart';

class GroupCollectionPage extends ConsumerStatefulWidget {
  const GroupCollectionPage({super.key});
  @override
  ConsumerState<GroupCollectionPage> createState() => _GroupCollectionPageState();
}

/// Bucket for groups carrying no agent, so they stay pickable once the operator
/// has narrowed to an agent. Not a real user id, so it can never collide with one.
const _unassignedAgent = '__unassigned__';

class _GroupCollectionPageState extends ConsumerState<GroupCollectionPage> {
  Map<String, dynamic>? _group;
  List<Map<String, dynamic>> _groups = [];
  // Optional narrowing of the group picker to one agent's groups. null = all agents.
  String? _agentId;
  bool _groupsLoading = false;
  List<Map<String, dynamic>> _loans = [];
  final Map<String, TextEditingController> _amounts = {};
  final Map<String, TextEditingController> _alrs = {};
  String _mode = 'CASH';
  final _reference = TextEditingController();
  bool _loading = false;
  bool _saving = false;

  static const _weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];

  @override
  void initState() {
    super.initState();
    _loadGroups();
  }

  Future<void> _loadGroups() async {
    setState(() => _groupsLoading = true);
    try {
      final r = await ref.read(loanGroupRepoProvider).list(limit: 500);
      final all = ((r['data'] as List?) ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      // Only groups collectible today: meeting day matches, or no fixed meeting
      // day (those are collectible any day) — same rule as the web app.
      final today = _weekdays[DateTime.now().weekday - 1];
      if (!mounted) return;
      setState(() {
        _groups = all.where((g) {
          final day = g['meetingDay']?.toString() ?? '';
          return day.isEmpty || day == today;
        }).toList();
        // Refresh the selected group so its status chip reflects the latest counts.
        if (_group != null) {
          _group = _groups.firstWhere(
            (g) => g['id'].toString() == _group!['id'].toString(),
            orElse: () => _group!,
          );
        }
      });
    } finally {
      if (mounted) setState(() => _groupsLoading = false);
    }
  }

  // Agent = the team member the group is assigned to (LoanGroup.assignedTo). Options
  // are built from the groups already on offer rather than from /team, so the picker
  // lists only agents who actually have a group to collect today, each with the
  // number of groups picking them narrows the list to.
  List<Map<String, dynamic>> _agentOptions() {
    final byId = <String, Map<String, dynamic>>{};
    var unassigned = 0;
    for (final g in _groups) {
      final a = g['assignedTo'];
      if (a is! Map || a['id'] == null) {
        unassigned += 1;
        continue;
      }
      final id = a['id'].toString();
      final entry = byId[id] ?? {'id': id, 'name': a['name']?.toString() ?? 'Unnamed', 'count': 0};
      entry['count'] = (entry['count'] as int) + 1;
      byId[id] = entry;
    }
    final options = byId.values.toList()
      ..sort((a, b) => (a['name'] as String).toLowerCase().compareTo((b['name'] as String).toLowerCase()));
    // Only worth offering alongside real agents — on its own it would filter to everything.
    if (options.isNotEmpty && unassigned > 0) {
      options.add({'id': _unassignedAgent, 'name': 'Unassigned', 'count': unassigned});
    }
    return options;
  }

  List<Map<String, dynamic>> get _visibleGroups {
    if (_agentId == null) return _groups;
    return _groups.where((g) {
      final a = g['assignedTo'];
      final id = (a is Map && a['id'] != null) ? a['id'].toString() : _unassignedAgent;
      return id == _agentId;
    }).toList();
  }

  String? get _agentName {
    if (_agentId == null) return null;
    for (final a in _agentOptions()) {
      if (a['id'] == _agentId) return a['name'] as String;
    }
    return null;
  }

  Future<void> _pickAgent(List<Map<String, dynamic>> options) async {
    final picked = await showSearchableSelect<String>(
      context,
      title: 'Agent',
      searchHint: 'Search agents',
      selected: _agentId ?? '',
      options: [
        SelectOption<String>(value: '', label: 'All agents'),
        ...options.map((a) => SelectOption<String>(
              value: a['id'].toString(),
              label: '${a['name']} (${a['count']})',
              searchText: a['name'].toString(),
            )),
      ],
    );
    if (picked == null) return;
    setState(() {
      _agentId = picked.isEmpty ? null : picked;
      // The picked group may not be this agent's, so it is dropped rather than
      // left loaded under the new filter.
      _group = null;
      _loans = [];
    });
  }

  // Today's collection status for the picker, from the per-group counts the
  // /loan-groups list returns (active loans vs. those collected today).
  StatusChip _groupStatusChip(Map<String, dynamic> g) {
    final active = int.tryParse(g['activeLoans']?.toString() ?? '') ?? 0;
    final collected = int.tryParse(g['todayCollectedLoans']?.toString() ?? '') ?? 0;
    if (active == 0) return const StatusChip(label: 'No loans', color: AppColors.textSecondary);
    if (collected >= active) return const StatusChip(label: 'Fully collected', color: AppColors.accent);
    if (collected > 0) return const StatusChip(label: 'Partially collected', color: AppColors.warning);
    return const StatusChip(label: 'Pending', color: AppColors.danger);
  }

  Future<void> _pickGroup() async {
    final groups = _visibleGroups;
    if (groups.isEmpty) {
      return showToast(
        _agentId == null
            ? 'No groups due for collection today'
            : 'No groups for ${_agentName ?? 'this agent'} today',
        error: true,
      );
    }
    final picked = await showSearchableSelect<String>(
      context,
      title: 'Select Group',
      searchHint: 'Search by name, number or leader',
      selected: _group?['id']?.toString(),
      options: groups
          .map((g) => SelectOption<String>(
                value: g['id'].toString(),
                label: '${g['name']} (${g['groupNumber']})',
                searchText: '${g['name']} ${g['groupNumber']} ${g['leaderName'] ?? ''}',
                trailing: _groupStatusChip(g),
              ))
          .toList(),
    );
    if (picked != null) {
      setState(() {
        _group = _groups.firstWhere((g) => g['id'].toString() == picked);
        _loans = [];
      });
      await _loadLoans();
    }
  }

  Future<void> _loadLoans() async {
    if (_group == null) return;
    setState(() => _loading = true);
    try {
      final list = await ref.read(loanGroupRepoProvider).loans(_group!['id'].toString());
      if (!mounted) return;
      setState(() {
        _loans = list.map((e) => Map<String, dynamic>.from(e as Map)).where((l) => l['status'] == 'ACTIVE').toList();
        _amounts.clear();
        _alrs.clear();
        for (final l in _loans) {
          _amounts[l['id'].toString()] = TextEditingController();
          // ALR prefills from the loan's ALR; tracked separately from the amount.
          final alr = double.tryParse(l['alr']?.toString() ?? '');
          _alrs[l['id'].toString()] = TextEditingController(text: alr != null && alr > 0 ? l['alr'].toString() : '');
        }
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _submit() async {
    if (_group == null) return showToast('Select a group', error: true);
    final collections = <Map<String, dynamic>>[];
    for (final l in _loans) {
      // Already collected today — the row renders as collected with no input,
      // and must never be re-submitted (the API rejects the whole batch).
      if (l['todayCollection'] != null) continue;
      final amt = double.tryParse(_amounts[l['id'].toString()]?.text ?? '');
      if (amt != null && amt > 0) {
        final alr = double.tryParse(_alrs[l['id'].toString()]?.text ?? '');
        collections.add({
          'loanId': l['id'],
          'amount': amt,
          if (alr != null && alr > 0) 'alrAmount': alr,
        });
      }
    }
    if (collections.isEmpty) return showToast('Enter at least one amount', error: true);
    setState(() => _saving = true);
    try {
      // Best-effort GPS for the meeting — applies to every member's collection, never blocks.
      final location = await tryGetCurrentLocation();
      await ref.read(collectionRepoProvider).createGroup({
        'groupId': _group!['id'],
        'paymentMode': _mode,
        if (_reference.text.trim().isNotEmpty) 'paymentReference': _reference.text.trim(),
        'collections': collections,
        if (location != null) ...location.toJson(),
      });
      showToast('Group collection recorded');
      // Stay on the group collection page so the agent can keep working with the
      // same group — re-fetch the loans so the just-posted members flip to their
      // "Collected" state (which also recreates the inputs empty, so the posted
      // figures can't be re-submitted by accident).
      if (mounted) {
        _reference.clear();
        await _loadLoans();
        // Refresh group counts so the status chip flips (e.g. Pending → Fully collected).
        await _loadGroups();
      }
    } on ApiException catch (e) {
      showToast(e.message, error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // Which installment the loan is running, in its own cadence — "Week 5 / 20".
  // Null while the schedule hasn't reached its first installment.
  static const _periodNouns = {'DAYS': 'Day', 'WEEKS': 'Week', 'MONTHS': 'Month', 'YEARS': 'Month'};
  String? _installmentLabel(Map<String, dynamic> l) {
    final r = l['runningEmi'];
    if (r is! Map) return null;
    final n = toNum(r['number']).toInt();
    if (n <= 0) return null;
    final total = toNum(r['total']).toInt();
    final noun = l['loanType'] == 'DAILY'
        ? 'Day'
        : l['loanType'] == 'WEEKLY'
            ? 'Week'
            : _periodNouns[l['tenureType']?.toString()] ?? 'Week';
    return total > 0 ? '$noun $n / $total' : '$noun $n';
  }

  @override
  Widget build(BuildContext context) {
    final collectedCount = _loans.where((l) => l['todayCollection'] != null).length;
    final allCollected = _loans.isNotEmpty && collectedCount == _loans.length;
    final agentOptions = _agentOptions();
    // The filter only earns its place when there is more than one agent to choose
    // between: a single-agent org, or a field officer who only ever sees their own
    // groups, gets the plain group picker.
    final showAgentFilter = agentOptions.length > 1;
    return Scaffold(
      appBar: AppBar(title: const Text('Group Collection')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          SectionCard(
            title: 'Group',
            child: Column(
              children: [
                if (showAgentFilter)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.person_outline),
                    title: Text(_agentName ?? 'All agents'),
                    subtitle: Text('${_visibleGroups.length} group(s)'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _groupsLoading ? null : () => _pickAgent(agentOptions),
                  ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.groups),
                  title: Text(_group == null
                      ? (_groupsLoading ? 'Loading groups...' : 'Select Group *')
                      : _group!['name']?.toString() ?? ''),
                  trailing: _group == null
                      ? const Icon(Icons.chevron_right)
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _groupStatusChip(_group!),
                            const SizedBox(width: 4),
                            const Icon(Icons.chevron_right),
                          ],
                        ),
                  onTap: _groupsLoading ? null : _pickGroup,
                ),
              ],
            ),
          ),
          SectionCard(
            title: 'Payment Mode',
            child: Column(
              children: [
                DropdownButtonFormField<String>(
                  initialValue: _mode,
                  decoration: const InputDecoration(labelText: 'Mode'),
                  items: const [
                    DropdownMenuItem(value: 'CASH', child: Text('Cash')),
                    DropdownMenuItem(value: 'UPI', child: Text('UPI')),
                    DropdownMenuItem(value: 'BANK_TRANSFER', child: Text('Bank Transfer')),
                  ],
                  onChanged: (v) => setState(() => _mode = v!),
                ),
                const SizedBox(height: 10),
                TextField(controller: _reference, decoration: const InputDecoration(labelText: 'Reference (if non-cash)')),
              ],
            ),
          ),
          if (_loading)
            const LoadingView()
          else if (_loans.isEmpty && _group != null)
            const EmptyView(message: 'No active loans in group')
          else if (_loans.isNotEmpty)
            SectionCard(
              title: 'Members',
              child: Column(
                children: [
                  if (collectedCount > 0)
                    Container(
                      width: double.infinity,
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      decoration: BoxDecoration(
                        color: AppColors.accent.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        allCollected
                            ? 'Group collection already recorded today.'
                            : '$collectedCount of ${_loans.length} members already collected today — submitting records only the rest.',
                        style: const TextStyle(fontSize: 12, color: AppColors.accent, fontWeight: FontWeight.w500),
                      ),
                    ),
                  ..._loans.map((l) {
                    final c = Map<String, dynamic>.from(l['customer'] ?? {});
                    final today = l['todayCollection'] is Map ? Map<String, dynamic>.from(l['todayCollection'] as Map) : null;
                    final installment = _installmentLabel(l);
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text('${c['firstName'] ?? ''} ${c['lastName'] ?? ''}'.trim(), style: const TextStyle(fontWeight: FontWeight.w500)),
                                Text(
                                  [
                                    l['loanNumber']?.toString() ?? '',
                                    ?installment,
                                    'EMI ${formatCurrency(l['emiAmount'])}',
                                  ].join(' • '),
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 10),
                          if (today != null)
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(formatCurrency(today['amount']), style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.accent)),
                                Text('Collected • ${today['receiptNumber'] ?? ''}', style: const TextStyle(fontSize: 11, color: AppColors.accent)),
                              ],
                            )
                          else ...[
                            SizedBox(
                              width: 110,
                              child: TextField(
                                controller: _amounts[l['id'].toString()],
                                keyboardType: TextInputType.number,
                                decoration: const InputDecoration(prefixText: '₹ ', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
                              ),
                            ),
                            // ALR is only collectable when the loan was created with an ALR.
                            if ((double.tryParse(l['alr']?.toString() ?? '') ?? 0) > 0) ...[
                              const SizedBox(width: 8),
                              SizedBox(
                                width: 80,
                                child: TextField(
                                  controller: _alrs[l['id'].toString()],
                                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                                  decoration: const InputDecoration(labelText: 'ALR', isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10)),
                                ),
                              ),
                            ],
                          ],
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),
          if (_loans.isNotEmpty && !allCollected)
            SizedBox(width: double.infinity, child: ElevatedButton(onPressed: _saving ? null : _submit, child: Text(_saving ? 'Saving...' : 'Submit Group Collection'))),
        ],
      ),
    );
  }
}

