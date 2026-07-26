import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/api/api_client.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/common.dart';
import '../data/collection_repo.dart';
import '../../app_shell.dart';
import '../../../core/widgets/app_bottom_nav.dart';

// Mirrors the web CollectionList loan-type filter: only types whose org feature
// flag is enabled are offered. Kept local per the convention used across the
// collections feature (see collection_form_page.dart / verify_collections_page.dart).
const _loanTypeFeatureMap = {
  'PERSONAL': 'enablePersonalLoan',
  'GOLD': 'enableGoldLoan',
  'GROUP': 'enableGroupLoan',
  'VEHICLE': 'enableVehicleLoan',
  'PROPERTY': 'enableMortgage',
  'BUSINESS': 'enableBusinessLoan',
  'AGRICULTURE': 'enableAgricultureLoan',
  'EDUCATION': 'enableEducationLoan',
  'DAILY': 'enableDailyLoan',
  'WEEKLY': 'enableWeeklyLoan',
};

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

class CollectionListPage extends ConsumerStatefulWidget {
  const CollectionListPage({super.key});
  @override
  ConsumerState<CollectionListPage> createState() => _CollectionListPageState();
}

class _CollectionListPageState extends ConsumerState<CollectionListPage> {
  final _scroll = ScrollController();
  final _searchCtrl = TextEditingController();
  final List<Map<String, dynamic>> _items = [];
  int _page = 1;
  bool _loading = false;
  bool _hasMore = true;
  String? _search;
  String? _verification;
  String? _loanType;
  String? _collectedById;
  List<Map<String, dynamic>> _collectors = [];
  late String _dateFrom;
  late String _dateTo;
  Map<String, dynamic>? _summary;

