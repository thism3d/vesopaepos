import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../main.dart';
import '../payments/dojo_config.dart';
import '../payments/payment_provider.dart';
import 'printers_page.dart';
import 'theme.dart';
import 'theme_controller.dart';

/// Terminal settings. Anything that belongs to the venue lives in the back
/// office; what is here is specific to *this* screen — chiefly how it looks in
/// the room it stands in.
class SettingsPage extends ConsumerWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final mode = ref.watch(themeControllerProvider).value ?? ThemeMode.dark;
    final office = ref.watch(officeProvider);
    final api = ref.watch(apiBaseProvider);

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          'Settings',
          style: TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 24),

        const _SectionTitle('Appearance'),
        Card(
          margin: EdgeInsets.zero,
          child: RadioGroup<ThemeMode>(
            groupValue: mode,
            onChanged: (value) {
              if (value != null) {
                ref.read(themeControllerProvider.notifier).set(value);
              }
            },
            child: Column(
              children: [
                for (final option in const [
                  (
                    ThemeMode.light,
                    'Day',
                    Icons.light_mode,
                    'Bright rooms and daylight',
                  ),
                  (
                    ThemeMode.dark,
                    'Night',
                    Icons.dark_mode,
                    'Dim bars and evening service',
                  ),
                  (
                    ThemeMode.system,
                    'System',
                    Icons.brightness_auto,
                    'Follow the device setting',
                  ),
                ])
                  RadioListTile<ThemeMode>(
                    value: option.$1,
                    secondary: Icon(option.$3, color: Pos.brand),
                    title: Text(option.$2),
                    subtitle: Text(
                      option.$4,
                      style: const TextStyle(fontSize: 12.5),
                    ),
                  ),
              ],
            ),
          ),
        ),

        const SizedBox(height: 28),
        const _SectionTitle('This terminal'),
        Card(
          margin: EdgeInsets.zero,
          child: Column(
            children: [
              _Row(icon: Icons.storefront, label: 'Office', value: office),
              const Divider(height: 1),
              _Row(icon: Icons.cloud, label: 'Server', value: api),
              const Divider(height: 1),
              _Row(
                icon: Icons.sync,
                label: 'Catalogue',
                value: 'Synced from the back office',
                trailing: TextButton(
                  onPressed: () async {
                    final sync = ref.read(syncServiceProvider);
                    await sync.pullCatalogue();
                    await sync.pullDeals();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Catalogue refreshed.')),
                      );
                    }
                  },
                  child: const Text('Refresh'),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 28),
        const _SectionTitle('Card payments'),
        _DojoCard(),

        const SizedBox(height: 28),
        const _SectionTitle('Printing'),
        Card(
          margin: EdgeInsets.zero,
          child: Column(
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Row(
                  children: [
                    Icon(Icons.print, color: Pos.brand),
                    SizedBox(width: 14),
                    Expanded(
                      child: Text(
                        'Printers belong to this terminal, because they are '
                        'plugged into it. Set the roll width to match the paper '
                        'loaded — 80mm or 58mm.',
                        style: TextStyle(fontSize: 13, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
              // Live summary of what is actually configured, so a missing
              // kitchen printer is visible without opening the page.
              Consumer(
                builder: (context, ref, _) {
                  final settings = ref.watch(printerSettingsProvider).value;
                  final receipt = settings?.receiptPrinter;
                  final kitchen = settings?.kitchenPrinter;
                  return ListTile(
                    leading: const Icon(Icons.settings_outlined),
                    title: const Text('Set up printers'),
                    subtitle: Text(
                      [
                        receipt == null
                            ? 'No receipt printer'
                            : 'Receipt: ${receipt.name} (${receipt.paperWidthMm}mm)',
                        kitchen == null
                            ? 'No kitchen printer'
                            : 'Kitchen: ${kitchen.name} (${kitchen.paperWidthMm}mm)',
                      ].join('  ·  '),
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => Scaffold(
                          appBar: AppBar(title: const Text('Printers')),
                          body: const PrintersPage(),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Card payment configuration. Shows whether Dojo is set up on this terminal
/// and lets the operator enter or change the credentials on the device.
class _DojoCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final config = ref.watch(dojoConfigProvider).value ?? const DojoConfig();
    final configured = config.configured;

    return Card(
      margin: EdgeInsets.zero,
      child: Column(
        children: [
          ListTile(
            leading: Icon(
              configured ? Icons.credit_card : Icons.credit_card_off,
              color: configured ? Pos.green : Theme.of(context).hintColor,
            ),
            title: Text(
              configured ? 'Dojo card payments on' : 'Card not set up',
            ),
            subtitle: Text(
              configured
                  ? '${config.sandbox ? 'Sandbox' : 'Live'} · key '
                        '${_masked(config.apiKey)}\n${_howCardsAreTaken(config)}'
                  : 'Enter your Dojo key to take card payments on this till.',
              style: const TextStyle(fontSize: 12.5),
            ),
            isThreeLine: configured,
            trailing: TextButton(
              onPressed: () => _edit(context, ref, config),
              child: Text(configured ? 'Edit' : 'Set up'),
            ),
          ),
        ],
      ),
    );
  }

  /// Spell out how this terminal will actually present a card, because it
  /// differs by platform and by what has been filled in — and a clerk who does
  /// not know which route is live cannot tell a misconfiguration from a decline.
  static String _howCardsAreTaken(DojoConfig config) {
    final hasPartnerIds =
        config.softwareHouseId.trim().isNotEmpty &&
        config.resellerId.trim().isNotEmpty;
    final hasTerminal = config.terminalId.trim().isNotEmpty;

    // A card machine is used wherever one is set up, on every platform.
    if (hasTerminal && hasPartnerIds) {
      return 'Pay at counter on card machine ${config.terminalId}.';
    }
    if (hasTerminal) {
      // The ids are not optional: Dojo refuses the terminal call without both,
      // so say so here rather than letting it fail at the moment of payment.
      return 'Card machine set, but the software-house / reseller ids are '
          'incomplete — the card will be keyed instead.';
    }
    if (Platform.isAndroid) {
      return 'No card machine: card entry on this device (Dojo drop-in).';
    }
    return 'No card machine: the card is keyed on screen in a Dojo checkout '
        'window.';
  }

  /// Never show the full key back — enough to recognise it, no more.
  static String _masked(String key) {
    final k = key.trim();
    if (k.length <= 6) return '••••';
    return '${k.substring(0, 4)}…${k.substring(k.length - 2)}';
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    DojoConfig current,
  ) async {
    final saved = await showDialog<DojoConfig>(
      context: context,
      builder: (_) => _DojoEditor(current: current),
    );
    if (saved == null) return;
    await ref.read(dojoConfigProvider.notifier).save(saved);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            saved.configured
                ? 'Card payments configured.'
                : 'Card payments turned off.',
          ),
        ),
      );
    }
  }
}

class _DojoEditor extends StatefulWidget {
  const _DojoEditor({required this.current});

  final DojoConfig current;

  @override
  State<_DojoEditor> createState() => _DojoEditorState();
}

class _DojoEditorState extends State<_DojoEditor> {
  late final _key = TextEditingController(text: widget.current.apiKey);
  late final _terminal = TextEditingController(text: widget.current.terminalId);
  late final _softwareHouse = TextEditingController(
    text: widget.current.softwareHouseId,
  );
  late final _reseller = TextEditingController(text: widget.current.resellerId);
  late bool _sandbox = widget.current.sandbox;

  /// Readers found on the account, so the clerk picks one instead of copying an
  /// opaque `tm_…` id from a portal.
  List<DojoTerminal>? _terminals;
  bool _loadingTerminals = false;
  String? _terminalError;

  @override
  void dispose() {
    _key.dispose();
    _terminal.dispose();
    _softwareHouse.dispose();
    _reseller.dispose();
    super.dispose();
  }

  Future<void> _findTerminals() async {
    setState(() {
      _loadingTerminals = true;
      _terminalError = null;
    });
    try {
      final found = await DojoProvider(
        apiKey: _key.text.trim(),
        softwareHouseId: _softwareHouse.text.trim(),
        resellerId: _reseller.text.trim(),
      ).listTerminals();
      if (mounted) setState(() => _terminals = found);
    } catch (e) {
      if (mounted) setState(() => _terminalError = '$e');
    } finally {
      if (mounted) setState(() => _loadingTerminals = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Dojo card payments'),
      // Scrollable so the on-screen keyboard cannot overflow the fields on a
      // phone.
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Enter the Dojo API key for this terminal. Use a sandbox key to '
                'test without taking real money.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _key,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'API key',
                  hintText: 'sk_sandbox_…',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                value: _sandbox,
                onChanged: (v) => setState(() => _sandbox = v),
                title: const Text('Sandbox mode'),
                subtitle: const Text(
                  'Talk to Dojo\'s test environment, not live.',
                  style: TextStyle(fontSize: 12),
                ),
              ),
              const Divider(),
              Text(
                'Card machine (pay at counter). With a machine selected the '
                'card is taken on it; without one the card is keyed on screen. '
                'Both partner ids are required — the machine list is refused '
                'if either is missing.',
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).hintColor,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _softwareHouse,
                decoration: const InputDecoration(
                  labelText: 'Software-house id',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _reseller,
                decoration: const InputDecoration(
                  labelText: 'Reseller id',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _terminal,
                decoration: InputDecoration(
                  labelText: 'Card machine (blank = none)',
                  border: const OutlineInputBorder(),
                  helperText: _terminal.text.isEmpty
                      ? 'No machine: the card is keyed on screen.'
                      : null,
                  suffixIcon: _terminal.text.isEmpty
                      ? null
                      : IconButton(
                          tooltip: 'Use no card machine',
                          icon: const Icon(Icons.clear),
                          onPressed: () => setState(_terminal.clear),
                        ),
                ),
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: _loadingTerminals ? null : _findTerminals,
                    icon: _loadingTerminals
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.search, size: 18),
                    label: const Text('Find card machines'),
                  ),
                ],
              ),
              if (_terminalError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _terminalError!,
                    style: const TextStyle(fontSize: 12, color: Pos.red),
                  ),
                ),
              if (_terminals != null) ...[
                const SizedBox(height: 8),
                if (_terminals!.isEmpty)
                  Text(
                    'No card machines available on this account.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).hintColor,
                    ),
                  )
                else
                  // Tap to select — the id goes in the field, so what is saved
                  // is still just the id.
                  for (final t in _terminals!)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      leading: Icon(
                        _terminal.text.trim() == t.id
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                        color: _terminal.text.trim() == t.id
                            ? Pos.brand
                            : Theme.of(context).hintColor,
                      ),
                      onTap: () => setState(() => _terminal.text = t.id),
                      title: Text(t.label),
                      subtitle: Text(
                        '${t.status} · ${t.id}',
                        style: const TextStyle(fontSize: 11),
                      ),
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
          onPressed: () => Navigator.pop(
            context,
            DojoConfig(
              apiKey: _key.text.trim(),
              terminalId: _terminal.text.trim(),
              softwareHouseId: _softwareHouse.text.trim(),
              resellerId: _reseller.text.trim(),
              sandbox: _sandbox,
            ),
          ),
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 11.5,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.1,
        color: Theme.of(context).hintColor,
      ),
    ),
  );
}

class _Row extends StatelessWidget {
  const _Row({
    required this.icon,
    required this.label,
    required this.value,
    this.trailing,
  });

  final IconData icon;
  final String label;
  final String value;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon, color: Pos.brand),
      title: Text(label),
      subtitle: Text(value, style: const TextStyle(fontSize: 12.5)),
      trailing: trailing,
    );
  }
}
