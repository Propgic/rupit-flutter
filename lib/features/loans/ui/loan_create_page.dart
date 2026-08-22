import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/common.dart';
import '../../customers/data/customer_repo.dart';
import '../../loan_groups/data/loan_group_repo.dart';
import '../data/loan_dates.dart';
import 'emi_start_date_tile.dart';
import 'loan_preview_page.dart';

class LoanCreatePage extends ConsumerStatefulWidget {
  const LoanCreatePage({super.key});
  @override
  ConsumerState<LoanCreatePage> createState() => _LoanCreatePageState();
}

class _LoanCreatePageState extends ConsumerState<LoanCreatePage> {
  final _formKey = GlobalKey<FormState>();
  // One loan is created per selected customer. Only group loans are issued in
  // batches, so the picker allows multiple customers only when the type is GROUP.
  List<Map<String, dynamic>> _customers = [];
  Map<String, dynamic>? _assignee;
  Map<String, dynamic>? _group;
  String _loanType = 'PERSONAL';
  String _tenureType = 'MONTHS';
  String _interestType = 'REDUCING';
  bool _deductUpfront = false;
  // Traditional accrual (khata) loan: no EMIs — principal owed from disbursement
  // and simple monthly interest (rate % per MONTH) added to the balance as each
  // month arrives. Offered only to khata-mode orgs.
  bool _accrual = false;
  DateTime _startDate = DateTime.now();
  // Explicit EMI start (first EMI due ON it); null = normal cycle — same as the web.
  DateTime? _emiStartDate;
  final _principal = TextEditingController();
  final _rate = TextEditingController();
  final _tenure = TextEditingController();
  final _fee = TextEditingController(text: '0');
  final _alr = TextEditingController();
  final _lateFee = TextEditingController(text: '0');
  final _notes = TextEditingController();
  // type-specific
  final _goldWeight = TextEditingController();
  final _goldPurity = TextEditingController();
  final _vehType = TextEditingController();
  final _vehMake = TextEditingController();
  final _vehModel = TextEditingController();
  final _propType = TextEditingController();
  final _propAddr = TextEditingController();
  final _propValue = TextEditingController();
  final _guarantorName = TextEditingController();
  final _guarantorPhone = TextEditingController();
  Map<String, String> _suretyByType = const {};

  @override
  void initState() {
    super.initState();
    _loadSuretyPolicy();
  }

  Future<void> _loadSuretyPolicy() async {
    try {
      final api = ref.read(apiClientProvider);
      final res = await api.get('/settings/surety-policy') as Map;
      final by = Map<String, dynamic>.from(res['byLoanType'] ?? const {});
      if (!mounted) return;
      setState(() => _suretyByType = {for (final e in by.entries) e.key: e.value.toString()});
    } catch (_) {
      // Falls back to OPTIONAL — guarantor section stays visible/optional.
    }
  }

  String get _suretyPolicy => _suretyByType[_loanType] ?? 'OPTIONAL';

  bool get _isGroupLoan => _loanType == 'GROUP';

  // Day filter the backend snaps an explicit EMI start onto: a weekly group loan collects
  // on the group's meeting day. (DAILY/WEEKLY types keep the backend's default days here —
  // this form has no day picker — so no filter is known for them.)
  List<int> get _emiSnapDays {
    if (_isGroupLoan && _tenureType == 'WEEKS') {
      final i = meetingDayIndex(_group?['meetingDay']);
      if (i != null) return [i];
    }
    return const [];
  }

  // DAILY/WEEKLY loan TYPES are fixed flat-upfront — the method picker is only for term loans.
  bool get _showInterestMethod => _loanType != 'DAILY' && _loanType != 'WEEKLY' && !_accrual;
  // Accrual is a term-loan-only shape (DAILY/WEEKLY types are fixed flat-upfront).
  bool get _canAccrue => _loanType != 'DAILY' && _loanType != 'WEEKLY';
  // Sub-monthly cadence (tenure counted in weeks/days) chosen via the tenure Unit dropdown.
  bool get _isPeriodUnit => _tenureType == 'WEEKS' || _tenureType == 'DAYS';
  String get _periodWord => _tenureType == 'WEEKS' ? 'week' : 'day';

