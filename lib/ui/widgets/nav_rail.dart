import 'package:flutter/material.dart';

import '../theme.dart';

class NavDestination {
  const NavDestination(this.icon, this.label);
  final IconData icon;
  final String label;
}

const navDestinations = <NavDestination>[
  NavDestination(Icons.sell, 'Sale'),
  NavDestination(Icons.grid_view, 'Table'),
  NavDestination(Icons.receipt_long, 'Receipts'),
  NavDestination(Icons.bar_chart, 'Reports'),
  NavDestination(Icons.shopping_bag, 'Product'),
  NavDestination(Icons.exit_to_app, 'Functions'),
  NavDestination(Icons.settings, 'Settings'),
  NavDestination(Icons.info, 'About'),
];

/// Left-hand navigation, with Logout pinned to the bottom as in the mockups.
class PosNavRail extends StatelessWidget {
  const PosNavRail({
    super.key,
    required this.selected,
    required this.onSelect,
    required this.onLogout,
  });

  final int selected;
  final ValueChanged<int> onSelect;
  final VoidCallback onLogout;

  @override
  Widget build(BuildContext context) {
    // Inside a Drawer the parent already sets the width, so don't fight it.
    final inDrawer = Scaffold.maybeOf(context)?.hasDrawer ?? false;

    return Container(
      width: inDrawer ? null : 208,
      color: Theme.of(context).posRail,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // The drawer opens on a blank list otherwise — the brand belongs at
          // the top of it, the way the desktop rail has it.
          if (inDrawer)
            const _DrawerBrand()
          else
            const SizedBox(height: 16),
          for (var i = 0; i < navDestinations.length; i++)
            _NavItem(
              destination: navDestinations[i],
              active: i == selected,
              onTap: () => onSelect(i),
            ),
          const Spacer(),
          _NavItem(
            destination: const NavDestination(Icons.logout, 'Logout'),
            active: false,
            onTap: onLogout,
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}

/// The logo at the top of the drawer. Just the mark — no wordmark text beside
/// it, since the logo already carries the name.
///
/// The full-colour logo is drawn for print on white; on a dark rail its black
/// wordmark disappears, so the monochrome variant is used instead.
class _DrawerBrand extends StatelessWidget {
  const _DrawerBrand();

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;

    return Container(
      color: dark ? Pos.chrome : Colors.white,
      padding: const EdgeInsets.fromLTRB(20, 52, 20, 24),
      alignment: Alignment.centerLeft,
      child: Image.asset(
        dark
            ? 'assets/brand/vesopa_logo_monochrome.png'
            : 'assets/brand/vesopa_logo.png',
        height: 34,
        fit: BoxFit.contain,
        alignment: Alignment.centerLeft,
        errorBuilder: (_, _, _) => const SizedBox.shrink(),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({
    required this.destination,
    required this.active,
    required this.onTap,
  });

  final NavDestination destination;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 32,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                // The active item gets a filled pill behind its icon.
                color: active ? Pos.brandSoft : Colors.transparent,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(
                destination.icon,
                size: 20,
                // Reads from the theme, so the labels stay legible in dark
                // mode instead of turning black-on-black.
                color: active
                    ? Pos.brand
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(width: 16),
            Text(
              destination.label,
              style: TextStyle(
                fontSize: 15,
                color: active
                    ? Pos.brand
                    : Theme.of(context).colorScheme.onSurface,
                fontWeight: active ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
