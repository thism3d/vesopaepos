import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data/commerce.dart';
import '../data/tender_engine.dart';

String _money(int minor) =>
    NumberFormat.currency(locale: 'en_GB', symbol: '£').format(minor / 100);

/// What a redemption dialog agreed to take.
class RedemptionResult {
  const RedemptionResult({
    required this.amountMinor,
    required this.reference,
    this.customer,
    this.points = 0,
  });

  final int amountMinor;
  final String reference;
  final LoyaltyCustomer? customer;
  final int points;
}

/// Redeem a gift card.
///
/// The card is looked up before anything is taken, so a clerk finds out the
/// balance is short *before* telling the customer their card covers it. The
/// server is still the authority — this is a check, not a reservation.
Future<RedemptionResult?> showGiftCardDialog(
  BuildContext context, {
  required CommerceRepository commerce,
  required int outstandingMinor,
}) =>
    showDialog<RedemptionResult>(
      context: context,
      builder: (_) => _GiftCardDialog(
        commerce: commerce,
        outstandingMinor: outstandingMinor,
      ),
    );

class _GiftCardDialog extends StatefulWidget {
  const _GiftCardDialog({
    required this.commerce,
    required this.outstandingMinor,
  });

  final CommerceRepository commerce;
  final int outstandingMinor;

  @override
  State<_GiftCardDialog> createState() => _GiftCardDialogState();
}

class _GiftCardDialogState extends State<_GiftCardDialog> {
  final _code = TextEditingController();
  GiftCard? _card;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _lookup() async {
    final code = _code.text.trim();
    if (code.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
      _card = null;
    });
    try {
      final card = await widget.commerce.giftCard(code);
      if (!mounted) return;
      setState(() {
        _card = card;
        _error = card.redeemable
            ? null
            : card.expired
                ? 'This card has expired'
                : card.balanceMinor <= 0
                    ? 'This card has no balance left'
                    : 'This card is ${card.status}';
      });
    } on CommerceException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not reach the server. Check the network.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final card = _card;
    // Never take more than the bill needs, nor more than the card holds.
    final take = card == null
        ? 0
        : card.balanceMinor < widget.outstandingMinor
            ? card.balanceMinor
            : widget.outstandingMinor;

    return AlertDialog(
      title: const Text('Gift card'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _code,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: 'Card code',
                hintText: 'ABCD-EFGH-JKLM',
                suffixIcon: IconButton(
                  icon: _busy
                      ? const SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.search),
                  onPressed: _busy ? null : _lookup,
                ),
              ),
              onSubmitted: (_) => _lookup(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              _Banner(message: _error!, isError: true),
            ],
            if (card != null && card.redeemable) ...[
              const SizedBox(height: 14),
              _BalanceCard(
                title: 'Balance on card',
                amountMinor: card.balanceMinor,
                subtitle: card.recipientName,
              ),
              const SizedBox(height: 8),
              _Banner(
                message: take < widget.outstandingMinor
                    ? 'Takes ${_money(take)} — '
                        '${_money(widget.outstandingMinor - take)} still to pay'
                    : 'Takes ${_money(take)} and settles the bill',
                isError: false,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: card != null && card.redeemable && take > 0
              ? () => Navigator.pop(
                    context,
                    RedemptionResult(amountMinor: take, reference: card.code),
                  )
              : null,
          child: Text(take > 0 ? 'Take ${_money(take)}' : 'Take'),
        ),
      ],
    );
  }
}

/// Apply a voucher. The server decides whether it is valid and what it is
/// worth, so expiry and usage rules cannot be bypassed from the till.
Future<RedemptionResult?> showVoucherDialog(
  BuildContext context, {
  required CommerceRepository commerce,
  required int subtotalMinor,
}) =>
    showDialog<RedemptionResult>(
      context: context,
      builder: (_) => _VoucherDialog(
        commerce: commerce,
        subtotalMinor: subtotalMinor,
      ),
    );

class _VoucherDialog extends StatefulWidget {
  const _VoucherDialog({required this.commerce, required this.subtotalMinor});

