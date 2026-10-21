import 'package:flutter/material.dart';
import '../api.dart';
import '../store.dart';
import '../ui.dart';
import 'order_detail.dart';

class OrdersScreen extends StatefulWidget {
  const OrdersScreen({super.key});
  @override
  State<OrdersScreen> createState() => _OrdersScreenState();
}

class _OrdersScreenState extends State<OrdersScreen> {
  int _f = 0; // 0 new, 1 preparing, 2 out, 3 done

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: ListenableBuilder(
        listenable: Store.i,
        builder: (context, _) {
          final s = Store.i;
          final all = s.board?.orders ?? const <ShopOrder>[];
          final c = s.board?.counts ?? const {};
          final list = all.where((o) {
            switch (_f) {
              case 0:
                return o.isNew;
              case 1:
                return o.isPreparing;
              case 2:
                return o.isOut;
              default:
                return o.isDone;
            }
          }).toList();
          return Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(children: [
                Expanded(child: Text('Orders', style: h(22))),
                if (s.updatedAt != null)
                  Text('updated ${_since(s.updatedAt!)}', style: const TextStyle(color: C.muted, fontSize: 12.5)),
              ]),
            ),
            SizedBox(
              height: 40,
              child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 16), children: [
                _chip(0, 'New ${c['new'] ?? 0}'),
                _chip(1, 'Preparing ${c['preparing'] ?? 0}'),
                _chip(2, 'Out ${c['out'] ?? 0}'),
                _chip(3, 'Done ${c['delivered'] ?? 0}'),
              ]),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Newest sale order first', style: TextStyle(color: C.muted, fontSize: 12.5)),
              ),
            ),
            Expanded(
              child: RefreshIndicator(
                color: C.green,
                onRefresh: s.refresh,
                child: ListView(padding: const EdgeInsets.fromLTRB(16, 6, 16, 20), children: [
                  if (list.isEmpty)
                    const EmptyNote(Icons.inbox_outlined, 'No orders here.')
                  else
                    for (final o in list)
                      OrderCard(o,
                          onTap: () => Navigator.of(context)
                              .push(MaterialPageRoute(builder: (_) => OrderDetailScreen(orderId: o.id, preview: o)))),
                ]),
              ),
            ),
          ]);
        },
      ),
    );
  }

  String _since(DateTime t) {
    final s = DateTime.now().difference(t).inSeconds;
    return s < 60 ? '$s s ago' : '${s ~/ 60} min ago';
  }

  Widget _chip(int i, String label) {
    final on = _f == i;
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: on,
        onSelected: (_) => setState(() => _f = i),
        selectedColor: C.navy,
        labelStyle: h(13, w: FontWeight.w700, color: on ? Colors.white : C.ink),
        showCheckmark: false,
        side: BorderSide(color: on ? C.navy : C.line),
        backgroundColor: Colors.white,
      ),
    );
  }
}
