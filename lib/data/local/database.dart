import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

part 'database.g.dart';

/// Catalogue mirrored from the back office. Read-mostly on the terminal:
/// the server owns this data, the till holds a local copy so it can sell
/// while offline. Columns track `bo_products` in vesopa_eposdb.
class Products extends Table {
  IntColumn get pluId => integer()();
  TextColumn get name => text()();
  TextColumn get departmentName => text().nullable()();
  TextColumn get groupName => text().nullable()();
  TextColumn get accountingCode => text().nullable()();

  /// Minor units (pence). Money is never stored as a double.
  IntColumn get priceMinor => integer()();
  RealColumn get taxPercentage => real().withDefault(const Constant(0))();
  RealColumn get stockQuantity => real().withDefault(const Constant(0))();

  /// Where this product sits on the till grid. Null means "unassigned" — it
  /// still appears, just after the positioned ones.
  IntColumn get buttonPosition => integer().nullable()();

  /// Overrides the department colour for this one button.
  TextColumn get buttonColor => text().nullable()();

  /// Which kitchen printer this item routes to (e.g. "kitchen", "bar").
  /// Null means it is not sent to the kitchen at all.
  TextColumn get printerRoute => text().nullable()();

  /// An emoji shown large on the till button, and an optional uploaded image
  /// which takes precedence over the emoji when present.
  TextColumn get emoji => text().nullable()();
  TextColumn get imageUrl => text().nullable()();

  @override
  Set<Column> get primaryKey => {pluId};
}

/// A "buy N of these for £X" deal, defined in the back office and applied to
/// the basket here so the discount shows before the customer pays.
class MixMatchDeals extends Table {
  IntColumn get id => integer()();
  TextColumn get name => text()();
  IntColumn get triggerQty => integer().withDefault(const Constant(2))();
  IntColumn get dealPriceMinor => integer()();
  BoolColumn get active => boolean().withDefault(const Constant(true))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Which products qualify for a deal.
class MixMatchProducts extends Table {
  IntColumn get dealId => integer()();
  IntColumn get pluId => integer()();

  @override
  Set<Column> get primaryKey => {dealId, pluId};
}

/// A trading period. A Z report closes one and opens the next; an X report
/// reads the open one without touching it. Totals are always derived from the
/// orders inside the session rather than from a running counter, so a crash
/// cannot corrupt the day's takings.
class TillSessions extends Table {
  TextColumn get id => text()();
  DateTimeColumn get openedAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get closedAt => dateTime().nullable()();

  /// Sequential Z number, assigned when the session is closed.
  IntColumn get zNumber => integer().nullable()();

  /// Cash counted into the drawer at open.
  IntColumn get openingFloatMinor => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Restaurant tables. A table holds at most one open order at a time.
class DiningTables extends Table {
  IntColumn get number => integer()();
  TextColumn get label => text().nullable()();

  @override
  Set<Column> get primaryKey => {number};
}

/// A loyalty/membership account. Points are stored as an integer balance;
/// membership expiry is null for a non-member.
class Customers extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get phone => text().nullable()();
  TextColumn get email => text().nullable()();

  /// Card/fob number swiped at the till.
  TextColumn get cardNumber => text().nullable()();

