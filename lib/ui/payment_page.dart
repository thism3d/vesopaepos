import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../data/commerce.dart';
import '../data/local/database.dart';
import '../data/pricing_engine.dart';
import '../data/receipt_repository.dart';
import '../data/tender_engine.dart';
import '../main.dart';
import '../payments/connect_pac.dart';
import '../payments/dojo_desktop.dart';
import '../payments/payment_provider.dart';
import 'layout.dart';
import 'card_checkout_page.dart';
import 'card_payment_dialog.dart';
import 'confirm_tender_dialog.dart';
import 'discount_dialog.dart';
import 'print_receipt_sheet.dart';
import 'redemption_dialogs.dart';
import 'widgets/live_receipt.dart';
import 'widgets/tender_panel.dart';
import 'receipts_page.dart' show receiptListProvider;
import 'theme.dart';

/// Private so it does not collide with the basket panel's exported `money`,
/// which sale_page imports.
String _money(int minor) =>
    NumberFormat.currency(locale: 'en_GB', symbol: '£').format(minor / 100);

/// Tender screen. Everything here writes locally and settles immediately —
/// taking money must never wait on the network.
class PaymentPage extends ConsumerStatefulWidget {
  const PaymentPage({
    super.key,
    required this.orderId,
    required this.onSettled,
  });

  final String orderId;
  final VoidCallback onSettled;

  @override
  ConsumerState<PaymentPage> createState() => _PaymentPageState();
}

class _PaymentPageState extends ConsumerState<PaymentPage> {
  /// What the clerk has keyed in, in minor units. Null means "no override", in
  /// which case a tender settles the whole outstanding balance.
  String _entry = '';

  void _key(String k) {
    setState(() {
      if (k == 'CL') {
        _entry = '';
      } else if (k == '.' && _entry.contains('.')) {
        return;
      } else {
        _entry += k;
      }
    });
  }


  /// Get the just-closed sale onto the server and refresh the history, so the
  /// receipt shows up in the Receipts screen the moment it is paid instead of
  /// only after a manual refresh.
  ///
  /// The list is server-backed, so the sale has to reach the server first: we
  /// flush the outbox now rather than waiting for the periodic sync, then
  /// invalidate the list once that push has been attempted. If the till is
  /// offline the flush is a no-op and the sale stays queued — the receipt then
  /// appears when connectivity returns and the next flush lands, which is the
  /// best history can do without the network.
  ///
  /// The service and the container are read up front, before the page pops:
  /// this runs unawaited and the flush is slow, so by the time it finishes this
  /// State can be disposed — going through the root container rather than the
  /// widget's `ref` keeps the invalidation valid regardless.
  Future<void> _publishReceipt() async {
    final container = ProviderScope.containerOf(context, listen: false);
    await container.read(syncServiceProvider).flush();
    container.invalidate(receiptListProvider);
  }

  /// After payment, offer to print the receipt. Built from the just-settled
  /// local order, so it works even if the sale has not yet synced to the
  /// server — the customer gets their receipt regardless of the network.
  Future<void> _offerReceipt() async {
    final repo = ref.read(orderRepositoryProvider);
    final order = await repo.watchOrder(widget.orderId).first;
    final lines = await repo.watchLines(widget.orderId).first;
    final tenders = await repo.paymentsFor(widget.orderId);

    if (!mounted) return;

    final session = ref.read(sessionProvider);
    final detail = ReceiptDetail(
      summary: ReceiptSummary(
        id: order.id,
        totalMinor: order.totalMinor,
        taxMinor: order.taxMinor,
        discountMinor: order.discountMinor,
        tableNumber: order.tableNumber,
        closedAt: order.closedAt ?? DateTime.now(),
        covers: order.covers,
        // Who served it and who it was for — both print, and both are what
        // makes a receipt traceable back to a person rather than a terminal.
        clerkName: session.name,
        customerName: _customer?.name ?? order.customerName,
        orderNote: order.notes,
        // What was taken off, so the printed receipt explains its own total.
        voucherCode: _voucherCode,
        voucherMinor: _voucherMinor,
        serviceMinor: _tender.totals.gratuityMinor,
        pointsRedeemed: _pointsRedeemed,
        pointsEarned: _customer?.pointsFor(_tender.totals.netGoodsMinor) ?? 0,
        pointsBalance: _customer?.pointsBalance,
      ),
      lines: [
        for (final l in lines)
          ReceiptLine(
            name: l.name,
            quantity: l.quantity,
            unitPriceMinor: l.unitPriceMinor,
            taxPercentage: l.taxPercentage,
            note: l.notes,
          ),
      ],
      tenders: [
        for (final t in tenders)
          ReceiptTender(method: t.method, amountMinor: t.amountMinor),
      ],
    );

    await PrintReceiptSheet.show(
      context,
      receipt: detail,
      venueName: session.venueName,
      branding: ref.read(brandingProvider),
      // A takeaway counter has no kitchen ticket to send; a table order does.
      showKitchenOption: order.tableNumber != null,
    );
  }

