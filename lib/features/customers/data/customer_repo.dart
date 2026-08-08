import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';

class CustomerRepo {
  final ApiClient api;
  CustomerRepo(this.api);

  Future<Map<String, dynamic>> list({int page = 1, int limit = 20, String? search, String? city, bool? status, bool forLoan = false}) async {
    final query = <String, dynamic>{'page': page, 'limit': limit};
    if (search != null && search.isNotEmpty) query['search'] = search;
    if (city != null && city.isNotEmpty) query['city'] = city;
    if (status != null) query['status'] = status.toString();
    if (forLoan) query['forLoan'] = 'true';
    final res = await api.raw(() => api.dio.get('/customers', queryParameters: query));
    return Map<String, dynamic>.from(res.data as Map);
  }

  Future<Map<String, dynamic>> get(String id) async {
    final d = await api.get('/customers/$id');
    return Map<String, dynamic>.from(d as Map);
  }

  Future<Map<String, dynamic>> create(
    Map<String, dynamic> body, {
    File? photo,
    File? introducerPhoto,
    List<File> documents = const [],
  }) async {
    final payload = await _payload(body, photo, introducerPhoto, documents);
    final d = await api.post('/customers', data: payload);
    return Map<String, dynamic>.from(d as Map);
  }

  Future<Map<String, dynamic>> update(
    String id,
    Map<String, dynamic> body, {
    File? photo,
    File? introducerPhoto,
    List<File> documents = const [],
  }) async {
    final payload = await _payload(body, photo, introducerPhoto, documents);
    final d = await api.put('/customers/$id', data: payload);
    return Map<String, dynamic>.from(d as Map);
  }

  /// Builds the request body. When any file is attached, sends multipart so the
  /// backend's upload.fields([photo, introducerPhoto, documents]) middleware can
  /// store them; otherwise sends a plain JSON map. Mirrors the web CustomerForm.
  Future<dynamic> _payload(Map<String, dynamic> body, File? photo, File? introducerPhoto, List<File> documents) async {
    if (photo == null && introducerPhoto == null && documents.isEmpty) return body;
    final form = FormData();
    body.forEach((k, v) {
      if (v != null) form.fields.add(MapEntry(k, v.toString()));
    });
    Future<void> addFile(String field, File f) async {
      final name = f.path.split(Platform.pathSeparator).last;
      form.files.add(MapEntry(field, await MultipartFile.fromFile(f.path, filename: name)));
    }
    if (photo != null) await addFile('photo', photo);
    if (introducerPhoto != null) await addFile('introducerPhoto', introducerPhoto);
    for (final f in documents) {
      await addFile('documents', f);
    }
    return form;
  }

  Future<void> toggleStatus(String id) async => api.patch('/customers/$id/status');

  Future<void> delete(String id) async => api.delete('/customers/$id');

  Future<void> restore(String id) async => api.patch('/customers/$id/restore');

  Future<List<dynamic>> listDeleted() async {
    final d = await api.get('/customers/deleted');
    if (d is List) return d;
    if (d is Map && d['data'] is List) return d['data'];
    return const [];
  }

  Future<List<dynamic>> loans(String id) async {
    final d = await api.get('/customers/$id/loans');
    return (d as List?) ?? const [];
  }

  Future<List<dynamic>> savings(String id) async {
    final d = await api.get('/customers/$id/savings');
    return (d as List?) ?? const [];
  }

  Future<List<dynamic>> ledger(String id) async {
    final res = await api.raw(() => api.dio.get('/customers/$id/ledger'));
    final body = res.data;
    if (body is Map && body['data'] is List) return body['data'];
    if (body is List) return body;
    return const [];
  }

  /// Sets/resets the customer portal login password.
  /// Backend: POST /customers/:id/set-password { password } (min 6 chars).
  Future<void> setPassword(String id, String password) async =>
      api.post('/customers/$id/set-password', data: {'password': password});

