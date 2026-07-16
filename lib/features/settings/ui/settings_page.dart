import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import '../../../core/api/api_client.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/common.dart';
import '../../app_shell.dart';
import '../../../core/widgets/app_bottom_nav.dart';

// Per-role visibility catalog for the "Chitfund Settings" editor. KEEP IN SYNC with the
// web constants (finance/src/utils/constants.js) and the backend catalog
// (finance-backend/src/utils/uiVisibility.js). Roles an admin can restrict (ORG_ADMIN
// always sees everything); a ticked box = visible.
const _uiVisibilityRoles = ['MANAGER', 'FIELD_OFFICER', 'CASHIER', 'ACCOUNTANT', 'VIEWER'];
const _uiRoleLabels = {
  'MANAGER': 'Manager',
  'FIELD_OFFICER': 'Field Officer',
  'CASHIER': 'Cashier',
  'ACCOUNTANT': 'Accountant',
  'VIEWER': 'Viewer',
};
const _uiVisibilityItems = <Map<String, String>>[
  {'key': 'chitfund.edit', 'label': 'Edit button', 'group': 'Chitfund · Actions'},
  {'key': 'chitfund.reassign', 'label': 'Reassign Officer button', 'group': 'Chitfund · Actions'},
  {'key': 'chitfund.totalCollected', 'label': 'Total Collected', 'group': 'Chitfund · Financials'},
  {'key': 'chitfund.totalDue', 'label': 'Total Due', 'group': 'Chitfund · Financials'},
  {'key': 'chitfund.collected', 'label': 'Collected', 'group': 'Chitfund · Financials'},
  {'key': 'chitfund.outstanding', 'label': 'Outstanding', 'group': 'Chitfund · Financials'},
  {'key': 'chitfund.payouts', 'label': 'Payouts', 'group': 'Chitfund · Financials'},
  {'key': 'chitfund.tab.timeline', 'label': 'Timeline tab', 'group': 'Chitfund · Tabs'},
  {'key': 'chitfund.tab.members', 'label': 'Members tab', 'group': 'Chitfund · Tabs'},
  {'key': 'chitfund.tab.auctions', 'label': 'Auctions tab', 'group': 'Chitfund · Tabs'},
  {'key': 'chitfund.tab.payments', 'label': 'Payments tab', 'group': 'Chitfund · Tabs'},
  {'key': 'chitfund.tab.payouts', 'label': 'Payouts tab', 'group': 'Chitfund · Tabs'},
  {'key': 'dashboard.daySummary', 'label': 'Day Summary', 'group': 'Dashboard'},
  {'key': 'dashboard.memberDues', 'label': 'Member Dues', 'group': 'Dashboard'},
  {'key': 'dashboard.dayReport', 'label': 'Day Report', 'group': 'Dashboard'},
  {'key': 'dashboard.auctionsToConduct', 'label': 'Auctions To Conduct', 'group': 'Dashboard'},
  {'key': 'dashboard.auctionPayouts', 'label': 'Auction Payouts', 'group': 'Dashboard'},
];
// Items hidden by default when no explicit policy exists for a role. Only FIELD_OFFICER
// has defaults — the chitfund action + financial items. Mirrors DEFAULT_HIDDEN backend-side.
const _uiVisibilityDefaultHidden = <String, List<String>>{
  'FIELD_OFFICER': [
    'chitfund.edit', 'chitfund.reassign', 'chitfund.totalCollected', 'chitfund.totalDue',
    'chitfund.collected', 'chitfund.outstanding', 'chitfund.payouts',
  ],
};

// Effective visibility of one item for a role under a policy: explicit boolean if present,
// else the code default. Used to seed the editor checkboxes.
bool _isUiVisible(Map uiVisibility, String role, String key) {
  if (role == 'ORG_ADMIN') return true;
  final explicit = (uiVisibility[role] as Map?)?[key];
  if (explicit is bool) return explicit;
  return !((_uiVisibilityDefaultHidden[role] ?? const []).contains(key));
}

