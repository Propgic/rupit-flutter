import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/api/api_client.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/common.dart';
import '../data/investor_repo.dart';
import '../../app_shell.dart';
import '../../../core/widgets/app_bottom_nav.dart';

class InvestorListPage extends ConsumerStatefulWidget {
  const InvestorListPage({super.key});
  @override
  ConsumerState<InvestorListPage> createState() => _InvestorListPageState();
}

class _InvestorListPageState extends ConsumerState<InvestorListPage> {
  Future<Map<String, dynamic>>? _future;
  Map<String, dynamic>? _summary;

  @override
  void initState() {
    super.initState();
    _load();
    _loadSummary();
  }

  void _load() {
    _future = ref.read(investorRepoProvider).list();
    setState(() {});
  }

  Future<void> _loadSummary() async {
    try {
      final s = await ref.read(investorRepoProvider).summary();
      if (mounted) setState(() => _summary = s);
    } catch (_) {
      // Summary is non-critical; leave cards at their null-safe defaults.
    }
  }

  Future<void> _toggleStatus(Map<String, dynamic> inv) async {
    final wasActive = inv['isActive'] == true;
    try {
      await ref.read(investorRepoProvider).toggleStatus(inv['id']?.toString() ?? '');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Investor ${wasActive ? 'deactivated' : 'activated'}')),
      );
      _load();
      _loadSummary();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e is ApiException ? e.message : 'Failed to update status')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final canCreate = ref.watch(authProvider).hasPermission('investors.create');
    return Scaffold(
      drawer: const AppDrawer(),
      bottomNavigationBar: const AppBottomNav(),
      appBar: AppBar(
        title: const Text('Investors'),
        leading: Builder(builder: (ctx) => IconButton(icon: const Icon(Icons.menu), onPressed: () => Scaffold.of(ctx).openDrawer())),
        actions: [
          IconButton(icon: const Icon(Icons.add_card_outlined), tooltip: 'New Investment', onPressed: () => context.push('/investments/new')),
        ],
      ),
      floatingActionButton: canCreate
          ? FloatingActionButton.extended(onPressed: () => context.push('/investors/new'), icon: const Icon(Icons.add), label: const Text('New'))
          : null,
      body: FutureBuilder<Map<String, dynamic>>(
        future: _future,
        builder: (ctx, snap) {
          if (snap.connectionState == ConnectionState.waiting) return const LoadingView();
          if (snap.hasError) return ErrorView(message: snap.error.toString(), onRetry: _load);
          final items = extractList(snap.data?['data'] ?? snap.data);
          return RefreshIndicator(
            onRefresh: () async {
              _load();
              await _loadSummary();
            },
            child: ListView(
              children: [
                _summaryGrid(),
                if (items.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(top: 48),
                    child: EmptyView(message: 'No investors', icon: Icons.trending_up),
                  )
                else
                  ...items.map((raw) {
                    final inv = Map<String, dynamic>.from(raw as Map);
                    final isActive = inv['isActive'] == true;
                    return Card(
                      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                      child: ListTile(
                        onTap: () => context.push('/investors/${inv['id']}'),
                        leading: Avatar(name: inv['name']?.toString() ?? ''),
                        title: Text(inv['name']?.toString() ?? ''),
                        subtitle: Text(inv['phone']?.toString() ?? ''),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                Text(formatCurrency(inv['totalInvested']), style: const TextStyle(fontWeight: FontWeight.w600)),
                                StatusChip(label: isActive ? 'ACTIVE' : 'INACTIVE', color: isActive ? AppColors.accent : AppColors.textSecondary),
                              ],
                            ),
                            IconButton(
                              tooltip: isActive ? 'Deactivate' : 'Activate',
                              icon: Icon(
                                isActive ? Icons.toggle_on : Icons.toggle_off,
                                color: isActive ? AppColors.accent : AppColors.textMuted,
                                size: 28,
                              ),
                              onPressed: () => _toggleStatus(inv),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _summaryGrid() {
    final s = _summary;
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
      mainAxisSpacing: 10,
      crossAxisSpacing: 10,
      childAspectRatio: 1.5,
      children: [
        _statCard(
          label: 'Total Investors',
          value: '${s?['totalInvestors'] ?? 0}',
          color: AppColors.primary,
          icon: Icons.groups_outlined,
          subtitle: s != null ? '${s['activeInvestors'] ?? 0} active' : null,
        ),
        _statCard(
          label: 'Active Investors',
          value: '${s?['activeInvestors'] ?? 0}',
          color: AppColors.accent,
          icon: Icons.how_to_reg_outlined,
        ),
        _statCard(
          label: 'Total Invested',
          value: formatCurrency(s?['totalInvested'] ?? 0),
          color: AppColors.purple,
          icon: Icons.account_balance_wallet_outlined,
          subtitle: s != null ? '${s['activeInvestments'] ?? 0} active investments' : null,
        ),
        _statCard(
          label: 'Share Allocated',
          value: '${s?['totalSharePercentage'] ?? 0}%',
          color: AppColors.orange,
          icon: Icons.pie_chart_outline,
        ),
      ],
    );
  }

  Widget _statCard({
    required String label,
    required String value,
    required Color color,
    required IconData icon,
    String? subtitle,
  }) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, size: 16, color: color),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  label,
                  style: const TextStyle(fontSize: 12, color: AppColors.textSecondary, fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const Spacer(),
          Text(
            value,
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: color),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (subtitle != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                subtitle,
                style: const TextStyle(fontSize: 11, color: AppColors.textMuted),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }
}
