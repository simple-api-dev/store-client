/// The shop screen: the catalog.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../open_url.dart';
import '../store_api.dart';
import 'auth_screen.dart';
import 'cart_screen.dart';
import 'orders_screen.dart';
import 'product_screen.dart';
import 'ui.dart';

/// The landing screen. The catalog needs only the API key, so a visitor sees it
/// at once, and can search it, keep what is in stock and sort it. Logged out it
/// offers the demo account, and logged in it adds products to the cart.
class ShopScreen extends StatefulWidget {
  const ShopScreen({super.key, required this.state, required this.openUrl});

  final AppState state;
  final UrlOpener openUrl;

  @override
  State<ShopScreen> createState() => _ShopScreenState();
}

/// The sort choices: label and the API's `sort` value (null is newest first).
const _sorts = <(String, String?)>[
  ('Newest', null),
  ('Price: low to high', 'price'),
  ('Price: high to low', '-price'),
  ('Name', 'name'),
];

class _ShopScreenState extends State<ShopScreen> {
  /// How long typing has to pause before a search goes out: the API allows 60 requests a minute.
  static const _searchPause = Duration(milliseconds: 400);

  final _search = TextEditingController();
  Timer? _searchTimer;
  bool _inStock = false;
  String? _sort;

  List<Product> _products = [];
  int _page = 1;
  bool _hasMore = false;
  bool _loading = true;
  Object? _error;
  int _seenStockVersion = 0;

  /// Numbers the loads. Only the answer to the latest one counts.
  int _latestLoad = 0;

  AppState get state => widget.state;

  bool get _filtered => _search.text.trim().isNotEmpty || _inStock;

  @override
  void initState() {
    super.initState();
    state.addListener(_onStateChanged);
    _seenStockVersion = state.stockVersion;
    _reload();
  }

  @override
  void dispose() {
    state.removeListener(_onStateChanged);
    _searchTimer?.cancel();
    _search.dispose();
    super.dispose();
  }

  /// A checkout or a cancel changed the stock: load the catalog again, quietly.
  void _onStateChanged() {
    if (state.stockVersion == _seenStockVersion) return;
    _seenStockVersion = state.stockVersion;
    _load();
  }

  /// Forgets the list on screen and loads the first page.
  void _reload() {
    _products = [];
    _hasMore = false;
    _error = null;
    _loading = true;
    _load();
  }

  // GET /api/products
  Future<void> _load({int page = 1}) async {
    final load = ++_latestLoad;
    final text = _search.text.trim();
    try {
      final result = await state.api.listProducts(
        q: text.isEmpty ? null : text,
        inStock: _inStock,
        sort: _sort,
        page: page,
      );
      if (load != _latestLoad || !mounted) return;
      setState(() {
        // A product added meanwhile shifts the pages, so the next page can repeat a row.
        final shown = {if (page > 1) ..._products.map((p) => p.id)};
        _products = [
          if (page > 1) ..._products,
          for (final p in result.items)
            if (shown.add(p.id)) p,
        ];
        _page = result.page;
        _hasMore = result.hasMore;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (load != _latestLoad || !mounted) return;
      setState(() {
        _loading = false;
        _error = _products.isEmpty ? e : null;
      });
      if (_products.isNotEmpty) showSnack(context, describeError(e));
    }
  }

  void _loadMore() {
    setState(() => _loading = true);
    _load(page: _page + 1);
  }

  void _searchChanged(String _) {
    _searchTimer?.cancel();
    _searchTimer = Timer(_searchPause, _applyFilters);
    setState(() {}); // shows or hides the clear button
  }

  void _applyFilters() {
    _searchTimer?.cancel();
    setState(_reload);
  }

  void _clearSearch() {
    _search.clear();
    _applyFilters();
  }

  // POST /api/users/{user_id}/cart  (one unit)
  Future<void> _add(Product p) async {
    try {
      await state.addToCart(p.id, 1);
      if (mounted) showSnack(context, 'Added ${p.name} to your cart.');
    } catch (e) {
      if (mounted) showSnack(context, describeError(e));
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

  void _openAuth({bool register = false}) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => AuthScreen(state: state, startAsRegister: register),
    ),
  );

  void _openProduct(Product p) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ProductScreen(state: state, product: p),
    ),
  );

