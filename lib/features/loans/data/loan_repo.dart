import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';

class LoanRepo {
  final ApiClient api;
  LoanRepo(this.api);

  Future<Map<String, dynamic>> list({
    int page = 1,
    int limit = 20,
    String? search,
    String? status,
    String? type,
    String? assignedToId,
    String? fromDate,
    String? toDate,
    bool archived = false,
  }) async {
    final q = <String, dynamic>{'page': page, 'limit': limit};
    if (search?.isNotEmpty ?? false) q['search'] = search;
    if (status?.isNotEmpty ?? false) q['status'] = status;
    if (type?.isNotEmpty ?? false) q['loanType'] = type;
    if (assignedToId?.isNotEmpty ?? false) q['assignedToId'] = assignedToId;
    if (fromDate?.isNotEmpty ?? false) q['fromDate'] = fromDate;
    if (toDate?.isNotEmpty ?? false) q['toDate'] = toDate;
    if (archived) q['archived'] = 'true';
    final res = await api.raw(() => api.dio.get('/loans', queryParameters: q));
    return Map<String, dynamic>.from(res.data as Map);
  }

  Future<List<dynamic>> overdue({bool groupByCustomer = false}) async {
    final q = <String, dynamic>{};
    if (groupByCustomer) q['groupBy'] = 'customer';
    final res = await api.raw(() => api.dio.get('/loans/overdue', queryParameters: q));
    final body = res.data;
    if (body is Map && body['data'] is List) return body['data'];
    if (body is List) return body;
    return const [];
  }

  Future<Map<String, dynamic>> get(String id) async {
    final d = await api.get('/loans/$id');
    return Map<String, dynamic>.from(d as Map);
  }

  Future<Map<String, dynamic>> create(Map<String, dynamic> body) async {
    final d = await api.post('/loans', data: body);
    return Map<String, dynamic>.from(d as Map);
  }

  Future<void> update(String id, Map<String, dynamic> body) async => api.put('/loans/$id', data: body);

  /// Admin correction of structural terms after collections exist
  /// (PATCH /loans/:id/correct). Rebuilds the EMI schedule from the corrected
  /// terms and re-applies recorded payments. Requires a `reason`; gated server-side
  /// by ORG_ADMIN + the `enableLoanCorrection` feature flag.
  Future<void> correct(String id, Map<String, dynamic> body) async => api.patch('/loans/$id/correct', data: body);
  Future<void> delete(String id) async => api.delete('/loans/$id');
  Future<void> disburse(String id) async => api.patch('/loans/$id/disburse');
  Future<void> reject(String id) async => api.patch('/loans/$id/reject');
  /// Closes a loan (PATCH /loans/:id/close).
  ///
  /// `body` carries the closure decision: `closureType` (FULL_PAYMENT / SETTLEMENT /
  /// WRITE_OFF), plus `waiverAmount` for a settlement and an optional `closureNotes`.
  /// A SETTLEMENT without an explicit `waiverAmount` is rejected server-side — the
  /// amount being forgiven must be named, never inferred. Passing no body only works
  /// when every due is already paid.
  Future<void> close(String id, [Map<String, dynamic>? body]) async =>
      api.patch('/loans/$id/close', data: body ?? const <String, dynamic>{});

  /// Archives a loan: hides it from the active book (Outstanding / Overdue /
  /// Amount-in-Market totals) without deleting or closing it. Reversible.
  Future<void> archive(String id, {String? reason}) async =>
      api.patch('/loans/$id/archive', data: {if (reason?.isNotEmpty ?? false) 'reason': reason});

  /// Restores an archived loan back into the active book.
  Future<void> unarchive(String id) async => api.patch('/loans/$id/unarchive');

  /// Pre-close figures (GET /loans/:id/closure-summary): payable, recovered,
  /// outstanding, late fees, EMIs paid. Drives the close sheet so the operator sees
  /// what is actually owed before choosing how to close it.
  Future<Map<String, dynamic>> closureSummary(String id) async {
    final d = await api.get('/loans/$id/closure-summary');
    return Map<String, dynamic>.from(d as Map);
  }

  Future<List<dynamic>> emiSchedule(String id) async {
    final d = await api.get('/loans/$id/emi-schedule');
    if (d is List) return d;
    if (d is Map && d['data'] is List) return d['data'];
    return const [];
  }

  /// Uploads one or more loan documents in a single multipart request.
  /// Backend route: POST /loans/:id/documents (upload.array('documents', 10)).
  /// The file title defaults to the filename (matches the web's `titles` field).
  Future<void> uploadDocuments(String id, List<File> files) async {
    final form = FormData();
    for (final f in files) {
      final name = f.path.split(Platform.pathSeparator).last;
      form.files.add(MapEntry('documents', await MultipartFile.fromFile(f.path, filename: name)));
      form.fields.add(MapEntry('titles', name.replaceFirst(RegExp(r'\.[^/.]+$'), '')));
    }
    await api.post('/loans/$id/documents', data: form);
  }

  /// Removes the document at [index] (DELETE /loans/:id/documents/:docIndex).
  Future<void> deleteDocument(String id, int index) async => api.delete('/loans/$id/documents/$index');

  /// Renames the document at [index] (PUT /loans/:id/documents/:docIndex { title }).
  Future<void> renameDocument(String id, int index, String title) async =>
      api.put('/loans/$id/documents/$index', data: {'title': title});

  /// Lightweight feed for the Assign Loan screen: every active loan with its
  /// outstanding balance and current field officer ({ id, name } | null).
  Future<List<dynamic>> assignable() async {
    final d = await api.get('/loans/assignable');
    if (d is List) return d;
    if (d is Map && d['data'] is List) return d['data'];
    return const [];
  }

  /// Saves an employee's loan "basket": [loanIds] become their exact set of active
  /// loans — unassigned loans are picked up, and any of their loans not in the list
  /// are released. Only UNASSIGNED loans can be picked up (the server rejects stealing
  /// a loan that another agent still holds). Returns the server's summary message.
  Future<String> assignBasket(String employeeId, List<String> loanIds) async {
    final res = await api.raw(() => api.dio.post('/loans/assign',
        data: {'employeeId': employeeId, 'loanIds': loanIds}));
    final body = res.data;
    if (body is Map && body['success'] == false) {
      throw ApiException(body['message']?.toString() ?? 'Failed to assign',
          statusCode: res.statusCode, data: body);
    }
    return (body is Map ? body['message']?.toString() : null) ?? 'Assignment saved';
  }

  /// Hands over an officer's entire live workload to another officer (e.g. when they
  /// resign), optionally moving their assigned customers too. Returns the summary.
  Future<String> reassignFrom({
    required String toUserId,
    required String fromUserId,
    bool includeCustomers = true,
  }) async {
    final res = await api.raw(() => api.dio.post('/loans/reassign', data: {
          'toUserId': toUserId,
          'fromUserId': fromUserId,
          'includeCustomers': includeCustomers,
        }));
    final body = res.data;
    if (body is Map && body['success'] == false) {
      throw ApiException(body['message']?.toString() ?? 'Failed to reassign',
          statusCode: res.statusCode, data: body);
    }
    return (body is Map ? body['message']?.toString() : null) ?? 'Work reassigned';
  }
}

final loanRepoProvider = Provider<LoanRepo>((ref) => LoanRepo(ref.read(apiClientProvider)));
