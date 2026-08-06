import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import '../../../core/api/api_client.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/common.dart';
import '../../team/data/team_repo.dart';
import '../data/customer_repo.dart';

class CustomerFormPage extends ConsumerStatefulWidget {
  final String? id;
  const CustomerFormPage({super.key, this.id});
  @override
  ConsumerState<CustomerFormPage> createState() => _CustomerFormPageState();
}

class _CustomerFormPageState extends ConsumerState<CustomerFormPage> {
  final _formKey = GlobalKey<FormState>();
  final _c = <String, TextEditingController>{
    for (final k in [
      'firstName','lastName','fatherName','phone','alternatePhone','email','aadhaarNumber','panNumber','verifiedBy',
      'address','city','district','state','pincode','occupation','monthlyIncome',
      'bankName','accountNumber','ifscCode','nomineeName','nomineeRelation','nomineePhone',
      'introducerName','introducerPhone',
    ]) k: TextEditingController(),
  };
  String _gender = 'MALE';
  // Field officers only see customers assigned to them, so admins/managers pick
  // the agent here; officers can't change it (the server ignores it from them).
  String? _assignedToId;
  List<Map<String, dynamic>> _agents = [];
  DateTime? _dob;
  // Server-side validation error for the phone field (e.g. a 409 duplicate mobile),
  // surfaced inline under the field in addition to the toast. Cleared on edit.
  final _phoneFocus = FocusNode();
  String? _phoneError;
  File? _photo;
  String? _existingPhotoUrl;
  File? _introducerPhoto;
  String? _existingIntroducerPhotoUrl;
  final List<File> _documents = [];
  bool _loading = false;
  bool _saving = false;

  bool get _canAssign {
    final role = ref.read(authProvider).user?.role;
    return role == 'ORG_ADMIN' || role == 'MANAGER';
  }

  @override
  void initState() {
    super.initState();
    if (_canAssign) _loadAgents();
    if (widget.id != null) _load();
  }

