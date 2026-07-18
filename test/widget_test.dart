import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vesopa_epos/data/local/database.dart';
import 'package:vesopa_epos/main.dart';
import 'package:vesopa_epos/ui/sale_page.dart';

void main() {
  testWidgets('ringing up a product shows it in the basket with a total',
      (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);

    await db.into(db.products).insert(
          ProductsCompanion.insert(
            pluId: const Value(1),
            name: 'Cola',
            departmentName: const Value('Drinks'),
            priceMinor: 150,
            taxPercentage: const Value(20),
          ),
        );

    const orderId = 'test-order';
    await db.into(db.orders).insert(
          const OrdersCompanion(id: Value(orderId)),
        );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(db)],
        child: MaterialApp(
          home: Scaffold(
            body: SalePage(orderId: orderId, onNewOrder: () {}),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The category rail is driven by the catalogue's departments, not a
    // hardcoded menu.
    expect(find.text('Drinks'), findsOneWidget);
    expect(find.text('Cola'), findsOneWidget);

    await tester.tap(find.text('Cola'));
    await tester.pumpAndSettle();

    // Cola now appears twice: once on the grid, once in the basket.
    expect(find.text('Cola'), findsNWidgets(2));
    expect(find.text('1x - '), findsOneWidget);
    expect(find.text('£1.50'), findsWidgets);
  });
}
