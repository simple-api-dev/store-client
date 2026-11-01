/// The small data types shared by the API client and the screens.
library;

/// Thrown for any non-2xx answer. [message] is the API's own text,
/// e.g. "Invalid email or password."
class ApiException implements Exception {
  ApiException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => message;
}

int _int(Object? value, [int fallback = 0]) => value is num ? value.toInt() : fallback;

/// A product of the catalog. Money is always whole cents.
class Product {
  const Product({
    required this.id,
    required this.name,
    this.description = '',
    required this.priceCents,
    this.stock = 0,
    this.imageUrl,
  });

  final int id;
  final String name;
  final String description;
  final int priceCents;
  final int stock;

  /// An https address, or null: the app then shows a placeholder.
  final String? imageUrl;

  bool get inStock => stock > 0;

  factory Product.fromJson(Map<String, dynamic> json) {
    final image = json['image_url'];
    return Product(
      id: _int(json['id']),
      name: '${json['name'] ?? ''}',
      description: '${json['description'] ?? ''}',
      priceCents: _int(json['price_cents']),
      stock: _int(json['stock']),
      imageUrl: image is String && image.trim().isNotEmpty ? image : null,
    );
  }
}

/// One product in the user's cart. [name] and [priceCents] are the product's
/// name and price now, and null once the product is gone.
class CartItem {
  const CartItem({required this.id, required this.productId, this.name, this.priceCents, required this.quantity});

  final int id;
  final int productId;
  final String? name;
  final int? priceCents;
  final int quantity;

  /// Null when the product is gone and has no price.
  int? get lineCents => priceCents == null ? null : priceCents! * quantity;

  factory CartItem.fromJson(Map<String, dynamic> json) {
    final name = json['name'];
    final price = json['price_cents'];
    return CartItem(
      id: _int(json['id']),
      productId: _int(json['product_id']),
      name: name is String ? name : null,
      priceCents: price is num ? price.toInt() : null,
      quantity: _int(json['quantity'], 1),
    );
  }
}

/// A line of an order, with the name and price it had at checkout.
class OrderItem {
  const OrderItem({required this.productId, required this.name, required this.priceCents, required this.quantity});

  final int productId;
  final String name;
  final int priceCents;
  final int quantity;

  factory OrderItem.fromJson(Map<String, dynamic> json) => OrderItem(
    productId: _int(json['product_id']),
    name: '${json['name'] ?? ''}',
    priceCents: _int(json['price_cents']),
    quantity: _int(json['quantity'], 1),
  );
}

/// An order. [status] is `placed`, `shipped` or `cancelled`.
class Order {
  const Order({
    required this.id,
    required this.status,
    required this.totalCents,
    this.items = const [],
    this.createdAt,
  });

  final int id;
  final String status;
  final int totalCents;
  final List<OrderItem> items;
  final String? createdAt;

  bool get canCancel => status == 'placed';

  factory Order.fromJson(Map<String, dynamic> json) => Order(
    id: _int(json['id']),
    status: '${json['status'] ?? 'placed'}',
    totalCents: _int(json['total_cents']),
    items: [for (final i in (json['items'] as List? ?? const [])) OrderItem.fromJson(i as Map<String, dynamic>)],
    createdAt: json['created_at'] is String ? json['created_at'] as String : null,
  );
}

/// One page of a list. Every list answers `{data, total, page, per_page}`.
class ListPage<T> {
  const ListPage({required this.items, required this.total, required this.page, required this.perPage});

  final List<T> items;
  final int total;
  final int page;
  final int perPage;

  bool get hasMore => page * perPage < total;

  factory ListPage.fromJson(Map<String, dynamic> json, T Function(Map<String, dynamic>) parse) {
    return ListPage(
      items: [for (final row in (json['data'] as List? ?? const [])) parse(row as Map<String, dynamic>)],
      total: _int(json['total']),
      page: _int(json['page'], 1),
      perPage: _int(json['per_page'], 25),
    );
  }
}

/// The cart list: a page of items, plus the total of the whole cart.
class CartPage {
  const CartPage({required this.items, required this.totalCents});

  final List<CartItem> items;
  final int totalCents;
}

/// What login / register answer with. [token] is null only for a 2xx answer
/// that carried no token.
class AuthResult {
  const AuthResult({this.token, this.id, this.name = '', this.message = ''});

  final String? token;
  final int? id;
  final String name;
  final String message;
}