  /// Updates the interest-free opening balance.
  /// Backend: PATCH /customers/:id/opening-balance { openingBalance }.
  Future<Map<String, dynamic>> updateOpeningBalance(String id, num amount) async {
    final d = await api.patch('/customers/$id/opening-balance', data: {'openingBalance': amount});
    return Map<String, dynamic>.from(d as Map);
  }

  /// Uploads one or more documents in a single multipart request.
  /// Backend: POST /customers/:id/documents (upload.array('documents', 5)).
  /// Documents are stored as { name, path }.
  Future<void> uploadDocuments(String id, List<File> files) async {
    final form = FormData();
    for (final f in files) {
      final name = f.path.split(Platform.pathSeparator).last;
      form.files.add(MapEntry('documents', await MultipartFile.fromFile(f.path, filename: name)));
    }
    await api.post('/customers/$id/documents', data: form);
  }

  /// Removes the document at [index].
  /// Backend: DELETE /customers/:id/documents/:docIndex.
  Future<void> deleteDocument(String id, int index) async =>
      api.delete('/customers/$id/documents/$index');

  /// Bulk-settles all active loans for the customer.
  /// Backend: POST /customers/:id/consolidated-settle { settlementAmount, notes }.
  Future<Map<String, dynamic>> consolidatedSettle(String id, Map<String, dynamic> body) async {
    final d = await api.post('/customers/$id/consolidated-settle', data: body);
    return Map<String, dynamic>.from(d as Map);
  }

  /// Fetches the per-customer consolidated balance sheet.
  /// Backend: GET /customers/:id/consolidated-balance.
  /// Returns { customer, loansByType, summary, generatedAt }.
  Future<Map<String, dynamic>> consolidatedBalance(String id) async {
    final d = await api.get('/customers/$id/consolidated-balance');
    return Map<String, dynamic>.from(d as Map);
  }

  /// Fetches the org-wide consolidated balances (paginated, with summary).
  /// Backend: GET /customers/consolidated-balances.
  /// Returns the raw body: { data, pagination, summary }.
  Future<Map<String, dynamic>> consolidatedBalances({Map<String, dynamic>? params}) async {
    final res = await api.raw(() => api.dio.get('/customers/consolidated-balances', queryParameters: params));
    return Map<String, dynamic>.from(res.data as Map);
  }

  /// Full khata statement: every balance-affecting event across chits and loans
  /// with a running balance. Backend: GET /customers/:id/sheet-statement.
  /// Returns { customer, rows, closingBalance }.
  Future<Map<String, dynamic>> sheetStatement(String id) async {
    final d = await api.get('/customers/$id/sheet-statement');
    return Map<String, dynamic>.from(d as Map);
  }

  /// The balance sheet's "P A" — receive a lump payment, auto-allocated across
  /// the customer's chit dues then loan dues (ORG_ADMIN/MANAGER only).
  /// Backend: POST /customers/:id/sheet-payment { amount, paymentMode }.
  /// Returns { received, allocations, receipts }.
  Future<Map<String, dynamic>> sheetPayment(String id, num amount, {String paymentMode = 'CASH'}) async {
    final d = await api.post('/customers/$id/sheet-payment', data: {'amount': amount, 'paymentMode': paymentMode});
    return Map<String, dynamic>.from(d as Map);
  }

  /// The balance sheet's "I A" — issue cash against the customer's PENDING
  /// auction payouts, oldest first (partial settles split the payout).
  /// Backend: POST /customers/:id/sheet-issue { amount, paymentMode }.
  /// Returns { issued, settled }.
  Future<Map<String, dynamic>> sheetIssue(String id, num amount, {String paymentMode = 'CASH'}) async {
    final d = await api.post('/customers/$id/sheet-issue', data: {'amount': amount, 'paymentMode': paymentMode});
    return Map<String, dynamic>.from(d as Map);
  }
}

final customerRepoProvider = Provider<CustomerRepo>((ref) => CustomerRepo(ref.read(apiClientProvider)));