  @override
  void initState() {
    super.initState();
    final today = formatInputDate(DateTime.now());
    _dateFrom = today;
    _dateTo = today;
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 300 && !_loading && _hasMore) _load();
    });
    _loadCollectors();
    _load();
  }

  // Collector filter is admin/manager-only — field officers are scoped to their
  // own collections by the backend, so the dropdown would be a no-op for them.
  // Mirrors the web `canFilterByCollector` gate and `/team?limit=500` fetch.
  Future<void> _loadCollectors() async {
    final auth = ref.read(authProvider);
    if (!(auth.hasRole('ORG_ADMIN') || auth.hasRole('MANAGER'))) return;
    try {
      final api = ref.read(apiClientProvider);
      final res = await api.raw(() => api.dio.get('/team', queryParameters: {'limit': 500}));
      final body = res.data;
      final rawList = body is Map
          ? (body['data'] is List
              ? body['data']
              : body['data'] is Map && body['data']['data'] is List
                  ? body['data']['data']
                  : const [])
          : (body is List ? body : const []);
      if (!mounted) return;
      setState(() => _collectors = (rawList as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .where((u) => u['isActive'] == true)
          .toList());
    } catch (_) {}
  }

  @override
  void dispose() { _scroll.dispose(); _searchCtrl.dispose(); super.dispose(); }

  Future<void> _load({bool reset = false}) async {
    if (_loading) return;
    setState(() { _loading = true; if (reset) { _items.clear(); _page = 1; _hasMore = true; } });
    try {
      final res = await ref.read(collectionRepoProvider).list(
        page: _page, search: _search, fromDate: _dateFrom, toDate: _dateTo, verificationStatus: _verification,
        loanType: _loanType, collectedById: _collectedById,
        // Show loan + chit collections together (chit installments share this module).
        sourceType: 'ALL',
      );
      final rawData = res['data'];
      final data = rawData is List
          ? rawData
          : (rawData is Map && rawData['collections'] is List ? rawData['collections'] as List : const []);
      final pg = Map<String, dynamic>.from(res['pagination'] ?? {});
      if (res['summary'] != null) _summary = Map<String, dynamic>.from(res['summary'] as Map);
      var mapped = data.map((e) => Map<String, dynamic>.from(e as Map));
      if (_verification != null) {
        mapped = mapped.where((c) => c['verificationStatus']?.toString() == _verification);
      }
      setState(() {
        _items.addAll(mapped);
        _page += 1;
        _hasMore = _page <= (pg['totalPages'] ?? 1);
      });
    } catch (e) { showToast('Failed: $e', error: true); }
    finally { if (mounted) setState(() => _loading = false); }
  }

  Future<void> _pickDate(bool isFrom) async {
    final init = DateTime.tryParse(isFrom ? _dateFrom : _dateTo) ?? DateTime.now();
    final d = await showDatePicker(context: context, firstDate: DateTime(2020), lastDate: DateTime.now(), initialDate: init);
    if (d != null) {
      setState(() {
        if (isFrom) _dateFrom = formatInputDate(d); else _dateTo = formatInputDate(d);
      });
      _load(reset: true);
    }
  }

  void _openFilters() {
    final auth = ref.read(authProvider);
    final canFilterByCollector = auth.hasRole('ORG_ADMIN') || auth.hasRole('MANAGER');
    final features = auth.org?.features ?? const {};
    final loanTypes = _loanTypeLabels.entries
        .where((e) => !_loanTypeFeatureMap.containsKey(e.key) || features[_loanTypeFeatureMap[e.key]] == true)
        .toList();
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        String? tempLoanType = _loanType;
        String? tempCollector = _collectedById;
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Padding(
              padding: EdgeInsets.only(
                left: 16,
                right: 16,
                top: 4,
                bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Filters', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String?>(
                    initialValue: tempLoanType,
                    decoration: const InputDecoration(labelText: 'Loan Type'),
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('All Loan Types')),
                      ...loanTypes.map((e) => DropdownMenuItem<String?>(value: e.key, child: Text(e.value))),
                    ],
                    onChanged: (v) => setSheetState(() => tempLoanType = v),
                  ),
                  if (canFilterByCollector) ...[
                    const SizedBox(height: 12),
                    DropdownButtonFormField<String?>(
                      initialValue: tempCollector,
                      decoration: const InputDecoration(labelText: 'Collector'),
                      items: [
                        const DropdownMenuItem<String?>(value: null, child: Text('All Collectors')),
                        ..._collectors.map((c) => DropdownMenuItem<String?>(
                              value: c['id']?.toString(),
                              child: Text(c['name']?.toString() ?? ''),
                            )),
                      ],
                      onChanged: (v) => setSheetState(() => tempCollector = v),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () => setSheetState(() {
                            tempLoanType = null;
                            tempCollector = null;
                          }),
                          child: const Text('Clear'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () {
                            Navigator.pop(ctx);
                            setState(() {
                              _loanType = tempLoanType;
                              _collectedById = tempCollector;
                            });
                            _load(reset: true);
                          },
                          child: const Text('Apply'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final canCreate = auth.hasPermission('collections.create');
    // Group collection is available only when group loans are enabled, mirroring
    // the web CollectionList gate (`features.enableGroupLoan`).
    final showGroupCollection = auth.org?.feature('enableGroupLoan') == true
        && auth.hasPermission('collections.create');
    final activeFilterCount = (_loanType != null ? 1 : 0) + (_collectedById != null ? 1 : 0);
    return Scaffold(
      drawer: const AppDrawer(),
      bottomNavigationBar: const AppBottomNav(),
      appBar: AppBar(
        title: const Text('Collections'),
        leading: Builder(builder: (ctx) => IconButton(icon: const Icon(Icons.menu), onPressed: () => Scaffold.of(ctx).openDrawer())),
        actions: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              IconButton(icon: const Icon(Icons.tune), tooltip: 'Filters', onPressed: _openFilters),
              if (activeFilterCount > 0)
                Positioned(
                  right: 6,
                  top: 6,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(color: AppColors.primary, shape: BoxShape.circle),
                    constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                    child: Text(
                      '$activeFilterCount',
                      style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
            ],
          ),
          if (showGroupCollection)
            IconButton(icon: const Icon(Icons.groups_outlined), tooltip: 'Group Collection', onPressed: () => context.push('/collections/group')),
          IconButton(icon: const Icon(Icons.map_outlined), tooltip: 'Route Map', onPressed: () => context.push('/collections/map')),
          IconButton(icon: const Icon(Icons.summarize_outlined), tooltip: 'Daily Summary', onPressed: () => context.push('/collections/summary')),
          IconButton(icon: const Icon(Icons.verified_outlined), tooltip: 'Verify', onPressed: () => context.push('/collections/verify')),
        ],
      ),
      floatingActionButton: canCreate
          ? FloatingActionButton.extended(onPressed: () => context.push('/collections/new'), icon: const Icon(Icons.add), label: const Text('New'))
          : null,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: TextField(
              controller: _searchCtrl,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search receipt, name, customer #, phone, loan / chit #...',
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searchCtrl.text.isNotEmpty
                    ? IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: 'Clear',
                        onPressed: () {
                          _searchCtrl.clear();
                          setState(() {});
                          if (_search != null) {
                            _search = null;
                            _load(reset: true);
                          }
                        },
                      )
                    : null,
              ),
              onChanged: (_) => setState(() {}),
              onSubmitted: (v) {
                _search = v.trim().isEmpty ? null : v.trim();
                _load(reset: true);
              },
            ),
          ),
          if (_summary != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Row(children: [
                _metricCard('Total', formatCurrency(_summary!['totalCollected']), AppColors.textPrimary),
                const SizedBox(width: 8),
                _metricCard('Pending', formatCurrency(_summary!['pending']), AppColors.warning),
                const SizedBox(width: 8),
                _metricCard('Verified', formatCurrency(_summary!['verified']), AppColors.accent),
              ]),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _pickDate(true),
                  icon: const Icon(Icons.calendar_today, size: 14),
                  label: Text(_dateFrom, style: const TextStyle(fontSize: 12)),
                ),
              ),
              const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: Text('to', style: TextStyle(fontSize: 12, color: AppColors.textSecondary))),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _pickDate(false),
                  icon: const Icon(Icons.calendar_today, size: 14),
                  label: Text(_dateTo, style: const TextStyle(fontSize: 12)),
                ),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _chip('All', null),
                  _chip('Pending', 'PENDING'),
                  _chip('Verified', 'VERIFIED'),
                  _chip('Rejected', 'REJECTED'),
                ],
              ),
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => _load(reset: true),
              child: _items.isEmpty && !_loading
                  ? const EmptyView(message: 'No collections', icon: Icons.payments_outlined)
                  : ListView.builder(
                      controller: _scroll,
                      itemCount: _items.length + (_loading ? 1 : 0),
                      itemBuilder: (ctx, i) {
                        if (i >= _items.length) return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
                        final c = _items[i];
                        final cust = Map<String, dynamic>.from(c['customer'] ?? {});
                        final loan = Map<String, dynamic>.from(c['loan'] ?? {});
                        final isChit = c['sourceType'] == 'CHITFUND';
                        final chit = Map<String, dynamic>.from(c['chitfund'] ?? {});
                        final ref = isChit
                            ? '${chit['chitNumber'] ?? chit['name'] ?? 'Chit'}${c['monthNumber'] != null ? ' · M${c['monthNumber']}' : ''}'
                            : (loan['loanNumber']?.toString() ?? '');
                        return Card(
                          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                          child: ListTile(
                            onTap: () => context.push('/collections/${c['id']}/receipt'),
                            leading: Icon(isChit ? Icons.savings_outlined : Icons.receipt_long_outlined, color: AppColors.accent),
                            title: Text('${cust['firstName'] ?? ''} ${cust['lastName'] ?? ''}'.trim()),
                            subtitle: Text('$ref • ${formatDateTime(c['collectedAt'])}'),
                            trailing: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(formatCurrency(c['amount']), style: const TextStyle(fontWeight: FontWeight.w600)),
                                if ((double.tryParse(c['alrAmount']?.toString() ?? '') ?? 0) > 0)
                                  Text('+ ALR ${formatCurrency(c['alrAmount'])}', style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                                StatusChip(label: c['verificationStatus']?.toString() ?? '', color: statusColor(c['verificationStatus']?.toString())),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
        ],
      ),
    );
  }

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

  Widget _chip(String label, String? value) {
    final sel = _verification == value;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: ChoiceChip(
        label: Text(label, style: TextStyle(color: sel ? AppColors.primary : AppColors.textPrimary, fontWeight: sel ? FontWeight.w600 : FontWeight.w500)),
        selected: sel,
        onSelected: (_) { _verification = value; _load(reset: true); },
        backgroundColor: Colors.white,
        selectedColor: AppColors.primary.withValues(alpha: 0.15),
        side: BorderSide(color: sel ? AppColors.primary : AppColors.border),
      ),
    );
  }
}
