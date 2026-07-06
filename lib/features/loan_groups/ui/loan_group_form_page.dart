import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/api/api_client.dart';
import '../../../core/widgets/common.dart';
import '../data/loan_group_repo.dart';

class LoanGroupFormPage extends ConsumerStatefulWidget {
  final String? id;
  const LoanGroupFormPage({super.key, this.id});
  @override
  ConsumerState<LoanGroupFormPage> createState() => _LoanGroupFormPageState();
}

const _roleLabels = {
  'ORG_ADMIN': 'Admin',
  'MANAGER': 'Manager',
  'FIELD_OFFICER': 'Field Officer',
  'CASHIER': 'Cashier',
  'ACCOUNTANT': 'Accountant',
  'VIEWER': 'Viewer',
};

const _tenureLabels = {
  'DAILY': 'Tenure (days)',
  'WEEKLY': 'Tenure (weeks)',
  'MONTHLY': 'Tenure (months)',
};

class _LoanGroupFormPageState extends ConsumerState<LoanGroupFormPage> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _desc = TextEditingController();
  final _leaderName = TextEditingController();
  final _leaderPhone = TextEditingController();
  final _meetingDay = TextEditingController();
  final _meetingTime = TextEditingController();
  final _meetingPlace = TextEditingController();
  final _memberCount = TextEditingController();
  final _cycle = TextEditingController();
  final _interestRate = TextEditingController();
  final _tenure = TextEditingController();
  final _processingFee = TextEditingController();
  String _emiFrequency = 'WEEKLY';
  String _interestType = 'FLAT';
  bool _deductUpfront = false;
  String? _assignedToId;
  Map<String, dynamic>? _groupAssignee; // from the group GET, in case not in _team yet
  List<Map<String, dynamic>> _team = [];
  bool _saving = false;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    if (widget.id != null) _load();
    _loadTeam();
  }

  Future<void> _loadTeam() async {
    try {
      final api = ref.read(apiClientProvider);
      final d = await api.get('/team', query: {'limit': 500});
      final list = (d is List ? d : (d is Map && d['data'] is List ? d['data'] : const [])) as List;
      if (!mounted) return;
      setState(() => _team = list
          .map<Map<String, dynamic>>((e) => Map<String, dynamic>.from(e as Map))
          .where((u) => u['isActive'] == true)
          .toList());
    } catch (_) {
      // Dropdown just stays empty — the assignee is optional.
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final g = await ref.read(loanGroupRepoProvider).get(widget.id!);
      _name.text = g['name']?.toString() ?? '';
      _desc.text = g['description']?.toString() ?? '';
      _leaderName.text = g['leaderName']?.toString() ?? '';
      _leaderPhone.text = g['leaderPhone']?.toString() ?? '';
      _meetingDay.text = g['meetingDay']?.toString() ?? '';
      _meetingTime.text = g['meetingTime']?.toString() ?? '';
      _meetingPlace.text = g['meetingPlace']?.toString() ?? '';
      _memberCount.text = g['memberCount']?.toString() ?? '';
      _cycle.text = g['cycle']?.toString() ?? '';
      _interestRate.text = g['interestRate']?.toString() ?? '';
      _tenure.text = g['tenure']?.toString() ?? '';
      _processingFee.text = g['processingFee']?.toString() ?? '';
      _emiFrequency = _tenureLabels.containsKey(g['emiFrequency']) ? g['emiFrequency'] as String : 'WEEKLY';
      _interestType = g['interestType'] == 'REDUCING' ? 'REDUCING' : 'FLAT';
      _deductUpfront = g['deductInterestUpfront'] == true;
      _assignedToId = g['assignedToId']?.toString();
      _groupAssignee = g['assignedTo'] is Map ? Map<String, dynamic>.from(g['assignedTo'] as Map) : null;
    } catch (e) {
      showToast('Load failed: $e', error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final body = {
        'name': _name.text.trim(),
        if (_desc.text.trim().isNotEmpty) 'description': _desc.text.trim(),
        if (_leaderName.text.trim().isNotEmpty) 'leaderName': _leaderName.text.trim(),
        if (_leaderPhone.text.trim().isNotEmpty) 'leaderPhone': _leaderPhone.text.trim(),
        if (_meetingDay.text.trim().isNotEmpty) 'meetingDay': _meetingDay.text.trim(),
        if (_meetingTime.text.trim().isNotEmpty) 'meetingTime': _meetingTime.text.trim(),
        if (_meetingPlace.text.trim().isNotEmpty) 'meetingPlace': _meetingPlace.text.trim(),
        if (_memberCount.text.trim().isNotEmpty) 'memberCount': int.tryParse(_memberCount.text.trim()),
        if (_cycle.text.trim().isNotEmpty) 'cycle': _cycle.text.trim(),
        // Loan-term defaults — explicit nulls so clearing a value on edit sticks.
        'interestRate': _interestRate.text.trim().isEmpty ? null : double.tryParse(_interestRate.text.trim()),
        'tenure': _tenure.text.trim().isEmpty ? null : int.tryParse(_tenure.text.trim()),
        'emiFrequency': _emiFrequency,
        'interestType': _interestType,
        // Upfront deduction only applies to flat-rate interest (same rule as loans).
        'deductInterestUpfront': _interestType == 'FLAT' && _deductUpfront,
        'processingFee': _processingFee.text.trim().isEmpty ? null : double.tryParse(_processingFee.text.trim()),
        'assignedToId': _assignedToId,
      };
      final repo = ref.read(loanGroupRepoProvider);
      if (widget.id == null) {
        await repo.create(body);
        showToast('Group created');
      } else {
        await repo.update(widget.id!, body);
        showToast('Group updated');
      }
      if (mounted) context.go('/loan-groups');
    } on ApiException catch (e) {
      showToast(e.message, error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  // Every active team member (Admin and Manager included) can hold a group. If the
  // group's current assignee isn't in the fetched list yet (still loading, or the
  // member was deactivated), keep them as an extra item so the dropdown stays valid.
  List<DropdownMenuItem<String?>> get _assigneeItems {
    final items = <DropdownMenuItem<String?>>[
      const DropdownMenuItem(value: null, child: Text('Unassigned')),
      for (final m in _team)
        DropdownMenuItem(
          value: m['id']?.toString(),
          child: Text('${m['name']} (${_roleLabels[m['role']] ?? m['role']})', overflow: TextOverflow.ellipsis),
        ),
    ];
    if (_assignedToId != null && !_team.any((m) => m['id']?.toString() == _assignedToId)) {
      items.add(DropdownMenuItem(
        value: _assignedToId,
        child: Text(_groupAssignee?['name']?.toString() ?? 'Current assignee'),
      ));
    }
    return items;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return Scaffold(appBar: AppBar(title: const Text('Group')), body: const LoadingView());
    return Scaffold(
      appBar: AppBar(title: Text(widget.id == null ? 'New Group' : 'Edit Group')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(14),
          children: [
            SectionCard(
              title: 'Group Details',
              child: Column(
                children: [
                  TextFormField(controller: _name, decoration: const InputDecoration(labelText: 'Name *'), validator: (v) => v?.trim().isEmpty == true ? 'Required' : null),
                  const SizedBox(height: 10),
                  TextFormField(controller: _desc, maxLines: 2, decoration: const InputDecoration(labelText: 'Description')),
                  const SizedBox(height: 10),
                  TextFormField(controller: _leaderName, decoration: const InputDecoration(labelText: 'Leader Name')),
                  const SizedBox(height: 10),
                  TextFormField(controller: _leaderPhone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Leader Phone')),
                  const SizedBox(height: 10),
                  TextFormField(controller: _memberCount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Number of Members')),
                  const SizedBox(height: 10),
                  TextFormField(controller: _cycle, decoration: const InputDecoration(labelText: 'Cycle')),
                ],
              ),
            ),
            SectionCard(
              title: 'Loan Terms',
              child: Column(
                children: [
                  DropdownButtonFormField<String?>(
                    key: ValueKey('assignee-${_team.length}-$_assignedToId'),
                    initialValue: _assignedToId,
                    decoration: const InputDecoration(labelText: 'Assigned To'),
                    items: _assigneeItems,
                    onChanged: (v) => setState(() => _assignedToId = v),
                  ),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: _interestRate,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(labelText: 'Interest Rate (%)'),
                    validator: (v) {
                      final t = v?.trim() ?? '';
                      if (t.isEmpty) return null;
                      final n = double.tryParse(t);
                      return n == null || n < 0 ? 'Invalid rate' : null;
                    },
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _tenure,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(labelText: _tenureLabels[_emiFrequency] ?? 'Tenure'),
                          validator: (v) {
                            final t = v?.trim() ?? '';
                            if (t.isEmpty) return null;
                            final n = int.tryParse(t);
                            return n == null || n < 1 ? 'Min 1' : null;
                          },
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: _emiFrequency,
                          decoration: const InputDecoration(labelText: 'EMI Frequency'),
                          items: const [
                            DropdownMenuItem(value: 'DAILY', child: Text('DAILY')),
                            DropdownMenuItem(value: 'WEEKLY', child: Text('WEEKLY')),
                            DropdownMenuItem(value: 'MONTHLY', child: Text('MONTHLY')),
                          ],
                          onChanged: (v) => setState(() => _emiFrequency = v ?? 'WEEKLY'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: _interestType,
                    decoration: const InputDecoration(labelText: 'Interest Calculation'),
                    items: const [
                      DropdownMenuItem(value: 'REDUCING', child: Text('Reducing Balance (interest on outstanding)')),
                      DropdownMenuItem(value: 'FLAT', child: Text('Flat Rate (interest on full principal)')),
                    ],
                    onChanged: (v) => setState(() {
                      _interestType = v ?? 'FLAT';
                      if (_interestType != 'FLAT') _deductUpfront = false;
                    }),
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
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: _processingFee,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Processing Fee', prefixText: '₹ '),
                    validator: (v) {
                      final t = v?.trim() ?? '';
                      if (t.isEmpty) return null;
                      final n = double.tryParse(t);
                      return n == null || n < 0 ? 'Invalid amount' : null;
                    },
                  ),
                ],
              ),
            ),
            SectionCard(
              title: 'Meeting',
              child: Column(
                children: [
                  TextFormField(controller: _meetingDay, decoration: const InputDecoration(labelText: 'Meeting Day (e.g. Monday)')),
                  const SizedBox(height: 10),
                  TextFormField(controller: _meetingTime, decoration: const InputDecoration(labelText: 'Meeting Time')),
                  const SizedBox(height: 10),
                  TextFormField(controller: _meetingPlace, decoration: const InputDecoration(labelText: 'Meeting Place')),
                ],
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saving ? null : _save,
                child: Text(_saving ? 'Saving...' : (widget.id == null ? 'Create Group' : 'Update Group')),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