  IntColumn get pointsBalance => integer().withDefault(const Constant(0))();
  DateTimeColumn get membershipExpiry => dateTime().nullable()();
  DateTimeColumn get syncedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Every movement of points, so a balance can always be explained. The balance
/// on Customers is a cache of the sum of these.
class LoyaltyEntries extends Table {
  TextColumn get id => text()();
  TextColumn get customerId => text().references(Customers, #id)();
  TextColumn get orderId => text().nullable()();

  /// Positive when earned, negative when redeemed.
  IntColumn get points => integer()();
  TextColumn get reason => text()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

/// A sale. Created locally and immediately durable; `syncedAt` stays null
/// until the outbox has pushed it to the server.
class Orders extends Table {
  /// UUID, generated on the terminal. Doubles as the server-side idempotency
  /// key so a retried push can never book the same sale twice.
  TextColumn get id => text()();

  /// open | closed | void | parked (saved to a table)
  TextColumn get status => text().withDefault(const Constant('open'))();
  IntColumn get tableNumber => integer().nullable()();
  TextColumn get clerkPin => text().nullable()();

  /// The trading period this sale belongs to. Fixed at settlement so a Z
  /// report can never be changed by a later sale.
  TextColumn get sessionId => text().nullable()();

  TextColumn get customerId => text().nullable()();

  /// Set when this order was split off another; both halves keep the link so
  /// the original bill can still be reconstructed.
  TextColumn get splitFromOrderId => text().nullable()();

  IntColumn get subtotalMinor => integer().withDefault(const Constant(0))();

  /// What the clerk keyed in by hand. Held separately from [discountMinor],
  /// which is the total including automatic mix & match savings — if the two
  /// shared a column, every recalculation would fold the deal saving back in on
  /// top of itself and the discount would grow without limit.
  IntColumn get manualDiscountMinor =>
      integer().withDefault(const Constant(0))();

  /// Manual discount plus any mix & match savings. This is what the receipt and
  /// the reports show.
  IntColumn get discountMinor => integer().withDefault(const Constant(0))();

  IntColumn get taxMinor => integer().withDefault(const Constant(0))();
  IntColumn get totalMinor => integer().withDefault(const Constant(0))();

  /// Number of diners. Shown as "Covers" on the action bar.
  IntColumn get covers => integer().nullable()();
  TextColumn get notes => text().nullable()();
  TextColumn get customerName => text().nullable()();

  /// The attached customer's standing discount, copied onto the order so it can
  /// fold into the total. 'none' | 'percent' | 'amount'; value is whole percent
  /// or pence depending on the type.
  TextColumn get customerDiscountType =>
      text().withDefault(const Constant('none'))();
  IntColumn get customerDiscountValue =>
      integer().withDefault(const Constant(0))();

  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();
  DateTimeColumn get closedAt => dateTime().nullable()();
  DateTimeColumn get syncedAt => dateTime().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Line items. Price is copied from the catalogue at the moment of sale so a
/// later price change in the back office cannot rewrite historical takings.
class OrderLines extends Table {
  TextColumn get id => text()();
  TextColumn get orderId => text().references(Orders, #id)();
  IntColumn get pluId => integer()();
  TextColumn get name => text()();
  RealColumn get quantity => real().withDefault(const Constant(1))();
  IntColumn get unitPriceMinor => integer()();
  RealColumn get taxPercentage => real().withDefault(const Constant(0))();
  TextColumn get notes => text().nullable()();

  /// A discount on this single line, keyed in by the clerk, in pence off the
  /// line total. Separate from the order-level discount.
  IntColumn get lineDiscountMinor => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

/// Tenders. Split payments are supported by allowing many rows per order.
class Payments extends Table {
  TextColumn get id => text()();
  TextColumn get orderId => text().references(Orders, #id)();

  /// cash | card | voucher
  TextColumn get method => text()();
  IntColumn get amountMinor => integer()();
  DateTimeColumn get takenAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

/// The durable outbox: the single mechanism by which local work reaches the
/// server. Every mutation is appended here in the same transaction that writes
/// the business row, so a crash can never leave a sale that is committed
/// locally but invisible to sync.
class OutboxEntries extends Table {
  TextColumn get id => text()();

  /// order | payment
  TextColumn get entity => text()();
  TextColumn get entityId => text()();
  TextColumn get payload => text()();
  IntColumn get attempts => integer().withDefault(const Constant(0))();
  TextColumn get lastError => text().nullable()();
  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

@DriftDatabase(
  tables: [
    Products,
    Orders,
    OrderLines,
    Payments,
    OutboxEntries,
    TillSessions,
    DiningTables,
    Customers,
    LoyaltyEntries,
    MixMatchDeals,
    MixMatchProducts,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_open());

  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 7;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await m.addColumn(orders, orders.discountMinor);
            await m.addColumn(orders, orders.covers);
            await m.addColumn(orders, orders.notes);
            await m.addColumn(orders, orders.customerName);
          }
          if (from < 3) {
            await m.createTable(tillSessions);
            await m.createTable(diningTables);
            await m.createTable(customers);
            await m.createTable(loyaltyEntries);
            await m.addColumn(products, products.buttonPosition);
            await m.addColumn(products, products.buttonColor);
            await m.addColumn(products, products.printerRoute);
            await m.addColumn(orders, orders.sessionId);
            await m.addColumn(orders, orders.customerId);
            await m.addColumn(orders, orders.splitFromOrderId);
          }
          if (from < 4) {
            await m.createTable(mixMatchDeals);
            await m.createTable(mixMatchProducts);
            await m.addColumn(orders, orders.manualDiscountMinor);
            // Anything already discounted was keyed in by hand, so carry it
            // across rather than silently zeroing open bills.
            await m.database.customStatement(
              'UPDATE orders SET manual_discount_minor = discount_minor',
            );
          }
          if (from < 5) {
            await m.addColumn(orderLines, orderLines.lineDiscountMinor);
          }
          if (from < 6) {
            await m.addColumn(orders, orders.customerDiscountType);
            await m.addColumn(orders, orders.customerDiscountValue);
          }
          if (from < 7) {
            await m.addColumn(products, products.emoji);
            await m.addColumn(products, products.imageUrl);
          }
        },
      );
}

QueryExecutor _open() {
  return LazyDatabase(() async {
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, 'vesopa_epos.sqlite'));

    return NativeDatabase.createInBackground(file);
  });
}
