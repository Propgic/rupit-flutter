import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';

class CollectionRepo {
  final ApiClient api;
  CollectionRepo(this.api);

  Future<Map<String, dynamic>> list({int page = 1, int limit = 20, String? search, String? status, String? verificationStatus, String? date, String? fromDate, String? toDate, String? loanType, String? collectedById, String? sourceType}) async {
    final q = <String, dynamic>{'page': page, 'limit': limit};
    if (search?.isNotEmpty ?? false) q['search'] = search;
    if (verificationStatus?.isNotEmpty ?? false) q['verificationStatus'] = verificationStatus;
    if (date?.isNotEmpty ?? false) q['date'] = date;
    if (fromDate?.isNotEmpty ?? false) q['fromDate'] = fromDate;
    if (toDate?.isNotEmpty ?? false) q['toDate'] = toDate;
    if (loanType?.isNotEmpty ?? false) q['loanType'] = loanType;
    if (collectedById?.isNotEmpty ?? false) q['collectedById'] = collectedById;
    // Loan / chit / all. Defaults (omitted) to loan on the server.
    if (sourceType?.isNotEmpty ?? false) q['sourceType'] = sourceType;
    final res = await api.raw(() => api.dio.get('/collections', queryParameters: q));
    return Map<String, dynamic>.from(res.data as Map);
  }

  /// Collections for the route map: a single date range with a high limit and
  /// optional collector filter. Mirrors the web CollectionMap which calls
  /// `/collections?fromDate&toDate&limit=500[&collectedById]`.
  Future<List<Map<String, dynamic>>> forMap({required String date, String? collectedById}) async {
    final q = <String, dynamic>{'fromDate': date, 'toDate': date, 'limit': 500};
    if (collectedById?.isNotEmpty ?? false) q['collectedById'] = collectedById;
    final res = await api.raw(() => api.dio.get('/collections', queryParameters: q));
    final body = res.data;
    final data = body is Map ? (body['data'] ?? body) : body;
    final list = data is Map ? data['collections'] : data;
    if (list is List) return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    return const [];
  }

  Future<Map<String, dynamic>> dailySummary({String? date}) async {
    final q = <String, dynamic>{};
    if (date?.isNotEmpty ?? false) q['date'] = date;
    final d = await api.get('/collections/daily-summary', query: q);
    return Map<String, dynamic>.from(d as Map);
  }

  Future<List<dynamic>> pendingVerifications() async {
    final d = await api.get('/collections/pending-verification');
    if (d is List) return d;
    if (d is Map && d['data'] is List) return d['data'];
    return const [];
  }

  Future<Map<String, dynamic>> get(String id) async {
    final d = await api.get('/collections/$id');
    return Map<String, dynamic>.from(d as Map);
  }

  Future<Map<String, dynamic>> getReceipt(String id) async {
    final d = await api.get('/collections/$id/receipt');
    return Map<String, dynamic>.from(d as Map);
  }

  Future<Map<String, dynamic>> create(Map<String, dynamic> body) async {
    final d = await api.post('/collections', data: body);
    return Map<String, dynamic>.from(d as Map);
  }

  Future<void> createGroup(Map<String, dynamic> body) async => api.post('/collections/group', data: body);

  Future<Map<String, dynamic>> update(String id, {required num amount, num? alrAmount, bool sendAlr = false, String? notes}) async {
    // sendAlr distinguishes "leave ALR unchanged" (omitted) from "clear it" (null).
    final d = await api.put('/collections/$id', data: {
      'amount': amount,
      if (sendAlr) 'alrAmount': alrAmount,
      if (notes != null) 'notes': notes,
    });
    return Map<String, dynamic>.from(d as Map);
  }

  Future<void> verify(String id, {required bool approve, String? remarks}) async {
    // Backend expects { status: 'VERIFIED' | 'REJECTED', notes } — not { approve, remarks }.
    await api.patch('/collections/$id/verify', data: {
      'status': approve ? 'VERIFIED' : 'REJECTED',
      if (remarks != null) 'notes': remarks,
    });
  }

  /// Verify/reject a whole selection in one call. Rows that are no longer PENDING
  /// (verified elsewhere in the meantime) are skipped server-side, so this returns the
  /// full envelope — callers should surface `message`, which reports what actually
  /// applied, instead of assuming the entire selection went through.
  Future<Map<String, dynamic>> bulkVerify(List<String> ids, {required bool approve, String? remarks}) async {
    final res = await api.raw(() => api.dio.patch('/collections/bulk-verify', data: {
      'ids': ids,
      'status': approve ? 'VERIFIED' : 'REJECTED',
      if (remarks != null) 'notes': remarks,
    }));
    final body = res.data;
    return body is Map ? Map<String, dynamic>.from(body) : <String, dynamic>{};
  }
}

final collectionRepoProvider = Provider<CollectionRepo>((ref) => CollectionRepo(ref.read(apiClientProvider)));
