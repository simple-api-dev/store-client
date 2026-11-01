/// The shared app state: who is logged in, and their cart.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'config.dart';
import 'store_api.dart';

/// The app's shared state: who is logged in and what is in their cart. Screens
/// listen to it with [ListenableBuilder]. The API key is the build-time key
/// ([configuredKey]).
class AppState extends ChangeNotifier {
  AppState({String apiKey = configuredKey, http.Client? client}) : api = StoreApi(apiKey: apiKey, client: client);

  /// The client for the build-time key.
  final StoreApi api;
  String? userName;

  /// The cart of the logged-in user, as the API last said.
  List<CartItem> cart = const [];
  int cartTotalCents = 0;

  /// Goes up when a checkout or a cancel changed stock, so the catalog loads again.
  int stockVersion = 0;

  bool get loggedIn => api.loggedIn;

  /// How many units are in the cart, for the badge.
  int get cartCount => cart.fold(0, (sum, item) => sum + item.quantity);

  CartItem? cartItemFor(int productId) {
    for (final item in cart) {
      if (item.productId == productId) return item;
    }
    return null;
  }

  void loggedInAs(String name) {
    userName = name;
    notifyListeners();
    unawaited(refreshCart());
  }

  /// POST /api/users/login as the shared demo user. Throws [ApiException] on failure.
  Future<void> loginDemo() async {
    final result = await api.login(email: demoEmail, password: demoPassword);
    if (result.token == null) throw ApiException(401, result.message);
    loggedInAs(result.name.isEmpty ? 'Demo' : result.name);
  }

  Future<void> logout() async {
    try {
      await api.logout();
    } on ApiException {
      // The token was already invalid: logging out locally is all that is left.
    }
    _forget();
  }

  /// The API said our token is no longer valid (401 while logged in): drop it.
  void sessionExpired() {
    if (!api.loggedIn) return;
    api.token = null;
    api.userId = null;
    _forget();
  }

  void _forget() {
    userName = null;
    cart = const [];
    cartTotalCents = 0;
    notifyListeners();
  }

  /// Runs a call made while logged in. A 401 means the session is over: the
  /// user is logged out here, and the error goes on to the screen.
  Future<T> authed<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on ApiException catch (e) {
      if (e.statusCode == 401) sessionExpired();
      rethrow;
    }
  }

  // GET /api/users/{user_id}/cart
  ///
  /// Quiet by default, so a failed refresh after another call leaves the cart as it was.
  /// The cart screen asks for [strict] and shows the error.
  Future<void> refreshCart({bool strict = false}) async {
    if (!loggedIn) return;
    try {
      final page = await api.listCart();
      if (!loggedIn) return;
      cart = page.items;
      cartTotalCents = page.totalCents;
      notifyListeners();
    } on ApiException catch (e) {
      if (e.statusCode == 401) sessionExpired();
      if (strict) rethrow;
    }
  }

  // POST /api/users/{user_id}/cart
  Future<void> addToCart(int productId, int quantity) async {
    await authed(() => api.addToCart(productId, quantity));
    await refreshCart();
  }

  // PUT /api/users/{user_id}/cart/{id}
  Future<void> setQuantity(int itemId, int quantity) async {
    await authed(() => api.updateCartItem(itemId, quantity));
    await refreshCart();
  }

  // DELETE /api/users/{user_id}/cart/{id}
  Future<void> removeFromCart(int itemId) async {
    await authed(() => api.removeCartItem(itemId));
    await refreshCart();
  }

  // POST /api/users/{user_id}/orders
  Future<Order> checkout() async {
    final order = await authed(api.checkout);
    stockVersion++;
    await refreshCart();
    return order;
  }

  // POST /api/users/{user_id}/orders/{id}/cancel
  Future<Order> cancelOrder(int id) async {
    final order = await authed(() => api.cancelOrder(id));
    stockVersion++;
    notifyListeners();
    return order;
  }
}
