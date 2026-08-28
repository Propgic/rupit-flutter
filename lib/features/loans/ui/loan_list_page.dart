import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../../core/api/api_client.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/common.dart';
import '../data/loan_repo.dart';
import '../../app_shell.dart';
import '../../../core/widgets/app_bottom_nav.dart';

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

const _statusDropdownOptions = [
  'DRAFT',
  'PENDING',
  'APPROVED',
  'DISBURSED',
  'ACTIVE',
  'CLOSED',
  'REJECTED',
  'WRITTEN_OFF',
];

class LoanListPage extends ConsumerStatefulWidget {
  final String? fromDate;
  final String? toDate;
  const LoanListPage({super.key, this.fromDate, this.toDate});
  @override
  ConsumerState<LoanListPage> createState() => _LoanListPageState();
}

class _LoanListPageState extends ConsumerState<LoanListPage> {
  final _scroll = ScrollController();
  final _searchCtrl = TextEditingController();
  final List<Map<String, dynamic>> _items = [];
  int _page = 1;
  bool _loading = false;
  bool _hasMore = true;
  String? _search;
  String? _typeTab;
  late String _statusTab;
  String? _statusFilter;
  String? _assigneeFilter;
  String? _fromDate;
  String? _toDate;
  List<Map<String, dynamic>> _assignees = [];
  Object? _error;
  // Portfolio metrics spanning every loan matching the current filters (not just
  // the current page) — from the backend `totals` object. Null until first load.
  Map<String, dynamic>? _totals;
  int _totalCount = 0;

