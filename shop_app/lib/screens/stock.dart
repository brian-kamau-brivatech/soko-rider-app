import 'package:flutter/material.dart';
import '../api.dart';
import '../store.dart';
import '../ui.dart';

/// Stock on hand and the latest inventory moves (sales, receipts, adjustments).
class StockScreen extends StatefulWidget {
  const StockScreen({super.key});
  @override
  State<StockScreen> createState() => _StockScreenState();
}

class _StockScreenState extends State<StockScreen> {
  List<StockItem>? _items;
  List<StockMove> _moves = const [];
  String? _error;
  bool _showMoves = false;
  String _q = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final (items, moves) = await PosApi.stock(Store.i.pin);
      if (mounted) setState(() {
        _items = items;
        _moves = moves;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  String _n(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    final q = _q.trim().toLowerCase();
    final items = (_items ?? const <StockItem>[]).where((i) => q.isEmpty || i.name.toLowerCase().contains(q)).toList();
    final moves = _moves.where((m) => q.isEmpty || m.product.toLowerCase().contains(q) || m.ref.toLowerCase().contains(q)).toList();
    return Scaffold(
      appBar: AppBar(backgroundColor: Colors.white, surfaceTintColor: Colors.white, title: Text('Stock', style: h(18))),
      body: RefreshIndicator(
        color: C.green,
        onRefresh: _load,
        child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: [
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('On hand'), icon: Icon(Icons.inventory_2_outlined)),
              ButtonSegment(value: true, label: Text('Moves'), icon: Icon(Icons.swap_horiz_rounded)),
            ],
            selected: {_showMoves},
            onSelectionChanged: (v) => setState(() => _showMoves = v.first),
          ),
          const SizedBox(height: 10),
          TextField(
            onChanged: (v) => setState(() => _q = v),
            decoration: InputDecoration(
              hintText: _showMoves ? 'Search product or reference' : 'Search product',
              prefixIcon: const Icon(Icons.search_rounded),
              isDense: true,
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: C.line)),
              enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(14), borderSide: const BorderSide(color: C.line)),
            ),
          ),
          const SizedBox(height: 10),
          if (_items == null && _error == null)
            const Padding(padding: EdgeInsets.all(40), child: Center(child: CircularProgressIndicator(color: C.green)))
          else if (_items == null)
            EmptyNote(Icons.wifi_off_rounded, _error!)
          else if (!_showMoves) ...[
            if (items.isEmpty)
              const EmptyNote(Icons.inventory_2_outlined, 'No stock-tracked POS products.\nIn Odoo, set the product type to "Storable".')
            else
              for (final i in items)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: card(14),
                  child: Row(children: [
                    Expanded(child: Text(i.name, style: h(14, w: FontWeight.w700))),
                    Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                      Text('${_n(i.qty)} ${i.uom}', style: h(15, color: i.qty <= 0 ? C.red : C.ink)),
                      if (i.forecast != i.qty)
                        Text('forecast ${_n(i.forecast)}', style: const TextStyle(fontSize: 11.5, color: C.muted)),
                    ]),
                  ]),
                ),
          ] else ...[
            if (moves.isEmpty)
              const EmptyNote(Icons.swap_horiz_rounded, 'No stock moves yet.')
            else
              for (final m in moves)
                Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(12),
                  decoration: card(14),
                  child: Row(children: [
                    Icon(m.isIn ? Icons.south_west_rounded : m.isOut ? Icons.north_east_rounded : Icons.swap_horiz_rounded,
                        color: m.isIn ? C.green : m.isOut ? C.red : C.muted),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(m.product, style: h(14, w: FontWeight.w700)),
                        Text('${m.from} → ${m.to}', style: const TextStyle(fontSize: 12, color: C.muted)),
                        Text('${m.ref} · ${m.date}', style: const TextStyle(fontSize: 12, color: C.muted)),
                      ]),
                    ),
                    Text('${m.isOut ? '−' : m.isIn ? '+' : ''}${_n(m.qty)} ${m.uom}',
                        style: h(14, color: m.isIn ? C.green : m.isOut ? C.red : C.ink)),
                  ]),
                ),
          ],
        ]),
      ),
    );
  }
}
