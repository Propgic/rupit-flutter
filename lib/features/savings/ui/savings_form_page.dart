import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/api/api_client.dart';
import '../../../core/widgets/common.dart';
import '../data/savings_repo.dart';
import '../../customers/data/customer_repo.dart';

class SavingsFormPage extends ConsumerStatefulWidget {
  const SavingsFormPage({super.key});
  @override
  ConsumerState<SavingsFormPage> createState() => _SavingsFormPageState();
}

class _SavingsFormPageState extends ConsumerState<SavingsFormPage> {
  final _formKey = GlobalKey<FormState>();
  Map<String, dynamic>? _customer;
  String _type = 'SAVINGS';
  final _interest = TextEditingController(text: '0');
  final _pigmiAmount = TextEditingController();
  String _pigmiFrequency = 'DAILY';
  final _rdAmount = TextEditingController();
  final _rdTenure = TextEditingController();
  final _fdAmount = TextEditingController();
  final _fdTenure = TextEditingController();
  final _fdRate = TextEditingController();
  final _notes = TextEditingController();
  bool _saving = false;

  Future<void> _pickCustomer() async {
    final res = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SimpleCustomerPicker(ref: ref),
    );
    if (res != null) setState(() => _customer = res);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_customer == null) return showToast('Select a customer', error: true);
    setState(() => _saving = true);
    try {
      final body = <String, dynamic>{
        'customerId': _customer!['id'],
        'accountType': _type,
        'interestRate': double.tryParse(_interest.text) ?? 0,
        if (_notes.text.trim().isNotEmpty) 'notes': _notes.text.trim(),
      };
      if (_type == 'PIGMI') {
        body['pigmiAmount'] = double.tryParse(_pigmiAmount.text);
        body['pigmiFrequency'] = _pigmiFrequency;
      }
      if (_type == 'RD') {
        body['rdAmount'] = double.tryParse(_rdAmount.text);
        body['rdTenure'] = int.tryParse(_rdTenure.text);
      }
      if (_type == 'FD') {
        body['fdAmount'] = double.tryParse(_fdAmount.text);
        body['fdTenure'] = int.tryParse(_fdTenure.text);
        body['fdInterestRate'] = double.tryParse(_fdRate.text);
      }
      await ref.read(savingsRepoProvider).create(body);
      showToast('Account created');
      if (mounted) context.go('/savings');
    } on ApiException catch (e) {
      showToast(e.message, error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('New Savings Account')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(14),
          children: [
            SectionCard(
              title: 'Basics',
              child: Column(
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.person),
                    title: Text(_customer == null ? 'Select Customer *' : '${_customer!['firstName']} ${_customer!['lastName'] ?? ''}'.trim()),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _pickCustomer,
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: _type,
                    decoration: const InputDecoration(labelText: 'Account Type *'),
                    items: const [
                      DropdownMenuItem(value: 'SAVINGS', child: Text('Savings')),
                      DropdownMenuItem(value: 'PIGMI', child: Text('Pigmi (recurring)')),
                      DropdownMenuItem(value: 'RD', child: Text('Recurring Deposit')),
                      DropdownMenuItem(value: 'FD', child: Text('Fixed Deposit')),
                    ],
                    onChanged: (v) => setState(() => _type = v!),
                  ),
                  const SizedBox(height: 10),
                  TextFormField(controller: _interest, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'Interest Rate (%)')),
                ],
              ),
            ),
            if (_type == 'PIGMI')
              SectionCard(
                title: 'Pigmi Details',
                child: Column(
                  children: [
                    TextFormField(controller: _pigmiAmount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Amount *'), validator: (v) => (double.tryParse(v ?? '') ?? 0) > 0 ? null : 'Required'),
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String>(
                      initialValue: _pigmiFrequency,
                      decoration: const InputDecoration(labelText: 'Frequency'),
                      items: const [
                        DropdownMenuItem(value: 'DAILY', child: Text('Daily')),
                        DropdownMenuItem(value: 'WEEKLY', child: Text('Weekly')),
                        DropdownMenuItem(value: 'MONTHLY', child: Text('Monthly')),
                      ],
                      onChanged: (v) => setState(() => _pigmiFrequency = v!),
                    ),
                  ],
                ),
              ),
            if (_type == 'RD')
              SectionCard(
                title: 'RD Details',
                child: Column(
                  children: [
                    TextFormField(controller: _rdAmount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Monthly Amount *')),
                    const SizedBox(height: 10),
                    TextFormField(controller: _rdTenure, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Tenure (months) *')),
                  ],
                ),
              ),
            if (_type == 'FD')
              SectionCard(
                title: 'FD Details',
                child: Column(
                  children: [
                    TextFormField(controller: _fdAmount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Amount *')),
                    const SizedBox(height: 10),
                    TextFormField(controller: _fdTenure, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Tenure (months) *')),
                    const SizedBox(height: 10),
                    TextFormField(controller: _fdRate, keyboardType: const TextInputType.numberWithOptions(decimal: true), decoration: const InputDecoration(labelText: 'FD Interest Rate (%)')),
                  ],
                ),
              ),
            SectionCard(title: 'Notes', child: TextFormField(controller: _notes, maxLines: 2)),
            SizedBox(width: double.infinity, child: ElevatedButton(onPressed: _saving ? null : _save, child: Text(_saving ? 'Saving...' : 'Create Account'))),
          ],
        ),
      ),
    );
  }
}

class _SimpleCustomerPicker extends StatefulWidget {
  final WidgetRef ref;
  const _SimpleCustomerPicker({required this.ref});
  @override
  State<_SimpleCustomerPicker> createState() => _SimpleCustomerPickerState();
}

class _SimpleCustomerPickerState extends State<_SimpleCustomerPicker> {
  final _search = TextEditingController();
  List<Map<String, dynamic>>? _items;
  bool _loading = false;

  @override
  void initState() { super.initState(); _load(''); }

  Future<void> _load(String q) async {
    setState(() => _loading = true);
    try {
      final r = await widget.ref.read(customerRepoProvider).list(page: 1, search: q.isEmpty ? null : q);
      setState(() => _items = ((r['data'] as List?) ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList());
    } catch (e) {
      showToast('Failed: $e', error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.8,
      expand: false,
      builder: (_, ctrl) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                const Expanded(child: Text('Select Customer', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600))),
                IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TextField(
              controller: _search,
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search...'),
              onSubmitted: _load,
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: _loading
                ? const LoadingView()
                : ListView.builder(
                    controller: ctrl,
                    itemCount: _items?.length ?? 0,
                    itemBuilder: (ctx, i) {
                      final c = _items![i];
                      return ListTile(
                        title: Text('${c['firstName'] ?? ''} ${c['lastName'] ?? ''}'.trim()),
                        subtitle: Text('${c['customerId'] ?? ''} • ${c['phone'] ?? ''}'),
                        onTap: () => Navigator.pop(context, c),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
