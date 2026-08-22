import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/formatters.dart';
import '../data/loan_dates.dart';

/// "EMI Start Date" picker shared by loan create / edit / correct — mirrors the web field.
/// [emiStart] null = the normal cycle (first EMI one period after the start date); a date
/// — the start date itself included — makes the first EMI fall due ON it. Days before the
/// start date are deliberately NOT disabled in the picker (a greyed-out day is silently
/// ignored and the officer never learns the pick was rejected) — an inline error shows
/// instead and the caller blocks the save.
class EmiStartDateTile extends StatelessWidget {
  final DateTime startDate;
  final DateTime? emiStart;
  /// JS weekday numbers (0=Sun) the loan collects on; empty = no day filter.
  final List<int> collectionDays;
  /// How an untouched date was prefilled — shown by the create form, which fills the field
  /// in for the officer. Edit/correct load the loan's stored date and pass nothing.
  final String? prefillNote;
  final ValueChanged<DateTime?> onChanged;

  const EmiStartDateTile({
    super.key,
    required this.startDate,
    required this.emiStart,
    required this.onChanged,
    this.collectionDays = const [],
    this.prefillNote,
  });

  @override
  Widget build(BuildContext context) {
    final picked = emiStart;
    final error = emiStartError(picked, startDate);
    // Snap preview: where the picked date actually lands on the loan's collection days.
    final effective = picked == null ? null : effectiveEmiStart(picked, collectionDays);
    final snapHint = picked != null && effective != null && error == null && !sameDay(effective, picked)
        ? 'Collections fall on ${weekdayNames[jsWeekday(effective)]}s, so the first EMI will be due ${formatDate(effective)}.'
        : null;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(picked == null ? 'EMI Start Date: Normal cycle' : 'EMI Start Date: ${formatDate(picked)}'),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Normal cycle = first EMI one period after the start date, on the collection day. '
            'Pick a date — the start date itself included — and the first EMI falls due on it.',
            style: TextStyle(fontSize: 12, color: AppColors.textSecondary),
          ),
          if (prefillNote != null)
            Text(prefillNote!, style: const TextStyle(fontSize: 12, color: AppColors.textSecondary)),
          if (error != null)
            Text(error, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.error)),
          if (snapHint != null)
            Text(snapHint, style: const TextStyle(fontSize: 12, color: AppColors.warning)),
        ],
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (picked != null)
            IconButton(
              icon: const Icon(Icons.clear),
              tooltip: 'Back to normal cycle',
              onPressed: () => onChanged(null),
            ),
          const Icon(Icons.calendar_today),
        ],
      ),
      onTap: () async {
        final first = DateTime(2015);
        final last = DateTime.now().add(const Duration(days: 365));
        var initial = dayOnly(picked ?? startDate);
        if (initial.isBefore(first)) initial = first;
        if (initial.isAfter(last)) initial = last;
        final d = await showDatePicker(context: context, firstDate: first, lastDate: last, initialDate: initial);
        if (d != null) onChanged(d);
      },
    );
  }
}