  final CommerceRepository commerce;
  final int subtotalMinor;

  @override
  State<_VoucherDialog> createState() => _VoucherDialogState();
}

class _VoucherDialogState extends State<_VoucherDialog> {
  final _code = TextEditingController();
  VoucherCheck? _check;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _validate() async {
    final code = _code.text.trim();
    if (code.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
      _check = null;
    });
    try {
      final check = await widget.commerce.checkVoucher(
        code: code,
        subtotalMinor: widget.subtotalMinor,
      );
      if (!mounted) return;
      setState(() {
        _check = check;
        _error = check.valid ? null : check.problem;
      });
    } on CommerceException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not reach the server.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final check = _check;
    return AlertDialog(
      title: const Text('Voucher'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _code,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: 'Voucher code',
                suffixIcon: IconButton(
                  icon: _busy
                      ? const SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.search),
                  onPressed: _busy ? null : _validate,
                ),
              ),
              onSubmitted: (_) => _validate(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              _Banner(message: _error!, isError: true),
            ],
            if (check != null && check.valid) ...[
              const SizedBox(height: 14),
              _BalanceCard(
                title: check.name ?? 'Voucher',
                amountMinor: check.discountMinor,
                subtitle: 'Comes off the bill',
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: check != null && check.valid && check.discountMinor > 0
              ? () => Navigator.pop(
                    context,
                    RedemptionResult(
                      amountMinor: check.discountMinor,
                      reference: check.code,
                    ),
                  )
              : null,
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

/// Redeem a deposit taken earlier against this bill.
Future<RedemptionResult?> showDepositDialog(
  BuildContext context, {
  required CommerceRepository commerce,
  required int outstandingMinor,
}) =>
    showDialog<RedemptionResult>(
      context: context,
      builder: (_) => _DepositDialog(
        commerce: commerce,
        outstandingMinor: outstandingMinor,
      ),
    );

class _DepositDialog extends StatefulWidget {
  const _DepositDialog({
    required this.commerce,
    required this.outstandingMinor,
  });

  final CommerceRepository commerce;
  final int outstandingMinor;

  @override
  State<_DepositDialog> createState() => _DepositDialogState();
}

class _DepositDialogState extends State<_DepositDialog> {
  final _reference = TextEditingController();
  Deposit? _deposit;
  String? _error;
  bool _busy = false;

  @override
  void dispose() {
    _reference.dispose();
    super.dispose();
  }

  Future<void> _lookup() async {
    final reference = _reference.text.trim();
    if (reference.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
      _deposit = null;
    });
    try {
      final deposit = await widget.commerce.deposit(reference);
      if (!mounted) return;
      setState(() {
        _deposit = deposit;
        _error = deposit.redeemable
            ? null
            : 'This deposit is ${deposit.status}';
      });
    } on CommerceException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not reach the server.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final deposit = _deposit;
    final take = deposit == null
        ? 0
        : deposit.remainingMinor < widget.outstandingMinor
            ? deposit.remainingMinor
            : widget.outstandingMinor;

    return AlertDialog(
      title: const Text('Redeem deposit'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _reference,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: InputDecoration(
                labelText: 'Deposit reference',
                hintText: 'DEP-123456',
                suffixIcon: IconButton(
                  icon: _busy
                      ? const SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.search),
                  onPressed: _busy ? null : _lookup,
                ),
              ),
              onSubmitted: (_) => _lookup(),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              _Banner(message: _error!, isError: true),
            ],
            if (deposit != null && deposit.redeemable) ...[
              const SizedBox(height: 14),
              _BalanceCard(
                title: deposit.customerName ?? 'Deposit',
                amountMinor: deposit.remainingMinor,
                subtitle: deposit.description,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: deposit != null && deposit.redeemable && take > 0
              ? () => Navigator.pop(
                    context,
                    RedemptionResult(
                      amountMinor: take,
                      reference: deposit.reference,
                    ),
                  )
              : null,
          child: Text(take > 0 ? 'Redeem ${_money(take)}' : 'Redeem'),
        ),
      ],
    );
  }
}

/// Find a loyalty customer by phone, and optionally spend their points.
///
/// The phone number is how loyalty is claimed at a counter — nobody carries a
/// card. Enrolling is offered inline when the number is not known, because the
/// moment to sign someone up is while they are standing there.
Future<RedemptionResult?> showLoyaltyDialog(
  BuildContext context, {
  required CommerceRepository commerce,
  required int outstandingMinor,
  bool redeem = true,
}) =>
    showDialog<RedemptionResult>(
      context: context,
      builder: (_) => _LoyaltyDialog(
        commerce: commerce,
        outstandingMinor: outstandingMinor,
        redeem: redeem,
      ),
    );

class _LoyaltyDialog extends StatefulWidget {
  const _LoyaltyDialog({
    required this.commerce,
    required this.outstandingMinor,
    required this.redeem,
  });

