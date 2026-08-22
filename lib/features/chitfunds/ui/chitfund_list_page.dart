import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/common.dart';
import '../data/chitfund_repo.dart';
import '../../app_shell.dart';
import '../../../core/widgets/app_bottom_nav.dart';

// Status tabs, mirroring the web Chitfunds list. "All" is the working list — every
// chit still in play — so it EXCLUDES closed chits, which have their own tab and
// would otherwise bury the live ones. (Web sends the same excludeStatus=COMPLETED.)
const _statusPills = <List<String>>[
  ['ALL', 'All'],
  ['UPCOMING', 'Upcoming'],
  ['ACTIVE', 'Active'],
  ['COMPLETED', 'Closed'],
];

class ChitfundListPage extends ConsumerStatefulWidget {
  const ChitfundListPage({super.key});
  @override
  ConsumerState<ChitfundListPage> createState() => _ChitfundListPageState();
}

class _ChitfundListPageState extends ConsumerState<ChitfundListPage> {
  final _scroll = ScrollController();
  final _searchCtrl = TextEditingController();
  final List<Map<String, dynamic>> _items = [];
  String _statusTab = 'ALL';
  String? _search;
  int _page = 1;
  bool _loading = false;
  bool _hasMore = true;
  int _total = 0;
  Object? _error;
  // Bumped on every reset (tab switch / new search). A response whose id no longer
  // matches has been superseded — dropping it stops a slow page-1 load from
  // painting the old tab's chits under the pill the user just tapped.
  int _reqId = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 300 && !_loading && _hasMore) {
        _load();
      }
    });
    _load(reset: true);
  }

  @override
  void dispose() {
    _scroll.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load({bool reset = false}) async {
    // A reset always wins — it supersedes whatever is in flight.
    if (_loading && !reset) return;
    final req = reset ? ++_reqId : _reqId;
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
      final res = await ref
          .read(chitfundRepoProvider)
          .list(
            page: _page,
            search: _search,
            status: _statusTab == 'ALL' ? null : _statusTab,
            excludeStatus: _statusTab == 'ALL' ? 'COMPLETED' : null,
          );
      if (req != _reqId) return; // superseded by a newer tab/search load
      final data = extractList(res['data'] ?? res);
      final pg = Map<String, dynamic>.from(
        res['pagination'] ?? (res['data'] is Map ? res['data']['pagination'] ?? {} : {}),
      );
      setState(() {
        _items.addAll(data.map((e) => Map<String, dynamic>.from(e as Map)));
        _page += 1;
        _hasMore = _page <= (toNum(pg['totalPages'], 1)).toInt();
        _total = toNum(pg['total']).toInt();
      });
    } catch (e) {
      if (req != _reqId) return;
      setState(() {
        _error = e;
        if (_items.isEmpty) _total = 0;
      });
    } finally {
      if (mounted && req == _reqId) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final canCreate = ref.watch(authProvider).hasPermission('chitfunds.create');
    return Scaffold(
      drawer: const AppDrawer(),
      bottomNavigationBar: const AppBottomNav(),
      appBar: AppBar(
        title: const Text('Chitfunds'),
        leading: Builder(
          builder: (ctx) => IconButton(icon: const Icon(Icons.menu), onPressed: () => Scaffold.of(ctx).openDrawer()),
        ),
      ),
      floatingActionButton: canCreate
          ? FloatingActionButton.extended(
              onPressed: () => context.push('/chitfunds/new'),
              icon: const Icon(Icons.add),
              label: const Text('New'),
            )
          : null,
      // Search scrolls away with the list; the status pills stay pinned so
      // switching tabs never means scrolling back up (mirrors the loans list).
      body: RefreshIndicator(
        onRefresh: () => _load(reset: true),
        child: CustomScrollView(
          controller: _scroll,
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: _searchCtrl,
                      decoration: InputDecoration(
                        hintText: 'Search chitfunds...',
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _search == null
                            ? null
                            : IconButton(
                                icon: const Icon(Icons.clear, size: 18),
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
                    // How many chits match the current tab + search, across all pages —
                    // the mobile stand-in for the web list's pagination summary.
                    if (_total > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 6, right: 2),
                        child: Text(
                          '$_total ${_total == 1 ? 'chitfund' : 'chitfunds'}',
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            SliverPersistentHeader(
              pinned: true,
              delegate: PinnedHeaderDelegate(
                height: 34 + MediaQuery.textScalerOf(context).scale(18),
                child: Container(
                  color: AppColors.bg,
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                  child: Row(
                    children: [
                      for (final pill in _statusPills)
                        Expanded(
                          child: StatusPill(
                            label: pill[1],
                            selected: _statusTab == pill[0],
                            onTap: () {
                              if (_statusTab == pill[0]) return;
                              setState(() => _statusTab = pill[0]);
                              _load(reset: true);
                            },
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
            if (_error != null && _items.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: ErrorView(message: _error.toString(), onRetry: () => _load(reset: true)),
              )
            else if (_items.isEmpty && !_loading)
              SliverFillRemaining(
                hasScrollBody: false,
                child: EmptyView(
                  message: _statusTab == 'COMPLETED' ? 'No closed chitfunds' : 'No chitfunds',
                  icon: Icons.account_balance_wallet_outlined,
                ),
              )
            else
              SliverPadding(
                // Clears the extended FAB over the last card.
                padding: const EdgeInsets.only(bottom: 80),
                sliver: SliverList.builder(itemCount: _items.length + (_loading ? 1 : 0), itemBuilder: _chitTile),
              ),
          ],
        ),
      ),
    );
  }

  /// One chit card; the index past the end renders the pagination spinner
  /// while the next page loads.
  Widget _chitTile(BuildContext ctx, int i) {
    if (i >= _items.length) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    final c = _items[i];
    final chitTime = c['chitTime']?.toString().trim() ?? '';
    final officer = Map<String, dynamic>.from(c['assignedTo'] ?? {})['name']?.toString() ?? '';
    final duration = toNum(c['durationMonths']).toInt();
    final auctionsDone = toNum(Map<String, dynamic>.from(c['_count'] ?? {})['auctions']).toInt();
    // Mirrors the web list: a chit whose every month has been auctioned is finished
    // in practice even while its status still reads ACTIVE — an admin can close it.
    final allAuctionsDone = duration > 0 && auctionsDone >= duration && c['status'] == 'ACTIVE';
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      color: allAuctionsDone ? AppColors.accent.withValues(alpha: 0.12) : null,
      child: ListTile(
        onTap: () => context.push('/chitfunds/${c['id']}'),
        title: Text(c['name']?.toString() ?? ''),
        subtitle: Text(
          [
            formatCurrency(c['totalAmount']),
            '${c['durationMonths'] ?? 0}m',
            '${c['totalMembers'] ?? 0} members',
            '$auctionsDone/$duration auctions',
            if (chitTime.isNotEmpty) formatChitTime(chitTime),
            if (officer.isNotEmpty) '👤 $officer',
          ].join(' • '),
        ),
        trailing: StatusChip(
          label: c['status'] == 'COMPLETED' ? 'CLOSED' : (c['status']?.toString() ?? ''),
          color: statusColor(c['status']?.toString()),
        ),
      ),
    );
  }
}
