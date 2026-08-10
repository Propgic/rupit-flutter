import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/api/api_client.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/utils/location.dart';
import '../../../core/widgets/common.dart';
import '../data/collection_repo.dart';
import '../../loans/data/loan_repo.dart';
import '../../chitfunds/data/chitfund_repo.dart';
import '../../chitfunds/ui/chitfund_detail_page.dart' show openChitCollectionSheet;

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
  'PROPERTY': 'Mortgage',
  'BUSINESS': 'Business',
  'AGRICULTURE': 'Agriculture',
  'EDUCATION': 'Education',
  'DAILY': 'Daily',
  'WEEKLY': 'Weekly',
};

class CollectionFormPage extends ConsumerStatefulWidget {
  /// Loan to open with already selected — set when the form is reached from a
  /// loan's "Collect Payment" CTA (`/collections/new?loanId=…`), mirroring the web.
  /// The collector can still switch loans via "Change" on the selected-loan card.
  final String? loanId;
  const CollectionFormPage({super.key, this.loanId});
  @override
  ConsumerState<CollectionFormPage> createState() => _CollectionFormPageState();
}

class _CollectionFormPageState extends ConsumerState<CollectionFormPage> {
  // 'LOAN' collects loan EMIs (default); 'CHITFUND' collects chit installments. The
  // Loan/Chit toggle is only shown when both features are enabled (mirrors the web form);
  // single-feature orgs land directly in the one they use.
  String _source = 'LOAN';
  final _chitSearchCtrl = TextEditingController();
  List<Map<String, dynamic>> _chits = [];
  bool _loadingChits = false;
  String? _loanTypeFilter;
  String? _assigneeFilter;
  List<Map<String, dynamic>> _assignees = [];
  List<Map<String, dynamic>> _loans = [];
  Map<String, dynamic>? _selectedLoan;
  List<Map<String, dynamic>> _emis = [];
  List<Map<String, dynamic>> _pendingEmis = [];
  // The selected loan's previous payments — the customer's "passbook", shown read-only
  // beside the form so the collector sees what's already been paid while recording.
  List<Map<String, dynamic>> _loanPayments = [];
  bool _loadingPayments = false;
  final _searchCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  final _alrCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  // UTR / txn id / cheque number — the backend rejects any non-CASH mode without one.
  final _referenceCtrl = TextEditingController();
  String _mode = 'CASH';
  static const _modeLabels = {
    'CASH': 'Cash',
    'UPI': 'UPI',
    'BANK_TRANSFER': 'Bank Transfer',
    'CHEQUE': 'Cheque',
    'ONLINE': 'Online',
  };
  String get _modeLabel => _modeLabels[_mode] ?? _mode;
  // What to ask for varies by mode; a cheque has no UTR and UPI has no cheque number.
  String get _referenceHint => switch (_mode) {
        'UPI' => 'UPI txn / UTR number',
        'BANK_TRANSFER' => 'UTR / transaction number',
        'CHEQUE' => 'Cheque number',
        _ => 'Transaction reference',
      };
  bool _saving = false;
  bool _loadingLoans = false;
  Timer? _debounce;
  // The loan list is paged and grows as it's scrolled (infinite scroll), mirroring the web.
  static const int _loanPageSize = 20;
  int _loanPage = 1;
  bool _loanHasMore = false;
  bool _loanLoadingMore = false;
  final _loanScrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    final features = ref.read(authProvider).org?.features ?? const {};
    // Chit-only orgs open straight into chit collection; loan-enabled orgs default to loans.
    // Arriving with a loan in hand always means a loan collection.
    _source = (widget.loanId == null && features['enableChitfund'] == true && features['enableLoans'] != true)
        ? 'CHITFUND'
        : 'LOAN';
    _loadAssignees();
    if (_source == 'CHITFUND') { _loadChits(); } else { _loadLoans(); }
    if (widget.loanId != null) _preselectLoan(widget.loanId!);
    // Load the next page when the list is scrolled near the bottom.
    _loanScrollCtrl.addListener(_onLoanScroll);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _loanScrollCtrl.dispose();
    _searchCtrl.dispose();
    _chitSearchCtrl.dispose();
    _amountCtrl.dispose();
    _alrCtrl.dispose();
    _notesCtrl.dispose();
    _referenceCtrl.dispose();
    super.dispose();
  }

  // The field officer's active chits (scoped server-side to those assigned to them). Loaded
  // once when chit mode is entered; searched client-side since an org has few active chits.
  Future<void> _loadChits() async {
    setState(() => _loadingChits = true);
    try {
      final res = await ref.read(chitfundRepoProvider).list(status: 'ACTIVE', limit: 200);
      final chits = extractList(res['data'] ?? res).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      chits.sort((a, b) => (a['chitNumber']?.toString() ?? '').compareTo(b['chitNumber']?.toString() ?? ''));
      if (mounted) setState(() => _chits = chits);
    } catch (_) {
      if (mounted) setState(() => _chits = const []);
    } finally {
      if (mounted) setState(() => _loadingChits = false);
    }
  }

  // Fetch the chit's full detail (dividend type, member count, current month) and open the
  // shared chit-collection sheet, which handles month/member/dues selection and recording.
  Future<void> _selectChit(Map<String, dynamic> chit) async {
    Map<String, dynamic> detail;
    try {
      detail = await ref.read(chitfundRepoProvider).get(chit['id'].toString());
    } on ApiException catch (e) {
      showToast(e.message, error: true);
      return;
    } catch (_) {
      showToast('Could not load chit', error: true);
      return;
    }
    if (!mounted) return;
    await openChitCollectionSheet(context, ref, chitfund: detail);
  }

  void _onLoanScroll() {
    if (_loanLoadingMore || !_loanHasMore || !_loanScrollCtrl.hasClients) return;
    final pos = _loanScrollCtrl.position;
    if (pos.maxScrollExtent - pos.pixels < 48) _loadLoans(page: _loanPage + 1, append: true);
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
      setState(() => _assignees = (rawList as List)
          .map((e) => Map<String, dynamic>.from(e as Map))
          .where((u) => u['isActive'] == true && u['role'] != 'ORG_ADMIN' && u['role'] != 'MANAGER')
          .toList());
    } catch (e) {
      debugPrint('team load failed: $e');
    }
  }

  void _onSearchChanged(String v) {
    _debounce?.cancel();
    // Search/filter changes reset to the first page (debounced).
    _debounce = Timer(const Duration(milliseconds: 300), _loadLoans);
  }

  // The dropdown is sorted alphabetically by customer name; re-applied to the full
  // accumulated list each time another page is appended so order stays stable.
  void _sortLoansByName(List<Map<String, dynamic>> list) {
    list.sort((a, b) {
      final ac = Map<String, dynamic>.from(a['customer'] ?? {});
      final bc = Map<String, dynamic>.from(b['customer'] ?? {});
      final an = '${ac['firstName'] ?? ''} ${ac['lastName'] ?? ''}'.trim().toLowerCase();
      final bn = '${bc['firstName'] ?? ''} ${bc['lastName'] ?? ''}'.trim().toLowerCase();
      return an.compareTo(bn);
    });
  }

  // Fetch one page of matching loans. `append` adds the next page to the existing list
  // (infinite scroll); otherwise it replaces the list (new search/filter).
  Future<void> _loadLoans({int page = 1, bool append = false}) async {
    setState(() {
      if (append) { _loanLoadingMore = true; } else { _loadingLoans = true; }
    });
    try {
      final api = ref.read(apiClientProvider);
      final params = <String, dynamic>{'status': 'ACTIVE', 'limit': _loanPageSize, 'page': page};
      if (_searchCtrl.text.trim().length >= 2) params['search'] = _searchCtrl.text.trim();
      if (_loanTypeFilter != null) params['loanType'] = _loanTypeFilter;
      if (_assigneeFilter != null) params['assignedToId'] = _assigneeFilter;
      final res = await api.raw(() => api.dio.get('/loans', queryParameters: params));
      final body = res.data;
      final list = (body is Map && body['data'] is List ? body['data'] : body is List ? body : const []) as List;
      final fetched = list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      final merged = append
          ? <Map<String, dynamic>>[..._loans, ...fetched.where((l) => !_loans.any((p) => p['id'] == l['id']))]
          : fetched;
      _sortLoansByName(merged);
      final pg = body is Map && body['pagination'] is Map ? Map<String, dynamic>.from(body['pagination'] as Map) : const {};
      if (mounted) {
        setState(() {
          _loans = merged;
          _loanPage = page;
          _loanHasMore = pg.isNotEmpty ? page < toNum(pg['totalPages'], 1).toInt() : list.length >= _loanPageSize;
        });
      }
    } catch (_) {} finally {
      if (mounted) setState(() { if (append) { _loanLoadingMore = false; } else { _loadingLoans = false; } });
    }
  }

  Future<void> _loadEmis(String loanId) async {
    try {
      final list = await ref.read(loanRepoProvider).emiSchedule(loanId);
      final mapped = list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
      final pending = mapped.where((e) {
        final s = e['status']?.toString();
        return s == 'PENDING' || s == 'OVERDUE' || s == 'PARTIALLY_PAID';
      }).toList();
      setState(() {
        _emis = mapped;
        _pendingEmis = pending;
      });
    } catch (_) {
      setState(() { _emis = []; _pendingEmis = []; });
    }
  }

  Future<void> _loadLoanPayments(String loanId) async {
    setState(() => _loadingPayments = true);
    try {
      final d = await ref.read(apiClientProvider).get('/collections', query: {'loanId': loanId, 'limit': 100});
      final list = extractList(d).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      if (mounted) setState(() => _loanPayments = list);
    } catch (_) {
      if (mounted) setState(() => _loanPayments = []);
    } finally {
      if (mounted) setState(() => _loadingPayments = false);
    }
  }

  // Open with the loan the collector tapped "Collect Payment" on. Fetched by id rather
  // than picked from _loans because the list is paged/filtered and may not hold it.
  Future<void> _preselectLoan(String loanId) async {
    try {
      final loan = await ref.read(loanRepoProvider).get(loanId);
      if (!mounted) return;
      _selectLoan(loan);
    } on ApiException catch (e) {
      if (mounted) showToast(e.message, error: true);
    } catch (_) {
      if (mounted) showToast('Could not load that loan — pick it from the list', error: true);
    }
  }

  void _selectLoan(Map<String, dynamic> loan) {
    setState(() {
      _selectedLoan = loan;
      _searchCtrl.text = '';
      _loanPayments = [];
      // Prefill ALR from the loan's ALR; stays editable and is tracked separately.
      final alr = double.tryParse(loan['alr']?.toString() ?? '');
      _alrCtrl.text = alr != null && alr > 0 ? loan['alr'].toString() : '';
    });
    _loadEmis(loan['id'].toString());
    _loadLoanPayments(loan['id'].toString());
  }

  Future<void> _submit() async {
    if (_selectedLoan == null) return showToast('Select a loan', error: true);
    final amount = double.tryParse(_amountCtrl.text);
    if (amount == null || amount <= 0) return showToast('Enter valid amount', error: true);
    final alr = double.tryParse(_alrCtrl.text.trim());
    if (_alrCtrl.text.trim().isNotEmpty && (alr == null || alr < 0)) {
      return showToast('Enter valid ALR', error: true);
    }
    // Drop any reference typed before the mode was switched back to cash.
    final reference = _mode == 'CASH' ? '' : _referenceCtrl.text.trim();
    // Caught here rather than server-side so the collector sees which field to fill.
    if (_mode != 'CASH' && reference.isEmpty) {
      return showToast('Enter the payment reference for a $_modeLabel payment', error: true);
    }
    setState(() => _saving = true);
    try {
      // Best-effort GPS — never blocks recording if unavailable.
      final location = await tryGetCurrentLocation();
      final res = await ref.read(collectionRepoProvider).create({
        'loanId': _selectedLoan!['id'],
        'amount': amount,
        if (alr != null && alr > 0) 'alrAmount': alr,
        'paymentMode': _mode,
        if (reference.isNotEmpty) 'paymentReference': reference,
        if (_notesCtrl.text.trim().isNotEmpty) 'notes': _notesCtrl.text.trim(),
        if (location != null) ...location.toJson(),
      });
      showToast('Collection recorded');
      if (mounted) context.pushReplacement('/collections/${res['id']}/receipt');
    } on ApiException catch (e) {
      showToast(e.message, error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    final canFilterAssignee = auth.hasRole('ORG_ADMIN') || auth.hasRole('MANAGER');
    final features = auth.org?.features ?? const {};
    final loanTypeItems = _loanTypeLabels.entries
        .where((e) => !_loanTypeFeatureMap.containsKey(e.key) || features[_loanTypeFeatureMap[e.key]] == true)
        .toList();
    // Show the Loan/Chit toggle only when the org uses both; single-feature orgs stay on the
    // one source they have (chosen in initState).
    final showToggle = features['enableLoans'] == true && features['enableChitfund'] == true;

    return Scaffold(
      appBar: AppBar(title: const Text('Record Collection')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          if (showToggle) _sourceToggle(),
          if (_source == 'CHITFUND') ..._chitBody(),
          if (_source == 'LOAN') ...[
          SectionCard(
            title: 'Filter',
            child: Column(
              children: [
                DropdownButtonFormField<String?>(
                  initialValue: _loanTypeFilter,
                  decoration: const InputDecoration(labelText: 'Loan Type'),
                  items: [
                    const DropdownMenuItem<String?>(value: null, child: Text('All Loan Types')),
                    ...loanTypeItems.map((e) => DropdownMenuItem<String?>(value: e.key, child: Text(e.value))),
                  ],
                  onChanged: (v) {
                    setState(() { _loanTypeFilter = v; _selectedLoan = null; });
                    _loadLoans();
                  },
                ),
                if (canFilterAssignee) ...[
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String?>(
                    initialValue: _assigneeFilter,
                    decoration: const InputDecoration(labelText: 'Assignee'),
                    items: [
                      const DropdownMenuItem<String?>(value: null, child: Text('All Assignees')),
                      ..._assignees.map((a) => DropdownMenuItem<String?>(value: a['id']?.toString(), child: Text(a['name']?.toString() ?? ''))),
                    ],
                    onChanged: (v) {
                      setState(() { _assigneeFilter = v; _selectedLoan = null; });
                      _loadLoans();
                    },
                  ),
                ],
              ],
            ),
          ),
          if (_selectedLoan == null)
            SectionCard(
              title: 'Select Active Loan',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _searchCtrl,
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: 'Search by loan #, name, customer #, phone...',
                      suffixIcon: _searchCtrl.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () { _searchCtrl.clear(); _loadLoans(); },
                            ),
                    ),
                    onChanged: _onSearchChanged,
                  ),
                  const SizedBox(height: 8),
                  if (_loadingLoans)
                    const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
                  else if (_loans.isEmpty)
                    const Padding(padding: EdgeInsets.all(16), child: Center(child: Text('No active loans', style: TextStyle(color: AppColors.textSecondary))))
                  else
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxHeight: 340),
                      child: ListView.separated(
                        controller: _loanScrollCtrl,
                        shrinkWrap: true,
                        // One extra row for the "Loading more…" footer while the next page loads.
                        itemCount: _loans.length + (_loanHasMore ? 1 : 0),
                        separatorBuilder: (_, __) => const Divider(height: 1),
                        itemBuilder: (ctx, i) {
                          if (i >= _loans.length) {
                            return const Padding(
                              padding: EdgeInsets.symmetric(vertical: 10),
                              child: Center(child: Text('Loading more…', style: TextStyle(fontSize: 12, color: AppColors.textSecondary))),
                            );
                          }
                          final l = _loans[i];
                          final c = Map<String, dynamic>.from(l['customer'] ?? {});
                          final assignee = Map<String, dynamic>.from(l['assignedTo'] ?? {});
                          return InkWell(
                            onTap: () => _selectLoan(l),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: Text(
                                                '${c['firstName'] ?? ''} ${c['lastName'] ?? ''}'.trim(),
                                                style: const TextStyle(fontWeight: FontWeight.w600),
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                            Container(
                                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                              decoration: BoxDecoration(
                                                color: AppColors.primary.withValues(alpha: 0.12),
                                                borderRadius: BorderRadius.circular(4),
                                              ),
                                              child: Text(l['loanType']?.toString() ?? '', style: const TextStyle(fontSize: 10, color: AppColors.primary, fontWeight: FontWeight.w600)),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          '${l['loanNumber'] ?? ''}${assignee['name'] != null ? ' · Agent: ${assignee['name']}' : ''}',
                                          style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  if (!loanFieldHidden(l, 'totalPayable'))
                                    Text(formatCurrency(l['totalPayable']), style: const TextStyle(fontWeight: FontWeight.w600)),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          if (_selectedLoan != null) _selectedLoanCard(),
          if (_selectedLoan != null && _emis.isNotEmpty) _todaysDueCard(),
          if (_selectedLoan != null) _passbookCard(),
          if (_selectedLoan != null)
            SectionCard(
              title: 'Payment',
              child: Column(
                children: [
                  // ALR is only collectable when the loan was created with an ALR.
                  if ((double.tryParse(_selectedLoan?['alr']?.toString() ?? '') ?? 0) > 0)
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _amountCtrl,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: const InputDecoration(labelText: 'Amount *', prefixText: '₹ '),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextField(
                            controller: _alrCtrl,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: const InputDecoration(labelText: 'ALR'),
                          ),
                        ),
                      ],
                    )
                  else
                    TextField(
                      controller: _amountCtrl,
                      keyboardType: const TextInputType.numberWithOptions(decimal: true),
                      decoration: const InputDecoration(labelText: 'Amount *', prefixText: '₹ '),
                    ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: _mode,
                    decoration: const InputDecoration(labelText: 'Payment Mode'),
                    items: [
                      for (final e in _modeLabels.entries)
                        DropdownMenuItem(value: e.key, child: Text(e.value)),
                    ],
                    onChanged: (v) => setState(() => _mode = v!),
                  ),
                  // Only non-cash payments carry a reference, and there the backend requires one.
                  if (_mode != 'CASH') ...[
                    const SizedBox(height: 10),
                    TextField(
                      controller: _referenceCtrl,
                      textCapitalization: TextCapitalization.characters,
                      decoration: InputDecoration(labelText: 'Reference *', hintText: _referenceHint),
                    ),
                  ],
                  const SizedBox(height: 10),
                  TextField(controller: _notesCtrl, decoration: const InputDecoration(labelText: 'Notes')),
                ],
              ),
            ),
          if (_selectedLoan != null)
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _saving ? null : () => context.go('/collections'),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ElevatedButton(
                    onPressed: _saving ? null : _submit,
                    child: Text(_saving ? 'Saving...' : 'Record Collection'),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 20),
        ],
      ),
    );
  }

  // Loan / Chit source toggle (shown only when the org uses both). Switching resets any
  // in-progress loan selection and lazily loads the other source's list.
  Widget _sourceToggle() {
    Widget chip(String value, String label) {
      final sel = _source == value;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: ChoiceChip(
          label: Text(label, style: TextStyle(color: sel ? AppColors.primary : AppColors.textPrimary, fontWeight: sel ? FontWeight.w600 : FontWeight.w500)),
          selected: sel,
          onSelected: (_) {
            if (_source == value) return;
            setState(() { _source = value; _selectedLoan = null; });
            if (value == 'CHITFUND') { _loadChits(); } else { _loadLoans(); }
          },
          backgroundColor: Colors.white,
          selectedColor: AppColors.primary.withValues(alpha: 0.15),
          side: BorderSide(color: sel ? AppColors.primary : AppColors.border),
        ),
      );
    }

    return SectionCard(
      title: 'Source',
      child: Row(children: [chip('LOAN', 'Loan'), chip('CHITFUND', 'Chit')]),
    );
  }

  // Chit collection: pick one of the officer's active chits, then the shared chit-collection
  // sheet handles month/member/amount. Mirrors the loan picker's look.
  List<Widget> _chitBody() {
    final q = _chitSearchCtrl.text.trim().toLowerCase();
    final filtered = q.isEmpty
        ? _chits
        : _chits.where((c) =>
            (c['chitNumber']?.toString().toLowerCase() ?? '').contains(q) ||
            (c['name']?.toString().toLowerCase() ?? '').contains(q)).toList();
    return [
      SectionCard(
        title: 'Select Chit',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _chitSearchCtrl,
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.search),
                hintText: 'Search by chit # or name...',
                suffixIcon: _chitSearchCtrl.text.isEmpty
                    ? null
                    : IconButton(icon: const Icon(Icons.clear), onPressed: () => setState(() => _chitSearchCtrl.clear())),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 8),
            if (_loadingChits)
              const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
            else if (filtered.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: Text('No active chits assigned to you', style: TextStyle(color: AppColors.textSecondary))),
              )
            else
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 420),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: filtered.length,
                  separatorBuilder: (_, __) => const Divider(height: 1),
                  itemBuilder: (ctx, i) {
                    final c = filtered[i];
                    final assignee = Map<String, dynamic>.from(c['assignedTo'] ?? {});
                    final memberCount = c['totalMembers'] ?? (c['_count'] is Map ? c['_count']['members'] : null);
                    final subtitle = [
                      if (memberCount != null) '$memberCount members',
                      if ((c['calendarMonth'] ?? c['currentMonth']) != null) 'Month ${c['calendarMonth'] ?? c['currentMonth']}',
                      if (assignee['name'] != null) 'Agent: ${assignee['name']}',
                    ].join(' · ');
                    // Green row = every month auctioned, so only collections remain. Mirrors
                    // the chit list on both this app and the web.
                    final duration = toNum(c['durationMonths']).toInt();
                    final auctionsDone = toNum(Map<String, dynamic>.from(c['_count'] ?? {})['auctions']).toInt();
                    final allAuctionsDone = duration > 0 && auctionsDone >= duration;
                    return Ink(
                      color: allAuctionsDone ? AppColors.accent.withValues(alpha: 0.12) : null,
                      child: InkWell(
                        onTap: () => _selectChit(c),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
                          child: Row(
                            children: [
                              const Icon(Icons.savings_outlined, color: AppColors.accent),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('${c['chitNumber'] ?? ''}${c['name'] != null ? ' · ${c['name']}' : ''}'.trim(),
                                        style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                                    if (subtitle.isNotEmpty) ...[
                                      const SizedBox(height: 2),
                                      Text(subtitle, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                                    ],
                                  ],
                                ),
                              ),
                              const Icon(Icons.chevron_right, color: AppColors.textMuted),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
          ],
        ),
      ),
    ];
  }

  Widget _selectedLoanCard() {
    final loan = _selectedLoan!;
    final c = Map<String, dynamic>.from(loan['customer'] ?? {});
    final assignee = Map<String, dynamic>.from(loan['assignedTo'] ?? {});
    final totalPayable = toNum(loan['totalPayable']);
    // Use the API's authoritative paid/balance (from VERIFIED collections), consistent with
    // the loan detail and receipt. Summing EMI paidAmount client-side diverges.
    final totalPaid = loan['totalPaid'] != null
        ? toNum(loan['totalPaid'])
        : _emis.fold<num>(0, (s, e) => s + toNum(e['paidAmount']));
    final balance = loan['balance'] != null ? toNum(loan['balance']) : totalPayable - totalPaid;
    // Prefer the API's overdue (pending folded in when the org opts in); summing the
    // verified schedule client-side would ignore the setting.
    final overdue = loan['overdueAmount'] != null
        ? toNum(loan['overdueAmount'])
        : _emis
            .where((e) => e['status'] == 'OVERDUE')
            .fold<num>(0, (s, e) => s + toNum(e['emiAmount']) + toNum(e['lateFee']) - toNum(e['paidAmount']));
    return Card(
      color: AppColors.primary.withValues(alpha: 0.06),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                GestureDetector(
                  onTap: () => showImageViewer(context, c['photo']?.toString()),
                  child: Avatar(
                    url: c['photo']?.toString(),
                    name: '${c['firstName'] ?? ''} ${c['lastName'] ?? ''}'.trim(),
                    size: 48,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${c['firstName'] ?? ''} ${c['lastName'] ?? ''} - ${loan['loanNumber'] ?? ''}'.trim(),
                          style: const TextStyle(fontWeight: FontWeight.w600)),
                      if (c['customerId'] != null)
                        Text('Customer #: ${c['customerId']}', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                      if (assignee['name'] != null)
                        Text('Agent: ${assignee['name']}', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                    ],
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    _selectedLoan = null;
                    _emis = [];
                    _pendingEmis = [];
                    _loanPayments = [];
                  }),
                  child: const Text('Change'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              runSpacing: 8,
              children: [
                if (!loanFieldHidden(loan, 'totalPayable'))
                  _miniStat('Total Payable', formatCurrency(totalPayable)),
                _miniStat('Total Paid', formatCurrency(totalPaid), color: AppColors.accent),
                _miniStat('Balance', formatCurrency(balance)),
                if (overdue > 0) _miniStat('Overdue', formatCurrency(overdue), color: AppColors.danger),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // The customer's "passbook": the selected loan's previous payments, read-only, so the
  // collector sees what's already been paid (and when) while recording the next one.
  Widget _passbookCard() {
    final loan = _selectedLoan!;
    final showAmount = !loanFieldHidden(loan, 'totalPayable');
    // Pending money has been handed over too, so it counts toward what's paid; rejected don't.
    final counted = _loanPayments.where((p) => p['verificationStatus'] != 'REJECTED').toList();
    final totalPaid = counted.fold<num>(0, (s, p) => s + toNum(p['amount']));

    return SectionCard(
      title: 'Payment History',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_loadingPayments)
            const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator(strokeWidth: 2)))
          else if (_loanPayments.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 18),
              child: Center(
                child: Text('No previous payments — this will be the first collection',
                    textAlign: TextAlign.center, style: TextStyle(color: AppColors.textSecondary)),
              ),
            )
          else ...[
            Row(
              children: [
                Expanded(child: _passbookStat('${counted.length}', 'Payments')),
                if (showAmount) Expanded(child: _passbookStat(formatCurrency(totalPaid), 'Total paid', color: AppColors.accent)),
              ],
            ),
            const SizedBox(height: 6),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: _loanPayments.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (ctx, i) {
                  final p = _loanPayments[i];
                  final status = p['verificationStatus']?.toString() ?? 'PENDING';
                  final collectedBy = p['collectedBy'] is Map ? p['collectedBy']['name']?.toString() : null;
                  final mode = p['paymentMode']?.toString();
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                showAmount ? formatCurrency(p['amount']) : (mode ?? '-'),
                                style: const TextStyle(fontWeight: FontWeight.w700),
                              ),
                            ),
                            StatusChip(label: status, color: statusColor(status)),
                          ],
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                '${formatDate(p['collectedAt'])}${showAmount && mode != null ? ' · $mode' : ''}',
                                style: const TextStyle(fontSize: 11, color: AppColors.textSecondary),
                              ),
                            ),
                            if (collectedBy != null)
                              Text(collectedBy, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _passbookStat(String value, String label, {Color? color}) {
    return Column(
      children: [
        Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: color ?? AppColors.textPrimary)),
        Text(label, style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
      ],
    );
  }

  Widget _miniStat(String label, String value, {Color? color}) {
    return SizedBox(
      width: 150,
      child: Row(
        children: [
          Text('$label: ', style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          Expanded(
            child: Text(value,
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: color),
                overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  // ---- Today's Due helpers (mirror the web collection form) ----
  num _emiRemaining(Map e) => toNum(e['emiAmount']) + toNum(e['lateFee']) - toNum(e['paidAmount']);

  DateTime _startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);

  // Whether an EMI's due date has already passed (strictly before today).
  bool _isOverdueEmi(Map e, DateTime today) {
    final due = tryParseDate(e['dueDate']?.toString())?.toLocal();
    if (due == null) return false;
    return _startOfDay(due).isBefore(today);
  }

  // EMIs collectible as of today = any not-fully-paid EMI whose due date is
  // today or earlier (overdue + due today) — no double counting.
  List<Map<String, dynamic>> _dueTodayEmis(DateTime today) {
    return _emis.where((e) {
      if (e['status'] == 'PAID') return false;
      final due = tryParseDate(e['dueDate']?.toString())?.toLocal();
      if (due == null) return false;
      return !_startOfDay(due).isAfter(today); // due <= today
    }).toList();
  }

  Widget _todaysDueCard() {
    final loan = _selectedLoan!;
    final today = _startOfDay(DateTime.now());
    final dueEmis = _dueTodayEmis(today);
    final overdueEmis = dueEmis.where((e) => _isOverdueEmi(e, today)).toList();
    final dueTodayEmis = dueEmis.where((e) => !_isOverdueEmi(e, today)).toList();

    // Prefer the API's authoritative, pending-aware figures (same source as the
    // loan detail page and the web collection form) — overdue + currently-due.
    // Fall back to the verified-only EMI schedule only when those fields are
    // absent; re-deriving from the schedule ignores collected-but-unverified
    // money and overstates overdue.
    final overdueAmt = loan['overdueAmount'] != null
        ? toNum(loan['overdueAmount'])
        : overdueEmis.fold<num>(0, (s, e) => s + _emiRemaining(e));
    final overdueCount = (loan['overdueCount'] ?? loan['overdueEMIs']) != null
        ? toNum(loan['overdueCount'] ?? loan['overdueEMIs']).toInt()
        : overdueEmis.length;
    final dueTodayAmt = loan['dueAmount'] != null
        ? toNum(loan['dueAmount'])
        : dueTodayEmis.fold<num>(0, (s, e) => s + _emiRemaining(e));
    final dueTodayCount = loan['dueAmount'] != null
        ? (dueTodayAmt > 0 ? 1 : 0)
        : dueTodayEmis.length;
    final totalDue = overdueAmt + dueTodayAmt;

    // Nothing due yet — show the upcoming EMI for context (mirrors the web).
    if (totalDue <= 0) {
      if (_pendingEmis.isEmpty) return const SizedBox.shrink();
      final next = _pendingEmis.first;
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Next EMI', style: TextStyle(fontSize: 11, color: AppColors.textSecondary, fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text.rich(TextSpan(children: [
                TextSpan(
                  text: 'EMI #${next['emiNumber']} — ${formatCurrency(next['emiAmount'])}',
                  style: const TextStyle(fontWeight: FontWeight.w600, color: AppColors.textPrimary),
                ),
                TextSpan(
                  text: '  (Due: ${formatDate(next['dueDate'])})',
                  style: const TextStyle(fontWeight: FontWeight.w400, color: AppColors.textSecondary),
                ),
              ])),
            ],
          ),
        ),
      );
    }

    const dueTodayText = Color(0xFFB45309); // amber-700, matches web
    return Card(
      color: AppColors.warning.withValues(alpha: 0.10),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: AppColors.warning.withValues(alpha: 0.35)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Flexible(
                  child: Text("Today's Due (overdue + due today)",
                      style: TextStyle(fontSize: 12, color: AppColors.textSecondary, fontWeight: FontWeight.w600)),
                ),
                Text(formatCurrency(totalDue),
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
              ],
            ),
            const SizedBox(height: 4),
            Wrap(
              spacing: 16,
              runSpacing: 2,
              children: [
                if (overdueAmt > 0)
                  Text.rich(TextSpan(
                    style: const TextStyle(fontSize: 12, color: AppColors.danger),
                    children: [
                      TextSpan(text: 'Overdue ($overdueCount EMI${overdueCount > 1 ? 's' : ''}): '),
                      TextSpan(text: formatCurrency(overdueAmt), style: const TextStyle(fontWeight: FontWeight.w700)),
                    ],
                  )),
                if (dueTodayAmt > 0)
                  Text.rich(TextSpan(
                    style: const TextStyle(fontSize: 12, color: dueTodayText),
                    children: [
                      TextSpan(text: 'Due today ($dueTodayCount EMI${dueTodayCount > 1 ? 's' : ''}): '),
                      TextSpan(text: formatCurrency(dueTodayAmt), style: const TextStyle(fontWeight: FontWeight.w700)),
                    ],
                  )),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