  void _openCart() => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => CartScreen(state: state)),
  );

  void _openOrders() => Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => OrdersScreen(state: state)),
  );

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          leading: BackToSimpleApi(openUrl: widget.openUrl),
          title: const Text('SimpleAPI Store'),
          actions: [
            if (state.loggedIn) ...[
              IconButton(
                tooltip: 'Cart',
                onPressed: _openCart,
                icon: Badge(
                  isLabelVisible: state.cartCount > 0,
                  label: Text('${state.cartCount}'),
                  child: const Icon(Icons.shopping_cart_outlined),
                ),
              ),
              IconButton(tooltip: 'My orders', onPressed: _openOrders, icon: const Icon(Icons.receipt_long_outlined)),
              TextButton(
                onPressed: state.logout,
                style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
                child: const Text('Log out'),
              ),
            ] else
              TextButton(
                onPressed: _openAuth,
                style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
                child: const Text('Log in'),
              ),
          ],
        ),
        // The notice stays on screen while the catalog scrolls.
        body: Column(
          children: [
            const LearningNotice(),
            Expanded(child: Centered(child: _body())),
          ],
        ),
      ),
    );
  }

  /// One scrolling list, so nothing is squeezed on a phone: the header goes up with the products.
  Widget _body() {
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        if (!state.loggedIn)
          _LoggedOutHeader(onDemo: _demo, onLogin: _openAuth, onRegister: () => _openAuth(register: true))
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Text('Hi, ${state.userName ?? 'you'}. Add products to your cart, then check out.'),
          ),
        _filters(),
        ..._list(),
      ],
    );
  }

  Widget _filters() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _search,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              labelText: 'Search products',
              prefixIcon: const Icon(Icons.search),
              border: const OutlineInputBorder(),
              suffixIcon: _search.text.isEmpty
                  ? null
                  : IconButton(tooltip: 'Clear search', icon: const Icon(Icons.clear), onPressed: _clearSearch),
            ),
            onChanged: _searchChanged,
            onSubmitted: (_) => _applyFilters(),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              FilterChip(
                label: const Text('In stock only'),
                selected: _inStock,
                onSelected: (on) {
                  _inStock = on;
                  _applyFilters();
                },
              ),
              DropdownButton<String?>(
                key: const Key('sort'),
                value: _sort,
                underline: const SizedBox.shrink(),
                items: [for (final (label, value) in _sorts) DropdownMenuItem(value: value, child: Text(label))],
                onChanged: (value) {
                  _sort = value;
                  _applyFilters();
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _list() {
    if (_products.isEmpty && _loading) {
      return const [
        Padding(padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
      ];
    }
    final error = _error;
    if (error != null) return [ErrorView(error: error, onRetry: () => setState(_reload))];
    if (_products.isEmpty) {
      return [
        Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_filtered ? 'No products match.' : 'No products yet.', textAlign: TextAlign.center),
        ),
      ];
    }
    return [
      for (final p in _products)
        _ProductCard(
          key: ValueKey(p.id),
          product: p,
          onOpen: () => _openProduct(p),
          // null when logged out: the catalog is read-only then
          onAdd: state.loggedIn && p.inStock && state.cartItemFor(p.id) == null ? () => _add(p) : null,
          inCart: state.loggedIn && state.cartItemFor(p.id) != null,
        ),
      if (_hasMore)
        Center(
          child: OutlinedButton(onPressed: _loading ? null : _loadMore, child: const Text('Load more')),
        ),
    ];
  }
}

class _ProductCard extends StatelessWidget {
  const _ProductCard({super.key, required this.product, required this.onOpen, this.onAdd, this.inCart = false});

  final Product product;
  final VoidCallback onOpen;
  final VoidCallback? onAdd;
  final bool inCart;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    return Card(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ProductImage(url: product.imageUrl),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(product.name, style: text.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      '${formatCents(product.priceCents)}  ·  ${stockText(product.stock)}',
                      style: text.bodyMedium?.copyWith(color: product.inStock ? null : scheme.error),
                    ),
                    if (product.description.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(product.description, maxLines: 2, overflow: TextOverflow.ellipsis, style: text.bodySmall),
                    ],
                    if (onAdd != null || inCart) ...[
                      const SizedBox(height: 8),
                      if (inCart)
                        Text('In your cart', style: text.labelLarge?.copyWith(color: scheme.primary))
                      else
                        FilledButton.tonal(onPressed: onAdd, child: const Text('Add to cart')),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LoggedOutHeader extends StatelessWidget {
  const _LoggedOutHeader({required this.onDemo, required this.onLogin, required this.onRegister});

  final VoidCallback onDemo;
  final VoidCallback onLogin;
  final VoidCallback onRegister;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      child: Column(
        children: [
          const Text('A small demo shop', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          const Text(
            'This sample talks to the free SimpleAPI Store API. The catalog below needs only the API key. To use a '
            'cart and place orders, try the shared demo account in one click, or create an account with any email '
            'address. It is not verified.',
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: onDemo, child: const Text('Try the demo account')),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            alignment: WrapAlignment.center,
            children: [
              OutlinedButton(onPressed: onRegister, child: const Text('Create an account')),
              OutlinedButton(onPressed: onLogin, child: const Text('Log in')),
            ],
          ),
          const SizedBox(height: 16),
          const Text(demoNoticeText, key: Key('demo-notice'), textAlign: TextAlign.center),
        ],
      ),
    );
  }
}