  final CommerceRepository commerce;
  final int outstandingMinor;
  final bool redeem;

  @override
  State<_LoyaltyDialog> createState() => _LoyaltyDialogState();
}

class _LoyaltyDialogState extends State<_LoyaltyDialog> {
  final _phone = TextEditingController();
  final _name = TextEditingController();
  LoyaltyCustomer? _customer;
  String? _error;
  bool _busy = false;
  bool _enrolling = false;

  @override
  void dispose() {
    _phone.dispose();
    _name.dispose();
    super.dispose();
  }

  Future<void> _lookup() async {
    final phone = _phone.text.trim();
    if (phone.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
      _customer = null;
      _enrolling = false;
    });
    try {
      final customer = await widget.commerce.loyaltyByPhone(phone);
      if (mounted) setState(() => _customer = customer);
    } on CommerceException catch (e) {
      if (mounted) {
        setState(() {
          _error = e.message;
          // Not found is an opportunity, not a failure.
          _enrolling = true;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not reach the server.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _enrol() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final customer = await widget.commerce.enrol(
        phone: _phone.text.trim(),
        name: _name.text.trim().isEmpty ? 'Guest' : _name.text.trim(),
      );
      if (mounted) {
        setState(() {
          _customer = customer;
          _enrolling = false;
        });
      }
    } on CommerceException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not reach the server.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final customer = _customer;
    final redeemable =
        customer?.maxRedeemableAgainst(widget.outstandingMinor) ?? 0;
    final worth = customer == null ? 0 : redeemable * customer.pointValueMinor;

    return AlertDialog(
      title: Text(widget.redeem ? 'Loyalty' : 'Attach customer'),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              controller: _phone,
              autofocus: true,
              keyboardType: TextInputType.phone,
              decoration: InputDecoration(
                labelText: 'Phone number',
                suffixIcon: IconButton(
                  icon: _busy
                      ? const SizedBox(
                          width: 18, height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.search),
                  onPressed: _busy ? null : _lookup,
                ),
              ),
              onSubmitted: (_) => _lookup(),
            ),

            if (_enrolling) ...[
              const SizedBox(height: 12),
              _Banner(
                message: 'Not a member yet — sign them up?',
                isError: false,
              ),
              const SizedBox(height: 10),
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: 10),
              FilledButton.tonalIcon(
                onPressed: _busy ? null : _enrol,
                icon: const Icon(Icons.person_add_alt),
                label: const Text('Enrol this customer'),
              ),
            ] else if (_error != null) ...[
              const SizedBox(height: 12),
              _Banner(message: _error!, isError: true),
            ],

            if (customer != null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primaryContainer,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            customer.name,
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.bold),
                          ),
                        ),
                        if (customer.tierName != null)
                          Chip(
                            label: Text(customer.tierName!),
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text('${customer.pointsBalance} points '
                        '· worth ${_money(customer.pointsValueMinor)}'),
                    if (widget.redeem) ...[
                      const SizedBox(height: 6),
                      Text(
                        redeemable > 0
                            ? 'Can redeem $redeemable points (${_money(worth)}) '
                                'against this bill'
                            : customer.pointsBalance < customer.minRedeemPoints
                                ? 'Needs ${customer.minRedeemPoints} points to redeem'
                                : 'Nothing to redeem against this bill',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        // Attaching without redeeming still earns points on the sale.
        if (customer != null)
          TextButton(
            onPressed: () => Navigator.pop(
              context,
              RedemptionResult(
                amountMinor: 0,
                reference: customer.phone ?? '',
                customer: customer,
              ),
            ),
            child: const Text('Attach only'),
          ),
        if (widget.redeem)
          FilledButton(
            onPressed: customer != null && redeemable > 0
                ? () => Navigator.pop(
                      context,
                      RedemptionResult(
                        amountMinor: worth,
                        reference: customer.phone ?? '',
                        customer: customer,
                        points: redeemable,
                      ),
                    )
                : null,
            child: Text(worth > 0 ? 'Redeem ${_money(worth)}' : 'Redeem'),
          ),
      ],
    );
  }
}

/// Choose a gratuity. Returns the rate in tenths of a percent, or 0 to remove.
Future<int?> showGratuityDialog(
  BuildContext context, {
  required TenderSettings settings,
  required int baseMinor,
  int currentBp = 0,
}) =>
    showDialog<int>(
      context: context,
      builder: (_) => _GratuityDialog(
        settings: settings,
        baseMinor: baseMinor,
        currentBp: currentBp,
      ),
    );

class _GratuityDialog extends StatefulWidget {
  const _GratuityDialog({
    required this.settings,
    required this.baseMinor,
    required this.currentBp,
  });

