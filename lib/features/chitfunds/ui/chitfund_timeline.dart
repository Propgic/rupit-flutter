import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/auth/auth_controller.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../../../core/widgets/common.dart';
import '../data/chitfund_repo.dart';

// Consolidated lifecycle ("calendar") view for a single chit group: one card per
// month showing the auction, computed dues, what's been collected, what's still
// outstanding, and the winner payout — the whole chit at a glance. Backed by
// GET /chitfunds/:id/timeline. Tapping an auctioned month expands it into a
// per-member roster (expected vs collected vs status), lazily loaded from
// monthly-dues + payments. Mirrors the web ChitfundTimeline.
class ChitfundTimeline extends ConsumerStatefulWidget {
  final String chitfundId;
  final int reloadKey;
  const ChitfundTimeline({super.key, required this.chitfundId, this.reloadKey = 0});

  @override
  ConsumerState<ChitfundTimeline> createState() => _ChitfundTimelineState();
}

class _ChitfundTimelineState extends ConsumerState<ChitfundTimeline> {
  Map<String, dynamic>? _data;
  bool _loading = true;
  // Accordion: the row key currently expanded (or null), and a per-key cache of details.
  String? _openKey;
  final Map<String, Map<String, dynamic>> _details = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant ChitfundTimeline old) {
    super.didUpdateWidget(old);
    if (old.reloadKey != widget.reloadKey || old.chitfundId != widget.chitfundId) _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _openKey = null;
      _details.clear();
    });
    try {
      final res = await ref.read(chitfundRepoProvider).timeline(widget.chitfundId);
      if (mounted) setState(() { _data = res; _loading = false; });
    } catch (_) {
      if (mounted) setState(() { _data = null; _loading = false; });
    }
  }

  Future<void> _loadDetail(Map<String, dynamic> row, String key) async {
    setState(() => _details[key] = {'loading': true});
    try {
      final repo = ref.read(chitfundRepoProvider);
      final monthNumber = toNum(row['monthNumber']).toInt();
      final isFinalAccum = _data?['dividendType'] == 'ACCUMULATED'
          && monthNumber == toNum(_data?['durationMonths']).toInt()
          && row['isExtra'] != true;
      final results = await Future.wait([
        isFinalAccum ? repo.finalDues(widget.chitfundId) : repo.monthlyDues(widget.chitfundId, monthNumber),
        repo.payments(widget.chitfundId, monthNumber: monthNumber).then<dynamic>((v) => v),
      ]);
      final duesBody = Map<String, dynamic>.from(results[0] as Map);
      // final-dues exposes `finalAmount`; normalise it to `expectedAmount`.
      final rawDues = (duesBody['dues'] as List?) ?? const [];
      final dues = rawDues.map((e) {
        final m = Map<String, dynamic>.from(e as Map);
        if (isFinalAccum) m['expectedAmount'] = m['finalAmount'];
        return m;
      }).toList();
      final payments = ((results[1] as List?) ?? const [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
      // This month's winner gets a gold crown; anyone who won an earlier month gets silver.
      final currentWinnerId = (row['winner'] as Map?)?['memberId']?.toString();
      final priorWinnerIds = <String>{};
      for (final m in ((_data?['months'] as List?) ?? const [])) {
        final mm = Map<String, dynamic>.from(m as Map);
        final w = mm['winner'] as Map?;
        if (toNum(mm['monthNumber']).toInt() < monthNumber && w?['memberId'] != null) {
          priorWinnerIds.add(w!['memberId'].toString());
        }
      }
      final rows = _mergeMemberRows(dues, payments, currentWinnerId, priorWinnerIds);
      if (mounted) setState(() => _details[key] = {'rows': rows});
    } catch (_) {
      if (mounted) setState(() => _details[key] = {'error': true});
    }
  }

  // Merge per-member expected dues with that month's collection records into one roster row
  // per member. The "Collected" / "Balance" / status come from the backend's waterfall
  // allocation (dues[].paidVerified / paidPending) — a member's payments fill months oldest-
  // first, so an overpaid month is capped at its due and the excess shows against the next
  // month, instead of piling onto the month it was recorded against. The literal payment
  // records still drive the "N receipts" count and the Last Payment cell (those describe the
  // actual cash taken this month). `currentWinnerId` is this month's auction winner (gold
  // crown); `priorWinnerIds` are members who won an earlier month (silver crown).
  List<Map<String, dynamic>> _mergeMemberRows(
    List<Map<String, dynamic>> dues,
    List<Map<String, dynamic>> payments,
    String? currentWinnerId,
    Set<String> priorWinnerIds,
  ) {
    final collections = payments.where(
      (p) => (p['type'] ?? 'COLLECTION') != 'PAYOUT' && p['verificationStatus'] != 'REJECTED',
    );
    final byMember = <String, Map<String, dynamic>>{};
    for (final p in collections) {
      final mid = p['chitfundMemberId']?.toString() ?? '';
      final agg = byMember[mid] ?? {'verified': 0.0, 'pending': 0.0, 'count': 0, 'lastMode': null, 'lastDate': null};
      final amt = toNum(p['amount']).toDouble();
      if (p['verificationStatus'] == 'VERIFIED') {
        agg['verified'] = (agg['verified'] as double) + amt;
      } else {
        agg['pending'] = (agg['pending'] as double) + amt;
      }
      agg['count'] = (agg['count'] as int) + 1;
      // Payments arrive newest-first, so the first record seen is the latest.
      if (agg['lastDate'] == null) {
        agg['lastMode'] = p['paymentMode'];
        agg['lastDate'] = p['paidDate'] ?? p['createdAt'];
      }
      byMember[mid] = agg;
    }
    final rows = dues.map((d) {
      final mid = d['memberId']?.toString() ?? '';
      final agg = byMember[mid] ?? {'verified': 0.0, 'pending': 0.0, 'count': 0, 'lastMode': null, 'lastDate': null};
      final expected = toNum(d['expectedAmount']).toDouble();
      // Prefer the backend's allocated paid; fall back to the literal month sums only when
      // it's absent (e.g. the ACCUMULATED final-month dues endpoint doesn't allocate).
      final hasAlloc = d['paidVerified'] != null || d['paidPending'] != null;
      final verified = hasAlloc ? toNum(d['paidVerified']).toDouble() : agg['verified'] as double;
      final pending = hasAlloc ? toNum(d['paidPending']).toDouble() : agg['pending'] as double;
      return {
        'memberId': mid,
        'ticketNumber': d['ticketNumber'],
        'customerName': d['customerName'],
        'crown': mid == currentWinnerId ? 'gold' : (priorWinnerIds.contains(mid) ? 'silver' : null),
        'expected': expected,
        'verified': verified,
        'pending': pending,
        'remaining': (expected - verified - pending) > 0 ? (expected - verified - pending) : 0.0,
        'count': agg['count'],
        'lastMode': agg['lastMode'],
        'lastDate': agg['lastDate'],
        'status': _memberPaymentStatus(expected, verified, pending),
      };
    }).toList()
      ..sort((a, b) => toNum(a['ticketNumber']).toInt().compareTo(toNum(b['ticketNumber']).toInt()));
    return rows;
  }

  // A member's status for a month. `verified` mirrors the row's "Collected" total
  // (VERIFIED money only); `pending` is handed-over money still awaiting verification.
  ({String label, Color color}) _memberPaymentStatus(double expected, double verified, double pending) {
    if (expected <= 0.009) return (label: 'No due', color: AppColors.textSecondary);
    if (verified + 0.009 >= expected) return (label: 'Paid', color: AppColors.accent);
    if (pending > 0.009 && verified + pending + 0.009 >= expected) {
      return (label: 'Awaiting verification', color: AppColors.warning);
    }
    if (verified + pending > 0.009) return (label: 'Partial', color: AppColors.info);
    return (label: 'Pending', color: AppColors.danger);
  }

  static const _auctionStatusColor = {
    'COMPLETED': AppColors.accent,
    'SCHEDULED': AppColors.info,
    'PENDING': AppColors.textSecondary,
    'CANCELLED': AppColors.danger,
  };
  static const _auctionStatusLabel = {
    'COMPLETED': 'Auctioned',
    'SCHEDULED': 'Scheduled',
    'PENDING': 'Not started',
    'CANCELLED': 'Cancelled',
  };

  @override
  Widget build(BuildContext context) {
    final auth = ref.watch(authProvider);
    if (_loading) {
      return const Padding(padding: EdgeInsets.symmetric(vertical: 48), child: LoadingView());
    }
    if (_data == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(child: Text('Could not load the timeline.', style: TextStyle(color: AppColors.textSecondary))),
      );
    }

    final data = _data!;
    final rows = [
      ...((data['months'] as List?) ?? const []),
      ...((data['extras'] as List?) ?? const []),
    ].map((e) => Map<String, dynamic>.from(e as Map)).toList();
    final totals = Map<String, dynamic>.from(data['totals'] ?? const {});
    final chitTime = data['chitTime'];

    // Per-role money visibility (Settings → Chitfund Settings). Hidden figures are
    // also redacted server-side; hiding the card/chip keeps the redacted nulls off-screen.
    final showDue = !auth.isHidden('chitfund.totalDue');
    final showCollected = !auth.isHidden('chitfund.collected');
    final showOutstanding = !auth.isHidden('chitfund.outstanding');
    final showPayout = !auth.isHidden('chitfund.payouts');

    // Scrollable: this widget lives inside a bounded-height TabBarView, so a bare
    // Column of month cards overflows the moment the chit has more months than fit
    // on screen. Wrap in a scroll view (matching the other detail tabs' ListViews).
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showDue || showCollected || showOutstanding || showPayout) ...[
            _summaryGrid(totals, showDue: showDue, showCollected: showCollected, showOutstanding: showOutstanding, showPayout: showPayout),
            const SizedBox(height: 12),
          ],
          ...rows.map((r) => _monthCard(r, chitTime,
              showDue: showDue, showCollected: showCollected, showOutstanding: showOutstanding, showPayout: showPayout)),
        ],
      ),
    );
  }

  Widget _summaryGrid(Map<String, dynamic> t, {required bool showDue, required bool showCollected, required bool showOutstanding, required bool showPayout}) {
    final expectedDue = toNum(t['expectedDue']);
    final collected = toNum(t['collected']);
    final collectedPct = expectedDue > 0 ? ((collected / expectedDue) * 100).round() : 0;
    final payoutPending = toNum(t['payoutPending']);
    final tiles = <Widget>[
      if (showDue) _summaryTile(Icons.account_balance_wallet_outlined, 'Total Due', formatCurrency(expectedDue), AppColors.primary),
      if (showCollected) _summaryTile(Icons.volunteer_activism_outlined, 'Collected', formatCurrency(collected), AppColors.accent, sub: '$collectedPct% of due'),
      if (showOutstanding) _summaryTile(Icons.error_outline, 'Outstanding', formatCurrency(t['outstanding']), AppColors.danger),
      if (showPayout) _summaryTile(Icons.gavel_outlined, 'Payouts', formatCurrency(toNum(t['payoutPaid']) + payoutPending), AppColors.warning,
          sub: payoutPending > 0 ? '${formatCurrency(payoutPending)} pending' : 'all settled'),
    ];
    return GridView.count(
      crossAxisCount: 2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 2.4,
      children: tiles,
    );
  }

  Widget _summaryTile(IconData icon, String label, String value, Color color, {String? sub}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(12)),
      child: Row(
        children: [
          Icon(icon, size: 20, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color.withValues(alpha: 0.9))),
                Text(value, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: AppColors.textPrimary)),
                if (sub != null) Text(sub, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: AppColors.textSecondary)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  bool _isExpandable(Map<String, dynamic> r) =>
      r['isExtra'] != true && (r['auctionStatus'] == 'COMPLETED' || toNum(r['collected']) > 0);

  Widget _monthCard(Map<String, dynamic> r, dynamic chitTime,
      {required bool showDue, required bool showCollected, required bool showOutstanding, required bool showPayout}) {
    final isExtra = r['isExtra'] == true;
    final isCurrent = r['isCurrentMonth'] == true;
    final expandable = _isExpandable(r);
    final key = isExtra ? 'extra-${r['monthNumber']}-${r['auctionDate']}' : 'm-${r['monthNumber']}';
    final open = _openKey == key;
    final status = r['auctionStatus']?.toString() ?? 'PENDING';
    final winner = r['winner'] as Map?;
    final payout = r['payout'] as Map?;

    final moneyChips = <Widget>[
      if (showDue && r['expectedDue'] != null) _moneyChip('Due', formatCurrency(r['expectedDue'])),
      if (showCollected && r['collected'] != null)
        _moneyChip('Collected', formatCurrency(r['collected']),
            color: AppColors.accent,
            sub: toNum(r['collectedCount']) > 0 ? '${toNum(r['collectedCount']).toInt()} paid' : null),
      if (showOutstanding && r['outstanding'] != null)
        _moneyChip('Outstanding', toNum(r['outstanding']) > 0 ? formatCurrency(r['outstanding']) : 'Cleared',
            color: toNum(r['outstanding']) > 0 ? AppColors.danger : AppColors.accent),
      if (showPayout && (payout != null || r['netPayoutToWinner'] != null))
        _moneyChip('Payout', formatCurrency(payout != null ? payout['amount'] : r['netPayoutToWinner']),
            color: AppColors.warning,
            sub: payout != null ? (payout['status'] == 'PAID' ? 'Paid' : 'Pending') : null),
    ];

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: open ? AppColors.primary.withValues(alpha: 0.4) : AppColors.border),
      ),
      color: isCurrent && !open ? AppColors.primarySoft.withValues(alpha: 0.5) : AppColors.surface,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: expandable ? () {
          setState(() => _openKey = open ? null : key);
          if (!open && !_details.containsKey(key)) _loadDetail(r, key);
        } : null,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (expandable)
                    AnimatedRotation(
                      turns: open ? 0.25 : 0,
                      duration: const Duration(milliseconds: 150),
                      child: const Icon(Icons.chevron_right, size: 20, color: AppColors.textSecondary),
                    ),
                  if (expandable) const SizedBox(width: 2),
                  if (isExtra)
                    const _MiniBadge(label: 'Extra', color: AppColors.purple, icon: Icons.auto_awesome)
                  else
                    Text('Month ${r['monthNumber']}', style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800)),
                  if (isCurrent) ...[
                    const SizedBox(width: 6),
                    const _MiniBadge(label: 'Current', color: AppColors.primary),
                  ],
                  const Spacer(),
                  _MiniBadge(label: _auctionStatusLabel[status] ?? status, color: _auctionStatusColor[status] ?? AppColors.textSecondary),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '${formatDate(r['auctionDate'])}${chitTime != null ? ' · ${formatChitTime(chitTime)}' : ''}',
                style: const TextStyle(fontSize: 12, color: AppColors.textSecondary),
              ),
              if (toNum(r['bidAmount']) > 0 || winner != null) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    if (winner != null) ...[
                      const Icon(Icons.emoji_events, size: 15, color: AppColors.warning),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          '${winner['customerName'] ?? '—'} · #${winner['ticketNumber']}',
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                    if (r['bidAmount'] != null && toNum(r['bidAmount']) > 0) ...[
                      const Spacer(),
                      Text('Bid ${formatCurrency(r['bidAmount'])}', style: const TextStyle(fontSize: 11.5, color: AppColors.textSecondary)),
                    ],
                  ],
                ),
              ],
              if (showCollected && r['collected'] != null && toNum(r['expectedDue']) > 0) ...[
                const SizedBox(height: 8),
                _CollectionBar(collected: toNum(r['collected']).toDouble(), due: toNum(r['expectedDue']).toDouble()),
              ],
              if (moneyChips.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(spacing: 8, runSpacing: 8, children: moneyChips),
              ],
              if (open) ...[
                const Divider(height: 20),
                _MonthRoster(detail: _details[key]),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _moneyChip(String label, String value, {Color? color, String? sub}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(color: AppColors.bg, borderRadius: BorderRadius.circular(8)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(fontSize: 10, color: AppColors.textSecondary)),
          Text(value, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: color ?? AppColors.textPrimary)),
          if (sub != null) Text(sub, style: const TextStyle(fontSize: 10, color: AppColors.textMuted)),
        ],
      ),
    );
  }
}

