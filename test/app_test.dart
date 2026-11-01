import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:store_client/app.dart';
import 'package:store_client/app_state.dart';
import 'package:store_client/screens/ui.dart';

// All HTTP is mocked; nothing here calls the real API.

http.Response json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

const authAnswer = {
  'token': 'tok',
  'expires_at': '2026-12-01T03:47:06Z',
  'user': {'id': 42, 'name': 'Ann', 'email': 'ann@example.com', 'admin': false, 'enabled': true},
};

Map<String, Object?> productJson(int id, String name, int price, int stock, {String? image, String? description}) => {
  'id': id,
  'name': name,
  'description': description ?? 'About the $name',
  'price_cents': price,
  'stock': stock,
  'active': true,
  'image_url': image,
  'created_at': '2026-11-01T03:47:06Z',
  'updated_at': '2026-11-01T03:47:06Z',
};

Map<String, Object?> page(List<Object?> rows, {Map<String, Object?> extra = const {}}) => {
  'data': rows,
  'total': rows.length,
  'page': 1,
  'per_page': 100,
  ...extra,
};

final opened = <String>[];

Future<List<http.Request>> pumpApp(
  WidgetTester tester, {
  required FutureOr<http.Response> Function(http.Request) server,
  Size size = const Size(1000, 1600),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  opened.clear();
  final seen = <http.Request>[];
  final client = MockClient((r) async {
    seen.add(r);
    return server(r);
  });
  final state = AppState(apiKey: 'build-key', client: client);
  await tester.pumpWidget(StoreApp(state: state, openUrl: opened.add));
  await tester.pumpAndSettle();
  return seen;
}

/// A tiny in-memory Store API with user 42.
class FakeServer {
  FakeServer({List<Map<String, Object?>>? products})
    : products = products ?? [
        productJson(1, 'Stoneware Mug', 1800, 12),
        productJson(2, 'Linen Tote', 2450, 0, description: null),
        productJson(3, 'Desk Lamp', 123456, 3),
      ];

  final List<Map<String, Object?>> products;
  final List<Map<String, Object?>> cart = [];
  final List<Map<String, Object?>> orders = [];
  int nextId = 100;
  http.Response? failNext;

  Map<String, Object?>? product(Object? id) {
    for (final p in products) {
      if (p['id'] == id) return p;
    }
    return null;
  }

  Map<String, Object?> cartJson(Map<String, Object?> item) {
    final p = product(item['product_id'])!;
    return {...item, 'name': p['name'], 'price_cents': p['price_cents']};
  }

  http.Response call(http.Request r) {
    final path = r.url.path;
    final fail = failNext;
    if (fail != null && path.startsWith('/api/users/42/')) {
      failNext = null;
      return fail;
    }
    if (path == '/api/users/login') return json(authAnswer);
    if (path == '/api/users/register') return json(authAnswer, 201);
    if (path == '/api/users/logout') return json({'message': 'Logged out.'});

    if (path == '/api/products') {
      final q = r.url.queryParameters['q']?.toLowerCase();
      var rows = [
        for (final p in products)
          if ((q == null || '${p['name']} ${p['description']}'.toLowerCase().contains(q)) &&
              (r.url.queryParameters['in_stock'] != 'true' || (p['stock'] as int) > 0))
            p,
      ];
      final sort = r.url.queryParameters['sort'];
      if (sort == 'price') rows.sort((a, b) => (a['price_cents'] as int) - (b['price_cents'] as int));
      if (sort == '-price') rows.sort((a, b) => (b['price_cents'] as int) - (a['price_cents'] as int));
      return json(page(rows));
    }
    final single = RegExp(r'^/api/products/(\d+)$').firstMatch(path);
    if (single != null) {
      final p = product(int.parse(single.group(1)!));
      return p == null ? json({'message': 'Product not found.'}, 404) : json(p);
    }

    if (path == '/api/users/42/cart' && r.method == 'GET') {
      final total = cart.fold<int>(0, (s, i) => s + (product(i['product_id'])!['price_cents'] as int) * (i['quantity'] as int));
      return json(page([for (final i in cart.reversed) cartJson(i)], extra: {'total_cents': total}));
    }
    if (path == '/api/users/42/cart' && r.method == 'POST') {
      final body = jsonDecode(r.body) as Map<String, Object?>;
      if (product(body['product_id']) == null) return json({'message': 'Product not found.'}, 404);
      if (cart.any((i) => i['product_id'] == body['product_id'])) {
        return json({'message': 'That product is already in the cart.'}, 409);
      }
      final item = {'id': nextId++, 'product_id': body['product_id'], 'quantity': body['quantity']};
      cart.add(item);
      return json(cartJson(item), 201);
    }
    final line = RegExp(r'^/api/users/42/cart/(\d+)$').firstMatch(path);
    if (line != null) {
      final item = cart.where((i) => i['id'] == int.parse(line.group(1)!)).firstOrNull;
      if (item == null) return json({'message': 'Cart item not found.'}, 404);
      if (r.method == 'DELETE') {
        cart.remove(item);
        return json({'message': 'Cart item deleted.'});
      }
      item['quantity'] = (jsonDecode(r.body) as Map<String, Object?>)['quantity'];
      return json(cartJson(item));
    }

    if (path == '/api/users/42/orders' && r.method == 'GET') return json(page(orders.reversed.toList()));
    if (path == '/api/users/42/orders' && r.method == 'POST') {
      if (cart.isEmpty) return json({'message': 'Your cart is empty. Add a product before you check out.'}, 422);
      for (final i in cart) {
        final p = product(i['product_id'])!;
        if ((p['stock'] as int) < (i['quantity'] as int)) {
          return json({'message': 'Not enough stock of ${p['name']}.'}, 409);
        }
      }
      var total = 0;
      final items = <Map<String, Object?>>[];
      for (final i in cart) {
        final p = product(i['product_id'])!;
        p['stock'] = (p['stock'] as int) - (i['quantity'] as int);
        total += (p['price_cents'] as int) * (i['quantity'] as int);
        items.add({'product_id': p['id'], 'name': p['name'], 'price_cents': p['price_cents'], 'quantity': i['quantity']});
      }
      cart.clear();
      final order = {'id': nextId++, 'status': 'placed', 'total_cents': total, 'items': items, 'created_at': '2026-11-01T03:47:06Z'};
      orders.add(order);
      return json(order, 201);
    }
    final cancel = RegExp(r'^/api/users/42/orders/(\d+)/cancel$').firstMatch(path);
    if (cancel != null) {
      final order = orders.where((o) => o['id'] == int.parse(cancel.group(1)!)).firstOrNull;
      if (order == null) return json({'message': 'Order not found.'}, 404);
      if (order['status'] != 'placed') return json({'message': 'Order is ${order['status']}, so it cannot be cancelled.'}, 409);
      for (final i in order['items'] as List) {
        final p = product((i as Map)['product_id'])!;
        p['stock'] = (p['stock'] as int) + (i['quantity'] as int);
      }
      order['status'] = 'cancelled';
      return json(order);
    }
    return json({'message': 'This route does not exist.'}, 404);
  }
}

Future<void> demoLogin(WidgetTester tester) async {
  await tester.tap(find.text('Try the demo account'));
  await tester.pumpAndSettle();
}

void main() {
  test('formatCents shows whole cents as dollars with two decimals', () {
    expect(formatCents(0), r'$0.00');
    expect(formatCents(5), r'$0.05');
    expect(formatCents(1800), r'$18.00');
    expect(formatCents(123456), r'$1,234.56');
    expect(formatCents(100000000), r'$1,000,000.00');
  });

  testWidgets('a visitor sees the catalog with prices, stock, placeholders and the learning notice', (tester) async {
    final server = FakeServer();
    final seen = await pumpApp(tester, server: server.call);

    expect(find.text('Stoneware Mug'), findsOneWidget);
    expect(find.textContaining(r'$18.00'), findsOneWidget);
    expect(find.textContaining('12 in stock'), findsOneWidget);
    expect(find.textContaining('Sold out'), findsOneWidget);
    expect(find.textContaining(r'$1,234.56'), findsOneWidget);
    expect(find.textContaining('Only 3 left'), findsOneWidget);
    expect(find.byKey(const Key('product-placeholder')), findsNWidgets(3));
    expect(find.byKey(const Key('learning-notice')), findsOneWidget);
    expect(find.textContaining('No payment is taken'), findsOneWidget);
    expect(find.text('Try the demo account'), findsOneWidget);
    expect(find.text('Create an account'), findsOneWidget);
    expect(find.text('Log in'), findsWidgets);
    expect(find.text('Add to cart'), findsNothing);
    // the key goes in the query string and no token is sent
    expect(seen.single.url.queryParameters['apikey'], 'build-key');
    expect(seen.single.headers.containsKey('Authorization'), isFalse);
  });

  testWidgets('the back arrow opens the SimpleAPI home page', (tester) async {
    await pumpApp(tester, server: FakeServer().call);
    await tester.tap(find.byTooltip('Back to SimpleAPI'));
    expect(opened, ['https://simpleapi.dev']);
  });

  testWidgets('search, in stock and sort go to the API', (tester) async {
    final server = FakeServer();
    final seen = await pumpApp(tester, server: server.call);

    await tester.enterText(find.byType(TextField), 'lamp');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(seen.last.url.queryParameters['q'], 'lamp');
    expect(find.text('Desk Lamp'), findsOneWidget);
    expect(find.text('Stoneware Mug'), findsNothing);

    await tester.tap(find.byTooltip('Clear search'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('In stock only'));
    await tester.pumpAndSettle();
    expect(seen.last.url.queryParameters['in_stock'], 'true');
    expect(find.text('Linen Tote'), findsNothing);

    await tester.tap(find.byKey(const Key('sort')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Price: high to low').last);
    await tester.pumpAndSettle();
    expect(seen.last.url.queryParameters['sort'], '-price');
    final lamp = tester.getTopLeft(find.text('Desk Lamp')).dy;
    final mug = tester.getTopLeft(find.text('Stoneware Mug')).dy;
    expect(lamp, lessThan(mug));
  });

  testWidgets('an empty search result says so', (tester) async {
    await pumpApp(tester, server: FakeServer().call);
    await tester.enterText(find.byType(TextField), 'zzz');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.text('No products match.'), findsOneWidget);
  });

  testWidgets('a failed catalog shows the API message wording and retries', (tester) async {
    var fail = true;
    final server = FakeServer();
    await pumpApp(
      tester,
      server: (r) => fail ? json({'message': 'x'}, 503) : server.call(r),
    );
    expect(find.text('The service is busy. Please try again shortly.'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Stoneware Mug'), findsOneWidget);
  });

  testWidgets('a product opens its detail, and a visitor is asked to log in', (tester) async {
    await pumpApp(tester, server: FakeServer().call);
    await tester.tap(find.text('Stoneware Mug'));
    await tester.pumpAndSettle();
    expect(find.text('About the Stoneware Mug'), findsOneWidget);
    expect(find.text('Log in to add this to a cart.'), findsOneWidget);
    expect(find.byKey(const Key('learning-notice')), findsOneWidget);
    expect(find.text('Linen Tote'), findsNothing);
  });

  testWidgets('a missing product shows a readable error', (tester) async {
    final server = FakeServer();
    await pumpApp(tester, server: server.call);
    await tester.tap(find.text('Stoneware Mug'));
    server.products.removeAt(0);
    await tester.pumpAndSettle();
    expect(find.text('Not found. It may already have been deleted.'), findsOneWidget);
  });

  testWidgets('the demo account logs in with one click and the cart badge appears', (tester) async {
    final server = FakeServer();
    final seen = await pumpApp(tester, server: server.call);
    await demoLogin(tester);

    final login = seen.firstWhere((r) => r.url.path == '/api/users/login');
    expect(jsonDecode(login.body), {'email': 'demo@simpleapi.dev', 'password': 'try-the-demo'});
    expect(login.headers.containsKey('Authorization'), isFalse);
    expect(find.text('Log out'), findsOneWidget);
    expect(find.text('Try the demo account'), findsNothing);
    expect(find.text('Add to cart'), findsNWidgets(2)); // the sold out product has none
  });

  testWidgets('add to cart, change quantity, remove, and the total', (tester) async {
    final server = FakeServer();
    await pumpApp(tester, server: server.call);
    await demoLogin(tester);

    await tester.tap(find.text('Add to cart').first); // the mug
    await tester.pumpAndSettle();
    expect(find.text('In your cart'), findsOneWidget);
    expect(server.cart.single['quantity'], 1);

    await tester.tap(find.byTooltip('Cart'));
    await tester.pumpAndSettle();
    expect(find.text('Your cart'), findsOneWidget);
    expect(find.byKey(const Key('cart-total')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const Key('cart-total'))).data, r'$18.00');

    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const Key('cart-total'))).data, r'$36.00');
    expect(server.cart.single['quantity'], 2);

    await tester.tap(find.byTooltip('Fewer'));
    await tester.pumpAndSettle();
    expect(server.cart.single['quantity'], 1);

    await tester.tap(find.byTooltip('Remove'));
    await tester.pumpAndSettle();
    expect(server.cart, isEmpty);
    expect(find.textContaining('Your cart is empty'), findsOneWidget);
  });

  testWidgets('add from the detail page with a quantity', (tester) async {
    final server = FakeServer();
    await pumpApp(tester, server: server.call);
    await demoLogin(tester);

    await tester.tap(find.text('Desk Lamp'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More'));
    await tester.pump();
    await tester.tap(find.byTooltip('More'));
    await tester.pump();
    await tester.tap(find.byTooltip('More')); // stock is 3: the third tap does nothing
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const Key('quantity'))).data, '3');
    expect(find.textContaining(r'$3,703.68'), findsOneWidget);
    await tester.tap(find.textContaining('Add to cart'));
    await tester.pumpAndSettle();
    expect(server.cart.single['quantity'], 3);
    expect(find.text('In your cart (3).'), findsOneWidget);
  });

  testWidgets('adding a product that is already in the cart shows the API message', (tester) async {
    final server = FakeServer();
    await pumpApp(tester, server: server.call);
    await demoLogin(tester);
    // the cart changed elsewhere: the app does not know yet
    server.cart.add({'id': 90, 'product_id': 1, 'quantity': 1});
    await tester.tap(find.text('Add to cart').first);
    await tester.pumpAndSettle();
    expect(find.text('That product is already in the cart.'), findsOneWidget);
  });

  testWidgets('checkout places the order, shows it with its items, and the stock drops', (tester) async {
    final server = FakeServer();
    await pumpApp(tester, server: server.call);
    await demoLogin(tester);
    await tester.tap(find.text('Add to cart').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Cart'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Place order'));
    await tester.pumpAndSettle();

    expect(find.text('Your orders'), findsOneWidget);
    expect(find.textContaining('Order '), findsWidgets);
    expect(find.text('2 × Stoneware Mug'), findsOneWidget);
    expect(find.textContaining(r'$36.00'), findsWidgets);
    expect(find.text('placed'), findsOneWidget);
    expect(find.textContaining('No money was taken'), findsOneWidget);
    expect(server.product(1)!['stock'], 10);
    expect(server.cart, isEmpty);

    // back on the shop, the stock shown is the new one
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.textContaining('10 in stock'), findsOneWidget);
  });

  testWidgets('checkout shows the API message when stock is short, and keeps the cart', (tester) async {
    final server = FakeServer();
    await pumpApp(tester, server: server.call);
    await demoLogin(tester);
    await tester.tap(find.text('Add to cart').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Cart'));
    await tester.pumpAndSettle();
    server.product(1)!['stock'] = 0; // sold out meanwhile
    await tester.tap(find.text('Place order'));
    await tester.pumpAndSettle();
    expect(find.text('Not enough stock of Stoneware Mug.'), findsOneWidget);
    expect(find.text('Your cart'), findsOneWidget);
    expect(server.cart, hasLength(1));
  });

  testWidgets('a placed order can be cancelled, and the stock goes back', (tester) async {
    final server = FakeServer();
    await pumpApp(tester, server: server.call);
    await demoLogin(tester);
    await tester.tap(find.text('Add to cart').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Cart'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Place order'));
    await tester.pumpAndSettle();
    expect(server.product(1)!['stock'], 11);

    await tester.tap(find.text('Cancel order'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel order').last); // the dialog button
    await tester.pumpAndSettle();
    expect(find.text('cancelled'), findsOneWidget);
    expect(find.text('Cancel order'), findsNothing);
    expect(server.product(1)!['stock'], 12);
  });

  testWidgets('cancelling an order that already moved shows the API message', (tester) async {
    final server = FakeServer();
    server.orders.add({
      'id': 7,
      'status': 'placed',
      'total_cents': 1800,
      'created_at': '2026-11-01T03:47:06Z',
      'items': [
        {'product_id': 1, 'name': 'Stoneware Mug', 'price_cents': 1800, 'quantity': 1},
      ],
    });
    await pumpApp(tester, server: server.call);
    await demoLogin(tester);
    await tester.tap(find.byTooltip('My orders'));
    await tester.pumpAndSettle();
    server.orders.single['status'] = 'shipped';
    await tester.tap(find.text('Cancel order'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel order').last);
    await tester.pumpAndSettle();
    expect(find.text('Order is shipped, so it cannot be cancelled.'), findsOneWidget);
    expect(find.text('shipped'), findsOneWidget);
  });

  testWidgets('a 401 on the cart screen logs out and returns to the shop', (tester) async {
    final server = FakeServer();
    server.cart.add({'id': 90, 'product_id': 1, 'quantity': 1});
    await pumpApp(tester, server: server.call);
    await demoLogin(tester);
    await tester.tap(find.byTooltip('Cart'));
    await tester.pumpAndSettle();
    server.failNext = json({'message': 'Invalid or expired auth token. Log in again.'}, 401);
    await tester.tap(find.byTooltip('More'));
    await tester.pumpAndSettle();
    expect(find.text('Your session has ended. Please log in again.'), findsOneWidget);
    expect(find.text('Your cart'), findsNothing);
    expect(find.text('Try the demo account'), findsOneWidget);
  });

  testWidgets('a dead session during add logs out with a clear message', (tester) async {
    final server = FakeServer();
    await pumpApp(tester, server: server.call);
    await demoLogin(tester);
    server.failNext = json({'message': 'Invalid or expired auth token. Log in again.'}, 401);
    await tester.tap(find.text('Add to cart').first);
    await tester.pumpAndSettle();
    expect(find.text('Your session has ended. Please log in again.'), findsOneWidget);
    expect(find.text('Try the demo account'), findsOneWidget);
    expect(find.text('Log out'), findsNothing);
  });

  testWidgets('log out clears the cart and the logged-in buttons', (tester) async {
    final server = FakeServer();
    await pumpApp(tester, server: server.call);
    await demoLogin(tester);
    await tester.tap(find.text('Log out'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Cart'), findsNothing);
    expect(find.text('Try the demo account'), findsOneWidget);
  });

  testWidgets('the login screen has the demo button, the notice, and registers', (tester) async {
    final server = FakeServer();
    final seen = await pumpApp(tester, server: server.call);
    await tester.tap(find.text('Create an account'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('demo-notice')), findsOneWidget);
    expect(find.text('Try the demo account'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'Ann');
    await tester.enterText(find.widgetWithText(TextField, 'Email'), 'ann@example.com');
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'secret-pass');
    await tester.tap(find.widgetWithText(FilledButton, 'Register'));
    await tester.pumpAndSettle();
    expect(seen.any((r) => r.url.path == '/api/users/register'), isTrue);
    expect(find.text('Log out'), findsOneWidget);
  });

  testWidgets('a failed login shows the API message', (tester) async {
    await pumpApp(
      tester,
      server: (r) => r.url.path == '/api/users/login'
          ? json({'message': 'Invalid email or password.'}, 401)
          : FakeServer().call(r),
    );
    await tester.tap(find.text('Log in').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Email'), 'a@example.com');
    await tester.enterText(find.widgetWithText(TextField, 'Password'), 'wrong-pass');
    await tester.tap(find.widgetWithText(FilledButton, 'Log in'));
    await tester.pumpAndSettle();
    expect(find.text('Invalid email or password.'), findsOneWidget);
  });

  testWidgets('works at phone width without overflow, logged out and in', (tester) async {
    final server = FakeServer();
    await pumpApp(tester, server: server.call, size: const Size(360, 740));
    expect(tester.takeException(), isNull);
    expect(find.text('SimpleAPI Store'), findsOneWidget);
    await demoLogin(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('SimpleAPI Store'), findsOneWidget);
    await tester.tap(find.text('Add to cart').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Cart'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Place order'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
