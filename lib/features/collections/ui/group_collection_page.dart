import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';
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

class _GroupCollectionPageState extends ConsumerState<GroupCollectionPage> {
  Map<String, dynamic>? _group;
  List<Map<String, dynamic>> _loans = [];
  final Map<String, TextEditingController> _amounts = {};
  final Map<String, TextEditingController> _alrs = {};
  String _mode = 'CASH';
  final _reference = TextEditingController();
  bool _loading = false;
  bool _saving = false;

  Future<void> _pickGroup() async {
    final picked = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _GroupPicker(ref: ref),
    );
    if (picked != null) {
      setState(() { _group = picked; _loading = true; _loans = []; });
      try {
        final list = await ref.read(loanGroupRepoProvider).loans(picked['id'].toString());
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
  }

  Future<void> _submit() async {
    if (_group == null) return showToast('Select a group', error: true);
    final collections = <Map<String, dynamic>>[];
    for (final l in _loans) {
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
      // same group — clear the entered amounts (and reference) so the just-posted
      // figures can't be re-submitted by accident.
      if (mounted) {
        setState(() {
          for (final c in _amounts.values) {
            c.clear();
          }
          for (final c in _alrs.values) {
            c.clear();
          }
          _reference.clear();
        });
      }
    } on ApiException catch (e) {
      showToast(e.message, error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Group Collection')),
      body: ListView(
        padding: const EdgeInsets.all(14),
        children: [
          SectionCard(
            title: 'Group',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.groups),
              title: Text(_group == null ? 'Select Group *' : _group!['name']?.toString() ?? ''),
              trailing: const Icon(Icons.chevron_right),
              onTap: _pickGroup,
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
                children: _loans.map((l) {
                  final c = Map<String, dynamic>.from(l['customer'] ?? {});
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${c['firstName'] ?? ''} ${c['lastName'] ?? ''}'.trim(), style: const TextStyle(fontWeight: FontWeight.w500)),
                              Text('${l['loanNumber']} • EMI ${formatCurrency(l['emiAmount'])}', style: const TextStyle(fontSize: 12)),
                            ],
                          ),
                        ),
                        const SizedBox(width: 10),
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
                    ),
                  );
                }).toList(),
              ),
            ),
          if (_loans.isNotEmpty)
            SizedBox(width: double.infinity, child: ElevatedButton(onPressed: _saving ? null : _submit, child: Text(_saving ? 'Saving...' : 'Submit Group Collection'))),
        ],
      ),
    );
  }
}

class _GroupPicker extends StatefulWidget {
  final WidgetRef ref;
  const _GroupPicker({required this.ref});
  @override
  State<_GroupPicker> createState() => _GroupPickerState();
}

class _GroupPickerState extends State<_GroupPicker> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = false;

  @override
  void initState() { super.initState(); _load(); }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final r = await widget.ref.read(loanGroupRepoProvider).list(limit: 50);
      setState(() => _items = ((r['data'] as List?) ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList());
    } finally { if (mounted) setState(() => _loading = false); }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.7,
      expand: false,
      builder: (_, ctrl) => Column(
        children: [
          Padding(padding: const EdgeInsets.all(12), child: Row(children: [const Expanded(child: Text('Select Group', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600))), IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context))])),
          Expanded(
            child: _loading
                ? const LoadingView()
                : ListView.builder(
                    controller: ctrl,
                    itemCount: _items.length,
                    itemBuilder: (ctx, i) {
                      final g = _items[i];
                      return ListTile(title: Text(g['name']?.toString() ?? ''), subtitle: Text(g['leaderName']?.toString() ?? ''), onTap: () => Navigator.pop(context, g));
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
