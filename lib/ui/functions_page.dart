import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../main.dart';
import 'card_machine_page.dart';
import 'layout.dart';
import 'theme.dart';
import 'till_actions.dart';

/// Till functions — the actions a clerk reaches for that are not part of ringing
/// up a sale: park the current bill, reprint, open the drawer for a no-sale, and
/// jump to the end-of-day reports.
///
/// Each function is wired to a real backend where one exists; where a function
/// needs hardware that may not be present (the cash drawer needs a printer set
/// up), it says so plainly rather than pretending to work.
class FunctionsPage extends ConsumerWidget {
  const FunctionsPage({
    super.key,
    required this.orderId,
    required this.onGoToReports,
    required this.onGoToReceipts,
    required this.onGoToTables,
  });

  /// The bill currently on the sale screen, so "Save to table" can park it.
  final String orderId;
  final VoidCallback onGoToReports;
  final VoidCallback onGoToReceipts;
  final VoidCallback onGoToTables;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final phone = context.isPhone;

    final functions = <_Function>[
      _Function(
        'Save to Table',
        Icons.table_restaurant,
        Pos.teal,
        'Park this bill against a table so you can start another.',
        () => _saveToTable(context, ref),
      ),
      _Function(
        'Reprint Last Receipt',
        Icons.receipt_long,
        Pos.indigo,
        'Print another copy of the most recent sale.',
        () => TillActions.reprintLastReceipt(context, ref),
      ),
      _Function(
        'No Sale (Open Drawer)',
        Icons.point_of_sale,
        Pos.amber,
        'Open the cash drawer without ringing up a sale.',
        () => TillActions.openCashDrawer(context, ref),
      ),
      _Function(
        'X Report',
        Icons.refresh,
        Pos.blue,
        "Read the current period's takings without closing it.",
        onGoToReports,
      ),
      _Function(
        'Z Report',
        Icons.lock_clock,
        Pos.red,
        'Close the trading period and reset the totals.',
        onGoToReports,
      ),
      _Function(
        'Receipts',
        Icons.history,
        Pos.cyan,
        'Browse and reprint any earlier sale.',
        onGoToReceipts,
      ),
      _Function(
        'Tables',
        Icons.grid_view,
        Pos.purple,
        'Recall a parked bill, transfer or split it.',
        onGoToTables,
      ),
      // The card machine's own end of day can only be started from the till on
      // an integrated reader, so it needs a key of its own or the venue cannot
      // cash the machine up.
      _Function(
        'Card Machine',
        Icons.point_of_sale,
        Pos.teal,
        'End of day, balances and card refunds on the PDQ.',
        () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const CardMachinePage()),
        ),
      ),
    ];

    return Padding(
      padding: EdgeInsets.all(phone ? 12 : 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 12),
            child: Text(
              'Functions',
              style: TextStyle(
                fontSize: phone ? 22 : 24,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: GridView.count(
              crossAxisCount: phone ? 2 : 3,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.4,
              children: [for (final f in functions) _FunctionTile(f)],
            ),
          ),
        ],
      ),
    );
  }

  /// "Save Memory" — park the current bill against a table number so the clerk
  /// can begin a fresh sale and come back to this one from Tables.
  Future<void> _saveToTable(BuildContext context, WidgetRef ref) async {
    final lines = await ref.read(orderRepositoryProvider).watchLines(orderId).first;
    if (!context.mounted) return;
    if (lines.isEmpty) {
      _toast(context, 'Nothing to save — this bill is empty.');
      return;
    }

    final number = await _askTableNumber(context);
    if (number == null || !context.mounted) return;

    await ref.read(tableRepositoryProvider).park(orderId, number);
    if (!context.mounted) return;
    _toast(context, 'Saved to table $number.');
    onGoToTables();
  }

  Future<int?> _askTableNumber(BuildContext context) async {
    final controller = TextEditingController();
    return showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save to which table?'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Table number'),
          onSubmitted: (v) => Navigator.pop(context, int.tryParse(v)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(context, int.tryParse(controller.text)),
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _Function {
  const _Function(
    this.label,
    this.icon,
    this.color,
    this.hint,
    this.onTap,
  );
  final String label;
  final IconData icon;
  final Color color;
  final String hint;
  final VoidCallback onTap;
}

class _FunctionTile extends StatelessWidget {
  const _FunctionTile(this.function);
  final _Function function;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: function.color,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: function.onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(function.icon, color: Colors.white, size: 26),
              const Spacer(),
              Text(
                function.label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                function.hint,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontSize: 11.5,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
