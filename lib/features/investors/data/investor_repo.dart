import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';

class InvestorRepo {
  final ApiClient api;
  InvestorRepo(this.api);

  Future<Map<String, dynamic>> list({int page = 1, int limit = 20, String? search}) async {
    final q = <String, dynamic>{'page': page, 'limit': limit};
    if (search?.isNotEmpty ?? false) q['search'] = search;
    final res = await api.raw(() => api.dio.get('/investors', queryParameters: q));
    return Map<String, dynamic>.from(res.data as Map);
  }

  Future<Map<String, dynamic>> get(String id) async {
    final d = await api.get('/investors/$id');
    return Map<String, dynamic>.from(d as Map);
  }

  Future<Map<String, dynamic>> summary() async {
    final d = await api.get('/investors/summary');
    return Map<String, dynamic>.from(d as Map);
  }

  Future<List<dynamic>> investments(String id) async {
    final d = await api.get('/investors/$id/investments');
    if (d is List) return d;
    if (d is Map && d['data'] is List) return d['data'];
    return const [];
  }

  Future<void> create(Map<String, dynamic> body) async => api.post('/investors', data: body);
  Future<void> update(String id, Map<String, dynamic> body) async => api.put('/investors/$id', data: body);
  Future<void> toggleStatus(String id) async => api.patch('/investors/$id/status');
}

class InvestmentRepo {
  final ApiClient api;
  InvestmentRepo(this.api);

  Future<Map<String, dynamic>> list({int page = 1, int limit = 20, String? status}) async {
    final q = <String, dynamic>{'page': page, 'limit': limit};
    if (status?.isNotEmpty ?? false) q['status'] = status;
    final res = await api.raw(() => api.dio.get('/investments', queryParameters: q));
    return Map<String, dynamic>.from(res.data as Map);
  }

  Future<Map<String, dynamic>> get(String id) async {
    final d = await api.get('/investments/$id');
    return Map<String, dynamic>.from(d as Map);
  }

  Future<void> create(Map<String, dynamic> body) async => api.post('/investments', data: body);
  Future<void> update(String id, Map<String, dynamic> body) async => api.put('/investments/$id', data: body);
  Future<Map<String, dynamic>> closureSummary(String id) async {
    final d = await api.get('/investments/$id/closure-summary');
    return Map<String, dynamic>.from(d as Map);
  }

  Future<void> close(String id) async => api.post('/investments/$id/close');
  Future<void> withdrawInterest(String id, {required num amount}) async => api.post('/investments/$id/withdraw-interest', data: {'amount': amount});
  Future<void> partialWithdrawal(String id, {required num amount}) async => api.post('/investments/$id/partial-withdrawal', data: {'amount': amount});

  Future<List<dynamic>> transactions(String id) async {
    final d = await api.get('/investments/$id/transactions');
    if (d is List) return d;
    if (d is Map && d['data'] is List) return d['data'];
    return const [];
  }

  Future<void> deleteInvestment(String id) async => api.delete('/investments/$id');
  Future<void> deleteTransaction(String investmentId, String transactionId) async =>
      api.delete('/investments/$investmentId/transactions/$transactionId');
}

final investorRepoProvider = Provider<InvestorRepo>((ref) => InvestorRepo(ref.read(apiClientProvider)));
final investmentRepoProvider = Provider<InvestmentRepo>((ref) => InvestmentRepo(ref.read(apiClientProvider)));