class SettingsPage extends ConsumerStatefulWidget {
  const SettingsPage({super.key});
  @override
  ConsumerState<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends ConsumerState<SettingsPage> {
  final _companyName = TextEditingController();
  final _tagline = TextEditingController();
  final _address = TextEditingController();
  final _phone = TextEditingController();
  final _receiptPrefix = TextEditingController();
  final _loanPrefix = TextEditingController();
  final _customerPrefix = TextEditingController();
  final _savingsPrefix = TextEditingController();
  final _defaultRate = TextEditingController();
  final _defaultLateFee = TextEditingController();
  final _processingFee = TextEditingController();
  final _gracePeriodDays = TextEditingController();
  bool _hydrated = false;
  Map<String, dynamic>? _settings;
  Map<String, dynamic>? _features;
  Map<String, dynamic>? _subscription;
  Object? _error;
  bool _loading = true;
  bool _saving = false;
  File? _logoFile;

  // Loan customer filter (web: ALL | NEW_OR_CLOSED). Backend accepts `loanCustomerFilter`.
  static const _customerFilters = <List<String>>[
    ['ALL', 'Show all customers'],
    ['NEW_OR_CLOSED', 'Only new or loan-closed customers'],
  ];
  String _loanCustomerFilter = 'ALL';

  // Master switch for editing collections (web: allowCollectionEdit). When off, no
  // collection can be edited or removed; when on, pending edits are allowed and verified
  // edits follow _verifiedCollectionEditPolicy below.
  bool _allowCollectionEdit = false;
  // When a VERIFIED collection may still be edited (only applies once editing is on).
  // Backend accepts `verifiedCollectionEditPolicy`.
  static const _verifiedEditPolicies = <List<String>>[
    ['ALWAYS', 'Always', 'A verified collection can be edited at any time.'],
    ['WINDOW_24H', 'Only within 24 hours', 'Editable only within 24 hours of verification.'],
    ['NEVER', 'Never', 'Once verified, a collection is locked.'],
  ];
  String _verifiedCollectionEditPolicy = 'WINDOW_24H';
  // Lets a field officer correct their OWN collection until it's verified. Independent of
  // _allowCollectionEdit (which governs admin edits of already-verified collections).
  bool _allowFieldOfficerCollectionEdit = true;
  // When true, a PENDING (unverified) collection already lowers the loan's shown balance.
  bool _includePendingInBalance = false;
  // When true (default), the customer number shows under the name in listings.
  bool _showCustomerNumber = true;

  // Per-role visibility of sensitive loan financials (web: Loan Settings → Field
  // Visibility). KEEP IN SYNC with finance-backend/src/utils/loanVisibility.js. Shape:
  // { ROLE: { fieldKey: false } } — a field is hidden from a role only when explicitly
  // false; absent = visible. ORG_ADMIN is never restricted.
  static const _loanFieldItems = <List<String>>[
    ['interestRate', 'Interest Rate'],
    ['totalInterest', 'Total / Upfront Interest'],
    ['processingFee', 'Processing Fee'],
    ['totalPayable', 'Total Payable / Net Disbursed'],
  ];
  Map<String, dynamic> _loanFieldVisibility = {};

  // Collection defaults (web sends flat `defaultCollectionDays` (List<int>) + `defaultWeeklyDay` (int)).
  // Day values: 0=Sun .. 6=Sat (matches web).
  static const _weekDays = <List<dynamic>>[
    [1, 'Mon'],
    [2, 'Tue'],
    [3, 'Wed'],
    [4, 'Thu'],
    [5, 'Fri'],
    [6, 'Sat'],
    [0, 'Sun'],
  ];
  Set<int> _collectionDays = {1, 2, 3, 4, 5, 6};
  int _weeklyDay = 1;

  // Notification preferences (web sends nested `notifications: {...}`).
  final Map<String, bool> _notifications = {
    'emailOnCollection': true,
    'emailOnLoanApproval': true,
    'smsOnEmiReminder': false,
    'smsOnOverdue': false,
  };

  static const _loanTypes = <List<String>>[
    ['PERSONAL', 'Personal'],
    ['GOLD', 'Gold'],
    ['VEHICLE', 'Vehicle'],
    ['PROPERTY', 'Property/Mortgage'],
    ['BUSINESS', 'Business'],
    ['AGRICULTURE', 'Agriculture'],
    ['EDUCATION', 'Education'],
    ['DAILY', 'Daily'],
    ['WEEKLY', 'Weekly'],
    ['GROUP', 'Group'],
  ];
  static const _policyValues = ['REQUIRED', 'OPTIONAL', 'HIDDEN'];
  String _suretyDefault = 'OPTIONAL';
  final Map<String, String> _suretyByType = {};

  // Per-role chitfund/dashboard UI visibility (ORG_ADMIN only). Shape:
  // { ROLE: { 'chitfund.edit': false } }. Stored value is "visible?".
  Map<String, dynamic> _uiVisibility = {};
  bool _savingVisibility = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _error = null; });
    try {
      final api = ref.read(apiClientProvider);
      final results = await Future.wait([
        api.get('/settings'),
        api.get('/settings/features'),
        // Subscription is read-only; tolerate failure (non-admin roles may be forbidden).
        api.get('/settings/subscription').then<dynamic>((v) => v).catchError((_) => null),
      ]);
      final s = Map<String, dynamic>.from(results[0] as Map);
      final f = Map<String, dynamic>.from(results[1] as Map);
      final sub = results[2] is Map ? Map<String, dynamic>.from(results[2] as Map) : null;
      if (!_hydrated) {
        _companyName.text = s['companyName']?.toString() ?? '';
        _tagline.text = s['tagline']?.toString() ?? '';
        _address.text = s['address']?.toString() ?? '';
        _phone.text = s['phone']?.toString() ?? '';
        _receiptPrefix.text = s['receiptPrefix']?.toString() ?? '';
        _loanPrefix.text = s['loanNumberPrefix']?.toString() ?? '';
        _customerPrefix.text = s['customerPrefix']?.toString() ?? '';
        _savingsPrefix.text = s['savingsPrefix']?.toString() ?? '';
        _defaultRate.text = s['defaultInterestRate']?.toString() ?? '';
        _defaultLateFee.text = s['defaultLateFee']?.toString() ?? '';
        _processingFee.text = s['defaultProcessingFee']?.toString() ?? '';
        _gracePeriodDays.text = s['gracePeriodDays']?.toString() ?? '';
        final filter = s['loanCustomerFilter']?.toString();
        _loanCustomerFilter = _customerFilters.any((c) => c[0] == filter) ? filter! : 'ALL';
        final vcep = s['verifiedCollectionEditPolicy']?.toString();
        _verifiedCollectionEditPolicy = _verifiedEditPolicies.any((p) => p[0] == vcep) ? vcep! : 'WINDOW_24H';
        _allowCollectionEdit = s['allowCollectionEdit'] == true;
        _allowFieldOfficerCollectionEdit = s['allowFieldOfficerCollectionEdit'] != false;
        _includePendingInBalance = s['includePendingInBalance'] == true;
        _showCustomerNumber = s['showCustomerNumber'] != false;
        final lfv = s['loanFieldVisibility'];
        if (lfv is Map) _loanFieldVisibility = Map<String, dynamic>.from(lfv);
        final days = s['defaultCollectionDays'];
        if (days is List) {
          _collectionDays = days.map((e) => (e as num).toInt()).toSet();
        }
        final wd = s['defaultWeeklyDay'];
        if (wd is num) _weeklyDay = wd.toInt();
        final notifs = (s['notifications'] as Map?) ?? const {};
        for (final key in _notifications.keys.toList()) {
          if (notifs[key] is bool) _notifications[key] = notifs[key] as bool;
        }
        final policy = (s['suretyPolicy'] as Map?) ?? const {};
        _suretyDefault = _policyValues.contains(policy['default']) ? policy['default'] as String : 'OPTIONAL';
        _suretyByType.clear();
        final by = (policy['byLoanType'] as Map?) ?? const {};
        by.forEach((k, v) {
          if (v is String && _policyValues.contains(v)) _suretyByType[k.toString()] = v;
        });
        final vis = s['uiVisibility'];
        if (vis is Map) _uiVisibility = Map<String, dynamic>.from(vis);
        _hydrated = true;
      }
      if (mounted) setState(() { _settings = s; _features = f; _subscription = sub; _loading = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e; _loading = false; });
    }
  }

  Future<void> _pickLogo() async {
    final x = await ImagePicker().pickImage(source: ImageSource.gallery, maxWidth: 512, imageQuality: 85);
    if (x != null) setState(() => _logoFile = File(x.path));
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    try {
      final api = ref.read(apiClientProvider);
      await api.put('/settings', data: {
        'companyName': _companyName.text.trim(),
        'tagline': _tagline.text.trim(),
        'address': _address.text.trim(),
        'phone': _phone.text.trim(),
        // Numbering (match web keys exactly)
        'receiptPrefix': _receiptPrefix.text.trim(),
        'loanNumberPrefix': _loanPrefix.text.trim(),
        'customerPrefix': _customerPrefix.text.trim(),
        'savingsPrefix': _savingsPrefix.text.trim(),
        // Defaults
        if (_defaultRate.text.trim().isNotEmpty) 'defaultInterestRate': double.tryParse(_defaultRate.text.trim()),
        if (_defaultLateFee.text.trim().isNotEmpty) 'defaultLateFee': double.tryParse(_defaultLateFee.text.trim()),
        if (_processingFee.text.trim().isNotEmpty) 'defaultProcessingFee': double.tryParse(_processingFee.text.trim()),
        if (_gracePeriodDays.text.trim().isNotEmpty) 'gracePeriodDays': int.tryParse(_gracePeriodDays.text.trim()),
        // Loan customer filter
        'loanCustomerFilter': _loanCustomerFilter,
        // Collection edit controls
        'allowCollectionEdit': _allowCollectionEdit,
        'verifiedCollectionEditPolicy': _verifiedCollectionEditPolicy,
        'allowFieldOfficerCollectionEdit': _allowFieldOfficerCollectionEdit,
        'includePendingInBalance': _includePendingInBalance,
        'showCustomerNumber': _showCustomerNumber,
        // Per-role loan field visibility (nested, like web)
        'loanFieldVisibility': _loanFieldVisibility,
        // Collection defaults (flat keys, like web)
        'defaultCollectionDays': (_collectionDays.toList()..sort()),
        'defaultWeeklyDay': _weeklyDay,
        // Notification preferences (nested, like web)
        'notifications': Map<String, bool>.from(_notifications),
        'suretyPolicy': {
          'default': _suretyDefault,
          'byLoanType': Map<String, String>.from(_suretyByType),
        },
      });
      if (_logoFile != null) {
        final form = FormData.fromMap({'logo': await MultipartFile.fromFile(_logoFile!.path)});
        await api.post('/settings/logo', data: form);
      }
      // Sync collection-edit settings into the cached session so the receipt Edit
      // button reflects them immediately (mirrors the web's updateOrg).
      await ref.read(authProvider.notifier).updateOrgSettings(
            allowCollectionEdit: _allowCollectionEdit,
            verifiedCollectionEditPolicy: _verifiedCollectionEditPolicy,
            allowFieldOfficerCollectionEdit: _allowFieldOfficerCollectionEdit,
          );
      showToast('Settings saved');
      _load();
    } on ApiException catch (e) {
      showToast(e.message, error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _toggleFeature(String key, bool value) async {
    try {
      final api = ref.read(apiClientProvider);
      final res = await api.put('/settings/features', data: {key: value}) as Map;
      final org = Map<String, dynamic>.from(res['org'] ?? {});
      final features = Map<String, dynamic>.from(org['features'] ?? {});
      final boolFeatures = <String, bool>{for (final e in features.entries) e.key: e.value == true};
      await ref.read(authProvider.notifier).updateOrgFeatures(boolFeatures);
      _load();
    } on ApiException catch (e) {
      showToast(e.message, error: true);
    }
  }

  // Toggle one item's visibility for a role. Stores the explicit "visible?" boolean so an
  // admin can re-show a FIELD_OFFICER default or hide a default-visible item.
  void _toggleUiVisible(String role, String key) {
    setState(() {
      final next = Map<String, dynamic>.from(_uiVisibility);
      final roleMap = Map<String, dynamic>.from(next[role] as Map? ?? const {});
      roleMap[key] = !_isUiVisible(_uiVisibility, role, key);
      next[role] = roleMap;
      _uiVisibility = next;
    });
  }

  Future<void> _saveVisibility() async {
    setState(() => _savingVisibility = true);
    try {
      await ref.read(apiClientProvider).put('/settings', data: {'uiVisibility': _uiVisibility});
      showToast('Visibility settings saved');
    } on ApiException catch (e) {
      showToast(e.message, error: true);
    } finally {
      if (mounted) setState(() => _savingVisibility = false);
    }
  }

  Widget _visibilitySection() {
    final groups = <String>[];
    for (final it in _uiVisibilityItems) {
      final g = it['group']!;
      if (!groups.contains(g)) groups.add(g);
    }
    return SectionCard(
      title: 'Chitfund Settings',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Choose which chitfund and dashboard elements each role can see. Untick a box to '
            'hide that item from the role. Organisation admins always see everything. The money '
            'figures are also stripped from API responses for roles that can’t see them. '
            'Changes apply on the user’s next login.',
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 14),
          ...groups.map(_visibilityGroup),
          const SizedBox(height: 4),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _savingVisibility ? null : _saveVisibility,
              icon: const Icon(Icons.save),
              label: Text(_savingVisibility ? 'Saving...' : 'Save Visibility'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _visibilityGroup(String group) {
    final items = _uiVisibilityItems.where((i) => i['group'] == group).toList();
    const labelW = 150.0;
    const cellW = 58.0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(group, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const SizedBox(width: labelW),
                    ..._uiVisibilityRoles.map((r) => SizedBox(
                          width: cellW,
                          child: Text(_uiRoleLabels[r] ?? r,
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
                        )),
                  ],
                ),
                const SizedBox(height: 2),
                ...items.map((it) {
                  final key = it['key']!;
                  return Row(
                    children: [
                      SizedBox(width: labelW, child: Text(it['label']!, style: const TextStyle(fontSize: 12))),
                      ..._uiVisibilityRoles.map((r) => SizedBox(
                            width: cellW,
                            height: 40,
                            child: Checkbox(
                              value: _isUiVisible(_uiVisibility, r, key),
                              visualDensity: VisualDensity.compact,
                              onChanged: (_) => _toggleUiVisible(r, key),
                            ),
                          )),
                    ],
                  );
                }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // Loan Settings card: collection edit master switch + verified-edit policy + the
  // pending-in-balance and customer-number display toggles. Mirrors the web Loan Settings.
  Widget _loanSettingsSection() {
    return SectionCard(
      title: 'Loan Settings',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SwitchListTile(
            title: const Text('Allow editing collections'),
            subtitle: const Text(
                'Off: collections are locked once recorded. On: pending collections can be corrected; verified ones follow the policy below.'),
            contentPadding: EdgeInsets.zero,
            value: _allowCollectionEdit,
            onChanged: (v) => setState(() => _allowCollectionEdit = v),
          ),
          Opacity(
            opacity: _allowCollectionEdit ? 1 : 0.4,
            child: IgnorePointer(
              ignoring: !_allowCollectionEdit,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Padding(
                    padding: EdgeInsets.only(top: 6, bottom: 2),
                    child: Text('After verification, allow edits',
                        style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
                  ),
                  ..._verifiedEditPolicies.map((p) {
                    final selected = _verifiedCollectionEditPolicy == p[0];
                    return InkWell(
                      onTap: () => setState(() => _verifiedCollectionEditPolicy = p[0]),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 6),
                        child: Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Icon(
                              selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                              color: selected ? AppColors.primary : AppColors.textSecondary,
                              size: 20,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(p[1]),
                                  Text(p[2], style: const TextStyle(color: AppColors.textSecondary, fontSize: 11)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                ],
              ),
            ),
          ),
          const Divider(),
          SwitchListTile(
            title: const Text('Allow field officers to edit before verification'),
            subtitle: const Text(
                'On: a field officer can correct their own collection until it is verified. Off: field officers cannot edit collections. Works independently of the master switch above.'),
            contentPadding: EdgeInsets.zero,
            value: _allowFieldOfficerCollectionEdit,
            onChanged: (v) => setState(() => _allowFieldOfficerCollectionEdit = v),
          ),
          const Divider(),
          SwitchListTile(
            title: const Text('Count pending collections in balance'),
            subtitle: const Text(
                'On: a payment lowers the loan balance as soon as it is recorded, before verification.'),
            contentPadding: EdgeInsets.zero,
            value: _includePendingInBalance,
            onChanged: (v) => setState(() => _includePendingInBalance = v),
          ),
          SwitchListTile(
            title: const Text('Show customer number in listings'),
            subtitle: const Text('Show the customer number under the name on lists and collection search.'),
            contentPadding: EdgeInsets.zero,
            value: _showCustomerNumber,
            onChanged: (v) => setState(() => _showCustomerNumber = v),
          ),
        ],
      ),
    );
  }

  // Effective visibility of a loan financial field for a role: explicit boolean if set,
  // else visible. ORG_ADMIN always sees everything. Mirrors loanVisibility.js.
  bool _isFieldVisible(String role, String key) {
    if (role == 'ORG_ADMIN') return true;
    final explicit = (_loanFieldVisibility[role] as Map?)?[key];
    return explicit is bool ? explicit : true;
  }

  void _toggleFieldVisible(String role, String key) {
    setState(() {
      final next = Map<String, dynamic>.from(_loanFieldVisibility);
      final roleMap = Map<String, dynamic>.from(next[role] as Map? ?? const {});
      roleMap[key] = !_isFieldVisible(role, key);
      next[role] = roleMap;
      _loanFieldVisibility = next;
    });
  }

  // Per-role matrix controlling which sensitive loan financials each role can see.
  // Saved with the main Save button. Mirrors the web Loan Settings → Field Visibility.
  Widget _fieldVisibilitySection() {
    const labelW = 150.0;
    const cellW = 58.0;
    return SectionCard(
      title: 'Loan Field Visibility',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Choose which sensitive loan figures each role can see. Untick a box to hide that '
            'field from the role — it is also stripped from API responses. Organisation admins '
            'always see everything. Changes apply on the user’s next login.',
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 12),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const SizedBox(width: labelW),
                    ..._uiVisibilityRoles.map((r) => SizedBox(
                          width: cellW,
                          child: Text(_uiRoleLabels[r] ?? r,
                              textAlign: TextAlign.center,
                              style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: AppColors.textSecondary)),
                        )),
                  ],
                ),
                const SizedBox(height: 2),
                ..._loanFieldItems.map((it) {
                  final key = it[0];
                  return Row(
                    children: [
                      SizedBox(width: labelW, child: Text(it[1], style: const TextStyle(fontSize: 12))),
                      ..._uiVisibilityRoles.map((r) => SizedBox(
                            width: cellW,
                            height: 40,
                            child: Checkbox(
                              value: _isFieldVisible(r, key),
                              visualDensity: VisualDensity.compact,
                              onChanged: (_) => _toggleFieldVisible(r, key),
                            ),
                          )),
                    ],
                  );
                }),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      drawer: const AppDrawer(),
      bottomNavigationBar: const AppBottomNav(),
      appBar: AppBar(
        title: const Text('Settings'),
        leading: Builder(
          builder: (ctx) => IconButton(icon: const Icon(Icons.menu), onPressed: () => Scaffold.of(ctx).openDrawer()),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.shield_outlined),
            tooltip: 'Roles & Permissions',
            onPressed: () => context.push('/settings/roles'),
          ),
        ],
      ),
      body: _loading
          ? const LoadingView()
          : _error != null
              ? ErrorView(message: _error.toString(), onRetry: _load)
              : _buildBody(_settings ?? const {}, _features ?? const {}),
    );
  }

  Widget _buildBody(Map<String, dynamic> s, Map<String, dynamic> f) {
    // Role gating mirrors the web Settings config: changing settings requires ORG_ADMIN
    // (PUT /settings is ORG_ADMIN-only on the backend); the subscription view is for
    // ORG_ADMIN + MANAGER. Non-admins see the values read-only.
    final role = ref.read(authProvider).user?.role;
    final isAdmin = role == 'ORG_ADMIN';
    final isAdminOrManager = isAdmin || role == 'MANAGER';
    return ListView(
      padding: const EdgeInsets.all(14),
      children: [
        SectionCard(
          title: 'Branding',
          child: Column(
            children: [
              Row(
                children: [
                  InkWell(
                    onTap: _pickLogo,
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: AppColors.bg,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.border),
                      ),
                      child: _logoFile != null
                          ? ClipRRect(borderRadius: BorderRadius.circular(10), child: Image.file(_logoFile!, fit: BoxFit.cover))
                          : const Icon(Icons.image_outlined, size: 32, color: AppColors.textSecondary),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _pickLogo,
                      icon: const Icon(Icons.upload),
                      label: const Text('Choose Logo'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(controller: _companyName, decoration: const InputDecoration(labelText: 'Company Name')),
              const SizedBox(height: 10),
              TextField(controller: _tagline, decoration: const InputDecoration(labelText: 'Tagline')),
              const SizedBox(height: 10),
              TextField(controller: _address, maxLines: 2, decoration: const InputDecoration(labelText: 'Address')),
              const SizedBox(height: 10),
              TextField(controller: _phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone')),
            ],
          ),
        ),
        SectionCard(
          title: 'Numbering',
          child: Column(
            children: [
              TextField(controller: _loanPrefix, decoration: const InputDecoration(labelText: 'Loan Number Prefix')),
              const SizedBox(height: 10),
              TextField(controller: _customerPrefix, decoration: const InputDecoration(labelText: 'Customer Prefix')),
              const SizedBox(height: 10),
              TextField(controller: _receiptPrefix, decoration: const InputDecoration(labelText: 'Receipt Prefix')),
              const SizedBox(height: 10),
              TextField(controller: _savingsPrefix, decoration: const InputDecoration(labelText: 'Savings Prefix')),
            ],
          ),
        ),
        SectionCard(
          title: 'Default Loan Settings',
          child: Column(
            children: [
              TextField(controller: _defaultRate, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Default Interest Rate (%)')),
              const SizedBox(height: 10),
              TextField(controller: _defaultLateFee, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Default Late Fee')),
              const SizedBox(height: 10),
              TextField(controller: _processingFee, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Processing Fee (%)')),
              const SizedBox(height: 10),
              TextField(controller: _gracePeriodDays, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Grace Period (days)')),
              const SizedBox(height: 14),
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('Customer List Filter', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              ),
              const SizedBox(height: 4),
              ..._customerFilters.map((cf) {
                final selected = _loanCustomerFilter == cf[0];
                return InkWell(
                  onTap: () => setState(() => _loanCustomerFilter = cf[0]),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Icon(
                          selected ? Icons.radio_button_checked : Icons.radio_button_unchecked,
                          color: selected ? AppColors.primary : AppColors.textSecondary,
                          size: 20,
                        ),
                        const SizedBox(width: 10),
                        Expanded(child: Text(cf[1])),
                      ],
                    ),
                  ),
                );
              }),
            ],
          ),
        ),
        _loanSettingsSection(),
        SectionCard(
          title: 'Collection Defaults',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Default days when collections are scheduled for daily and weekly loans.',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: 12),
              const Text('Daily Loan Collection Days', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _weekDays.map((d) {
                  final val = d[0] as int;
                  final selected = _collectionDays.contains(val);
                  return FilterChip(
                    label: Text(d[1] as String),
                    selected: selected,
                    onSelected: (sel) => setState(() {
                      if (sel) {
                        _collectionDays.add(val);
                      } else {
                        _collectionDays.remove(val);
                      }
                    }),
                  );
                }).toList(),
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '${_collectionDays.length} days/week selected',
                  style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
                ),
              ),
              const SizedBox(height: 14),
              const Text('Weekly Loan Collection Day', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _weekDays.map((d) {
                  final val = d[0] as int;
                  return ChoiceChip(
                    label: Text(d[1] as String),
                    selected: _weeklyDay == val,
                    onSelected: (_) => setState(() => _weeklyDay = val),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
        SectionCard(
          title: 'Notification Preferences',
          child: Column(
            children: [
              SwitchListTile(
                title: const Text('Email on Collection'),
                subtitle: const Text('Send email when payment is collected'),
                contentPadding: EdgeInsets.zero,
                value: _notifications['emailOnCollection'] ?? false,
                onChanged: (v) => setState(() => _notifications['emailOnCollection'] = v),
              ),
              SwitchListTile(
                title: const Text('Email on Loan Approval'),
                subtitle: const Text('Send email when loan is approved'),
                contentPadding: EdgeInsets.zero,
                value: _notifications['emailOnLoanApproval'] ?? false,
                onChanged: (v) => setState(() => _notifications['emailOnLoanApproval'] = v),
              ),
              SwitchListTile(
                title: const Text('SMS EMI Reminder'),
                subtitle: const Text('Send SMS reminder before EMI due date'),
                contentPadding: EdgeInsets.zero,
                value: _notifications['smsOnEmiReminder'] ?? false,
                onChanged: (v) => setState(() => _notifications['smsOnEmiReminder'] = v),
              ),
              SwitchListTile(
                title: const Text('SMS on Overdue'),
                subtitle: const Text('Send SMS when EMI becomes overdue'),
                contentPadding: EdgeInsets.zero,
                value: _notifications['smsOnOverdue'] ?? false,
                onChanged: (v) => setState(() => _notifications['smsOnOverdue'] = v),
              ),
            ],
          ),
        ),
        SectionCard(
          title: 'Surety / Guarantor Policy',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.only(bottom: 8),
                child: Text(
                  'Control whether surety info is required, optional, or hidden when creating a loan. The default applies to any loan type not set explicitly.',
                  style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
                ),
              ),
              _suretyRow('Default (all types)', null, _suretyDefault, (v) => setState(() => _suretyDefault = v)),
              const Divider(),
              ..._loanTypes.map((lt) => _suretyRow(
                    lt[1],
                    lt[0],
                    _suretyByType[lt[0]] ?? _suretyDefault,
                    (v) => setState(() {
                      if (v == _suretyDefault) {
                        _suretyByType.remove(lt[0]);
                      } else {
                        _suretyByType[lt[0]] = v;
                      }
                    }),
                  )),
            ],
          ),
        ),
        // Per-role loan field visibility (ORG_ADMIN only). Saved with the main button below.
        if (isAdmin) _fieldVisibilitySection(),
        // Saving any of these settings requires ORG_ADMIN (backend gates PUT /settings),
        // so the save is admin-only; other roles see the values read-only.
        if (isAdmin)
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _saving ? null : _save,
              icon: const Icon(Icons.save),
              label: Text(_saving ? 'Saving...' : 'Save Settings'),
            ),
          )
        else
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              'Only organisation admins can change these settings — shown here read-only for your role.',
              style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
          ),
        const SizedBox(height: 16),
        // Per-role chitfund/dashboard visibility editor (ORG_ADMIN only).
        if (isAdmin) _visibilitySection(),
        SectionCard(
          title: 'Features',
          child: Column(
            children: [
              SwitchListTile(
                title: const Text('Customer Portal'),
                subtitle: const Text('Allow customers to login via self-service portal'),
                contentPadding: EdgeInsets.zero,
                value: f['enableCustomerPortal'] == true,
                onChanged: isAdmin ? (v) => _toggleFeature('enableCustomerPortal', v) : null,
              ),
              SwitchListTile(
                title: const Text('Edit / Correct Loan Terms'),
                subtitle: const Text('Allow admins to correct a loan\'s terms and rebuild its EMI schedule after disbursement'),
                contentPadding: EdgeInsets.zero,
                value: f['enableLoanCorrection'] == true,
                onChanged: isAdmin ? (v) => _toggleFeature('enableLoanCorrection', v) : null,
              ),
              SwitchListTile(
                title: const Text('Expenses'),
                subtitle: const Text('Track salary payments and operational expenses'),
                contentPadding: EdgeInsets.zero,
                value: f['enableExpenses'] == true,
                onChanged: isAdmin ? (v) => _toggleFeature('enableExpenses', v) : null,
              ),
              SwitchListTile(
                title: const Text('Consolidated Balance'),
                subtitle: const Text('View customer consolidated balance sheet and manage settlement'),
                contentPadding: EdgeInsets.zero,
                value: f['enableConsolidatedBalance'] == true,
                onChanged: isAdmin ? (v) => _toggleFeature('enableConsolidatedBalance', v) : null,
              ),
              const Divider(),
              _featureReadOnly('Loans', f['enableLoans'] == true),
              _featureReadOnly('Savings', f['enableSavings'] == true),
              _featureReadOnly('Chitfunds', f['enableChitfund'] == true),
              _featureReadOnly('Investments', f['enableInvestments'] == true),
              _featureReadOnly('Reports', f['enableReports'] == true),
              _featureReadOnly('Group Loans', f['enableGroupLoan'] == true),
              const SizedBox(height: 8),
              const Text(
                'Contact support to enable/disable module features.',
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
              ),
            ],
          ),
        ),
        if (isAdminOrManager && _subscription != null) _buildSubscription(_subscription!),
      ],
    );
  }

  Widget _buildSubscription(Map<String, dynamic> sub) {
    final status = sub['subscriptionStatus']?.toString() ?? 'UNKNOWN';
    final counts = (sub['_count'] as Map?) ?? const {};
    return SectionCard(
      title: 'Subscription',
      actions: [StatusChip(label: status, color: statusColor(status == 'TRIAL' ? 'PENDING' : status))],
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          KeyValueRow(label: 'Organization', value: sub['name']?.toString() ?? '-'),
          KeyValueRow(label: 'Plan / Slug', value: sub['slug']?.toString() ?? '-'),
          KeyValueRow(label: 'Status', value: titleCase(status)),
          KeyValueRow(label: 'Billing Amount', value: formatCurrency(sub['subscriptionAmount'])),
          KeyValueRow(label: 'Billing Cycle', value: titleCase(sub['billingCycle']?.toString() ?? '-')),
          KeyValueRow(label: 'Renewal Date', value: formatDate(sub['renewalDate'])),
          KeyValueRow(label: 'Member Since', value: formatDate(sub['createdAt'])),
          const Divider(height: 24),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('Usage', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          ),
          const SizedBox(height: 6),
          KeyValueRow(label: 'Team Members', value: '${counts['users'] ?? 0}'),
          KeyValueRow(label: 'Customers', value: '${counts['customers'] ?? 0}'),
          KeyValueRow(label: 'Loans', value: '${counts['loans'] ?? 0}'),
          KeyValueRow(label: 'Savings Accounts', value: '${counts['savings'] ?? 0}'),
          const SizedBox(height: 8),
          const Text(
            'To upgrade or modify your subscription, please contact the administrator.',
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _suretyRow(String label, String? loanType, String value, ValueChanged<String> onChanged) {
    final overridden = loanType != null && _suretyByType.containsKey(loanType);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontWeight: loanType == null || overridden ? FontWeight.w600 : FontWeight.normal),
            ),
          ),
          DropdownButton<String>(
            value: value,
            underline: const SizedBox.shrink(),
            items: _policyValues
                .map((v) => DropdownMenuItem(value: v, child: Text(v[0] + v.substring(1).toLowerCase())))
                .toList(),
            onChanged: (v) { if (v != null) onChanged(v); },
          ),
        ],
      ),
    );
  }

  Widget _featureReadOnly(String name, bool enabled) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Icon(enabled ? Icons.check_circle : Icons.cancel_outlined,
              color: enabled ? AppColors.accent : AppColors.textSecondary, size: 18),
          const SizedBox(width: 10),
          Text(name),
          const Spacer(),
          StatusChip(label: enabled ? 'ENABLED' : 'DISABLED', color: enabled ? AppColors.accent : AppColors.textSecondary),
        ],
      ),
    );
  }
}