// Thin progress bar showing collected vs. expected for the month.
class _CollectionBar extends StatelessWidget {
  final double collected;
  final double due;
  const _CollectionBar({required this.collected, required this.due});
  @override
  Widget build(BuildContext context) {
    if (due <= 0) return const SizedBox.shrink();
    final pct = (collected / due).clamp(0.0, 1.0);
    final full = pct >= 1.0;
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: LinearProgressIndicator(
        value: pct,
        minHeight: 6,
        backgroundColor: AppColors.border,
        valueColor: AlwaysStoppedAnimation(full ? AppColors.accent : (pct > 0 ? AppColors.primary : AppColors.border)),
      ),
    );
  }
}

class _MiniBadge extends StatelessWidget {
  final String label;
  final Color color;
  final IconData? icon;
  const _MiniBadge({required this.label, required this.color, this.icon});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 11, color: color), const SizedBox(width: 3)],
          Text(label, style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w700, color: color)),
        ],
      ),
    );
  }
}

// Expanded per-member breakdown for one month.
class _MonthRoster extends StatelessWidget {
  final Map<String, dynamic>? detail;
  const _MonthRoster({this.detail});

  @override
  Widget build(BuildContext context) {
    final d = detail;
    if (d == null || d['loading'] == true) {
      return const Padding(padding: EdgeInsets.symmetric(vertical: 16), child: Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))));
    }
    if (d['error'] == true) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(child: Text("Could not load this month's payments.", style: TextStyle(fontSize: 12, color: AppColors.textSecondary))),
      );
    }
    final rows = (d['rows'] as List?)?.cast<Map<String, dynamic>>() ?? const [];
    if (rows.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(child: Text('No members in this chit.', style: TextStyle(fontSize: 12, color: AppColors.textSecondary))),
      );
    }
    final paidCount = rows.where((r) {
      final label = (r['status'] as ({String label, Color color})).label;
      return label == 'Paid' || label == 'No due';
    }).length;
    final expectedTotal = rows.fold<double>(0, (s, r) => s + (r['expected'] as double));
    final verifiedTotal = rows.fold<double>(0, (s, r) => s + (r['verified'] as double));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('$paidCount of ${rows.length} members paid', style: const TextStyle(fontSize: 11.5, color: AppColors.textSecondary)),
            ),
            Text('${formatCurrency(verifiedTotal)} of ${formatCurrency(expectedTotal)}',
                style: const TextStyle(fontSize: 11.5, color: AppColors.textSecondary)),
          ],
        ),
        const SizedBox(height: 8),
        ...rows.map(_rosterRow),
      ],
    );
  }

  Widget _rosterRow(Map<String, dynamic> r) {
    final crown = r['crown'];
    final status = r['status'] as ({String label, Color color});
    final remaining = r['remaining'] as double;
    final pending = r['pending'] as double;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: crown != null ? AppColors.orange.withValues(alpha: 0.08) : AppColors.bg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Flexible(
                child: Text(r['customerName']?.toString() ?? '—',
                    overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
              ),
              if (crown == 'gold') ...[const SizedBox(width: 4), const Icon(Icons.emoji_events, size: 14, color: AppColors.warning)],
              if (crown == 'silver') ...[const SizedBox(width: 4), Icon(Icons.emoji_events, size: 14, color: AppColors.textMuted)],
              const Spacer(),
              StatusChip(label: status.label, color: status.color),
            ],
          ),
          Text('Ticket #${r['ticketNumber']}', style: const TextStyle(fontSize: 11, color: AppColors.textMuted)),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(child: _miniStat('Expected', formatCurrency(r['expected']))),
              Expanded(
                child: _miniStat('Collected', formatCurrency(r['verified']),
                    sub: pending > 0.009 ? '+${formatCurrency(pending)} unverified' : null, subColor: AppColors.warning),
              ),
              Expanded(
                child: _miniStat('Balance', remaining > 0.009 ? formatCurrency(remaining) : '—',
                    valueColor: remaining > 0.009 ? AppColors.danger : AppColors.accent),
              ),
            ],
          ),
          if (r['lastDate'] != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Last: ${r['lastMode'] ?? '—'} · ${formatDate(r['lastDate'])}${toNum(r['count']) > 1 ? ' (${toNum(r['count']).toInt()})' : ''}',
                style: const TextStyle(fontSize: 10.5, color: AppColors.textMuted),
              ),
            ),
        ],
      ),
    );
  }

  Widget _miniStat(String label, String value, {Color? valueColor, String? sub, Color? subColor}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 9.5, color: AppColors.textMuted)),
        Text(value, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: valueColor ?? AppColors.textPrimary)),
        if (sub != null) Text(sub, style: TextStyle(fontSize: 9, color: subColor ?? AppColors.textMuted)),
      ],
    );
  }
}
