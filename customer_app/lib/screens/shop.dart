import 'package:flutter/material.dart';
import '../api.dart';
import '../store.dart';
import '../ui.dart';
import 'shell.dart';

class ShopScreen extends StatefulWidget {
  const ShopScreen({super.key});
  @override
  State<ShopScreen> createState() => _ShopScreenState();
}

class _ShopScreenState extends State<ShopScreen> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void initState() {
    super.initState();
    shopCategory.addListener(_onCategory);
  }

  void _onCategory() => setState(() {
        _search.clear();
        _query = '';
      });

  @override
  void dispose() {
    shopCategory.removeListener(_onCategory);
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = AppStore.instance;
    return SafeArea(
      bottom: false,
      child: ListenableBuilder(
        listenable: Listenable.merge([store, shopCategory]),
        builder: (context, _) {
          final cat = store.catalog;
          if (cat == null) {
            return store.catalogError != null
                ? ErrorRetry(store.catalogError!, () => store.loadCatalog(force: true))
                : const Center(child: CircularProgressIndicator(color: C.green));
          }
          final selected = shopCategory.value;
          Category? selCat;
          for (final c in cat.categories) {
            if (c.id == selected) selCat = c;
          }
          final q = _query.trim().toLowerCase();
          final items = cat.products
              .where((p) => selected == null || p.categIds.contains(selected))
              .where((p) => q.isEmpty || p.name.toLowerCase().contains(q))
              .toList();
          return Stack(children: [
            CustomScrollView(slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                sliver: SliverList.list(children: [
                  Row(children: [
                    Expanded(child: Text(selCat?.name ?? 'All products', style: head(20))),
                    Text('${items.length} items', style: const TextStyle(color: C.muted, fontSize: 13.5)),
                  ]),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _search,
                    onChanged: (v) => setState(() => _query = v),
                    textInputAction: TextInputAction.search,
                    decoration: InputDecoration(
                      hintText: 'Search products…',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon: _query.isEmpty
                          ? null
                          : IconButton(
                              tooltip: 'Clear',
                              icon: const Icon(Icons.close_rounded),
                              onPressed: () => setState(() {
                                _search.clear();
                                _query = '';
                              }),
                            ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (cat.categories.isNotEmpty)
                    SizedBox(
                      height: 36,
                      child: ListView(scrollDirection: Axis.horizontal, children: [
                        _chip('All', selected == null, () => shopCategory.value = null),
                        for (final c in cat.categories) _chip(c.name, selected == c.id, () => shopCategory.value = c.id),
                      ]),
                    ),
                  const SizedBox(height: 12),
                ]),
              ),
              if (items.isEmpty)
                const SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(child: Text('No products found.', style: TextStyle(color: C.muted))),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 100),
                  sliver: SliverGrid(
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 2,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      mainAxisExtent: 238,
                    ),
                    delegate: SliverChildBuilderDelegate((_, i) => ProductCard(items[i]), childCount: items.length),
                  ),
                ),
            ]),
            if (store.cartCount > 0)
              Positioned(
                left: 20,
                right: 20,
                bottom: 16,
                child: Material(
                  color: C.green,
                  borderRadius: BorderRadius.circular(16),
                  elevation: 6,
                  shadowColor: C.greenDark.withValues(alpha: 0.4),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(16),
                    onTap: () => currentTab.value = 2,
                    child: SizedBox(
                      height: 58,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 18),
                        child: Row(children: [
                          const Icon(Icons.shopping_cart_outlined, color: Colors.white),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text('View cart · ${store.cartCount} items',
                                style: head(15, w: FontWeight.w600, color: Colors.white)),
                          ),
                          Text(money(store.cartTotal), style: head(15, w: FontWeight.w600, color: Colors.white)),
                        ]),
                      ),
                    ),
                  ),
                ),
              ),
          ]);
        },
      ),
    );
  }

  Widget _chip(String label, bool on, VoidCallback tap) => Padding(
        padding: const EdgeInsets.only(right: 8),
        child: InkWell(
          onTap: tap,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? C.green : Colors.white,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: on ? C.green : C.line),
            ),
            child: Text(label, style: TextStyle(fontSize: 13.5, color: on ? Colors.white : C.ink)),
          ),
        ),
      );
}
