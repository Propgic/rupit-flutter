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

class ChitfundListPage extends ConsumerStatefulWidget {
  const ChitfundListPage({super.key});
  @override
  ConsumerState<ChitfundListPage> createState() => _ChitfundListPageState();
}

class _ChitfundListPageState extends ConsumerState<ChitfundListPage> {
  Future<Map<String, dynamic>>? _future;

  @override
  void initState() { super.initState(); _load(); }

  void _load() { _future = ref.read(chitfundRepoProvider).list(); setState(() {}); }

  @override
  Widget build(BuildContext context) {
    final canCreate = ref.watch(authProvider).hasPermission('chitfunds.create');
    return Scaffold(
      drawer: const AppDrawer(),
      bottomNavigationBar: const AppBottomNav(),
      appBar: AppBar(
        title: const Text('Chitfunds'),
        leading: Builder(builder: (ctx) => IconButton(icon: const Icon(Icons.menu), onPressed: () => Scaffold.of(ctx).openDrawer())),
      ),
      floatingActionButton: canCreate
          ? FloatingActionButton.extended(onPressed: () => context.push('/chitfunds/new'), icon: const Icon(Icons.add), label: const Text('New'))
          : null,
      body: FutureBuilder<Map<String, dynamic>>(
        future: _future,
        builder: (ctx, snap) {
          if (snap.connectionState == ConnectionState.waiting) return const LoadingView();
          if (snap.hasError) return ErrorView(message: snap.error.toString(), onRetry: _load);
          final items = extractList(snap.data?['data'] ?? snap.data);
          if (items.isEmpty) return const EmptyView(message: 'No chitfunds', icon: Icons.account_balance_wallet_outlined);
          return RefreshIndicator(
            onRefresh: () async => _load(),
            child: ListView.builder(
              itemCount: items.length,
              itemBuilder: (ctx, i) {
                final c = Map<String, dynamic>.from(items[i] as Map);
                final chitTime = c['chitTime']?.toString().trim() ?? '';
                final officer = Map<String, dynamic>.from(c['assignedTo'] ?? {})['name']?.toString() ?? '';
                final duration = toNum(c['durationMonths']).toInt();
                final auctionsDone = toNum(Map<String, dynamic>.from(c['_count'] ?? {})['auctions']).toInt();
                // Mirrors the web list: a chit whose every month has been auctioned is
                // finished in practice even while its status still reads ACTIVE.
                final allAuctionsDone = duration > 0 && auctionsDone >= duration;
                return Card(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  color: allAuctionsDone ? AppColors.accent.withValues(alpha: 0.12) : null,
                  child: ListTile(
                    onTap: () => context.push('/chitfunds/${c['id']}'),
                    title: Text(c['name']?.toString() ?? ''),
                    subtitle: Text([
                      formatCurrency(c['totalAmount']),
                      '${c['durationMonths'] ?? 0}m',
                      '${c['totalMembers'] ?? 0} members',
                      '$auctionsDone/$duration auctions',
                      if (chitTime.isNotEmpty) formatChitTime(chitTime),
                      if (officer.isNotEmpty) '👤 $officer',
                    ].join(' • ')),
                    trailing: StatusChip(label: c['status']?.toString() ?? '', color: statusColor(c['status']?.toString())),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}
