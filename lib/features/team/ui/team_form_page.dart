import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import '../../../core/api/api_client.dart';
import '../../../core/widgets/common.dart';
import '../data/team_repo.dart';

class TeamFormPage extends ConsumerStatefulWidget {
  final String? id;
  const TeamFormPage({super.key, this.id});
  @override
  ConsumerState<TeamFormPage> createState() => _TeamFormPageState();
}

class _TeamFormPageState extends ConsumerState<TeamFormPage> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _email = TextEditingController();
  final _phone = TextEditingController();
  final _password = TextEditingController();
  final _salary = TextEditingController();
  final _commission = TextEditingController();
  final _bankName = TextEditingController();
  final _bankAcc = TextEditingController();
  final _bankIfsc = TextEditingController();
  String _role = 'FIELD_OFFICER';
  String _salaryMode = 'FIXED';
  String _salaryType = 'MONTHLY';
  File? _photo;
  String? _existingPhotoUrl;
  bool _saving = false;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    if (widget.id != null) _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final u = await ref.read(teamRepoProvider).get(widget.id!);
      _name.text = u['name']?.toString() ?? '';
      _email.text = u['email']?.toString() ?? '';
      _phone.text = u['phone']?.toString() ?? '';
      _role = u['role']?.toString() ?? 'FIELD_OFFICER';
      _salary.text = u['salary']?.toString() ?? '';
      _commission.text = u['commissionPercentage']?.toString() ?? '';
      _salaryMode = u['salaryMode']?.toString() ?? 'FIXED';
      _salaryType = u['salaryType']?.toString() ?? 'MONTHLY';
      _bankName.text = u['bankName']?.toString() ?? '';
      _bankAcc.text = u['bankAccountNumber']?.toString() ?? '';
      _bankIfsc.text = u['bankIfsc']?.toString() ?? '';
      _existingPhotoUrl = u['photo']?.toString();
    } catch (e) {
      showToast('Failed: $e', error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    // Backend rejects create without a photo (upload.single('photo') is mandatory).
    if (widget.id == null && _photo == null) {
      showToast('Team member photo is required', error: true);
      return;
    }
    setState(() => _saving = true);
    try {
      final body = <String, dynamic>{
        'name': _name.text.trim(),
        'phone': _phone.text.trim(),
        'role': _role,
        'salaryMode': _salaryMode,
        if (_salary.text.trim().isNotEmpty) 'salary': _salary.text.trim(),
        'salaryType': _salaryType,
        if (_commission.text.trim().isNotEmpty) 'commissionPercentage': _commission.text.trim(),
        if (_bankName.text.trim().isNotEmpty) 'bankName': _bankName.text.trim(),
        if (_bankAcc.text.trim().isNotEmpty) 'bankAccountNumber': _bankAcc.text.trim(),
        if (_bankIfsc.text.trim().isNotEmpty) 'bankIfsc': _bankIfsc.text.trim(),
      };
      if (widget.id == null) {
        body['email'] = _email.text.trim().isEmpty ? null : _email.text.trim();
        if (_password.text.isNotEmpty) body['password'] = _password.text;
      }
      final repo = ref.read(teamRepoProvider);
      if (widget.id == null) {
        await repo.create(body, photo: _photo);
        showToast('Team member added');
      } else {
        await repo.update(widget.id!, body, photo: _photo);
        showToast('Updated');
      }
      if (mounted) context.go('/team');
    } on ApiException catch (e) {
      showToast(e.message, error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickPhoto() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_camera_outlined),
              title: const Text('Camera'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Gallery'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    final x = await ImagePicker().pickImage(source: source, maxWidth: 1600, imageQuality: 80);
    if (x != null) setState(() => _photo = File(x.path));
  }

  Widget _photoPicker() {
    final hasNew = _photo != null;
    final resolved = resolveUrl(_existingPhotoUrl);
    ImageProvider? preview;
    if (hasNew) {
      preview = FileImage(_photo!);
    } else if (resolved != null) {
      preview = NetworkImage(resolved);
    }
    return Row(
      children: [
        GestureDetector(
          onTap: _pickPhoto,
          child: Container(
            width: 84,
            height: 84,
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.grey.shade300),
              image: preview == null ? null : DecorationImage(image: preview, fit: BoxFit.cover),
            ),
            child: preview == null
                ? const Icon(Icons.add_a_photo_outlined, color: Colors.grey)
                : null,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.id == null ? 'Photo *' : 'Photo', style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Row(
                children: [
                  TextButton(onPressed: _pickPhoto, child: Text(preview == null ? 'Upload' : 'Change')),
                  if (hasNew)
                    TextButton(
                      onPressed: () => setState(() => _photo = null),
                      child: const Text('Remove', style: TextStyle(color: Colors.red)),
                    ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return Scaffold(appBar: AppBar(title: const Text('Team')), body: const LoadingView());
    final editing = widget.id != null;
    return Scaffold(
      appBar: AppBar(title: Text(editing ? 'Edit Member' : 'Add Member')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(14),
          children: [
            SectionCard(
              title: 'Basic',
              child: Column(
                children: [
                  _photoPicker(),
                  const SizedBox(height: 10),
                  TextFormField(controller: _name, decoration: const InputDecoration(labelText: 'Full Name *'), validator: (v) => v?.trim().isEmpty == true ? 'Required' : null),
                  const SizedBox(height: 10),
                  if (!editing) TextFormField(controller: _email, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email')),
                  if (!editing) const SizedBox(height: 10),
                  TextFormField(controller: _phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone *'), validator: (v) => v?.trim().isEmpty == true ? 'Required' : null),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: _role,
                    decoration: const InputDecoration(labelText: 'Role *'),
                    items: const [
                      DropdownMenuItem(value: 'ORG_ADMIN', child: Text('Org Admin')),
                      DropdownMenuItem(value: 'MANAGER', child: Text('Manager')),
                      DropdownMenuItem(value: 'FIELD_OFFICER', child: Text('Field Officer')),
                      DropdownMenuItem(value: 'CASHIER', child: Text('Cashier')),
                      DropdownMenuItem(value: 'ACCOUNTANT', child: Text('Accountant')),
                      DropdownMenuItem(value: 'VIEWER', child: Text('Viewer')),
                    ],
                    onChanged: (v) => setState(() => _role = v!),
                  ),
                  if (!editing) const SizedBox(height: 10),
                  if (!editing) TextFormField(controller: _password, obscureText: true, decoration: const InputDecoration(labelText: 'Password (optional, auto-generated if blank)')),
                ],
              ),
            ),
            SectionCard(
              title: 'Compensation',
              child: Column(
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: _salaryMode,
                    decoration: const InputDecoration(labelText: 'Salary Mode'),
                    items: const [
                      DropdownMenuItem(value: 'FIXED', child: Text('Fixed')),
                      DropdownMenuItem(value: 'PERCENTAGE', child: Text('Percentage')),
                      DropdownMenuItem(value: 'FIXED_AND_PERCENTAGE', child: Text('Fixed + Percentage')),
                    ],
                    onChanged: (v) => setState(() => _salaryMode = v!),
                  ),
                  const SizedBox(height: 10),
                  if (_salaryMode != 'PERCENTAGE') TextFormField(controller: _salary, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Salary', prefixText: '₹ ')),
                  if (_salaryMode != 'PERCENTAGE') const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    initialValue: _salaryType,
                    decoration: const InputDecoration(labelText: 'Salary Type'),
                    items: const [
                      DropdownMenuItem(value: 'MONTHLY', child: Text('Monthly')),
                      DropdownMenuItem(value: 'WEEKLY', child: Text('Weekly')),
                      DropdownMenuItem(value: 'DAILY', child: Text('Daily')),
                    ],
                    onChanged: (v) => setState(() => _salaryType = v!),
                  ),
                  const SizedBox(height: 10),
                  if (_salaryMode != 'FIXED') TextFormField(controller: _commission, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Commission %')),
                ],
              ),
            ),
            SectionCard(
              title: 'Bank',
              child: Column(
                children: [
                  TextFormField(controller: _bankName, decoration: const InputDecoration(labelText: 'Bank')),
                  const SizedBox(height: 10),
                  TextFormField(controller: _bankAcc, decoration: const InputDecoration(labelText: 'Account #')),
                  const SizedBox(height: 10),
                  TextFormField(controller: _bankIfsc, decoration: const InputDecoration(labelText: 'IFSC')),
                ],
              ),
            ),
            SizedBox(width: double.infinity, child: ElevatedButton(onPressed: _saving ? null : _save, child: Text(_saving ? 'Saving...' : (editing ? 'Update' : 'Create Member')))),
          ],
        ),
      ),
    );
  }
}
