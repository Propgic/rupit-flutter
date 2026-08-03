import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/common.dart';
import '../data/customer_repo.dart';
import '../../app_shell.dart';
import '../../../core/widgets/app_bottom_nav.dart';

class CustomerListPage extends ConsumerStatefulWidget {
  final String? initialStatus;
  const CustomerListPage({super.key, this.initialStatus});
  @override
  ConsumerState<CustomerListPage> createState() => _CustomerListPageState();
}

class _CustomerListPageState extends ConsumerState<CustomerListPage> {
  final _scroll = ScrollController();
  final _searchCtrl = TextEditingController();
  final List<Map<String, dynamic>> _items = [];
  int _page = 1;
  bool _loading = false;
  bool _hasMore = true;
  String? _search;
  bool? _active;
  Object? _error;

  @override
  void initState() {
    super.initState();
    if (widget.initialStatus == 'active') _active = true;
    if (widget.initialStatus == 'inactive') _active = false;
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 300 && !_loading && _hasMore) {
        _load();
      }
    });
    _load();
  }

  @override
  void dispose() {
    _scroll.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load({bool reset = false}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      if (reset) {
        _items.clear();
        _page = 1;
        _hasMore = true;
        _error = null;
      }
    });
    try {
      final res = await ref.read(customerRepoProvider).list(page: _page, search: _search, status: _active);
      final data = (res['data'] as List?) ?? const [];
      final pagination = Map<String, dynamic>.from(res['pagination'] ?? {});
      setState(() {
        _items.addAll(data.map((e) => Map<String, dynamic>.from(e as Map)));
        _page += 1;
        final totalPages = pagination['totalPages'] ?? 1;
        _hasMore = _page <= totalPages;
      });
    } catch (e) {
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canCreate = ref.watch(authProvider).hasPermission('customers.create');
    final isAdmin = ref.watch(authProvider).hasRole('ORG_ADMIN');
    return Scaffold(
      drawer: const AppDrawer(),
      bottomNavigationBar: const AppBottomNav(),
      appBar: AppBar(
        title: const Text('Customers'),
        leading: Builder(
          builder: (ctx) => IconButton(icon: const Icon(Icons.menu), onPressed: () => Scaffold.of(ctx).openDrawer()),
        ),
        actions: [
          if (isAdmin)
            IconButton(icon: const Icon(Icons.delete_outline), tooltip: 'Deleted', onPressed: () => context.push('/customers/deleted')),
        ],
      ),
      floatingActionButton: canCreate
          ? FloatingActionButton.extended(
              onPressed: () => context.push('/customers/new'),
              icon: const Icon(Icons.add),
              label: const Text('New'),
            )
          : null,
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _searchCtrl,
                    decoration: InputDecoration(
                      hintText: 'Search name, phone, ID...',
                      prefixIcon: const Icon(Icons.search),
                      suffixIcon: _searchCtrl.text.isEmpty
                          ? null
                          : IconButton(
                              icon: const Icon(Icons.clear),
                              onPressed: () {
                                _searchCtrl.clear();
                                _search = null;
                                _load(reset: true);
                              },
                            ),
                    ),
                    onSubmitted: (v) {
                      _search = v.trim().isEmpty ? null : v.trim();
                      _load(reset: true);
                    },
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () => _load(reset: true),
              child: _error != null && _items.isEmpty
                  ? ErrorView(message: _error.toString(), onRetry: () => _load(reset: true))
                  : _items.isEmpty && !_loading
                      ? const EmptyView(message: 'No customers found', icon: Icons.people_outline)
                      : ListView.builder(
                          controller: _scroll,
                          itemCount: _items.length + (_loading ? 1 : 0),
                          itemBuilder: (ctx, i) {
                            if (i >= _items.length) {
                              return const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator(strokeWidth: 2)));
                            }
                            final c = _items[i];
                            final counts = Map<String, dynamic>.from(c['_count'] ?? {});
                            final fullName = '${c['firstName'] ?? ''} ${c['lastName'] ?? ''}'.trim();
                            return Card(
                              margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                              child: ListTile(
                                onTap: () => context.push('/customers/${c['id']}'),
                                // Tapping the photo zooms it; without a photo the tap
                                // falls through to the row (no recognizer registered).
                                leading: GestureDetector(
                                  onTap: c['photo'] != null ? () => showImageViewer(ctx, c['photo']?.toString()) : null,
                                  child: Avatar(url: c['photo']?.toString(), name: fullName, size: 40),
                                ),
                                title: Text(fullName, style: const TextStyle(fontWeight: FontWeight.w600)),
                                subtitle: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('${c['customerId'] ?? ''} • ${c['phone'] ?? ''}',
                                        style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
                                    if (c['city'] != null) Text(c['city'].toString(), style: const TextStyle(fontSize: 12)),
                                  ],
                                ),
                                trailing: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    StatusChip(
                                      label: c['isActive'] == true ? 'ACTIVE' : 'INACTIVE',
                                      color: c['isActive'] == true ? AppColors.accent : AppColors.textSecondary,
                                    ),
                                    const SizedBox(height: 4),
                                    Text('${counts['loans'] ?? 0} loans',
                                        style: const TextStyle(fontSize: 11, color: AppColors.textSecondary)),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
            ),
          ),
        ],
      ),
    );
  }
}
