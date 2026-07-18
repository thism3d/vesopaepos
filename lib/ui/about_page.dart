import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'layout.dart';
import 'theme.dart';

/// About Vesopa EPOS — the brand mark, a tagline, a short description of what
/// the till is, the headline features, and links out to the web and socials.
///
/// Replaces the old plain placeholder. Social links open in the device browser;
/// a link that cannot be opened is reported rather than silently doing nothing.
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  static const _tagline = 'Point of sale that never stops trading.';
  static const _brief =
      'Vesopa EPOS is an offline-first till. Every sale is written to this '
      'terminal first and synced to the back office when the network allows, so '
      'you keep serving customers whether the internet is up or not. Products, '
      'prices, staff and the floor plan are managed centrally and pushed to '
      'every till the moment they change.';

  static const _features = [
    ('Works fully offline', Icons.cloud_off,
        'Sales queue locally and sync automatically when you are back online.'),
    ('Live back office', Icons.sync,
        'Price, product and floor changes reach every till instantly over a live connection.'),
    ('Card payments', Icons.credit_card,
        'Take card via Dojo, alongside cash, split and partial tenders.'),
    ('Tables & kitchen', Icons.restaurant,
        'Park bills to tables, split and transfer, and print orders to the kitchen.'),
  ];

  static const _socials = [
    ('Website', Icons.language, 'https://vesopaepos.store'),
    ('Instagram', Icons.camera_alt, 'https://instagram.com/vesopaepos'),
    ('Facebook', Icons.facebook, 'https://facebook.com/vesopaepos'),
    ('Support', Icons.email, 'mailto:support@vesopaepos.store'),
  ];

  @override
  Widget build(BuildContext context) {
    final phone = context.isPhone;
    final onVariant = Theme.of(context).colorScheme.onSurfaceVariant;

    return SingleChildScrollView(
      padding: EdgeInsets.all(phone ? 20 : 32),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Brand header.
              Center(
                child: Column(
                  children: [
                    Image.asset(
                      Theme.of(context).brightness == Brightness.dark
                          ? 'assets/brand/vesopa_logo_monochrome.png'
                          : 'assets/brand/vesopa_logo.png',
                      height: 54,
                      errorBuilder: (_, _, _) => Text(
                        'Vesopa EPOS',
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          color: Pos.brand,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    Text(
                      _tagline,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 16,
                        fontStyle: FontStyle.italic,
                        color: Pos.brand,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 28),

              Text(
                _brief,
                style: TextStyle(fontSize: 15, height: 1.55, color: onVariant),
              ),
              const SizedBox(height: 26),

              const Text(
                'What it does',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              for (final (title, icon, body) in _features)
                _FeatureRow(title: title, icon: icon, body: body),

              const SizedBox(height: 26),
              const Text(
                'Connect',
                style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final (label, icon, url) in _socials)
                    _SocialChip(
                      label: label,
                      icon: icon,
                      onTap: () => _open(context, url),
                    ),
                ],
              ),

              const SizedBox(height: 30),
              Center(
                child: Text(
                  'Vesopa EPOS · version 1.0.0\n© ${DateTime.now().year} Vesopa',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 12.5, height: 1.5, color: onVariant),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _open(BuildContext context, String url) async {
    final uri = Uri.parse(url);
    final ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!ok && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not open $url')),
      );
    }
  }
}

class _FeatureRow extends StatelessWidget {
  const _FeatureRow({
    required this.title,
    required this.icon,
    required this.body,
  });

  final String title;
  final IconData icon;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: Pos.brandSoft,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 20, color: Pos.brand),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SocialChip extends StatelessWidget {
  const _SocialChip({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Pos.brandSoft,
      borderRadius: BorderRadius.circular(24),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 18, color: Pos.brand),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  color: Pos.brand,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
