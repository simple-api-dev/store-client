/// The cart and checkout.
library;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import 'orders_screen.dart';
import 'ui.dart';

/// The logged-in user's cart: change a quantity, remove an item, see the
/// total and check out. Checkout only places a demo order: no money moves.
class CartScreen extends StatefulWidget {
  const CartScreen({super.key, required this.state});

  final AppState state;

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  bool _loading = true;
  bool _busy = false;
  Object? _error;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    state.addListener(_onStateChanged);
    _load();
  }

  @override
  void dispose() {
    state.removeListener(_onStateChanged);
    super.dispose();
  }

  /// The session ended (a 401 anywhere): there is no cart to show any more.
  void _onStateChanged() {
    if (!state.loggedIn && mounted) Navigator.of(context).maybePop();
  }

  // GET /api/users/{user_id}/cart
  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await state.refreshCart(strict: true);
      if (mounted) setState(() => _loading = false);
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = e;
        });
      }
    }
  }

  /// Runs one change, shows the API's message if it fails, and reads the cart again after a 404.
  Future<void> _run(Future<void> Function() action) async {
    setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      if (mounted) showSnack(context, describeError(e));
      if (e is ApiException && e.statusCode == 404) await state.refreshCart();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // PUT /api/users/{user_id}/cart/{id}
  Future<void> _setQuantity(CartItem item, int quantity) => _run(() => state.setQuantity(item.id, quantity));

  // DELETE /api/users/{user_id}/cart/{id}
  Future<void> _remove(CartItem item) => _run(() => state.removeFromCart(item.id));

  // POST /api/users/{user_id}/orders
  Future<void> _checkout() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    try {
      final order = await state.checkout();
      messenger
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('Order ${order.id} placed. No money was taken.')));
      await navigator.pushReplacement(MaterialPageRoute<void>(builder: (_) => OrdersScreen(state: state)));
    } catch (e) {
      if (!mounted) return;
      showSnack(context, describeError(e));
      // a refused checkout changed nothing, but the cart on screen may be out of date
      await state.refreshCart();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Your cart')),
        body: Column(
          children: [
            const LearningNotice(),
            Expanded(child: Centered(child: _body())),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading && state.cart.isEmpty) return const Center(child: CircularProgressIndicator());
    final error = _error;
    if (error != null && state.cart.isEmpty) return ErrorView(error: error, onRetry: _load);
    if (state.cart.isEmpty) {
      return const Center(
        child: Padding(padding: EdgeInsets.all(24), child: Text('Your cart is empty. Add a product from the shop.')),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        for (final item in state.cart) _CartLine(key: ValueKey(item.id), item: item, busy: _busy, screen: this),
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            children: [
              Text('Total', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              Text(
                formatCents(state.cartTotalCents),
                key: const Key('cart-total'),
                style: Theme.of(context).textTheme.titleLarge,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        FilledButton(onPressed: _busy ? null : _checkout, child: const Text('Place order')),
        const SizedBox(height: 8),
        const Text(
          'Demo only: placing an order takes no payment. You can cancel it from your orders.',
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

class _CartLine extends StatelessWidget {
  const _CartLine({super.key, required this.item, required this.busy, required this.screen});

  final CartItem item;
  final bool busy;
  final _CartScreenState screen;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final price = item.priceCents;
    final line = item.lineCents;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(item.name ?? 'This product is no longer available', style: text.titleMedium),
            if (price != null) Text('${formatCents(price)} each', style: text.bodySmall),
            Row(
              children: [
                IconButton(
                  tooltip: 'Fewer',
                  onPressed: busy || item.quantity <= 1 ? null : () => screen._setQuantity(item, item.quantity - 1),
                  icon: const Icon(Icons.remove_circle_outline),
                ),
                Text('${item.quantity}', key: Key('qty-${item.id}')),
                IconButton(
                  tooltip: 'More',
                  onPressed: busy || item.quantity >= 99 ? null : () => screen._setQuantity(item, item.quantity + 1),
                  icon: const Icon(Icons.add_circle_outline),
                ),
                const Spacer(),
                if (line != null) Text(formatCents(line), style: text.titleMedium),
                IconButton(
                  tooltip: 'Remove',
                  onPressed: busy ? null : () => screen._remove(item),
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
