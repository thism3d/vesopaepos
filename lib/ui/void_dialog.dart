import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../main.dart';
import 'theme.dart';

/// The void reasons offered on the till. Defined in the back office; cached in
/// prefs is overkill for a short list, so this just fetches with a sensible
/// fallback for when the network is down.
final voidReasonsProvider = FutureProvider<List<String>>((ref) async {
  const fallback = [
    'Customer changed mind',
    'Wrong item rung up',
    'Duplicate order',
    'Kitchen error',
    'Other',
  ];
  try {
    final res = await http
        .get(Uri.parse('${ref.watch(apiBaseProvider)}/till/void-reasons'))
        .timeout(const Duration(seconds: 5));
    if (res.statusCode != 200) return fallback;
    final reasons = (jsonDecode(res.body) as List<dynamic>).cast<String>();
    return reasons.isEmpty ? fallback : reasons;
  } catch (_) {
    return fallback;
  }
});

/// Confirms a void and captures why. Returns the chosen reason, or null if
/// cancelled. A void with no reason is not allowed — that is the whole point of
/// the audit trail.
Future<String?> showVoidDialog(BuildContext context, WidgetRef ref) {
  return showDialog<String>(
    context: context,
    builder: (_) => const _VoidDialog(),
  );
}

class _VoidDialog extends ConsumerStatefulWidget {
  const _VoidDialog();

  @override
  ConsumerState<_VoidDialog> createState() => _VoidDialogState();
}

class _VoidDialogState extends ConsumerState<_VoidDialog> {
  String? _selected;
  final _custom = TextEditingController();

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reasons = ref.watch(voidReasonsProvider).value ?? const [];
    final isCustom = _selected == '__custom__';

    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.block, color: Pos.red),
          SizedBox(width: 12),
          Text('Void this sale?'),
        ],
      ),
      // Scrollable so that when "Other reason…" pulls up the on-screen
      // keyboard, the shrunken content area scrolls instead of overflowing.
      content: SizedBox(
        width: 380,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'This clears the whole bill. Choose a reason — it is recorded '
                'against the terminal.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              for (final reason in reasons)
                RadioListTile<String>(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  value: reason,
                  // ignore: deprecated_member_use
                  groupValue: _selected,
                  // ignore: deprecated_member_use
                  onChanged: (v) => setState(() => _selected = v),
                  title: Text(reason),
                ),
              RadioListTile<String>(
                dense: true,
                contentPadding: EdgeInsets.zero,
                value: '__custom__',
                // ignore: deprecated_member_use
                groupValue: _selected,
                // ignore: deprecated_member_use
                onChanged: (v) => setState(() => _selected = v),
                title: const Text('Other reason…'),
              ),
              if (isCustom)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: TextField(
                    controller: _custom,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: 'Type the reason',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Pos.red),
          onPressed: _canConfirm ? _confirm : null,
          child: const Text('Void'),
        ),
      ],
    );
  }

  bool get _canConfirm {
    if (_selected == null) return false;
    if (_selected == '__custom__') return _custom.text.trim().isNotEmpty;
    return true;
  }

  void _confirm() {
    final reason = _selected == '__custom__' ? _custom.text.trim() : _selected!;
    Navigator.pop(context, reason);
  }
}
