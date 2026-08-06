import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:fluttertoast/fluttertoast.dart';
import '../theme/app_theme.dart';

void showToast(String msg, {bool error = false}) {
  Fluttertoast.showToast(
    msg: msg,
    toastLength: Toast.LENGTH_SHORT,
    gravity: ToastGravity.BOTTOM,
    backgroundColor: error ? AppColors.danger : AppColors.textPrimary,
    textColor: Colors.white,
    fontSize: 14,
  );
}

String? resolveUrl(String? path) {
  if (path == null || path.isEmpty) return null;
  if (path.startsWith('http://') || path.startsWith('https://')) return path;
  final base = dotenv.env['API_BASE_URL'] ?? '';
  final origin = base.replaceAll(RegExp(r'/api/?$'), '');
  // Match web: strip any leading path up through "uploads/" so only the filename remains.
  final filename = path.replaceFirst(RegExp(r'^.*uploads/'), '');
  return '$origin/uploads/$filename';
}

class LoadingView extends StatelessWidget {
  const LoadingView({super.key});
  @override
  Widget build(BuildContext context) => const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: CircularProgressIndicator(strokeWidth: 2.5),
        ),
      );
}

class ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;
  const ErrorView({super.key, required this.message, this.onRetry});
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, color: AppColors.danger, size: 48),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
              if (onRetry != null) ...[
                const SizedBox(height: 12),
                OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
              ],
            ],
          ),
        ),
      );
}

class EmptyView extends StatelessWidget {
  final String message;
  final IconData icon;
  final Widget? action;
  const EmptyView({super.key, required this.message, this.icon = Icons.inbox_outlined, this.action});
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 56, color: AppColors.textSecondary),
              const SizedBox(height: 12),
              Text(message, style: const TextStyle(color: AppColors.textSecondary)),
              if (action != null) ...[const SizedBox(height: 16), action!],
            ],
          ),
        ),
      );
}

class SectionCard extends StatelessWidget {
  final String? title;
  final Widget child;
  final EdgeInsets? padding;
  final List<Widget>? actions;
  const SectionCard({super.key, this.title, required this.child, this.padding, this.actions});
  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: padding ?? const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (title != null) ...[
              Row(
                children: [
                  Expanded(child: Text(title!, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600))),
                  if (actions != null) ...actions!,
                ],
              ),
              const SizedBox(height: 12),
            ],
            child,
          ],
        ),
      ),
    );
  }
}

class KeyValueRow extends StatelessWidget {
  final String label;
  final String value;
  final Widget? trailing;
  final VoidCallback? onTap;
  final Color? valueColor;
  const KeyValueRow({super.key, required this.label, required this.value, this.trailing, this.onTap, this.valueColor});
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(label, style: const TextStyle(color: AppColors.textSecondary, fontSize: 13)),
          ),
          Expanded(
            child: onTap != null
                ? GestureDetector(
                    onTap: onTap,
                    child: Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: AppColors.primary, decoration: TextDecoration.underline)),
                  )
                : Text(value, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: valueColor)),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class StatusChip extends StatelessWidget {
  final String label;
  final Color color;
  const StatusChip({super.key, required this.label, required this.color});
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
    );
  }
}

Color statusColor(String? status) {
  switch (status?.toUpperCase()) {
    case 'ACTIVE':
    case 'PAID':
    case 'CLOSED':
    case 'COMPLETED':
    case 'APPROVED':
    case 'VERIFIED':
      return AppColors.accent;
    case 'PENDING':
    case 'PARTIAL':
      return AppColors.warning;
    case 'OVERDUE':
    case 'REJECTED':
    case 'DEFAULTED':
      return AppColors.danger;
    case 'INACTIVE':
      return AppColors.textSecondary;
    default:
      return AppColors.info;
  }
}

class Avatar extends StatelessWidget {
  final String? url;
  final String name;
  final double size;
  const Avatar({super.key, this.url, required this.name, this.size = 40});
  @override
  Widget build(BuildContext context) {
    final resolved = resolveUrl(url);
    final letters = name.trim().isEmpty
        ? '?'
        : name.trim().split(RegExp(r'\s+')).take(2).map((e) => e[0]).join().toUpperCase();
    if (resolved != null) {
      return ClipOval(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.12),
            image: DecorationImage(
              image: CachedNetworkImageProvider(resolved),
              fit: BoxFit.cover,
              alignment: Alignment.topCenter,
            ),
          ),
        ),
      );
    }
    return CircleAvatar(
      radius: size / 2,
      backgroundColor: AppColors.primary.withValues(alpha: 0.12),
      child: Text(letters, style: TextStyle(color: AppColors.primary, fontSize: size * 0.4, fontWeight: FontWeight.w600)),
    );
  }
}

void showImageViewer(BuildContext context, String? url, {String? heroTag}) {
  final resolved = resolveUrl(url);
  if (resolved == null) return;
  Navigator.of(context).push(PageRouteBuilder(
    opaque: false,
    barrierColor: Colors.black.withValues(alpha: 0.9),
    pageBuilder: (ctx, _, _) => _ImageViewerPage(url: resolved, heroTag: heroTag),
  ));
}