  String get _rateLabel {
    if (_accrual) return 'Interest Rate (% per month) *';
    if (!_showInterestMethod) return 'Flat Interest Rate (% on principal) *';
    if (_isPeriodUnit && _interestType == 'REDUCING') return 'Interest Rate (% per month) *';
    if (_isPeriodUnit) return 'Flat Interest Rate (% on principal) *';
    return 'Interest Rate (% p.a.) *';
  }

  String _customerName(Map<String, dynamic> c) =>
      '${c['firstName'] ?? ''} ${c['lastName'] ?? ''}'.trim();

  Future<void> _pickCustomer() async {
    Future<List<Map<String, dynamic>>> fetch(String search) async {
      final r = await ref.read(customerRepoProvider).list(page: 1, limit: 20, search: search, forLoan: true);
      return ((r['data'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    }
    String subtitle(Map<String, dynamic> m) => '${m['customerId'] ?? ''} • ${m['phone'] ?? ''}';

    if (_isGroupLoan) {
      final picked = await showModalBottomSheet<List<Map<String, dynamic>>>(
        context: context,
        isScrollControlled: true,
        builder: (_) => _PickerSheet<Map<String, dynamic>>(
          title: 'Select Customers',
          fetcher: fetch,
          labelBuilder: _customerName,
          subtitleBuilder: subtitle,
          multi: true,
          initialSelected: _customers,
          idOf: (m) => m['id'].toString(),
        ),
      );
      if (picked != null) setState(() => _customers = picked);
      return;
    }
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _PickerSheet<Map<String, dynamic>>(
        title: 'Select Customer',
        fetcher: fetch,
        labelBuilder: _customerName,
        subtitleBuilder: subtitle,
      ),
    );
    if (picked != null) setState(() => _customers = [picked]);
  }

  Future<void> _pickAssignee() async {
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _PickerSheet<Map<String, dynamic>>(
        title: 'Assign To',
        fetcher: (search) async {
          final api = ref.read(apiClientProvider);
          final d = await api.get('/team');
          final list = (d is List ? d : (d is Map && d['data'] is List ? d['data'] : const [])) as List;
          var users = list
              .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map))
              .where((u) => u['isActive'] == true && u['role'] == 'FIELD_OFFICER')
              .toList();
          if (search.isNotEmpty) {
            users = users.where((u) {
              final nm = (u['name']?.toString() ?? '').toLowerCase();
              return nm.contains(search.toLowerCase());
            }).toList();
          }
          return users;
        },
        labelBuilder: (m) => m['name']?.toString() ?? '',
        subtitleBuilder: (m) => m['phone']?.toString() ?? '',
      ),
    );
    if (picked != null) setState(() => _assignee = picked);
  }

  Future<void> _pickGroup() async {
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _PickerSheet<Map<String, dynamic>>(
        title: 'Select Loan Group',
        fetcher: (search) async {
          final r = await ref.read(loanGroupRepoProvider).list(page: 1, limit: 50, search: search);
          return ((r['data'] as List?) ?? [])
              .map((e) => Map<String, dynamic>.from(e as Map))
              .where((g) => g['isActive'] == true)
              .toList();
        },
        labelBuilder: (m) => '${m['groupNumber'] ?? ''} — ${m['name'] ?? ''}',
        subtitleBuilder: (m) => [
          m['leaderName']?.toString() ?? '',
          if (m['memberCount'] != null) '${m['memberCount']} members',
        ].where((s) => s.isNotEmpty).join(' · '),
      ),
    );
    if (picked != null) {
      setState(() {
        _group = picked;
        _applyGroupDefaults(picked);
      });
      _prefillGroupAssignee(picked);
    }
  }

  // Seed the form with the group's default loan terms (captured on the group
  // form). Group defaults are informational — each loan stores its own terms —
  // so every field stays editable; re-picking a group re-applies them.
  void _applyGroupDefaults(Map<String, dynamic> g) {
    if (g['interestRate'] != null) _rate.text = g['interestRate'].toString();
    if (g['tenure'] != null) _tenure.text = g['tenure'].toString();
    const unitByFrequency = {'DAILY': 'DAYS', 'WEEKLY': 'WEEKS', 'MONTHLY': 'MONTHS'};
    final unit = unitByFrequency[g['emiFrequency']];
    if (unit != null) _tenureType = unit;
    if (g['interestType'] == 'FLAT' || g['interestType'] == 'REDUCING') {
      _interestType = g['interestType'] as String;
      _deductUpfront = _interestType == 'FLAT' && g['deductInterestUpfront'] == true;
    } else if (unit != null) {
      // No method stored on the group — fall back to the Unit dropdown's
      // convention (sub-monthly → flat, monthly → reducing).
      _interestType = _isPeriodUnit ? 'FLAT' : 'REDUCING';
      if (_interestType != 'FLAT') _deductUpfront = false;
    }
    if (g['processingFee'] != null) _fee.text = g['processingFee'].toString();
    if (g['alr'] != null) _alr.text = g['alr'].toString();
  }

  // Adopt the group's assignee only if they're still an active field officer
  // (same guard as the web form) — the group itself can be held by any role,
  // and a stale/deactivated assignee shouldn't ride into the loan silently.
  Future<void> _prefillGroupAssignee(Map<String, dynamic> g) async {
    final assignedToId = g['assignedToId']?.toString();
    if (assignedToId == null || assignedToId.isEmpty) return;
    if ((g['assignedTo'] as Map?)?['role'] != 'FIELD_OFFICER') return;
    try {
      final api = ref.read(apiClientProvider);
      final d = await api.get('/team');
      final list = (d is List ? d : (d is Map && d['data'] is List ? d['data'] : const [])) as List;
      Map<String, dynamic>? member;
      for (final e in list) {
        final u = Map<String, dynamic>.from(e as Map);
        if (u['id']?.toString() == assignedToId && u['isActive'] == true && u['role'] == 'FIELD_OFFICER') {
          member = u;
          break;
        }
      }
      // The officer may have picked a different group (or an assignee) while
      // the team list was loading — only apply if this group is still current.
      if (member == null || !mounted || _group?['id'] != g['id']) return;
      setState(() => _assignee = member);
    } catch (_) {
      // Prefill is best-effort; the assignee can still be picked manually.
    }
  }

  bool get _groupHasDefaults {
    final g = _group;
    if (g == null) return false;
    return g['interestRate'] != null || g['tenure'] != null || g['emiFrequency'] != null ||
        g['interestType'] != null || g['processingFee'] != null || g['alr'] != null;
  }

  String get _groupDefaultsSummary {
    final g = _group!;
    final freq = g['emiFrequency']?.toString();
    final tenureUnit = freq == 'DAILY' ? 'days' : freq == 'WEEKLY' ? 'weeks' : 'months';
    final parts = <String>[
      if (g['interestRate'] != null) "${g['interestRate']}% interest",
      if (g['tenure'] != null) "${g['tenure']} $tenureUnit tenure",
      if (freq != null) '${freq.toLowerCase()} EMI',
      if (g['interestType'] != null)
        g['interestType'] == 'FLAT'
            ? "flat rate${g['deductInterestUpfront'] == true ? ', interest upfront' : ''}"
            : 'reducing balance',
      if (g['processingFee'] != null && (double.tryParse(g['processingFee'].toString()) ?? 0) > 0)
        "₹${g['processingFee']} processing fee",
      if (g['alr'] != null && (double.tryParse(g['alr'].toString()) ?? 0) > 0)
        "ALR ${g['alr']}",
    ];
    return parts.join(' · ');
  }

  // Validate, assemble the request body, then push the preview screen. The actual POST
  // happens on the preview after the user confirms — mirroring the web create wizard's
  // "Review & Confirm" step.
  Future<void> _review() async {
    if (!_formKey.currentState!.validate()) return;
    if (_loanType == 'GROUP' && _group == null) return showToast('Select a loan group', error: true);
    if (_customers.isEmpty) {
      return showToast(_isGroupLoan ? 'Select at least one customer' : 'Select a customer', error: true);
    }
    if (!_accrual && emiStartError(_emiStartDate, _startDate) != null) {
      return showToast('EMI start date cannot be before the disbursement date', error: true);
    }
    if (_assignee == null) {
      final proceed = await confirmDialog(
        context,
        title: 'Continue without assignee?',
        message: 'No team member is assigned to this loan. You can assign one later. Continue?',
        confirmText: 'Continue',
      );
      if (!proceed) return;
    }
    if (_suretyPolicy == 'REQUIRED' &&
        (_guarantorName.text.trim().isEmpty || _guarantorPhone.text.trim().isEmpty)) {
      return showToast('Surety name and phone are required for this loan type', error: true);
    }

    // Shared terms for every loan in this pass — customerId is appended per
    // customer on the preview page when the loans are actually posted.
    final body = <String, dynamic>{
      if (_assignee != null) 'assignedToId': _assignee!['id'],
      'loanType': _loanType,
      'principalAmount': double.tryParse(_principal.text),
      'interestRate': double.tryParse(_rate.text),
      // Accrual loans are open-ended; the backend stores tenure 1 and appends
      // interest rows monthly via the accrual job.
      'tenure': _accrual ? 1 : int.tryParse(_tenure.text),
      'tenureType': _accrual ? 'MONTHS' : _tenureType,
      if (_accrual) 'interestAccrual': true,
      // Interest method (DAILY/WEEKLY types are normalized to flat-upfront by the backend).
      if (_showInterestMethod) 'interestType': _interestType,
      if (_showInterestMethod) 'deductInterestUpfront': _interestType == 'FLAT' && _deductUpfront,
      'startDate': formatInputDate(_startDate),
      // Omitted = normal cycle; a date (the start date itself included) = first EMI due on it.
      if (!_accrual && _emiStartDate != null) 'emiStartDate': formatInputDate(_emiStartDate!),
      'processingFee': double.tryParse(_fee.text) ?? 0,
      'alr': _alr.text.trim().isEmpty ? null : double.tryParse(_alr.text.trim()),
      'lateFeePerDay': double.tryParse(_lateFee.text) ?? 0,
      if (_notes.text.trim().isNotEmpty) 'notes': _notes.text.trim(),
    };
    if (_loanType == 'GROUP') {
      body['groupId'] = _group!['id'];
    }
    if (_loanType == 'GOLD') {
      body['goldWeight'] = double.tryParse(_goldWeight.text);
      body['goldPurity'] = _goldPurity.text.trim();
    }
    if (_loanType == 'VEHICLE') {
      body['vehicleType'] = _vehType.text.trim();
      body['vehicleMake'] = _vehMake.text.trim();
      body['vehicleModel'] = _vehModel.text.trim();
    }
    if (_loanType == 'PROPERTY') {
      body['propertyType'] = _propType.text.trim();
      body['propertyAddress'] = _propAddr.text.trim();
      body['propertyValue'] = double.tryParse(_propValue.text);
    }
    if (_guarantorName.text.trim().isNotEmpty) body['guarantorName'] = _guarantorName.text.trim();
    if (_guarantorPhone.text.trim().isNotEmpty) body['guarantorPhone'] = _guarantorPhone.text.trim();

    final preview = computeLoanPreview(
      loanType: _loanType,
      tenureType: _tenureType,
      interestType: _showInterestMethod ? _interestType : 'FLAT',
      deductUpfront: _showInterestMethod && _interestType == 'FLAT' && _deductUpfront,
      amount: double.tryParse(_principal.text) ?? 0,
      rate: double.tryParse(_rate.text) ?? 0,
      tenure: int.tryParse(_tenure.text) ?? 1,
      processingFee: double.tryParse(_fee.text) ?? 0,
      accrual: _accrual,
    );

    if (!mounted) return;
    await Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => LoanPreviewPage(
        body: body,
        preview: preview,
        customers: _customers
            .map((c) => {'id': c['id'], 'label': _customerName(c)})
            .toList(),
        loanTypeLabel: titleCase(_loanType),
        assigneeLabel: _assignee?['name']?.toString(),
        startDate: _startDate,
        rateText: _rate.text.trim(),
        firstEmiDate: _accrual || _emiStartDate == null
            ? null
            : effectiveEmiStart(_emiStartDate!, _emiSnapDays),
      ),
    ));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Create Loan')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(14),
          children: [
            SectionCard(
              title: 'Basics',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: _loanType,
                    decoration: const InputDecoration(labelText: 'Loan Type *'),
                    items: [
                      const DropdownMenuItem(value: 'PERSONAL', child: Text('Personal')),
                      const DropdownMenuItem(value: 'GOLD', child: Text('Gold')),
                      if (ref.watch(authProvider).org?.feature('enableGroupLoan') == true)
                        const DropdownMenuItem(value: 'GROUP', child: Text('Group')),
                      const DropdownMenuItem(value: 'VEHICLE', child: Text('Vehicle')),
                      const DropdownMenuItem(value: 'PROPERTY', child: Text('Property/Mortgage')),
                      const DropdownMenuItem(value: 'BUSINESS', child: Text('Business')),
                      const DropdownMenuItem(value: 'AGRICULTURE', child: Text('Agriculture')),
                      const DropdownMenuItem(value: 'EDUCATION', child: Text('Education')),
                      const DropdownMenuItem(value: 'DAILY', child: Text('Daily')),
                      const DropdownMenuItem(value: 'WEEKLY', child: Text('Weekly')),
                    ],
                    onChanged: (v) => setState(() {
                      _loanType = v!;
                      if (_loanType != 'GROUP') {
                        _group = null;
                        // Leaving GROUP drops the batch down to one borrower so a
                        // stray multi-selection can't create several loans at once.
                        if (_customers.length > 1) _customers = [_customers.first];
                        // Clear the group-only fee fields (their inputs unmount but
                        // the controllers keep the text, which would still be
                        // deducted from net disbursed).
                        _fee.clear();
                        _alr.clear();
                      }
                    }),
                  ),
                  if (_loanType == 'GROUP')
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.groups),
                      title: Text(_group == null
                          ? 'Select Loan Group *'
                          : '${_group!['groupNumber'] ?? ''} — ${_group!['name'] ?? ''}'),
                      subtitle: _group == null ? null : Text(_group!['leaderName']?.toString() ?? ''),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _pickGroup,
                    ),
                  if (_loanType == 'GROUP' && _groupHasDefaults)
                    Container(
                      margin: const EdgeInsets.only(bottom: 8),
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        'Prefilled from group defaults: $_groupDefaultsSummary. '
                        'You can still edit any of these below.',
                        style: Theme.of(context)
                            .textTheme
                            .bodySmall
                            ?.copyWith(color: AppColors.primary),
                      ),
                    ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(_isGroupLoan ? Icons.group_add : Icons.person),
                    title: Text(_customers.isEmpty
                        ? (_isGroupLoan ? 'Select Customers *' : 'Select Customer *')
                        : _customers.length == 1
                            ? _customerName(_customers.first)
                            : '${_customers.length} customers selected'),
                    subtitle: _customers.isEmpty
                        ? null
                        : Text(_customers.length == 1
                            ? _customers.first['phone']?.toString() ?? ''
                            : '${_customers.length} separate loans will be created with the terms below'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _pickCustomer,
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.assignment_ind),
                    title: Text(_assignee == null ? 'Assign To' : _assignee!['name']?.toString() ?? ''),
                    subtitle: _assignee == null ? null : Text(_assignee!['phone']?.toString() ?? ''),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _pickAssignee,
                  ),
                ],
              ),
            ),
            SectionCard(
              title: 'Terms',
              child: Column(
                children: [
                  TextFormField(
                    controller: _principal,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Principal Amount *', prefixText: '₹ '),
                    validator: (v) => (double.tryParse(v ?? '') ?? 0) > 0 ? null : 'Required',
                  ),
                  // Repayment shape — khata-mode orgs can book a traditional
                  // accrual loan (no EMIs) instead of an installment loan.
                  if (_canAccrue && ref.watch(authProvider).org?.khataCollectionMode == true) ...[
                    const SizedBox(height: 10),
                    DropdownButtonFormField<bool>(
                      initialValue: _accrual,
                      decoration: const InputDecoration(labelText: 'Repayment Mode'),
                      items: const [
                        DropdownMenuItem(value: false, child: Text('EMI installments')),
                        DropdownMenuItem(value: true, child: Text('Monthly interest (khata)')),
                      ],
                      onChanged: (v) => setState(() {
                        _accrual = v ?? false;
                        if (_accrual) {
                          _tenureType = 'MONTHS';
                          _deductUpfront = false;
                          _interestType = 'FLAT';
                        }
                      }),
                    ),
                  ],
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: _rate,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: InputDecoration(labelText: _rateLabel),
                    validator: (v) => double.tryParse(v ?? '') != null ? null : 'Required',
                  ),
                  const SizedBox(height: 10),
                  // Khata (accrual) loans are open-ended — no tenure/unit to pick.
                  if (_accrual)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.primarySoft,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Text(
                        'Traditional khata loan. The full principal is owed from disbursement; '
                        'simple monthly interest (rate% × principal) is added to the balance when '
                        'each month arrives. Collections and adjustments flow through the balance sheet.',
                        style: TextStyle(fontSize: 12.5, color: AppColors.primaryDark),
                      ),
                    )
                  else
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _tenure,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'Tenure *'),
                          validator: (v) => (int.tryParse(v ?? '') ?? 0) > 0 ? null : 'Required',
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: _tenureType,
                          decoration: const InputDecoration(labelText: 'Unit'),
                          items: const [
                            DropdownMenuItem(value: 'DAYS', child: Text('Days')),
                            DropdownMenuItem(value: 'WEEKS', child: Text('Weeks')),
                            DropdownMenuItem(value: 'MONTHS', child: Text('Months')),
                            DropdownMenuItem(value: 'YEARS', child: Text('Years')),
                          ],
                          onChanged: (v) => setState(() {
                            _tenureType = v!;
                            // Sub-monthly collection is conventionally flat; monthly/yearly
                            // reducing. The user can still override the method below.
                            _interestType = _isPeriodUnit ? 'FLAT' : 'REDUCING';
                            if (_interestType != 'FLAT') _deductUpfront = false;
                          }),
                        ),
                      ),
                    ],
                  ),
                  if (_showInterestMethod) ...[
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: _interestType,
                      decoration: const InputDecoration(labelText: 'Interest Calculation'),
                      items: const [
                        DropdownMenuItem(value: 'REDUCING', child: Text('Reducing Balance (interest on outstanding)')),
                        DropdownMenuItem(value: 'FLAT', child: Text('Flat Rate (interest on full principal)')),
                      ],
                      onChanged: (v) => setState(() {
                        _interestType = v ?? 'REDUCING';
                        if (_interestType != 'FLAT') _deductUpfront = false;
                      }),
                    ),
                    if (_isPeriodUnit && _interestType == 'REDUCING')
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          'Interest is charged on the outstanding balance each $_periodWord; '
                          'the rate is per month and is converted to a ${_tenureType == 'WEEKS' ? 'weekly' : 'daily'} charge automatically.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    if (_interestType == 'FLAT')
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Deduct interest upfront'),
                        subtitle: const Text(
                          'Interest is taken out of the disbursed amount; the EMIs repay '
                          'principal only. Leave off to add the interest into each EMI.',
                        ),
                        value: _deductUpfront,
                        onChanged: (v) => setState(() => _deductUpfront = v),
                      ),
                  ],
                  const SizedBox(height: 10),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text('Start Date: ${formatDate(_startDate)}'),
                    trailing: const Icon(Icons.calendar_today),
                    onTap: () async {
                      final d = await showDatePicker(
                        context: context,
                        firstDate: DateTime(2020),
                        lastDate: DateTime.now().add(const Duration(days: 30)),
                        initialDate: _startDate,
                      );
                      if (d != null) setState(() => _startDate = d);
                    },
                  ),
                  if (!_accrual)
                    EmiStartDateTile(
                      startDate: _startDate,
                      emiStart: _emiStartDate,
                      collectionDays: _emiSnapDays,
                      onChanged: (d) => setState(() => _emiStartDate = d),
                    ),
                  if (_isGroupLoan) ...[
                    Row(
                      children: [
                        Expanded(
                          child: TextFormField(controller: _fee, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Processing Fee')),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: TextFormField(
                            controller: _alr,
                            keyboardType: const TextInputType.numberWithOptions(decimal: true),
                            decoration: const InputDecoration(labelText: 'ALR'),
                            validator: (v) {
                              final t = v?.trim() ?? '';
                              if (t.isEmpty) return null;
                              final n = double.tryParse(t);
                              return n == null || n < 0 ? 'Invalid value' : null;
                            },
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                  ],
                  TextFormField(controller: _lateFee, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Late Fee Per Day')),
                ],
              ),
            ),
            if (_loanType == 'GOLD')
              SectionCard(
                title: 'Gold Details',
                child: Column(
                  children: [
                    TextFormField(controller: _goldWeight, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Weight (grams) *')),
                    const SizedBox(height: 10),
                    TextFormField(controller: _goldPurity, decoration: const InputDecoration(labelText: 'Purity (e.g. 22K) *')),
                  ],
                ),
              ),
            if (_loanType == 'VEHICLE')
              SectionCard(
                title: 'Vehicle Details',
                child: Column(
                  children: [
                    TextFormField(controller: _vehType, decoration: const InputDecoration(labelText: 'Type *')),
                    const SizedBox(height: 10),
                    TextFormField(controller: _vehMake, decoration: const InputDecoration(labelText: 'Make *')),
                    const SizedBox(height: 10),
                    TextFormField(controller: _vehModel, decoration: const InputDecoration(labelText: 'Model *')),
                  ],
                ),
              ),
            if (_loanType == 'PROPERTY')
              SectionCard(
                title: 'Property Details',
                child: Column(
                  children: [
                    TextFormField(controller: _propType, decoration: const InputDecoration(labelText: 'Type *')),
                    const SizedBox(height: 10),
                    TextFormField(controller: _propAddr, maxLines: 2, decoration: const InputDecoration(labelText: 'Address *')),
                    const SizedBox(height: 10),
                    TextFormField(controller: _propValue, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Value *')),
                  ],
                ),
              ),
            if (_suretyPolicy != 'HIDDEN')
              SectionCard(
                title: _suretyPolicy == 'REQUIRED' ? 'Surety / Guarantor *' : 'Surety / Guarantor (optional)',
                child: Column(
                  children: [
                    TextFormField(
                      controller: _guarantorName,
                      decoration: InputDecoration(labelText: 'Name${_suretyPolicy == 'REQUIRED' ? ' *' : ''}'),
                      validator: (v) => _suretyPolicy == 'REQUIRED' && (v == null || v.trim().isEmpty) ? 'Required' : null,
                    ),
                    const SizedBox(height: 10),
                    TextFormField(
                      controller: _guarantorPhone,
                      keyboardType: TextInputType.phone,
                      decoration: InputDecoration(labelText: 'Phone${_suretyPolicy == 'REQUIRED' ? ' *' : ''}'),
                      validator: (v) => _suretyPolicy == 'REQUIRED' && (v == null || v.trim().isEmpty) ? 'Required' : null,
                    ),
                  ],
                ),
              ),
            SectionCard(
              title: 'Notes',
              child: TextFormField(controller: _notes, maxLines: 3, decoration: const InputDecoration(hintText: 'Additional notes')),
            ),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _review,
                child: const Text('Review & Create'),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}

class _PickerSheet<T> extends StatefulWidget {
  final String title;
  final Future<List<T>> Function(String search) fetcher;
  final String Function(T) labelBuilder;
  final String Function(T) subtitleBuilder;
  // Multi mode (group loans): rows toggle checkboxes, the selection survives new
  // searches, and Done pops with a List<T> instead of popping on the first tap.
  final bool multi;
  final List<T> initialSelected;
  final String Function(T)? idOf;
  const _PickerSheet({
    required this.title,
    required this.fetcher,
    required this.labelBuilder,
    required this.subtitleBuilder,
    this.multi = false,
    this.initialSelected = const [],
    this.idOf,
  });
  @override
  State<_PickerSheet<T>> createState() => _PickerSheetState<T>();
}

class _PickerSheetState<T> extends State<_PickerSheet<T>> {
  final _search = TextEditingController();
  Future<List<T>>? _future;
  late final List<T> _selected = [...widget.initialSelected];

  String _keyOf(T item) => widget.idOf?.call(item) ?? item.toString();
  bool _isSelected(T item) => _selected.any((e) => _keyOf(e) == _keyOf(item));
  void _toggle(T item) {
    setState(() {
      if (_isSelected(item)) {
        _selected.removeWhere((e) => _keyOf(e) == _keyOf(item));
      } else {
        _selected.add(item);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _future = widget.fetcher('');
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, ctrl) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(child: Text(widget.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600))),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TextField(
              controller: _search,
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search...'),
              onSubmitted: (v) => setState(() => _future = widget.fetcher(v)),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: FutureBuilder<List<T>>(
              future: _future,
              builder: (ctx, snap) {
                if (snap.connectionState == ConnectionState.waiting) return const LoadingView();
                if (snap.hasError) return ErrorView(message: snap.error.toString());
                final items = snap.data ?? [];
                if (items.isEmpty) return const EmptyView(message: 'No results');
                return ListView.builder(
                  controller: ctrl,
                  itemCount: items.length,
                  itemBuilder: (ctx, i) {
                    final item = items[i];
                    if (widget.multi) {
                      return CheckboxListTile(
                        value: _isSelected(item),
                        onChanged: (_) => _toggle(item),
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(widget.labelBuilder(item)),
                        subtitle: Text(widget.subtitleBuilder(item)),
                      );
                    }
                    return ListTile(
                      title: Text(widget.labelBuilder(item)),
                      subtitle: Text(widget.subtitleBuilder(item)),
                      onTap: () => Navigator.pop(context, item),
                    );
                  },
                );
              },
            ),
          ),
          if (widget.multi)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
                child: Row(
                  children: [
                    Expanded(child: Text('${_selected.length} selected')),
                    ElevatedButton(
                      onPressed: () => Navigator.pop(context, List<T>.from(_selected)),
                      child: const Text('Done'),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
