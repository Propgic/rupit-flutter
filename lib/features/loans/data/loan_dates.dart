// Calendar-day helpers for the loan "EMI Start Date" feature. Mirrors the web app
// (LoanCreate / LoanDetail): the API stores `emiStartDate`; null means the normal cycle
// (first EMI one period after the start date), a date — the start date itself included —
// means the first EMI is due ON it.

DateTime dayOnly(DateTime d) => DateTime(d.year, d.month, d.day);

bool sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

/// JS weekday number (0=Sun..6=Sat) — the convention the API uses for collectionDays.
int jsWeekday(DateTime d) => d.weekday % 7;

const weekdayNames = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

/// A loan group's meetingDay ("Monday") as a JS weekday number, or null when unset/unknown.
int? meetingDayIndex(dynamic meetingDay) {
  final s = meetingDay?.toString().trim().toLowerCase() ?? '';
  if (s.isEmpty) return null;
  final i = weekdayNames.indexWhere((n) => n.toLowerCase() == s);
  return i < 0 ? null : i;
}

/// First [dow] weekday (0=Sun) strictly AFTER [from] — the collection day a weekly-cadence
/// loan starts on when the officer hasn't picked an EMI start date themselves. Disbursing ON
/// the collection day rolls to the next week, so no EMI ever falls the day the money goes out.
DateTime nextWeekdayAfter(DateTime from, int dow) {
  var d = DateTime(from.year, from.month, from.day + 1);
  while (jsWeekday(d) != dow) {
    d = DateTime(d.year, d.month, d.day + 1);
  }
  return d;
}

/// Where the first EMI will ACTUALLY fall when an explicit EMI start date is picked: the
/// backend snaps it forward onto the loan's collection day(s) — a DAILY loan walks to the
/// next selected day, a weekly-cadence loan (WEEKLY type / weekly group) to its fixed
/// weekday. With no day filter it stays as picked. Mirrors `effectiveEmiStart` on the web.
DateTime effectiveEmiStart(DateTime emiStart, List<int> collectionDays) {
  if (collectionDays.isEmpty || collectionDays.length >= 7) return emiStart;
  var d = dayOnly(emiStart);
  while (!collectionDays.contains(jsWeekday(d))) {
    d = DateTime(d.year, d.month, d.day + 1);
  }
  return d;
}

/// Inline validation for the EMI start date (same rule and message as the web).
String? emiStartError(DateTime? emiStart, DateTime start) =>
    emiStart != null && dayOnly(emiStart).isBefore(dayOnly(start)) ? 'Cannot be before the disbursement date' : null;
