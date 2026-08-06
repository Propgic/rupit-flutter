import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/api/api_client.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/common.dart';
import '../data/collection_repo.dart';

const _loanTypeLabels = {
  'PERSONAL': 'Personal',
  'GOLD': 'Gold',
  'GROUP': 'Group',
  'VEHICLE': 'Vehicle',
  'PROPERTY': 'Property',
  'BUSINESS': 'Business',
  'AGRICULTURE': 'Agriculture',
  'EDUCATION': 'Education',
  'DAILY': 'Daily',
  'WEEKLY': 'Weekly',
};

const _paymentModeLabels = {
  'CASH': 'Cash',
  'UPI': 'UPI',
  'BANK_TRANSFER': 'Bank',
  'CHEQUE': 'Cheque',
  'ONLINE': 'Online',
};

class VerifyCollectionsPage extends ConsumerStatefulWidget {
  const VerifyCollectionsPage({super.key, this.collectedById, this.collectorName});
  final String? collectedById;
  final String? collectorName;
  @override
  ConsumerState<VerifyCollectionsPage> createState() => _VerifyCollectionsPageState();
}

class _VerifyCollectionsPageState extends ConsumerState<VerifyCollectionsPage> {
  List<Map<String, dynamic>> _items = [];
  Map<String, dynamic>? _summary;
  // True only until the first fetch settles. Gates the full-page spinner so later
  // searches re-render in place instead of unmounting (which would drop search focus).
  bool _initialLoad = true;
  Object? _error;
  final _searchCtrl = TextEditingController();
  String _search = '';
  Timer? _debounce;
  // Bulk verify/reject. Ids only, and cleared on every refetch — a selection is only ever
  // over collections currently on screen, so a search or refresh can't carry a stale one.
  final Set<String> _selected = {};
  bool _bulkBusy = false;