  final TenderSettings settings;
  final int baseMinor;
  final int currentBp;

  @override
  State<_GratuityDialog> createState() => _GratuityDialogState();
}

class _GratuityDialogState extends State<_GratuityDialog> {
  late int _bp = widget.currentBp;
  final _custom = TextEditingController();

  @override
  void dispose() {
    _custom.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final amount = TenderSettings.gratuityOn(widget.baseMinor, _bp);
    // A custom cash amount is entered as money, then converted back to a rate
    // so the receipt can still print the percentage.
    final customMinor = (double.tryParse(_custom.text) ?? 0) * 100;

    return AlertDialog(
      title: const Text('Gratuity'),
      content: SizedBox(
        width: 380,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('On ${_money(widget.baseMinor)}',
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final percent in widget.settings.gratuityPresets)
                  ChoiceChip(
                    label: Text('${percent.toStringAsFixed(
                        percent % 1 == 0 ? 0 : 1)}%'),
                    selected: _bp == (percent * 10).round(),
                    onSelected: (_) => setState(() {
                      _bp = (percent * 10).round();
                      _custom.clear();
                    }),
                  ),
                ChoiceChip(
                  label: const Text('None'),
                  selected: _bp == 0,
                  onSelected: (_) => setState(() {
                    _bp = 0;
                    _custom.clear();
                  }),
                ),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _custom,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Or a set amount (£)',
                prefixText: '£ ',
              ),
              onChanged: (_) => setState(() {
                final minor = (double.tryParse(_custom.text) ?? 0) * 100;
                _bp = widget.baseMinor > 0
                    ? (minor * 1000 / widget.baseMinor).round()
                    : 0;
              }),
            ),
            const SizedBox(height: 14),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(9),
              ),
              child: Row(
                children: [
                  const Expanded(child: Text('Gratuity')),
                  Text(
                    _money(customMinor > 0 ? customMinor.round() : amount),
                    style: const TextStyle(
                        fontWeight: FontWeight.bold, fontSize: 17),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _bp),
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

/// Choose how to split a bill.
Future<SplitChoice?> showSplitDialog(
  BuildContext context, {
  required TenderState state,
}) =>
    showDialog<SplitChoice>(
      context: context,
      builder: (_) => _SplitDialog(state: state),
    );

/// How the clerk decided to split.
class SplitChoice {
  const SplitChoice({required this.mode, this.ways = 0, this.groups});

  final SplitMode mode;
  final int ways;
  final List<List<String>>? groups;
}

class _SplitDialog extends StatefulWidget {
  const _SplitDialog({required this.state});

  final TenderState state;

  @override
  State<_SplitDialog> createState() => _SplitDialogState();
}

class _SplitDialogState extends State<_SplitDialog> {
  int _ways = 2;

  /// For an item split: which share each line has been assigned to.
  final Map<String, int> _assignment = {};
  bool _byItem = false;

  @override
  Widget build(BuildContext context) {
    final outstanding = widget.state.outstandingMinor;
    final each = _ways > 0 ? outstanding ~/ _ways : 0;

    return AlertDialog(
      title: const Text('Split the bill'),
      content: SizedBox(
        width: 440,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('Equally')),
                  ButtonSegment(value: true, label: Text('By item')),
                ],
                selected: {_byItem},
                onSelectionChanged: (s) => setState(() => _byItem = s.first),
              ),
              const SizedBox(height: 16),

              if (!_byItem) ...[
                Text('${_money(outstanding)} between $_ways',
                    style: Theme.of(context).textTheme.bodyMedium),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final ways in [2, 3, 4, 5, 6, 8])
                      ChoiceChip(
                        label: Text('$ways'),
                        selected: _ways == ways,
                        onSelected: (_) => setState(() => _ways = ways),
                      ),
                  ],
                ),
                const SizedBox(height: 14),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color:
                        Theme.of(context).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Row(
                    children: [
                      const Expanded(child: Text('Each pays about')),
                      Text(_money(each),
                          style: const TextStyle(
                              fontWeight: FontWeight.bold, fontSize: 17)),
                    ],
                  ),
                ),
              ] else ...[
                Text(
                  'Tap an item to move it between shares.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 10),
                for (final line in widget.state.totals.lines)
                  ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(line.name),
                    subtitle: Text(_money(line.netMinor)),
                    trailing: Wrap(
                      spacing: 4,
                      children: [
                        for (var share = 0; share < _ways; share++)
                          ChoiceChip(
                            label: Text('${share + 1}'),
                            selected: (_assignment[line.id] ?? 0) == share,
                            onSelected: (_) =>
                                setState(() => _assignment[line.id] = share),
                          ),
                      ],
                    ),
                  ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    const Text('Shares: '),
                    for (final ways in [2, 3, 4])
                      Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: ChoiceChip(
                          label: Text('$ways'),
                          selected: _ways == ways,
                          onSelected: (_) => setState(() => _ways = ways),
                        ),
                      ),
                  ],
                ),
              ],
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
          onPressed: () {
            if (_byItem) {
              // Group the lines by the share they were assigned to. Anything
              // untouched stays on share 1.
              final groups = List.generate(_ways, (i) => <String>[]);
              for (final line in widget.state.totals.lines) {
                groups[_assignment[line.id] ?? 0].add(line.id);
              }
              Navigator.pop(context,
                  SplitChoice(mode: SplitMode.byItem, groups: groups));
            } else {
              Navigator.pop(
                  context, SplitChoice(mode: SplitMode.equally, ways: _ways));
            }
          },
          child: const Text('Split'),
        ),
      ],
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.message, required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: isError ? scheme.errorContainer : scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            isError ? Icons.error_outline : Icons.info_outline,
            size: 17,
            color: isError ? scheme.onErrorContainer : scheme.onSecondaryContainer,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                fontSize: 13,
                color: isError
                    ? scheme.onErrorContainer
                    : scheme.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BalanceCard extends StatelessWidget {
  const _BalanceCard({
    required this.title,
    required this.amountMinor,
    this.subtitle,
  });

  final String title;
  final int amountMinor;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: scheme.onPrimaryContainer)),
                if (subtitle?.isNotEmpty ?? false)
                  Text(subtitle!,
                      style: TextStyle(
                          fontSize: 12,
                          color: scheme.onPrimaryContainer
                              .withValues(alpha: 0.75))),
              ],
            ),
          ),
          Text(
            _money(amountMinor),
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: scheme.onPrimaryContainer,
            ),
          ),
        ],
      ),
    );
  }
}
