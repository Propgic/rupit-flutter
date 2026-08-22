import 'package:intl/intl.dart';

final _inr = NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 0);
final _inrDec = NumberFormat.currency(locale: 'en_IN', symbol: '₹', decimalDigits: 2);
final _dateFmt = DateFormat('dd MMM yyyy');
final _dateTimeFmt = DateFormat('dd MMM yyyy, hh:mm a');
final _timeFmt = DateFormat('hh:mm a');
final _inputDate = DateFormat('yyyy-MM-dd');
// Indian-grouped patterns for compact currency: 0/2-decimal variants.
final _inGroupInt = NumberFormat('#,##,##0', 'en_IN');
final _inGroupDec = NumberFormat('#,##,##0.##', 'en_IN');

String formatCurrency(dynamic v, {bool decimals = false}) {
  if (v == null) return '-';
  num? n;
  if (v is num) {
    n = v;
  } else {
    n = num.tryParse(v.toString());
  }
  if (n == null) return '-';
  return (decimals ? _inrDec : _inr).format(n);
}

String formatDate(dynamic v) {
  if (v == null) return '-';
  try {
    final d = v is DateTime ? v : DateTime.parse(v.toString()).toLocal();
    return _dateFmt.format(d);
  } catch (_) {
    return v.toString();
  }
}

String formatDateTime(dynamic v) {
  if (v == null) return '-';
  try {
    final d = v is DateTime ? v : DateTime.parse(v.toString()).toLocal();
    return _dateTimeFmt.format(d);
  } catch (_) {
    return v.toString();
  }
}

String formatInputDate(DateTime d) => _inputDate.format(d);

/// Loan types that repay once a week — their age reads as "Week N", not "Day N".
/// Group loans are always weekly lines, so they count in weeks like WEEKLY loans.
const _weeklyLoanTypes = {'WEEKLY', 'GROUP'};

/// How far into its repayment a loan is, mirroring formatLoanAge() in the web
/// app's formatters.js. Daily loans count calendar age — the disbursement day
/// itself is Day 1. Weekly ones count INSTALLMENTS instead: the disbursement week
/// is Week 0 (nothing has fallen due yet) and the number ticks to 1 on the day the
/// first installment is due — the week the field speaks in, and what the group
/// screen shows as "Week 12 / 20". The server sends that count
/// (`installmentsElapsed`); without it — an older payload, or a loan carrying no
/// schedule — fall back to the same convention off the disbursement date.
/// Returns '-' when there is no disbursement date or the loan hasn't started yet.
String dayWeekLabel(dynamic disbursedDate, String? loanType,
    [dynamic installmentsElapsed]) {
  if (disbursedDate == null) return '-';
  DateTime d;
  try {
    d = DateTime.parse(disbursedDate.toString()).toLocal();
  } catch (_) {
    return '-';
  }
  final days = DateTime.now().difference(d).inDays + 1;
  if (days <= 0) return '-';
  if (_weeklyLoanTypes.contains(loanType)) {
    final elapsed = installmentsElapsed is num
        ? installmentsElapsed.toInt()
        : int.tryParse(installmentsElapsed?.toString() ?? '');
    if (elapsed != null) return 'Week $elapsed';
    return 'Week ${(days - 1) ~/ 7}';
  }
  return 'Day $days';
}

/// Time-only (12-hour) for a full datetime, e.g. "05:30 PM". Used where the date
/// is already shown alongside and only the clock time needs to appear. Mirrors
/// formatTime() in the web app's formatters.js.
String formatTime(dynamic v) {
  if (v == null) return '-';
  try {
    final d = v is DateTime ? v : DateTime.parse(v.toString()).toLocal();
    return _timeFmt.format(d);
  } catch (_) {
    return '-';
  }
}

/// Compact Indian-notation currency for tight spaces (e.g. dense metric cards):
/// ₹1.08 Cr, ₹33.8 L. Under a lakh it stays a plain grouped number since those
/// already fit. Mirrors formatCurrencyCompact() in the web app's formatters.js.
String formatCurrencyCompact(dynamic v) {
  final n = v is num ? v : num.tryParse(v?.toString() ?? '');
  if (n == null) return '₹0';
  final sign = n < 0 ? '-' : '';
  final abs = n.abs();
  // Round to 2 decimals then let the pattern drop trailing zeros (1.10 → 1.1, 2.00 → 2).
  String trim(num val) => _inGroupDec.format(double.parse(val.toStringAsFixed(2)));
  String body;
  if (abs >= 1e7) {
    body = '${trim(abs / 1e7)} Cr';
  } else if (abs >= 1e5) {
    body = '${trim(abs / 1e5)} L';
  } else {
    body = _inGroupInt.format(abs.round());
  }
  return '$sign₹$body';
}

/// Formats a chit auction time stored as a "HH:mm" 24-hour string into a
/// 12-hour "h:mm AM/PM" label. Returns '-' when unset (legacy/mobile chits may
/// omit it). Mirrors formatChitTime() in the web app's formatters.js.
String formatChitTime(dynamic v) {
  if (v == null) return '-';
  final time = v.toString().trim();
  if (time.isEmpty) return '-';
  final m = RegExp(r'^(\d{1,2}):(\d{2})$').firstMatch(time);
  if (m == null) return time;
  final hour = int.parse(m.group(1)!);
  final minute = m.group(2)!;
  if (hour > 23 || int.parse(minute) > 59) return time;
  final period = hour < 12 ? 'AM' : 'PM';
  final h12 = hour % 12 == 0 ? 12 : hour % 12;
  return '$h12:$minute $period';
}

DateTime? tryParseDate(String? s) {
  if (s == null || s.isEmpty) return null;
  try {
    return DateTime.parse(s);
  } catch (_) {
    return null;
  }
}

List<dynamic> extractList(dynamic data) {
  if (data is List) return data;
  if (data is Map) {
    for (final k in const ['data', 'expenses', 'collections', 'items', 'loans', 'customers', 'savings', 'members', 'auctions', 'payments', 'transactions', 'entries', 'investments']) {
      if (data[k] is List) return data[k] as List;
    }
  }
  return const [];
}

/// Whether a sensitive loan field was redacted server-side for the current
/// user's role. An org admin configures this under Settings → Loan Field
/// Visibility; the API then nulls the value and lists the hidden raw keys in
/// `_hiddenFields` (e.g. interestRate, totalInterest, processingFee,
/// totalPayable) so clients omit the row instead of showing a blank/zero.
bool loanFieldHidden(Map? loan, String key) {
  final hidden = loan?['_hiddenFields'];
  return hidden is List && hidden.contains(key);
}

num toNum(dynamic v, [num fallback = 0]) {
  if (v == null) return fallback;
  if (v is num) return v;
  return num.tryParse(v.toString()) ?? fallback;
}

String titleCase(String s) {
  if (s.isEmpty) return s;
  return s
      .toLowerCase()
      .split('_')
      .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
      .join(' ');
}