class _ImageViewerPage extends StatelessWidget {
  final String url;
  final String? heroTag;
  const _ImageViewerPage({required this.url, this.heroTag});
  @override
  Widget build(BuildContext context) {
    final image = InteractiveViewer(
      minScale: 1,
      maxScale: 5,
      child: Center(
        child: CachedNetworkImage(
          imageUrl: url,
          fit: BoxFit.contain,
          placeholder: (_, _) => const CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
          errorWidget: (_, _, _) => const Icon(Icons.broken_image, color: Colors.white54, size: 48),
        ),
      ),
    );
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Stack(
        children: [
          GestureDetector(
            onTap: () => Navigator.of(context).pop(),
            child: Container(color: Colors.transparent, width: double.infinity, height: double.infinity),
          ),
          Positioned.fill(child: heroTag != null ? Hero(tag: heroTag!, child: image) : image),
          Positioned(
            top: MediaQuery.of(context).padding.top + 4,
            right: 8,
            child: IconButton(
              icon: const Icon(Icons.close, color: Colors.white, size: 28),
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
    );
  }
}

// One selectable row in [showSearchableSelect]. [label] is what's shown; [searchText]
// is what the search box matches against (defaults to the label when omitted, so pass
// the raw name/number here when the label carries extra formatting like "— ₹x due").
// [trailing] renders on the right of the row (e.g. a StatusChip) before the check mark.
// [tileColor] tints the whole row, flagging a state that matters while picking (e.g. a
// chit member who has already won their auction).
class SelectOption<T> {
  final T value;
  final String label;
  final String searchText;
  final Widget? trailing;
  final Color? tileColor;
  SelectOption({required this.value, required this.label, String? searchText, this.trailing, this.tileColor})
      : searchText = (searchText ?? label).toLowerCase();
}

// A searchable replacement for a long DropdownButton: opens a bottom sheet with a search
// box over [options] and returns the chosen value (or null if dismissed). Use with a
// SearchableSelectField trigger, or call directly on any tap.
Future<T?> showSearchableSelect<T>(
  BuildContext context, {
  required String title,
  required List<SelectOption<T>> options,
  T? selected,
  String searchHint = 'Search...',
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _SearchableSelectSheet<T>(
      title: title,
      options: options,
      selected: selected,
      searchHint: searchHint,
    ),
  );
}

class _SearchableSelectSheet<T> extends StatefulWidget {
  final String title;
  final List<SelectOption<T>> options;
  final T? selected;
  final String searchHint;
  const _SearchableSelectSheet({required this.title, required this.options, required this.selected, required this.searchHint});
  @override
  State<_SearchableSelectSheet<T>> createState() => _SearchableSelectSheetState<T>();
}

class _SearchableSelectSheetState<T> extends State<_SearchableSelectSheet<T>> {
  final _search = TextEditingController();
  String _q = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final filtered = q.isEmpty ? widget.options : widget.options.where((o) => o.searchText.contains(q)).toList();
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        initialChildSize: 0.7,
        maxChildSize: 0.95,
        expand: false,
        builder: (_, ctrl) => Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
              child: Row(
                children: [
                  Expanded(child: Text(widget.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600))),
                  IconButton(icon: const Icon(Icons.close), onPressed: () => Navigator.pop(context)),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                controller: _search,
                autofocus: true,
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.search),
                  hintText: widget.searchHint,
                  suffixIcon: _q.isEmpty
                      ? null
                      : IconButton(icon: const Icon(Icons.clear), onPressed: () { _search.clear(); setState(() => _q = ''); }),
                ),
                onChanged: (v) => setState(() => _q = v),
              ),
            ),
            const SizedBox(height: 4),
            Expanded(
              child: filtered.isEmpty
                  ? const Center(child: Text('No matches', style: TextStyle(color: AppColors.textSecondary)))
                  : ListView.separated(
                      controller: ctrl,
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const Divider(height: 1),
                      itemBuilder: (ctx, i) {
                        final o = filtered[i];
                        final isSel = o.value == widget.selected;
                        return ListTile(
                          tileColor: o.tileColor,
                          title: Text(o.label, overflow: TextOverflow.ellipsis),
                          trailing: (o.trailing == null && !isSel)
                              ? null
                              : Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (o.trailing != null) o.trailing!,
                                    if (isSel) ...[
                                      const SizedBox(width: 6),
                                      const Icon(Icons.check, color: AppColors.primary),
                                    ],
                                  ],
                                ),
                          selected: isSel,
                          onTap: () => Navigator.pop(context, o.value),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

// A form-field-styled trigger for [showSearchableSelect]: looks like a DropdownButtonFormField
// (bordered, labelled, chevron) but opens the searchable sheet on tap. [display] is the
// current selection's text; null shows [hint] in the muted style.
class SearchableSelectField extends StatelessWidget {
  final String label;
  final String? display;
  final String hint;
  final VoidCallback? onTap;
  const SearchableSelectField({super.key, required this.label, this.display, this.hint = 'Select...', this.onTap});
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: InputDecorator(
        decoration: InputDecoration(labelText: label, enabled: onTap != null),
        child: Row(
          children: [
            Expanded(
              child: Text(
                display ?? hint,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: display == null ? AppColors.textMuted : AppColors.textPrimary),
              ),
            ),
            const Icon(Icons.arrow_drop_down, color: AppColors.textSecondary),
          ],
        ),
      ),
    );
  }
}

Future<bool> confirmDialog(BuildContext context, {String title = 'Confirm', required String message, String confirmText = 'Confirm', bool destructive = false}) async {
  final res = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(message),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        ElevatedButton(
          onPressed: () => Navigator.pop(ctx, true),
          style: destructive ? ElevatedButton.styleFrom(backgroundColor: AppColors.danger) : null,
          child: Text(confirmText),
        ),
      ],
    ),
  );
  return res == true;
}
