import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:store_client/store_api.dart';

// A made-up value: the tests never touch the real API or a real key.
const fakeKey = 'test-key';

Map<String, Object?> productJson(int id, String name, {int price = 1800, int stock = 5, String? image}) => {
  'id': id,
  'name': name,
  'description': 'About $name',
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

http.Response json(Object body, [int status = 200]) =>
    http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

// All HTTP is mocked; nothing here calls the real API.
(StoreApi, List<http.Request>) apiWith(http.Response Function(http.Request) handler, {bool loggedIn = false}) {
  final seen = <http.Request>[];
  final client = MockClient((request) async {
    seen.add(request);
    return handler(request);
  });
  return (
    StoreApi(apiKey: fakeKey, token: loggedIn ? 'tok' : null, userId: loggedIn ? 42 : null, client: client),
    seen,
  );
}

void main() {
  test('the catalog sends the key and no bearer token, with the filters', () async {
    final (api, seen) = apiWith((_) => json(page([productJson(1, 'Mug')])));
    api.token = 'tok';
    api.userId = 42;
    final result = await api.listProducts(q: 'mug', inStock: true, sort: '-price');

    final r = seen.single;
    expect(r.url.host, 'store.simpleapi.dev');
    expect(r.url.path, '/api/products');
    expect(r.url.queryParameters, {
      'apikey': fakeKey,
      'q': 'mug',
      'in_stock': 'true',
      'sort': '-price',
      'page': '1',
      'per_page': '100',
    });
    expect(r.headers.containsKey('Authorization'), isFalse);
    expect(result.items.single.name, 'Mug');
    expect(result.hasMore, isFalse);
  });

  test('no filter sends no q, in_stock or sort', () async {
    final (api, seen) = apiWith((_) => json(page([])));
    await api.listProducts();
    expect(seen.single.url.queryParameters.keys, {'apikey', 'page', 'per_page'});
  });

  test('a null image_url and description are read as none', () async {
    final (api, _) = apiWith((_) => json({...productJson(1, 'Mug'), 'description': null, 'image_url': null}));
    final p = await api.getProduct(1);
    expect(p.imageUrl, isNull);
    expect(p.description, '');
    expect(p.priceCents, 1800);
  });

  test('the cart is read with its total, and the calls use the user path and the token', () async {
    final (api, seen) = apiWith(
      (r) => json(
        page([
          {'id': 3, 'product_id': 1, 'name': 'Mug', 'price_cents': 1800, 'quantity': 2},
          {'id': 4, 'product_id': 9, 'name': null, 'price_cents': null, 'quantity': 1},
        ], extra: {'total_cents': 3600}),
      ),
      loggedIn: true,
    );
    final cart = await api.listCart();
    expect(seen.single.url.path, '/api/users/42/cart');
    expect(seen.single.headers['Authorization'], 'Bearer tok');
    expect(cart.totalCents, 3600);
    expect(cart.items.first.lineCents, 3600);
    expect(cart.items.last.name, isNull);
    expect(cart.items.last.lineCents, isNull);
  });

  test('add, change and remove an item', () async {
    final (api, seen) = apiWith((r) {
      if (r.method == 'DELETE') return json({'message': 'Cart item 3 deleted.'});
      return json({'id': 3, 'product_id': 1, 'name': 'Mug', 'price_cents': 1800, 'quantity': 4}, r.method == 'POST' ? 201 : 200);
    }, loggedIn: true);
    await api.addToCart(1, 4);
    await api.updateCartItem(3, 2);
    await api.removeCartItem(3);

    expect([for (final r in seen) '${r.method} ${r.url.path}'], [
      'POST /api/users/42/cart',
      'PUT /api/users/42/cart/3',
      'DELETE /api/users/42/cart/3',
    ]);
    expect(jsonDecode(seen[0].body), {'product_id': 1, 'quantity': 4});
    expect(jsonDecode(seen[1].body), {'quantity': 2});
  });

  test('checkout reads the order with its items, and cancel posts to the order', () async {
    final order = {
      'id': 7,
      'status': 'placed',
      'total_cents': 3600,
      'created_at': '2026-11-01T03:47:06Z',
      'items': [
        {'product_id': 1, 'name': 'Mug', 'price_cents': 1800, 'quantity': 2},
      ],
    };
    final (api, seen) = apiWith(
      (r) => r.url.path.endsWith('/cancel') ? json({...order, 'status': 'cancelled'}) : json(order, 201),
      loggedIn: true,
    );
    final placed = await api.checkout();
    expect(placed.items.single.name, 'Mug');
    expect(placed.canCancel, isTrue);
    final cancelled = await api.cancelOrder(7);
    expect(cancelled.status, 'cancelled');
    expect(cancelled.canCancel, isFalse);
    expect(seen[0].url.path, '/api/users/42/orders');
    expect(seen[0].body, isEmpty);
    expect(seen[1].url.path, '/api/users/42/orders/7/cancel');
  });

  test('a per-user call without a login throws a 401 and sends nothing', () async {
    final (api, seen) = apiWith((_) => json({}));
    expect(api.listCart, throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 401)));
    expect(seen, isEmpty);
  });

  test('an error carries the API message and status', () async {
    final (api, _) = apiWith((_) => json({'message': 'That product is already in the cart.'}, 409), loggedIn: true);
    await expectLater(
      api.addToCart(1, 1),
      throwsA(isA<ApiException>().having((e) => e.statusCode, 'status', 409).having((e) => e.message, 'message', contains('already'))),
    );
  });

  test('a non-JSON answer gets the generic message, a dead connection the host', () async {
    final (api, _) = apiWith((_) => http.Response('<html>Bad gateway</html>', 502));
    await expectLater(api.getProduct(1), throwsA(isA<ApiException>().having((e) => e.message, 'message', 'Something went wrong. Please try again.')));

    final dead = StoreApi(apiKey: fakeKey, client: MockClient((_) async => throw Exception('offline')));
    await expectLater(dead.getProduct(1), throwsA(isA<ApiException>().having((e) => e.message, 'message', contains('store.simpleapi.dev'))));
  });

  test('login reads the token and the user id, and sends no bearer token', () async {
    final (api, seen) = apiWith(
      (_) => json({'token': 'abc', 'expires_at': 'x', 'user': {'id': 5, 'name': 'Ann'}}),
    );
    api.token = 'old';
    final result = await api.login(email: 'a@example.com', password: 'secret-pass');
    expect(result.id, 5);
    expect(api.userId, 5);
    expect(api.token, 'abc');
    expect(seen.single.headers.containsKey('Authorization'), isFalse);
  });
}
