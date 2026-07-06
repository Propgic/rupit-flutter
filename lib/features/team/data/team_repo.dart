import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_client.dart';

class TeamRepo {
  final ApiClient api;
  TeamRepo(this.api);

  Future<List<dynamic>> list({int? limit}) async {
    final d = await api.get('/team', query: limit == null ? null : {'limit': limit});
    if (d is List) return d;
    if (d is Map && d['data'] is List) return d['data'];
    return const [];
  }

  Future<Map<String, dynamic>> get(String id) async {
    final d = await api.get('/team/$id');
    return Map<String, dynamic>.from(d as Map);
  }

  Future<void> create(Map<String, dynamic> body, {File? photo}) async =>
      api.post('/team', data: await _payload(body, photo));
  Future<void> update(String id, Map<String, dynamic> body, {File? photo}) async =>
      api.put('/team/$id', data: await _payload(body, photo));
  Future<void> delete(String id) async => api.delete('/team/$id');
  Future<void> toggleStatus(String id) async => api.patch('/team/$id/status');
  Future<void> resetPassword(String id, String newPassword) async => api.post('/team/$id/reset-password', data: {'newPassword': newPassword});

  /// Backend routes use upload.single('photo'); the photo is mandatory on create.
  Future<dynamic> _payload(Map<String, dynamic> body, File? photo) async {
    if (photo == null) return body;
    final form = FormData();
    body.forEach((k, v) {
      if (v != null) form.fields.add(MapEntry(k, v.toString()));
    });
    final name = photo.path.split(Platform.pathSeparator).last;
    form.files.add(MapEntry('photo', await MultipartFile.fromFile(photo.path, filename: name)));
    return form;
  }
}

final teamRepoProvider = Provider<TeamRepo>((ref) => TeamRepo(ref.read(apiClientProvider)));