  @override
  void initState() { super.initState(); _fetch(); }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSearchChanged(String v) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      _search = v;
      _fetch();
    });
  }

  Future<void> _fetch() async {
    setState(() { _error = null; _selected.clear(); });
    try {
      final api = ref.read(apiClientProvider);
      final q = <String, dynamic>{'limit': 200};
      if (widget.collectedById?.isNotEmpty ?? false) q['collectedById'] = widget.collectedById;
      if (_search.trim().isNotEmpty) q['search'] = _search.trim();
      final res = await api.raw(() => api.dio.get('/collections/pending-verification', queryParameters: q));
      final body = res.data;
      final data = body is Map && body['data'] is List ? body['data'] as List : const [];
      if (body is Map && body['summary'] != null) {
        _summary = Map<String, dynamic>.from(body['summary'] as Map);
      }
      if (mounted) setState(() => _items = data.map((e) => Map<String, dynamic>.from(e as Map)).toList());
    } catch (e) { if (mounted) setState(() => _error = e); }
    finally { if (mounted) setState(() => _initialLoad = false); }
  }

  Future<void> _verify(String id, bool approve) async {
    try {
      await ref.read(collectionRepoProvider).verify(id, approve: approve);
      showToast(approve ? 'Verified' : 'Rejected');
      _fetch();
    } on ApiException catch (e) {
      showToast(e.message, error: true);
    }
  }

  bool get _allSelected => _items.isNotEmpty && _selected.length == _items.length;

  double get _selectedTotal => _items
      .where((c) => _selected.contains(c['id'].toString()))
      .fold<double>(0, (s, c) => s + toNum(c['amount']));

  void _toggle(String id) => setState(() {
    if (!_selected.remove(id)) _selected.add(id);
  });

  Future<void> _bulkVerify(bool approve) async {
    final ids = _selected.toList();
    if (ids.isEmpty) return;
    final total = formatCurrency(_selectedTotal);
    final ok = await confirmDialog(
      context,
      title: approve ? 'Verify ${ids.length} collections' : 'Reject ${ids.length} collections',
      message: approve
          ? 'Verify ${ids.length} collection(s) totalling $total? The amounts are applied to each loan\'s EMIs immediately.'
          : 'Reject ${ids.length} collection(s) totalling $total?',
      confirmText: approve ? 'Verify' : 'Reject',
      destructive: !approve,
    );
    if (!ok) return;
    setState(() => _bulkBusy = true);
    try {
      final res = await ref.read(collectionRepoProvider).bulkVerify(ids, approve: approve);
      // The server reports what it actually applied — anything verified elsewhere in the
      // meantime is skipped — so show its message rather than claiming all of them went.
      showToast(res['message']?.toString() ?? (approve ? 'Verified' : 'Rejected'));
      _fetch();
    } on ApiException catch (e) {
      showToast(e.message, error: true);
    } finally {
      if (mounted) setState(() => _bulkBusy = false);
    }
  }

  // Field officers get a read-only self-scoped view (backend scopes the list to their
  // own collections); verify/reject is ORG_ADMIN/MANAGER only, so the action buttons and
  // the "Verify" framing are hidden for them.
  bool get _isFieldOfficer => ref.read(authProvider).user?.role == 'FIELD_OFFICER';

  @override
  Widget build(BuildContext context) {
    final title = _isFieldOfficer
        ? 'My Pending Collections'
        : (widget.collectorName?.isNotEmpty ?? false)
            ? 'Verify — ${widget.collectorName}'
            : 'Verify Collections';
    return Scaffold(
      appBar: AppBar(
        title: Text(_selected.isEmpty ? title : '${_selected.length} selected'),
        actions: [
          if (!_isFieldOfficer && _items.isNotEmpty)
            IconButton(
              tooltip: _allSelected ? 'Clear selection' : 'Select all',
              icon: Icon(_allSelected ? Icons.deselect : Icons.select_all),
              // Read _allSelected before mutating — it is derived from _selected, so
              // clearing first would make it always report "not all selected".
              onPressed: () {
                final selectAll = !_allSelected;
                setState(() {
                  _selected.clear();
                  if (selectAll) _selected.addAll(_items.map((e) => e['id'].toString()));
                });
              },
            ),
        ],
      ),
      bottomNavigationBar: (_isFieldOfficer || _selected.isEmpty) ? null : _bulkBar(),
      body: _initialLoad
          ? const LoadingView()
          : Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  child: TextField(
                    controller: _searchCtrl,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: 'Search customer, customer #, loan / chit #, agent, receipt...',
                      suffixIcon: _searchCtrl.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () { _searchCtrl.clear(); _search = ''; _fetch(); },
                            ),
                    ),
                    onChanged: _onSearchChanged,
                  ),
                ),
                Expanded(
                  child: _error != null
                      ? ErrorView(message: _error.toString(), onRetry: _fetch)
                      : _items.isEmpty
                          ? EmptyView(
                              message: _search.trim().isEmpty
                                  ? 'Nothing pending'
                                  : 'No pending collections match "${_search.trim()}"',
                              icon: Icons.check_circle_outline,
                            )
                          : RefreshIndicator(
                              onRefresh: _fetch,
                              child: ListView(
                                padding: const EdgeInsets.all(12),
                                children: [
                                  if (_summary != null) ...[
                                    Row(children: [
                                      _metricCard('To Be Verified', formatCurrency(_summary!['pendingAmount']), AppColors.warning),
                                      const SizedBox(width: 8),
                                      _metricCard("Today's Pending", formatCurrency(_summary!['todayPendingAmount']), AppColors.textPrimary),
                                    ]),
                                    const SizedBox(height: 8),
                                    Row(children: [
                                      _metricCard('Collectors', '${_summary!['collectorsCount'] ?? 0}', AppColors.primary),
                                      const SizedBox(width: 8),
                                      _metricCard('Older Pending', formatCurrency(toNum(_summary!['pendingAmount']) - toNum(_summary!['todayPendingAmount'])), AppColors.danger),
                                    ]),
                                    const SizedBox(height: 12),
                                  ],
                                  ..._items.map(_collectionCard),
                                  const SizedBox(height: 20),
                                ],
                              ),
                            ),
                ),
              ],
            ),
    );
  }

  Widget _bulkBar() => SafeArea(
    child: Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border: const Border(top: BorderSide(color: Color(0x1A000000))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(children: [
            Expanded(
              child: Text(
                '${_selected.length} selected · ${formatCurrency(_selectedTotal)}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ),
            TextButton(
              onPressed: _bulkBusy ? null : () => setState(_selected.clear),
              child: const Text('Clear'),
            ),
          ]),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _bulkBusy ? null : () => _bulkVerify(false),
                icon: const Icon(Icons.close, color: AppColors.danger),
                label: const Text('Reject', style: TextStyle(color: AppColors.danger)),
                style: OutlinedButton.styleFrom(side: const BorderSide(color: AppColors.danger)),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: ElevatedButton.icon(
                onPressed: _bulkBusy ? null : () => _bulkVerify(true),
                icon: _bulkBusy
                    ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.check),
                label: Text('Verify ${_selected.length}'),
                style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent),
              ),
            ),
          ]),
        ],
      ),
    ),
  );

  Widget _miniBadge(String label, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(label, style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color)),
  );

  Widget _metricCard(String label, String value, Color color) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.2)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w500)),
        const SizedBox(height: 2),
        Text(value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: color)),
      ]),
    ),
  );

  Widget _collectionCard(Map<String, dynamic> c) {
    final cust = Map<String, dynamic>.from(c['customer'] ?? {});
    final loan = Map<String, dynamic>.from(c['loan'] ?? {});
    final isChit = c['sourceType'] == 'CHITFUND';
    final chit = Map<String, dynamic>.from(c['chitfund'] ?? {});
    final collector = Map<String, dynamic>.from(c['collectedBy'] ?? {});
    final overdueEmis = (loan['emiSchedule'] as List?) ?? [];
    final overdueAmt = overdueEmis.fold<double>(0, (s, e) {
      final m = Map<String, dynamic>.from(e as Map);
      return s + toNum(m['emiAmount']) + toNum(m['lateFee']) - toNum(m['paidAmount']);
    });

    final id = c['id'].toString();
    final isSelected = _selected.contains(id);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      // Selected rows get a visible border so the bottom bar's count is always traceable
      // back to specific cards.
      shape: isSelected
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: const BorderSide(color: AppColors.accent, width: 2),
            )
          : null,
      child: InkWell(
        // Tapping anywhere on the card toggles selection; the inner gesture detectors
        // (photo, View Loan / View Chit) still absorb their own taps.
        onTap: _isFieldOfficer ? null : () => _toggle(id),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!_isFieldOfficer)
                  Padding(
                    padding: const EdgeInsets.only(right: 2),
                    child: SizedBox(
                      height: 24,
                      width: 24,
                      child: Checkbox(
                        value: isSelected,
                        onChanged: (_) => _toggle(id),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ),
                if (!_isFieldOfficer) const SizedBox(width: 6),
                GestureDetector(
                  onTap: () => showImageViewer(context, cust['photo']?.toString()),
                  child: Avatar(
                    url: cust['photo']?.toString(),
                    name: '${cust['firstName'] ?? ''} ${cust['lastName'] ?? ''}'.trim(),
                    size: 44,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${cust['firstName'] ?? ''} ${cust['lastName'] ?? ''}'.trim(),
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 4),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          if (isChit)
                            _miniBadge('Chitfund', const Color(0xFF7C3AED))
                          else if (loan['loanType'] != null)
                            _miniBadge(_loanTypeLabels[loan['loanType']?.toString()] ?? loan['loanType'].toString(), const Color(0xFF7C3AED)),
                          if (c['paymentMode'] != null)
                            _miniBadge(_paymentModeLabels[c['paymentMode']?.toString()] ?? c['paymentMode'].toString(), AppColors.primary),
                        ],
                      ),
                      const SizedBox(height: 4),
                      if (isChit)
                        Row(children: [
                          Flexible(child: Text(
                            '${chit['chitNumber'] ?? chit['name'] ?? ''}${c['monthNumber'] != null ? ' · M${c['monthNumber']}' : ''}',
                            style: const TextStyle(fontSize: 12, color: AppColors.textSecondary), overflow: TextOverflow.ellipsis)),
                          if (c['chitfundId'] != null) ...[
                            const SizedBox(width: 6),
                            GestureDetector(
                              onTap: () => context.push('/chitfunds/${c['chitfundId']}'),
                              child: const Text('View Chit', style: TextStyle(fontSize: 11, color: AppColors.primary, fontWeight: FontWeight.w600)),
                            ),
                          ],
                        ])
                      else
                        Row(children: [
                          Flexible(child: Text(loan['loanNumber']?.toString() ?? '', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary), overflow: TextOverflow.ellipsis)),
                          if (loan['id'] != null) ...[
                            const SizedBox(width: 6),
                            GestureDetector(
                              onTap: () => context.push('/loans/${loan['id']}'),
                              child: const Text('View Loan', style: TextStyle(fontSize: 11, color: AppColors.primary, fontWeight: FontWeight.w600)),
                            ),
                          ],
                        ]),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(formatCurrency(c['amount']), style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16)),
                    if ((double.tryParse(c['alrAmount']?.toString() ?? '') ?? 0) > 0)
                      Text('+ ALR ${formatCurrency(c['alrAmount'])}', style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(children: [
              Expanded(
                child: Text('Collected by ${collector['name'] ?? ''} • ${formatDateTime(c['collectedAt'])}',
                    style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
              ),
              if (overdueEmis.isNotEmpty)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.danger.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text('Overdue: ${formatCurrency(overdueAmt)}',
                      style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: AppColors.danger)),
                ),
            ]),
            // Per-row buttons give way to the bulk bar once a selection is active, so
            // there's only ever one obvious way to act on what's ticked.
            if (!_isFieldOfficer && _selected.isEmpty) ...[
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => _verify(c['id'].toString(), false),
                      icon: const Icon(Icons.close, color: AppColors.danger),
                      label: const Text('Reject', style: TextStyle(color: AppColors.danger)),
                      style: OutlinedButton.styleFrom(side: const BorderSide(color: AppColors.danger)),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () => _verify(c['id'].toString(), true),
                      icon: const Icon(Icons.check),
                      label: const Text('Verify'),
                      style: ElevatedButton.styleFrom(backgroundColor: AppColors.accent),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      ),
    );
  }
}
