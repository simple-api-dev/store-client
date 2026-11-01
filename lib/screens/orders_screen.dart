/// The user's orders.
library;

import 'package:flutter/material.dart';

import '../app_state.dart';
import '../models.dart';
import 'ui.dart';

/// The logged-in user's orders with their items and status. A placed order can
/// be cancelled, which puts its stock back. There is no payment, so nothing is refunded.
class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key, required this.state});

  final AppState state;

  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  List<Order> _orders = [];
  int _page = 1;
  bool _hasMore = false;
  bool _loading = true;
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

  /// The session ended (a 401 anywhere): there are no orders to show any more.
  void _onStateChanged() {
    if (!state.loggedIn && mounted) Navigator.of(context).maybePop();
  }

  // GET /api/users/{user_id}/orders
  Future<void> _load({int page = 1}) async {
    setState(() {
      _loading = true;
      if (page == 1) _error = null;
    });
    try {
      final result = await state.authed(() => state.api.listOrders(page: page));
      if (!mounted) return;
      setState(() {
        final shown = {if (page > 1) ..._orders.map((o) => o.id)};
        _orders = [
          if (page > 1) ..._orders,
          for (final o in result.items)
            if (shown.add(o.id)) o,
        ];
        _page = result.page;
        _hasMore = result.hasMore;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = _orders.isEmpty ? e : null;
      });
      if (_orders.isNotEmpty) showSnack(context, describeError(e));
    }
  }

  // POST /api/users/{user_id}/orders/{id}/cancel
  Future<void> _cancel(Order order) async {
    final sure = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Cancel order ${order.id}?'),
        content: const Text('The stock goes back to the shop.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Keep it')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Cancel order')),
        ],
      ),
    );
    if (sure != true || !mounted) return;
    try {
      final updated = await state.cancelOrder(order.id);
      if (!mounted) return;
      setState(() => _orders = [for (final o in _orders) o.id == updated.id ? updated : o]);
      showSnack(context, 'Order ${order.id} cancelled.');
    } catch (e) {
      if (!mounted) return;
      showSnack(context, describeError(e));
      // a 409 means the order is no longer placed: read the list again to show its status
      if (e is ApiException && (e.statusCode == 409 || e.statusCode == 404)) await _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Your orders')),
      body: Column(
        children: [
          const LearningNotice(),
          Expanded(child: Centered(child: _body())),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading && _orders.isEmpty) return const Center(child: CircularProgressIndicator());
    final error = _error;
    if (error != null) return ErrorView(error: error, onRetry: _load);
    if (_orders.isEmpty) {
      return const Center(
        child: Padding(padding: EdgeInsets.all(24), child: Text('No orders yet. Check out your cart to place one.')),
      );
    }
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      children: [
        for (final o in _orders) _OrderCard(key: ValueKey(o.id), order: o, onCancel: () => _cancel(o)),
        if (_hasMore)
          Center(
            child: OutlinedButton(
              onPressed: _loading ? null : () => _load(page: _page + 1),
              child: const Text('Load more'),
            ),
          ),
      ],
    );
  }
}

class _OrderCard extends StatelessWidget {
  const _OrderCard({super.key, required this.order, required this.onCancel});

  final Order order;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    final scheme = Theme.of(context).colorScheme;
    final cancelled = order.status == 'cancelled';
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('Order ${order.id}', style: text.titleMedium)),
                Chip(
                  key: Key('status-${order.id}'),
                  label: Text(order.status),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: cancelled ? scheme.errorContainer : scheme.secondaryContainer,
                ),
              ],
            ),
            if (formatDate(order.createdAt).isNotEmpty) Text(formatDate(order.createdAt), style: text.bodySmall),
            const SizedBox(height: 8),
            for (final item in order.items)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(child: Text('${item.quantity} × ${item.name}')),
                    const SizedBox(width: 8),
                    Text(formatCents(item.priceCents * item.quantity)),
                  ],
                ),
              ),
            const Divider(height: 16),
            Row(
              children: [
                Text('Total', style: text.titleSmall),
                const Spacer(),
                Text(formatCents(order.totalCents), style: text.titleSmall),
              ],
            ),
            if (order.canCancel)
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(onPressed: onCancel, child: const Text('Cancel order')),
              ),
          ],
        ),
      ),
    );
  }
}