  @override
  void initState() {
    super.initState();
    _fromDate = widget.fromDate;
    _toDate = widget.toDate;
    _statusTab = (_fromDate != null) ? 'ALL' : 'ACTIVE';
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 300 && !_loading && _hasMore) {
        _load();
      }
    });
    Future.microtask(() async {
      await ref.read(authProvider.notifier).refreshMe();
      if (!mounted) return;
      _initDefaults();
      _loadAssignees();
      _load();
    });
  }

  void _initDefaults() {
    final features = ref.read(authProvider).org?.features ?? const {};
    final enabled = _loanTypeLabels.keys
        .where((k) => !_loanTypeFeatureMap.containsKey(k) || features[_loanTypeFeatureMap[k]] == true)
        .toList();
    if (_typeTab == null && enabled.isNotEmpty) _typeTab = enabled.first;
  }

  Future<void> _loadAssignees() async {
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
      setState(() => _assignees = (rawList as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .where((u) => u['isActive'] == true)
          .toList());
    } catch (_) {}
  }

  @override
  void dispose() {
    _scroll.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  String? _resolvedStatus() {
    if (_statusTab == 'ACTIVE') return 'ACTIVE';
    if (_statusTab == 'CLOSED') return 'CLOSED';
    if (_statusTab == 'ARCHIVED') return null;
    return _statusFilter;
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading) return;
    if (_typeTab == null) return;
    setState(() {
      _loading = true;
      if (reset) {
        _items.clear();
        _page = 1;
        _hasMore = true;
        _error = null;
      }
    });
    try {
      final res = await ref.read(loanRepoProvider).list(
            page: _page,
            search: _search,
            status: _resolvedStatus(),
            type: _typeTab,
            assignedToId: _assigneeFilter,
            fromDate: _fromDate,
            toDate: _toDate,
            archived: _statusTab == 'ARCHIVED',
          );
      final data = (res['data'] as List?) ?? const [];
      final pg = Map<String, dynamic>.from(res['pagination'] ?? {});
      final totals = res['totals'] is Map ? Map<String, dynamic>.from(res['totals'] as Map) : null;
      setState(() {
        _items.addAll(data.map((e) => Map<String, dynamic>.from(e as Map)));
        _page += 1;
        _hasMore = _page <= (pg['totalPages'] ?? 1);
        // Totals span all matching loans, so refresh them on every load (they're
        // identical across pages of the same filter set).
        _totals = totals;
        _totalCount = (pg['total'] as num?)?.toInt() ?? 0;
      });
    } catch (e) {
      setState(() {
        _error = e;
        if (_items.isEmpty) {
          _totals = null;
          _totalCount = 0;
        }
      });
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _openAdvancedFilters() {
    final auth = ref.read(authProvider);
    final canFilterAssignee = auth.hasRole('ORG_ADMIN') || auth.hasRole('MANAGER');
    final isFieldOfficer = auth.hasRole('FIELD_OFFICER');
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (ctx) {
        String? tempStatus = _statusFilter;
        String? tempAssignee = _assigneeFilter;
        DateTime? tempFrom = _fromDate != null ? DateTime.tryParse(_fromDate!) : null;
        DateTime? tempTo = _toDate != null ? DateTime.tryParse(_toDate!) : null;
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            Future<void> pickDate(bool isFrom) async {
              final picked = await showDatePicker(
                context: ctx,
                initialDate: (isFrom ? tempFrom : tempTo) ?? DateTime.now(),
                firstDate: DateTime(2000),
                lastDate: DateTime(DateTime.now().year + 5),
              );
              if (picked != null) {
                setSheetState(() {
                  if (isFrom) {
                    tempFrom = picked;
                  } else {
                    tempTo = picked;
                  }
                });
              }
            }

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
                  if (_statusTab == 'ALL') ...[
                    DropdownButtonFormField<String?>(
                      initialValue: tempStatus,
                      decoration: const InputDecoration(labelText: 'Status'),
                      items: [
                        const DropdownMenuItem<String?>(value: null, child: Text('All Statuses')),
                        // Field officers never see closed loans, so don't offer CLOSED.
                        ..._statusDropdownOptions
                            .where((s) => !(isFieldOfficer && s == 'CLOSED'))
                            .map((s) => DropdownMenuItem<String?>(value: s, child: Text(s))),
                      ],
                      onChanged: (v) => setSheetState(() => tempStatus = v),
                    ),
                    const SizedBox(height: 12),
                  ],
                  if (canFilterAssignee) ...[
                    DropdownButtonFormField<String?>(
                      initialValue: tempAssignee,
                      decoration: const InputDecoration(labelText: 'Assignee'),
                      items: [
                        const DropdownMenuItem<String?>(value: null, child: Text('All Assignees')),
                        ..._assignees.map((a) => DropdownMenuItem<String?>(
                              value: a['id']?.toString(),
                              child: Text(a['name']?.toString() ?? ''),
                            )),
                      ],
                      onChanged: (v) => setSheetState(() => tempAssignee = v),
                    ),
                    const SizedBox(height: 12),
                  ],
                  // Date range — available to every role (mirrors the web From/To inputs).
                  // On the Closed tab the backend filters this range by closed date;
                  // everywhere else by disbursement date, so label it to match.
                  Row(
                    children: [
                      Expanded(
                        child: _SheetDateField(
                          label: _statusTab == 'CLOSED' ? 'Closed From' : 'From',
                          value: tempFrom,
                          onTap: () => pickDate(true),
                          onClear: tempFrom == null ? null : () => setSheetState(() => tempFrom = null),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: _SheetDateField(
                          label: _statusTab == 'CLOSED' ? 'Closed To' : 'To',
                          value: tempTo,
                          onTap: () => pickDate(false),
                          onClear: tempTo == null ? null : () => setSheetState(() => tempTo = null),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: () {
                            setSheetState(() {
                              tempStatus = null;
                              tempAssignee = null;
                              tempFrom = null;
                              tempTo = null;
                            });
                          },
                          child: const Text('Clear'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ElevatedButton(
                          onPressed: () {
                            Navigator.pop(ctx);
                            setState(() {
                              _statusFilter = tempStatus;
                              _assigneeFilter = tempAssignee;
                              _fromDate = tempFrom != null ? formatInputDate(tempFrom!) : null;
                              _toDate = tempTo != null ? formatInputDate(tempTo!) : null;
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

  /// Portfolio metrics row reflecting the current type/status/assignee/date
  /// filters, spanning every matching loan (from the backend `totals`, not just
  /// this page). Shows 0 / ₹0 when totals is null. Mirrors the web StatsCard row.
  Widget _buildMetrics() {
    final t = _totals;
    final cards = <Widget>[
      _LoanMetricCard(
        label: 'Total Loans',
        value: '$_totalCount',
        color: AppColors.textSecondary,
        icon: Icons.layers_outlined,
      ),
      _LoanMetricCard(
        label: 'Disbursed',
        value: formatCurrencyCompact(t?['principalAmount'] ?? 0),
        color: AppColors.info,
        icon: Icons.payments_outlined,
      ),
      _LoanMetricCard(
        label: 'Collected',
        value: formatCurrencyCompact(t?['totalPaid'] ?? 0),
        color: AppColors.accent,
        icon: Icons.savings_outlined,
      ),
      _LoanMetricCard(
        label: 'Outstanding',
        value: formatCurrencyCompact(t?['balance'] ?? 0),
        color: AppColors.primary,
        icon: Icons.account_balance_outlined,
      ),
      _LoanMetricCard(
        label: 'Due Today',
        value: formatCurrencyCompact(t?['dueTodayAmount'] ?? 0),
        color: AppColors.warning,
        icon: Icons.event_outlined,
      ),
      _LoanMetricCard(
        label: 'Overdue',
        value: formatCurrencyCompact(t?['overdueAmount'] ?? 0),
        color: AppColors.danger,
        icon: Icons.warning_amber_outlined,
      ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 3 columns on wider phones/tablets, 2 on narrow screens.
          final columns = constraints.maxWidth >= 480 ? 3 : 2;
          const spacing = 8.0;
          final cardWidth = (constraints.maxWidth - spacing * (columns - 1)) / columns;
          return Wrap(
            spacing: spacing,
            runSpacing: spacing,
            children: [
              for (final c in cards) SizedBox(width: cardWidth, child: c),
            ],
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final canCreate = auth.hasPermission('loans.create');
    final isFieldOfficer = auth.hasRole('FIELD_OFFICER');
    final features = auth.org?.features ?? const {};
    final typeTabs = _loanTypeLabels.entries
        .where((e) => !_loanTypeFeatureMap.containsKey(e.key) || features[_loanTypeFeatureMap[e.key]] == true)
        .toList();
    // Field officers don't see closed loans (backend hides CLOSED/SETTLED), so the
    // Closed pill would always be empty for them.
    final statusPills = <List<String>>[
      ['ACTIVE', 'Active'],
      if (!isFieldOfficer) ['CLOSED', 'Closed'],
      ['ARCHIVED', 'Archived'],
      ['ALL', 'All'],
    ];
    final activeFilterCount = (_statusTab == 'ALL' && _statusFilter != null ? 1 : 0) +
        (_assigneeFilter != null ? 1 : 0) +
        (_fromDate != null ? 1 : 0) +
        (_toDate != null ? 1 : 0);
    // Date range is filterable for everyone, so the filter affordance is always shown.
    const showFilterIcon = true;

    return Scaffold(
      drawer: const AppDrawer(),
      bottomNavigationBar: const AppBottomNav(),
      appBar: AppBar(
        title: const Text('Loans'),
        leading: Builder(
          builder: (ctx) => IconButton(icon: const Icon(Icons.menu), onPressed: () => Scaffold.of(ctx).openDrawer()),
        ),
        actions: [
          IconButton(icon: const Icon(Icons.warning_amber), tooltip: 'Overdue', onPressed: () => context.push('/loans/overdue')),
        ],
      ),
      floatingActionButton: canCreate
          ? FloatingActionButton.extended(onPressed: () => context.push('/loans/new'), icon: const Icon(Icons.add), label: const Text('New'))
          : null,
      // Everything above the list scrolls away with it (search, type chips,
      // metrics) so the loans get the full screen once you start scrolling;
      // only the status pills stay pinned for quick tab switching.
      body: RefreshIndicator(
        onRefresh: () => _load(reset: true),
        child: CustomScrollView(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _searchCtrl,
                        decoration: const InputDecoration(hintText: 'Search loan number, customer...', prefixIcon: Icon(Icons.search)),
                        onSubmitted: (v) {
                          _search = v.trim().isEmpty ? null : v.trim();
                          _load(reset: true);
                        },
                      ),
                    ),
                    if (showFilterIcon) ...[
                      const SizedBox(width: 8),
                      Stack(
                        clipBehavior: Clip.none,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.tune),
                            tooltip: 'Filters',
                            onPressed: _openAdvancedFilters,
                          ),
                          if (activeFilterCount > 0)
                            Positioned(
                              right: 4,
                              top: 4,
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
                    ],
                  ],
                ),
              ),
            ),
            if (typeTabs.isNotEmpty)
              SliverToBoxAdapter(
                child: SizedBox(
                  height: 40,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: typeTabs.length,
                    separatorBuilder: (_, _) => const SizedBox(width: 6),
                    itemBuilder: (_, i) {
                      final e = typeTabs[i];
                      final selected = _typeTab == e.key;
                      return ChoiceChip(
                        label: Text(
                          e.value,
                          style: TextStyle(
                            color: selected ? AppColors.primary : AppColors.textPrimary,
                            fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                          ),
                        ),
                        selected: selected,
                        showCheckmark: false,
                        backgroundColor: Colors.white,
                        selectedColor: AppColors.primary.withValues(alpha: 0.12),
                        side: BorderSide(color: selected ? AppColors.primary : AppColors.border),
                        onSelected: (_) {
                          if (selected) return;
                          setState(() => _typeTab = e.key);
                          _load(reset: true);
                        },
                      );
                    },
                  ),
                ),
              ),
            SliverToBoxAdapter(child: _buildMetrics()),
            // Pinned so Active/Closed/Archived/All stays reachable after the
            // summary has scrolled away. Extent tracks the user's text scale.
            SliverPersistentHeader(
              pinned: true,
              delegate: PinnedHeaderDelegate(
                height: 34 + MediaQuery.textScalerOf(context).scale(18),
                child: Container(
                  color: AppColors.bg,
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: Row(
                    children: [
                      for (final pill in statusPills) ...[
                        Expanded(
                          child: StatusPill(
                            label: pill[1],
                            selected: _statusTab == pill[0],
                            onTap: () {
                              if (_statusTab == pill[0]) return;
                              setState(() {
                                _statusTab = pill[0];
                                _statusFilter = null;
                              });
                              _load(reset: true);
                            },
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            if (_error != null && _items.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: ErrorView(message: _error.toString(), onRetry: () => _load(reset: true)),
              )
            else if (_items.isEmpty && !_loading)
              const SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyView(message: 'No loans', icon: Icons.request_quote_outlined),
              )
            else
              SliverPadding(
                // Clears the extended FAB over the last card.
                padding: const EdgeInsets.only(bottom: 80),
                sliver: SliverList.builder(
                  itemCount: _items.length + (_loading ? 1 : 0),
                  itemBuilder: _loanTile,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// One loan card; the index past the end renders the pagination spinner
  /// while the next page loads.
  Widget _loanTile(BuildContext ctx, int i) {
    if (i >= _items.length) {
      return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
    }
    final l = _items[i];
    final c = Map<String, dynamic>.from(l['customer'] ?? {});
    final customerName = '${c['firstName'] ?? ''} ${c['lastName'] ?? ''}'.trim();
    final phone = (c['phone'] ?? c['alternatePhone'] ?? '').toString().trim();
    final dayWeek = dayWeekLabel(
        l['disbursedDate'], l['loanType']?.toString(), l['installmentsElapsed']);
    // Start → end reads on the age line, which frees the trailing column to
    // hold just the photo and the status chip.
    final startDate = l['startDate'] ?? l['disbursedDate'];
    final timeline = <String>[
      if (dayWeek != '-') dayWeek,
      if (startDate != null) formatDate(startDate),
      if (l['endDate'] != null) 'Ends ${formatDate(l['endDate'])}',
    ].join(' · ');
    // Card tint mirrors the web list's row colours (LoanList.jsx rowClassName):
    // a live loan that is fully paid reads green, one that has run past its end
    // date (a 100-day daily loan still open on day 101, say) reads red.
    final endDate = DateTime.tryParse(l['endDate']?.toString() ?? '');
    final tint = l['status'] != 'ACTIVE'
        ? null
        : l['balance'] != null && toNum(l['balance']) == 0
            ? AppColors.accent.withValues(alpha: 0.12)
            : endDate != null && endDate.isBefore(DateTime.now())
                ? AppColors.danger.withValues(alpha: 0.10)
                : null;
    return Card(
      color: tint,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        onTap: () => context.push('/loans/${l['id']}'),
        title: Text(l['loanNumber']?.toString() ?? ''),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(customerName, style: const TextStyle(fontWeight: FontWeight.w500)),
            // Tapping the number dials it; the InkWell swallows the tap so it
            // doesn't fall through to the tile and open the loan instead.
            if (phone.isNotEmpty)
              InkWell(
                onTap: () => launchUrl(Uri.parse('tel:$phone')),
                borderRadius: BorderRadius.circular(4),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.phone, size: 13, color: AppColors.primary),
                      const SizedBox(width: 4),
                      Text(phone,
                          style: const TextStyle(fontSize: 12, color: AppColors.primary, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
            Text('${l['loanType'] ?? ''} • ${formatCurrency(l['principalAmount'])}',
                style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
            Text('Balance: ${formatCurrency(l['balance'])}',
                style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
            Text('Total Paid: ${formatCurrency(l['totalPaid'])}',
                style: const TextStyle(fontSize: 12, color: AppColors.accent, fontWeight: FontWeight.w600)),
            // Mirrors the web list's Total Paid column: pending collections
            // are either already counted in totalPaid or additional to it.
            if (toNum(l['pendingCollections']) > 0)
              Text(
                  l['pendingCounted'] == true
                      ? 'incl. ${formatCurrency(l['pendingCollections'])} pending'
                      : '+ ${formatCurrency(l['pendingCollections'])} pending',
                  style: const TextStyle(fontSize: 11, color: AppColors.warning, fontWeight: FontWeight.w500)),
            if (timeline.isNotEmpty)
              Text(timeline,
                  style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
            if (l['status'] == 'ACTIVE' && toNum(l['overdueAmount']) > 0) ...[
              Text('Overdue: ${formatCurrency(l['overdueAmount'])} (${l['overdueCount']} installment${(l['overdueCount'] ?? 0) > 1 ? 's' : ''})',
                  style: const TextStyle(fontSize: 11, color: AppColors.danger, fontWeight: FontWeight.w600)),
              if (l['pendingCounted'] != true && toNum(l['pendingCollections']) > 0)
                Text('✓ ${formatCurrency(l['pendingCollections'])} collected',
                    style: const TextStyle(fontSize: 10, color: AppColors.accent)),
            ] else if (l['status'] == 'ACTIVE' && toNum(l['dueTodayAmount']) > 0)
              // No overdue flagged, but money is still owed up to today
              // (e.g. a partially paid current/last EMI) — mirrors the
              // web list's "Due Today" column so it isn't hidden.
              Text('Due Today: ${formatCurrency(l['dueTodayAmount'])}',
                  style: const TextStyle(fontSize: 11, color: AppColors.warning, fontWeight: FontWeight.w600))
            else if (l['status'] == 'ACTIVE' && toNum(l['excessAmount']) > 0)
              Text('+${formatCurrency(l['excessAmount'])} advance',
                  style: const TextStyle(fontSize: 11, color: AppColors.accent, fontWeight: FontWeight.w600)),
          ],
        ),
        // Column sizes to the status chip, so centring lines the photo up over
        // it instead of hanging off one edge.
        trailing: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Tapping the photo zooms it; without a photo the tap falls
            // through to the tile (same pattern as the customer list).
            GestureDetector(
              onTap: c['photo'] != null ? () => showImageViewer(ctx, c['photo']?.toString()) : null,
              // 56 is the widest the photo can go without pushing the column
              // past the status chip and stealing width from the text.
              child: Avatar(url: c['photo']?.toString(), name: customerName, size: 56),
            ),
            const SizedBox(height: 6),
            StatusChip(label: l['status']?.toString() ?? '', color: statusColor(l['status']?.toString())),
          ],
        ),
      ),
    );
  }
}

/// Fixed-extent pinned header with an opaque background so the loan cards
/// don't show through as they scroll underneath.
/// Tappable date field for the filter sheet; shows the picked date (or "Any") and
/// a clear button once a date is set.
class _SheetDateField extends StatelessWidget {
  final String label;
  final DateTime? value;
  final VoidCallback onTap;
  final VoidCallback? onClear;
  const _SheetDateField({required this.label, required this.value, required this.onTap, this.onClear});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          suffixIcon: value != null && onClear != null
              ? IconButton(icon: const Icon(Icons.clear, size: 18), onPressed: onClear)
              : const Icon(Icons.calendar_today, size: 18),
        ),
        child: Text(
          value != null ? formatDate(value) : 'Any',
          style: TextStyle(
            fontSize: 14,
            color: value != null ? AppColors.textPrimary : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}

/// Compact portfolio metric card: a small label, an icon tinted with the metric's
/// accent color, and a big value. The value is wrapped in a FittedBox with an
/// ellipsis fallback so long amounts never overflow on narrow phones.
class _LoanMetricCard extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final IconData icon;
  const _LoanMetricCard({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Text(
              value,
              maxLines: 1,
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: color),
            ),
          ),
        ],
      ),
    );
  }
}