  /// Hand the clerk's signature decision back to the waiting provider.
  ///
  /// Guarded because the reader can resend the prompt: completing a Completer
  /// twice throws, which would abort a payment that is otherwise fine.
  void _answerSignature(
    ValueNotifier<CardPaymentState> payment,
    Completer<bool>? signature, {
    required bool accepted,
  }) {
    if (signature == null || signature.isCompleted) return;
    signature.complete(accepted);
    payment.value = payment.value.copyWith(
      step: accepted ? CardStep.processing : CardStep.starting,
      readerPrompt: accepted ? 'Finishing the payment' : 'Cancelling',
    );
  }

  /// Run a card. Returns true only if the money was actually taken — a decline,
  /// an error, or a timeout all return false, so the sale is never recorded as
  /// paid when it was not.
  ///
  /// [manual] takes the *keyed* route rather than a presented card: the number
  /// is typed in. Each acquirer expresses that differently — Connect flags the
  /// transaction card-not-present so the PDQ opens its keypad, Dojo routes to
  /// card-entry UI instead of the reader — so it is passed straight through to
  /// the provider rather than decided here. A venue reaches for this when a
  /// chip will not read or the customer is on the telephone.
  Future<PaymentResult?> _takeCard(
    int amountMinor, {
    bool manual = false,
  }) async {
    final provider = manual
        ? ref.read(manualCardProvider)
        : ref.read(dojoProvider);
    if (provider == null) {
      _toast(
        'Card payments are not set up. Add your card API URL and key in '
        'Settings › Card payments.',
      );
      return null;
    }

    // The clerk needs to know the till is waiting on the customer, and must not
    // be able to press Card twice while it is.
    //
    // Where the provider reports what it is actually doing, the wait can be
    // abandoned: a card payment can sit unanswered for minutes, and a spinner
    // with no message and no way out strands the till mid-service.
    final desktop = provider is DesktopDojoProvider ? provider : null;
    final rest = provider is DojoProvider ? provider : desktop?.intents;
    final connect = provider is ConnectPacProvider ? provider : null;

    // One notifier drives the whole screen: the stage the till knows about,
    // plus whatever the reader is telling the customer.
    final payment = ValueNotifier<CardPaymentState>(
      const CardPaymentState(step: CardStep.starting),
    );
    DojoStage? lastStage;

    // The provider blocks on this when the reader asks for a signature; the
    // Completer is finished by whichever button the clerk presses.
    Completer<bool>? signature;
    Future<bool> askForSignature() {
      final completer = Completer<bool>();
      signature = completer;
      payment.value = payment.value.copyWith(step: CardStep.signature);
      return completer.future;
    }

    // When the sale runs on a card machine, show what the reader is telling
    // the customer ("present card", "enter PIN") rather than a generic wait —
    // the clerk is the one who has to prompt them.
    rest?.onTerminalUpdate = (s) {
      payment.value = payment.value.copyWith(
        step: cardStepFor(stage: lastStage, session: s),
        readerPrompt: s.prompt,
        terminalLabel: rest.terminalId,
      );
    };
    rest?.onSignatureRequested = askForSignature;
    desktop?.onStageChanged = (s) {
      lastStage = s;
      payment.value = payment.value.copyWith(step: cardStepFor(stage: s));
    };

    connect?.onProgress = (p) {
      payment.value = payment.value.copyWith(
        step: cardStepForConnect(p),
        readerPrompt: p.prompt,
        terminalLabel: connect.terminalId,
      );
    };
    connect?.onSignatureRequested = askForSignature;

    // Render the hosted card page inside the till rather than handing it to the
    // system browser: on a Windows touch till there may be no browser to hand
    // it to, and on a tablet the customer ends up holding the whole device.
    desktop?.openCheckout = (url) async {
      if (!mounted) return false;
      unawaited(
        CardCheckoutPage.show(
          context,
          url: url,
          amountLabel: _money(amountMinor),
        ),
      );
      return true;
    };

    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        useRootNavigator: true,
        routeSettings: const RouteSettings(name: CardCheckoutPage.routeName),
        builder: (dialogContext) => ValueListenableBuilder<CardPaymentState>(
          valueListenable: payment,
          builder: (_, state, _) => CardPaymentView(
            state: state,
            amountLabel: _money(amountMinor),
            // Only providers that poll can abandon a wait; the Android drop-in
            // owns its own screen and its own cancel button.
            onCancel: desktop == null && connect == null
                ? null
                : () {
                    // Stop polling; the result comes back as "abandoned",
                    // never as paid or declined.
                    desktop?.cancel();
                    connect?.abandon();
                    Navigator.of(dialogContext).pop();
                  },
            // Signature verification, when the reader asks for it. Answering
            // is what releases the sale, so it must be reachable here.
            onSignatureAccepted: state.step == CardStep.signature
                ? () => _answerSignature(payment, signature, accepted: true)
                : null,
            onSignatureRejected: state.step == CardStep.signature
                ? () => _answerSignature(payment, signature, accepted: false)
                : null,
          ),
        ),
      ),
    );

    final result = await provider.take(
      amountMinor,
      orderId: widget.orderId,
      manual: manual,
    );

    // Detach before disposing, or a late poll would write to a dead notifier.
    rest?.onTerminalUpdate = null;
    rest?.onSignatureRequested = null;
    desktop?.onStageChanged = null;
    desktop?.openCheckout = null;
    connect?.onProgress = null;
    connect?.onSignatureRequested = null;
    payment.dispose();
    // Close the card screens. The checkout page may be sitting on top of the
    // progress dialog, and either may already be gone if the clerk or the
    // customer closed it, so this pops exactly the routes this flow pushed —
    // popping a fixed number of times would take the sale screen with it.
    if (mounted) {
      Navigator.of(context, rootNavigator: true).popUntil(
        (route) => route.settings.name != CardCheckoutPage.routeName,
      );
    }

    if (!result.approved) {
      // An outcome the till cannot trust is not a decline, and a snackbar is
      // the wrong shape for it: the clerk has to go and do something about the
      // reader before charging the card again.
      if (result.uncertainty != PaymentUncertainty.none && mounted) {
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (context) => AlertDialog(
            icon: Icon(
              result.uncertainty == PaymentUncertainty.terminalUnreachable
                  ? Icons.error_outline
                  : Icons.help_outline,
              size: 30,
              color: Theme.of(context).colorScheme.error,
            ),
            title: const Text('Did that payment go through?'),
            content: Text(
              '${result.message}\n\n'
              'This sale has NOT been marked as paid. Do not charge the card '
              'again until you know.',
            ),
            actions: [
              FilledButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Understood'),
              ),
            ],
          ),
        );
      } else {
        _toast(result.message ?? 'Card payment declined.');
      }
      return null;
    }
    return result;
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 5)),
    );
  }
  // ---- Commerce state ----------------------------------------------------

  /// Reductions the clerk has agreed, kept here rather than on the order so
  /// they can be undone before the sale is committed.
  int _manualDiscountMinor = 0;

  /// How the discount was expressed, kept alongside the money so the dialog can
  /// reopen on what the clerk actually chose rather than on a cash figure they
  /// never typed.
  DiscountChoice? _discount;

  int _voucherMinor = 0;
  String? _voucherCode;
  int _pointsMinor = 0;
  int _pointsRedeemed = 0;
  int _gratuityBp = 0;
  bool _gratuityApplies = false;
  bool _gratuityTouched = false;

  LoyaltyCustomer? _customer;

  /// Payments taken so far, and any split in progress.
  TenderState _tender = const TenderState(totals: BasketTotals.empty);

  /// Turns the order's lines into the pricing engine's shape.
  List<PricedLine> _priced(List<OrderLine> lines) => [
        for (final l in lines)
          PricedLine(
            id: l.id,
            pluid: l.pluId,
            name: l.name,
            quantity: l.quantity,
            unitPriceMinor: l.unitPriceMinor,
            taxPercentage: l.taxPercentage,
            note: l.notes,
          ),
      ];

  BasketTotals _totals(List<OrderLine> lines, Order? order) {
    final settings = ref.read(tenderSettingsProvider);

    // An automatic service charge applies unless the clerk has said otherwise.
    if (!_gratuityTouched && settings.autoAppliesTo(order?.covers)) {
      _gratuityApplies = true;
      _gratuityBp = settings.gratuityDefaultBp;
    }

    return PricingEngine(promotions: ref.read(promotionsProvider)).price(
      _priced(lines),
      manualDiscountMinor: _manualDiscountMinor,
      voucherMinor: _voucherMinor,
      pointsMinor: _pointsMinor,
      gratuityBp: _gratuityBp,
      gratuityApplies: _gratuityApplies,
    );
  }

  /// Take a tender. Each kind knows how to obtain its own authorisation before
  /// any money is recorded: a card must be approved, a gift card must have the
  /// balance, a voucher must validate.
  Future<void> _take(TenderKind kind, int requested) async {
    final due = _tender.dueNowMinor;
    if (due <= 0 && kind != TenderKind.voucher && kind != TenderKind.points) {
      return;
    }

    // Never take more than is owed, except cash — where the surplus is change.
    final amount = kind == TenderKind.cash
        ? requested
        : requested.clamp(0, due);

    switch (kind) {
      case TenderKind.cash:
        // Cash and card are one tap away from money moving, and unlike the
        // redemption routes below they have no lookup step of their own to act
        // as a check. So this is theirs.
        if (!await _confirm(kind, amount, due)) return;
        _record(TenderEntry(kind: kind, amountMinor: amount));

      case TenderKind.card:
      case TenderKind.manualCard:
        final manual = kind == TenderKind.manualCard;
        if (!await _confirm(kind, amount, due, manual: manual)) return;
        final result = await _takeCard(amount, manual: manual);
        if (result == null) return;

        // Cashback and gratuity are added on the card machine, so the till only
        // finds out about them here. Both have to be recorded — the drawer is
        // short by the cashback, and the tip belongs to whoever earned it.
        if (result.cashbackMinor > 0 || result.gratuityMinor > 0) {
          await _reportReaderExtras(result);
        }

        _record(TenderEntry(
          kind: kind,
          amountMinor: amount,
          entryMode: manual ? 'manual' : 'terminal',
          reference: result.reference,
          cashbackMinor: result.cashbackMinor,
          gratuityMinor: result.gratuityMinor,
        ));

      case TenderKind.giftCard:
        await _takeGiftCard(amount);

      case TenderKind.deposit:
        await _takeDeposit(amount);

      case TenderKind.voucher:
        await _takeVoucher();

      case TenderKind.points:
        await _takePoints();

      case TenderKind.account:
        _record(TenderEntry(kind: kind, amountMinor: amount));
    }
  }

  /// Tell the clerk what the customer added at the card machine.
  ///
  /// Cashback in particular is an instruction, not a notification: the card has
  /// been charged for it and the customer is now waiting for notes out of the
  /// drawer. Left as a snackbar it scrolls away, the customer leaves without
  /// their money, and the drawer is over at cash-up with nothing to explain it.
  Future<void> _reportReaderExtras(PaymentResult result) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.account_balance_wallet_outlined, size: 30),
        title: Text(
          result.cashbackMinor > 0 ? 'Give cashback' : 'Gratuity added',
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (result.cashbackMinor > 0) ...[
              Text(
                'Hand the customer ${_money(result.cashbackMinor)} from the '
                'drawer.',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
            ],
            if (result.gratuityMinor > 0)
              Text(
                'The customer added ${_money(result.gratuityMinor)} as a tip at '
                'the card machine.',
              ),
            const SizedBox(height: 10),
            Text(
              'The card was charged ${_money(result.chargedMinor)} in total.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  /// Last check before money moves. Returns false if the clerk backs out.
  Future<bool> _confirm(
    TenderKind kind,
    int amountMinor,
    int dueMinor, {
    bool manual = false,
  }) async {
    if (!mounted || amountMinor <= 0) return false;
    return confirmTender(
      context,
      kind: kind,
      amountMinor: amountMinor,
      dueMinor: dueMinor,
      manual: manual,
    );
  }

  void _record(TenderEntry entry) {
    setState(() {
      _entry = '';
      _tender = _tender.addTender(entry);
    });
    _settleIfPaid();
  }

  Future<void> _takeGiftCard(int amount) async {
    final commerce = ref.read(commerceRepositoryProvider);
    final result = await showGiftCardDialog(
      context,
      commerce: commerce,
      outstandingMinor: amount,
    );
    if (result == null || !mounted) return;

    try {
      // The server is the authority on the balance, and it decrements under a
      // lock — so this must succeed before the till counts the money.
      await commerce.redeemGiftCard(
        code: result.reference,
        amountMinor: result.amountMinor,
        orderId: widget.orderId,
        clerkName: ref.read(sessionProvider).name,
      );
      _record(TenderEntry(
        kind: TenderKind.giftCard,
        amountMinor: result.amountMinor,
        reference: result.reference,
      ));
    } on CommerceException catch (e) {
      _toast(e.message);
    } catch (_) {
      _toast('Could not reach the server to redeem that card.');
    }
  }

  Future<void> _takeDeposit(int amount) async {
    final commerce = ref.read(commerceRepositoryProvider);
    final result = await showDepositDialog(
      context,
      commerce: commerce,
      outstandingMinor: amount,
    );
    if (result == null || !mounted) return;

    try {
      final applied = await commerce.redeemDeposit(
        reference: result.reference,
        amountMinor: result.amountMinor,
        orderId: widget.orderId,
      );
      _record(TenderEntry(
        kind: TenderKind.deposit,
        amountMinor: applied,
        reference: result.reference,
      ));
    } on CommerceException catch (e) {
      _toast(e.message);
    } catch (_) {
      _toast('Could not reach the server to redeem that deposit.');
    }
  }

  /// A voucher reduces the bill rather than paying it, so it is not recorded
  /// as a tender — it changes what is owed.
  ///
  /// Applying one only *holds* it. It is marked used when the sale settles
  /// (see [_settleIfPaid]): burning it here meant a clerk who applied a voucher
  /// and then backed out of the payment had spent the customer's single-use
  /// voucher on nothing, with no way to give it back.
  Future<void> _takeVoucher() async {
    // Already holding one — offer to take it off rather than silently
    // replacing it, since only one voucher applies to a bill.
    if (_voucherMinor > 0) {
      final remove = await _confirmRemoval(
        'Remove voucher $_voucherCode?',
        'It comes back off the bill and stays unused.',
      );
      if (remove && mounted) {
        setState(() {
          _voucherMinor = 0;
          _voucherCode = null;
        });
      }
      return;
    }

    final result = await showVoucherDialog(
      context,
      commerce: ref.read(commerceRepositoryProvider),
      subtotalMinor: _tender.totals.netGoodsMinor,
    );
    if (result == null || !mounted) return;

    setState(() {
      _voucherMinor = result.amountMinor;
      _voucherCode = result.reference;
    });
  }

  /// Points also reduce the bill. They are only spent on the server once the
  /// sale settles, so an abandoned payment does not cost the customer points.
  Future<void> _takePoints() async {
    if (_pointsRedeemed > 0) {
      final remove = await _confirmRemoval(
        'Take back $_pointsRedeemed points?',
        'They go back on the bill and stay in the customer\'s balance.',
      );
      if (remove && mounted) {
        setState(() {
          _pointsMinor = 0;
          _pointsRedeemed = 0;
        });
      }
      return;
    }

    final result = await showLoyaltyDialog(
      context,
      commerce: ref.read(commerceRepositoryProvider),
      outstandingMinor: _tender.dueNowMinor,
      // So the dialog can tell the customer what this sale will earn them,
      // which is half of why they hand over their number.
      spendMinor: _tender.totals.netGoodsMinor,
    );
    if (result == null || !mounted) return;

    setState(() {
      _customer = result.customer;
      if (result.points > 0) {
        _pointsMinor = result.amountMinor;
        _pointsRedeemed = result.points;
      }
    });
  }

  /// Take an amount off the bill as a manual discount. This is the clerk's own
  /// reduction — a goodwill gesture or a price match — as distinct from an
  /// automatic offer or a voucher.
  ///
  /// Offered as a percentage or a cash amount: "give them 10% off" is the more
  /// common instruction, and making the clerk do that arithmetic at the counter
  /// is where discounts go wrong.
  Future<void> _applyManualDiscount() async {
    final base = _tender.totals.grossMinor - _tender.totals.promoMinor;
    final choice = await showDiscountDialog(
      context,
      subtotalMinor: base,
      current: _discount,
    );
    if (choice == null || !mounted) return;

    setState(() {
      _discount = choice.amountMinor > 0 ? choice : null;
      _manualDiscountMinor = choice.amountMinor;
      _entry = '';
    });
  }

  /// A small yes/no for undoing a reduction. Removing one changes what the
  /// customer owes, so it is not something a stray tap should do.
  Future<bool> _confirmRemoval(String title, String detail) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(detail),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    return yes ?? false;
  }

  Future<void> _chooseGratuity() async {
    final settings = ref.read(tenderSettingsProvider);
    final bp = await showGratuityDialog(
      context,
      settings: settings,
      baseMinor: _tender.totals.netGoodsMinor,
      currentBp: _gratuityBp,
    );
    if (bp == null || !mounted) return;

    setState(() {
      _gratuityTouched = true;
      _gratuityBp = bp;
      _gratuityApplies = bp > 0;
    });
  }

  Future<void> _chooseSplit() async {
    final choice = await showSplitDialog(context, state: _tender);
    if (choice == null || !mounted) return;

    setState(() {
      _tender = switch (choice.mode) {
        SplitMode.equally => _tender.splitEqually(choice.ways),
        SplitMode.byItem => _tender.splitByItems(choice.groups ?? const []),
        _ => _tender.clearSplit(),
      };
    });
  }

  /// Commit the sale once everything is paid.
  Future<void> _settleIfPaid() async {
    if (!_tender.settled) return;

    final repo = ref.read(orderRepositoryProvider);
    final session = await ref.read(sessionRepositoryProvider).current();

    // Record every tender against the order, so the Z report and the receipt
    // both show how the bill was actually paid.
    for (final entry in _tender.tenders) {
      await repo.settle(
        widget.orderId,
        entry.kind.method,
        entry.amountMinor,
        sessionId: session.id,
      );
    }

    final commerce = ref.read(commerceRepositoryProvider);

    // Mark the voucher used only now. Doing it when it was applied burned a
    // single-use voucher on a payment the clerk then abandoned, with no way to
    // hand it back.
    final voucher = _voucherCode;
    if (voucher != null && _voucherMinor > 0) {
      try {
        await commerce.redeemVoucher(voucher);
      } catch (_) {
        // The sale is paid and the customer has had the discount. A voucher
        // that could not be marked used is a reconciliation problem for the
        // back office, not a reason to hold up the receipt.
      }
    }

    // Loyalty is moved only now for the same reason: points are spent when the
    // sale completes, and earned on what was actually paid for the goods.
    final customer = _customer;
    if (customer != null) {
      try {
        if (_pointsRedeemed > 0) {
          await commerce.movePoints(
            customerId: customer.id,
            kind: 'redeem',
            points: _pointsRedeemed,
            orderId: widget.orderId,
          );
        }
        await commerce.movePoints(
          customerId: customer.id,
          kind: 'earn',
          spendMinor: _tender.totals.netGoodsMinor,
          orderId: widget.orderId,
        );
      } catch (_) {
        // Points are a loyalty nicety; failing to award them must never block
        // handing the customer their receipt.
      }
    }

    if (!mounted) return;
    unawaited(_publishReceipt());
    await _offerReceipt();
    if (!mounted) return;
    widget.onSettled();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(orderRepositoryProvider);
    final settings = ref.watch(tenderSettingsProvider);
    final branding = ref.watch(brandingProvider);

    return StreamBuilder<Order>(
      stream: repo.watchOrder(widget.orderId),
      builder: (context, orderSnap) {
        return StreamBuilder<List<OrderLine>>(
          stream: repo.watchLines(widget.orderId),
          builder: (context, linesSnap) {
            final order = orderSnap.data;
            final lines = linesSnap.data ?? const <OrderLine>[];

            // Re-price on every rebuild, then carry the payments already taken
            // across — the bill can change while it is being paid (a gratuity
            // added, a voucher applied) and the tenders must survive that.
            final totals = _totals(lines, order);
            _tender = _tender.copyWith(totals: totals);

            final receipt = LiveReceipt(
              totals: totals,
              branding: branding,
              tender: _tender,
              tableNumber: order?.tableNumber,
              covers: order?.covers,
              clerkName: ref.read(sessionProvider).name,
              customerName: _customer?.name ?? order?.customerName,
            );

            final panel = TenderPanel(
              state: _tender,
              settings: settings,
              entry: _entry,
              onKey: _key,
              onTender: _take,
              onGratuity: _chooseGratuity,
              onSplit: settings.allowSplitBill ? _chooseSplit : null,
              onSelectShare: (i) =>
                  setState(() => _tender = _tender.selectShare(i)),
              onClearSplit: () =>
                  setState(() => _tender = _tender.clearSplit()),
              onUndo: () =>
                  setState(() => _tender = _tender.removeLastTender()),
              onCustomer: _attachCustomer,
              onDiscount: _applyManualDiscount,
              compact: !context.isPhone,
            );

            return Scaffold(
              appBar: AppBar(
                backgroundColor: Pos.chrome,
                foregroundColor: Colors.white,
                title: const Text('Payment'),
                leading: IconButton(
                  icon: const Icon(Icons.arrow_back),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ),
              // On a desktop or tablet till the receipt stays visible beside
              // the tender keys: the clerk is reading the bill to the customer
              // while taking the money, and a full-screen keypad hides it.
              body: context.isPhone
                  ? DefaultTabController(
                      length: 2,
                      child: Column(
                        children: [
                          const TabBar(tabs: [
                            Tab(text: 'Pay'),
                            Tab(text: 'Receipt'),
                          ]),
                          Expanded(
                            child: TabBarView(
                              children: [
                                SingleChildScrollView(
                                  padding: const EdgeInsets.all(14),
                                  child: panel,
                                ),
                                Padding(
                                  padding: const EdgeInsets.all(14),
                                  child: receipt,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          flex: 3,
                          child: Padding(
                            padding: const EdgeInsets.all(14),
                            child: receipt,
                          ),
                        ),
                        SizedBox(
                          width: 380,
                          child: SingleChildScrollView(
                            padding: const EdgeInsets.fromLTRB(0, 14, 14, 14),
                            child: panel,
                          ),
                        ),
                      ],
                    ),
            );
          },
        );
      },
    );
  }

  /// Attach a customer without redeeming anything, so the sale still earns
  /// them points.
  Future<void> _attachCustomer() async {
    final result = await showLoyaltyDialog(
      context,
      commerce: ref.read(commerceRepositoryProvider),
      outstandingMinor: _tender.dueNowMinor,
      redeem: false,
    );
    if (result?.customer != null && mounted) {
      setState(() => _customer = result!.customer);
    }
  }
}
