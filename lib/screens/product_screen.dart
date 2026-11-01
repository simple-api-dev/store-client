/// One product.
library;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../store_api.dart';
import 'auth_screen.dart';
import 'cart_screen.dart';
import 'ui.dart';

/// The product detail: picture, price, stock and the full description. It
/// shows the product it was opened with at once, then reads it again, so the
/// stock is current. Logged in it adds to the cart, logged out it offers the
/// demo account.
class ProductScreen extends StatefulWidget {
  const ProductScreen({super.key, required this.state, required this.product});

  final AppState state;
  final Product product;

  @override
  State<ProductScreen> createState() => _ProductScreenState();
}

class _ProductScreenState extends State<ProductScreen> {
  late Product _product = widget.product;
  Object? _error;
  int _quantity = 1;
  bool _busy = false;

  AppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    _load();
  }

  // GET /api/products/{id}
  Future<void> _load() async {
    try {
      final fresh = await state.api.getProduct(widget.product.id);
      if (mounted) {
        setState(() {
          _product = fresh;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  // POST /api/users/{user_id}/cart
  Future<void> _add() async {
    setState(() => _busy = true);
    try {
      await state.addToCart(_product.id, _quantity);
      if (mounted) showSnack(context, 'Added ${_product.name} to your cart.');
    } catch (e) {
      if (mounted) showSnack(context, describeError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // POST /api/users/login as the shared demo user
  Future<void> _demo() async {
    try {
      await state.loginDemo();
    } catch (e) {
      if (mounted) showSnack(context, describeLoginError(e));
    }
  }

  void _openAuth() => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => AuthScreen(state: state)),
  );

  void _openCart() => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => CartScreen(state: state)),
  );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => Scaffold(
        appBar: AppBar(title: const Text('Product')),
        body: Column(
          children: [
            const LearningNotice(),
            Expanded(
              child: Centered(
                maxWidth: 640,
                child: _error != null ? ErrorView(error: _error!, onRetry: _load) : _details(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _details(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final p = _product;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Center(child: ProductImage(url: p.imageUrl, size: 200)),
        const SizedBox(height: 16),
        Text(p.name, style: text.headlineSmall),
        const SizedBox(height: 4),
        Text(formatCents(p.priceCents), style: text.titleLarge),
        Text(stockText(p.stock), style: text.bodyMedium?.copyWith(color: p.inStock ? null : Theme.of(context).colorScheme.error)),
        const SizedBox(height: 12),
        Text(p.description.isEmpty ? 'No description.' : p.description),
        const SizedBox(height: 24),
        ..._buy(p),
      ],
    );
  }

  List<Widget> _buy(Product p) {
    if (!state.loggedIn) {
      return [
        const Text('Log in to add this to a cart.'),
        const SizedBox(height: 12),
        FilledButton(onPressed: _demo, child: const Text('Try the demo account')),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: _openAuth, child: const Text('Log in')),
      ];
    }
    final inCart = state.cartItemFor(p.id);
    if (inCart != null) {
      return [
        Text('In your cart (${inCart.quantity}).'),
        const SizedBox(height: 8),
        OutlinedButton(onPressed: _openCart, child: const Text('View cart')),
      ];
    }
    if (!p.inStock) return [const Text('This product is sold out.')];
    final max = p.stock < 99 ? p.stock : 99;
    final quantity = _quantity > max ? max : _quantity;
    return [
      Row(
        children: [
          const Text('Quantity'),
          const SizedBox(width: 8),
          IconButton(
            tooltip: 'Fewer',
            onPressed: quantity > 1 ? () => setState(() => _quantity = quantity - 1) : null,
            icon: const Icon(Icons.remove_circle_outline),
          ),
          Text('$quantity', key: const Key('quantity')),
          IconButton(
            tooltip: 'More',
            onPressed: quantity < max ? () => setState(() => _quantity = quantity + 1) : null,
            icon: const Icon(Icons.add_circle_outline),
          ),
        ],
      ),
      const SizedBox(height: 8),
      FilledButton(
        onPressed: _busy ? null : _add,
        child: Text('Add to cart · ${formatCents(p.priceCents * quantity)}'),
      ),
    ];
  }
}