  Future<void> _loadAgents() async {
    try {
      final members = await ref.read(teamRepoProvider).list(limit: 500);
      if (!mounted) return;
      setState(() {
        _agents = members
            .map((e) => Map<String, dynamic>.from(e as Map))
            .where((m) => m['isActive'] == true)
            .toList();
      });
    } catch (_) {
      // Assignment is optional on the form; a failed team fetch shouldn't block saving.
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final c = await ref.read(customerRepoProvider).get(widget.id!);
      _c.forEach((k, ctrl) => ctrl.text = c[k]?.toString() ?? '');
      _gender = c['gender']?.toString() ?? 'MALE';
      _assignedToId = c['assignedToId']?.toString();
      _dob = tryParseDate(c['dateOfBirth']?.toString());
      _existingPhotoUrl = c['photo']?.toString();
      _existingIntroducerPhotoUrl = c['introducerPhoto']?.toString();
    } catch (e) {
      showToast('Failed to load: $e', error: true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    for (final c in _c.values) {
      c.dispose();
    }
    _phoneFocus.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    // Clear any stale server-side phone error so a corrected duplicate can be re-submitted.
    _phoneError = null;
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final body = <String, dynamic>{
        'gender': _gender,
        if (_dob != null) 'dateOfBirth': formatInputDate(_dob!),
        // Sent even when empty so an admin can clear the assignment; '' becomes
        // null server-side. Officers never send it — the server drops it anyway.
        if (_canAssign) 'assignedToId': _assignedToId ?? '',
      };
      _c.forEach((k, ctrl) {
        final v = ctrl.text.trim();
        if (v.isNotEmpty) {
          if (k == 'monthlyIncome') {
            body[k] = double.tryParse(v);
          } else if (k == 'panNumber') {
            body[k] = v.toUpperCase();
          } else {
            body[k] = v;
          }
        }
      });
      if (widget.id == null) {
        await ref.read(customerRepoProvider).create(
              body,
              photo: _photo,
              introducerPhoto: _introducerPhoto,
              documents: _documents,
            );
        showToast('Customer created');
      } else {
        await ref.read(customerRepoProvider).update(
              widget.id!,
              body,
              photo: _photo,
              introducerPhoto: _introducerPhoto,
              documents: _documents,
            );
        showToast('Customer updated');
      }
      if (mounted) context.go('/customers');
    } on ApiException catch (e) {
      // Duplicate mobile number — surface it inline under the Phone field too, and focus it.
      if (e.statusCode == 409 && mounted) {
        setState(() => _phoneError = e.message);
        _formKey.currentState!.validate();
        _phoneFocus.requestFocus();
      }
      showToast(e.message, error: true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<File?> _pickImage() async {
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
    if (source == null) return null;
    final x = await ImagePicker().pickImage(source: source, maxWidth: 1600, imageQuality: 80);
    return x == null ? null : File(x.path);
  }

  Future<void> _pickPhoto() async {
    final f = await _pickImage();
    if (f != null) setState(() => _photo = f);
  }

  Future<void> _pickIntroducerPhoto() async {
    final f = await _pickImage();
    if (f != null) setState(() => _introducerPhoto = f);
  }

  Future<void> _pickDocuments() async {
    final xs = await ImagePicker().pickMultiImage(maxWidth: 1600, imageQuality: 80);
    if (xs.isNotEmpty) setState(() => _documents.addAll(xs.map((x) => File(x.path))));
  }

  Widget _photoPicker({required String label, File? file, String? existingUrl, required VoidCallback onPick, required VoidCallback onClear}) {
    final hasNew = file != null;
    final resolved = resolveUrl(existingUrl);
    ImageProvider? preview;
    if (hasNew) {
      preview = FileImage(file);
    } else if (resolved != null) {
      preview = NetworkImage(resolved);
    }
    return Row(
      children: [
        GestureDetector(
          onTap: onPick,
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
              Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Row(
                children: [
                  TextButton(onPressed: onPick, child: Text(preview == null ? 'Upload' : 'Change')),
                  if (hasNew)
                    TextButton(
                      onPressed: onClear,
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

  Widget _text(String key, String label, {bool required = false, TextInputType? keyboard, int maxLines = 1, TextCapitalization textCapitalization = TextCapitalization.none, String? Function(String?)? validator, FocusNode? focusNode, ValueChanged<String>? onChanged}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextFormField(
        controller: _c[key],
        focusNode: focusNode,
        onChanged: onChanged,
        keyboardType: keyboard,
        maxLines: maxLines,
        textCapitalization: textCapitalization,
        decoration: InputDecoration(labelText: required ? '$label *' : label),
        validator: validator ??
            (required
                ? (v) => (v == null || v.trim().isEmpty) ? 'Required' : null
                : null),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.id != null;
    if (_loading) {
      return Scaffold(appBar: AppBar(title: const Text('Customer')), body: const LoadingView());
    }
    return Scaffold(
      appBar: AppBar(title: Text(editing ? 'Edit Customer' : 'New Customer')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(14),
          children: [
            SectionCard(
              title: 'Personal',
              child: Column(
                children: [
                  _text('firstName', 'First Name', required: true),
                  _text('lastName', 'Last Name'),
                  _text('fatherName', 'Father Name'),
                  DropdownButtonFormField<String>(
                    initialValue: _gender,
                    decoration: const InputDecoration(labelText: 'Gender *'),
                    items: const [
                      DropdownMenuItem(value: 'MALE', child: Text('Male')),
                      DropdownMenuItem(value: 'FEMALE', child: Text('Female')),
                      DropdownMenuItem(value: 'OTHER', child: Text('Other')),
                    ],
                    onChanged: (v) => setState(() => _gender = v ?? 'MALE'),
                  ),
                  const SizedBox(height: 10),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(_dob == null ? 'Date of Birth' : formatDate(_dob)),
                    trailing: const Icon(Icons.calendar_today),
                    onTap: () async {
                      final d = await showDatePicker(
                        context: context,
                        firstDate: DateTime(1940),
                        lastDate: DateTime.now(),
                        initialDate: _dob ?? DateTime(2000),
                      );
                      if (d != null) setState(() => _dob = d);
                    },
                  ),
                  _text('phone', 'Phone', required: true, keyboard: TextInputType.phone,
                      focusNode: _phoneFocus,
                      onChanged: (_) { if (_phoneError != null) setState(() => _phoneError = null); },
                      validator: (v) {
                    if (v == null || v.isEmpty) return 'Required';
                    if (!RegExp(r'^\d{10}$').hasMatch(v)) return 'Must be 10 digits';
                    return _phoneError; // server-side duplicate-mobile (409), surfaced inline
                  }),
                  _text('alternatePhone', 'Alt Phone', keyboard: TextInputType.phone, validator: (v) {
                    if (v == null || v.trim().isEmpty) return null;
                    if (!RegExp(r'^\d{10}$').hasMatch(v.trim())) return 'Must be 10 digits';
                    return null;
                  }),
                  _text('email', 'Email', keyboard: TextInputType.emailAddress),
                  _text('aadhaarNumber', 'Aadhaar', keyboard: TextInputType.number, validator: (v) {
                    if (v == null || v.trim().isEmpty) return null;
                    if (!RegExp(r'^\d{12}$').hasMatch(v.trim())) return 'Must be 12 digits';
                    return null;
                  }),
                  _text('panNumber', 'PAN (optional)', textCapitalization: TextCapitalization.characters, validator: (v) {
                    if (v == null || v.trim().isEmpty) return null;
                    if (!RegExp(r'^[A-Z]{5}[0-9]{4}[A-Z]$').hasMatch(v.trim().toUpperCase())) return 'Invalid PAN';
                    return null;
                  }),
                  _text('verifiedBy', 'Verified By'),
                  if (_canAssign) ...[
                    const SizedBox(height: 10),
                    DropdownButtonFormField<String?>(
                      initialValue: _agents.any((a) => a['id'] == _assignedToId) ? _assignedToId : null,
                      decoration: const InputDecoration(
                        labelText: 'Assigned Agent',
                        helperText: 'Only this agent sees the customer in the field app',
                      ),
                      items: [
                        const DropdownMenuItem<String?>(value: null, child: Text('Unassigned')),
                        ..._agents.map((a) => DropdownMenuItem<String?>(
                              value: a['id']?.toString(),
                              child: Text(a['name']?.toString() ?? '—'),
                            )),
                      ],
                      onChanged: (v) => setState(() => _assignedToId = v),
                    ),
                  ],
                ],
              ),
            ),
            SectionCard(
              title: 'Address',
              child: Column(
                children: [
                  _text('address', 'Address', maxLines: 2),
                  _text('city', 'City'),
                  _text('district', 'District'),
                  _text('state', 'State'),
                  _text('pincode', 'Pincode', keyboard: TextInputType.number, validator: (v) {
                    if (v == null || v.isEmpty) return null;
                    if (!RegExp(r'^\d{6}$').hasMatch(v)) return 'Must be 6 digits';
                    return null;
                  }),
                ],
              ),
            ),
            SectionCard(
              title: 'Employment & Banking',
              child: Column(
                children: [
                  _text('occupation', 'Occupation'),
                  _text('monthlyIncome', 'Monthly Income', keyboard: TextInputType.number),
                  _text('bankName', 'Bank Name'),
                  _text('accountNumber', 'Account Number'),
                  _text('ifscCode', 'IFSC'),
                ],
              ),
            ),
            SectionCard(
              title: 'Nominee',
              child: Column(
                children: [
                  _text('nomineeName', 'Nominee Name'),
                  _text('nomineeRelation', 'Relation'),
                  _text('nomineePhone', 'Nominee Phone', keyboard: TextInputType.phone),
                ],
              ),
            ),
            SectionCard(
              title: 'Attachments',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _photoPicker(
                    label: 'Customer Photo',
                    file: _photo,
                    existingUrl: _existingPhotoUrl,
                    onPick: _pickPhoto,
                    onClear: () => setState(() => _photo = null),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          _documents.isEmpty ? 'No documents selected' : '${_documents.length} document(s) selected',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: _pickDocuments,
                        icon: const Icon(Icons.attach_file),
                        label: const Text('Add'),
                      ),
                      if (_documents.isNotEmpty)
                        TextButton(
                          onPressed: () => setState(_documents.clear),
                          child: const Text('Clear', style: TextStyle(color: Colors.red)),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            SectionCard(
              title: 'Introducer',
              child: Column(
                children: [
                  _photoPicker(
                    label: 'Introducer Photo',
                    file: _introducerPhoto,
                    existingUrl: _existingIntroducerPhotoUrl,
                    onPick: _pickIntroducerPhoto,
                    onClear: () => setState(() => _introducerPhoto = null),
                  ),
                  const SizedBox(height: 12),
                  _text('introducerName', 'Introducer Name'),
                  _text('introducerPhone', 'Introducer Phone', keyboard: TextInputType.phone, validator: (v) {
                    if (v == null || v.trim().isEmpty) return null;
                    if (!RegExp(r'^\d{10}$').hasMatch(v.trim())) return 'Must be 10 digits';
                    return null;
                  }),
                ],
              ),
            ),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saving ? null : _save,
                child: _saving
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Text(editing ? 'Update Customer' : 'Create Customer'),
              ),
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }
}
