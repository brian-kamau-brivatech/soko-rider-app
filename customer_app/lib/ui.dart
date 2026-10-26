import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'api.dart';
import 'store.dart';

/// Colours taken from the Soko website.
class C {
  static const green = Color(0xFF336B4F);
  static const greenDark = Color(0xFF244E39);
  static const accent = Color(0xFF6CB33F);
  static const greenLight = Color(0xFFEAF5EC);
  static const ink = Color(0xFF161C2D);
  static const muted = Color(0xFF5E6662);
  static const bg = Color(0xFFF8FAF8);
  static const line = Color(0xFFE7ECE8);
}

String money(double v) {
  final whole = v.round();
  final s = whole.abs().toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (m) => ',');
  return 'KES ${whole < 0 ? '-' : ''}$s';
}

String qtyText(double q) => q == q.roundToDouble()
    ? q.toStringAsFixed(0)
    : q.toStringAsFixed(3).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '');

TextStyle head(double size, {FontWeight w = FontWeight.w700, Color color = C.ink}) =>
    GoogleFonts.poppins(fontSize: size, fontWeight: w, color: color);

BoxDecoration cardBox([double r = 18]) => BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(r),
      border: Border.all(color: C.line),
    );

/// Product photo from Odoo, with a quiet placeholder while loading or offline.
class NetImage extends StatelessWidget {
  final String url;
  final BoxFit fit;
  const NetImage(this.url, {super.key, this.fit = BoxFit.contain});
  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) return const _ImgPlaceholder();
    return Image.network(
      url,
      fit: fit,
      errorBuilder: (_, __, ___) => const _ImgPlaceholder(),
      loadingBuilder: (c, child, p) => p == null ? child : const _ImgPlaceholder(),
    );
  }
}

class _ImgPlaceholder extends StatelessWidget {
  const _ImgPlaceholder();
  @override
  Widget build(BuildContext context) => Container(
        color: C.greenLight,
        alignment: Alignment.center,
        child: const Icon(Icons.image_outlined, color: C.green, size: 26),
      );
}

class SquareButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final int badge;
  final String tooltip;
  const SquareButton({super.key, required this.icon, this.onTap, this.badge = 0, this.tooltip = ''});
  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Stack(clipBehavior: Clip.none, children: [
          Container(
            width: 44,
            height: 44,
            decoration: cardBox(14),
            child: Icon(icon, color: C.ink, size: 22),
          ),
          if (badge > 0)
            Positioned(
              top: -5,
              right: -5,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: C.accent,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: C.bg, width: 2),
                ),
                child: Text('$badge', style: head(11, color: Colors.white)),
              ),
            ),
        ]),
      ),
    );
  }
}

class BackSquare extends StatelessWidget {
  const BackSquare({super.key});
  @override
  Widget build(BuildContext context) => SquareButton(
        icon: Icons.chevron_left_rounded,
        tooltip: 'Back',
        onTap: () => Navigator.of(context).maybePop(),
      );
}

class PrimaryButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool busy;
  const PrimaryButton(this.label, {super.key, this.icon, this.onTap, this.busy = false});
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 54,
      width: double.infinity,
      child: ElevatedButton(
        onPressed: busy ? null : onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: C.green,
          foregroundColor: Colors.white,
          disabledBackgroundColor: C.green.withValues(alpha: 0.5),
          disabledForegroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
        child: busy
            ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.white))
            : Row(mainAxisSize: MainAxisSize.min, children: [
                if (icon != null) ...[Icon(icon, size: 20), const SizedBox(width: 8)],
                Text(label, style: head(15.5, w: FontWeight.w600, color: Colors.white)),
              ]),
      ),
    );
  }
}

/// − qty + control, or an "Add" button when the item is not in the cart.
class QtyControl extends StatelessWidget {
  final Product product;
  final double width;
  const QtyControl(this.product, {super.key, this.width = double.infinity});
  @override
  Widget build(BuildContext context) {
    final store = AppStore.instance;
    final q = store.qty(product.id);
    final step = product.decimal ? 0.5 : 1.0;
    if (q <= 0) {
      return SizedBox(
        width: width,
        height: 36,
        child: ElevatedButton.icon(
          onPressed: () => product.decimal ? _typeQty(context, store, product) : store.add(product.id),
          icon: const Icon(Icons.add_rounded, size: 18),
          label: Text('Add', style: head(13.5, w: FontWeight.w600, color: Colors.white)),
          style: ElevatedButton.styleFrom(
            backgroundColor: C.green,
            foregroundColor: Colors.white,
            elevation: 0,
            padding: EdgeInsets.zero,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        ),
      );
    }
    Widget btn(IconData i, VoidCallback f, bool filled, String tip) => Semantics(
          button: true,
          label: tip,
          child: InkWell(
            onTap: f,
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(color: filled ? C.green : Colors.white, borderRadius: BorderRadius.circular(8)),
              child: Icon(i, size: 17, color: filled ? Colors.white : C.green),
            ),
          ),
        );
    return Container(
      width: width,
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 3),
      decoration: BoxDecoration(color: C.greenLight, borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        btn(Icons.remove_rounded, () => store.remove(product.id, step), false, 'Less ${product.name}'),
        Expanded(
          child: InkWell(
            onTap: product.decimal ? () => _typeQty(context, store, product) : null,
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  product.decimal && product.uom.isNotEmpty ? '${qtyText(q)} ${product.uom}' : qtyText(q),
                  style: head(15, w: FontWeight.w600),
                ),
              ),
            ),
          ),
        ),
        btn(Icons.add_rounded, () => store.add(product.id, step), true, 'More ${product.name}'),
      ]),
    );
  }
}

/// Items sold by weight: type the exact amount, e.g. 1.5 kg.
Future<void> _typeQty(BuildContext context, AppStore store, Product product) async {
  final current = store.qty(product.id);
  final c = TextEditingController(text: current > 0 ? qtyText(current) : '');
  final v = await showDialog<double>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(product.name),
      content: TextField(
        controller: c,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: 'How many ${product.uom.isEmpty ? '' : product.uom}?',
          hintText: 'e.g. 1.5',
          suffixText: product.uom,
        ),
        onSubmitted: (t) => Navigator.pop(ctx, double.tryParse(t.trim().replaceAll(',', '.'))),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
        TextButton(
          onPressed: () => Navigator.pop(ctx, double.tryParse(c.text.trim().replaceAll(',', '.'))),
          child: const Text('OK'),
        ),
      ],
    ),
  );
  if (v == null || v < 0) return;
  store.setQty(product.id, (v * 1000).roundToDouble() / 1000);
}

class ProductCard extends StatelessWidget {
  final Product product;
  final double? width;
  const ProductCard(this.product, {super.key, this.width});
  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      padding: const EdgeInsets.all(10),
      decoration: cardBox(),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(
          height: 104,
          width: double.infinity,
          child: ClipRRect(borderRadius: BorderRadius.circular(12), child: NetImage(product.image)),
        ),
        const SizedBox(height: 8),
        Text(product.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: head(14, w: FontWeight.w500)),
        const SizedBox(height: 2),
        Text.rich(TextSpan(children: [
          TextSpan(text: money(product.price), style: head(15, w: FontWeight.w600, color: C.green)),
          if (product.uom.isNotEmpty && product.uom.toLowerCase() != 'units')
            TextSpan(text: ' / ${product.uom}', style: const TextStyle(fontSize: 12, color: C.muted)),
        ])),
        const SizedBox(height: 8),
        QtyControl(product),
      ]),
    );
  }
}

class SectionTitle extends StatelessWidget {
  final String title;
  final String? action;
  final VoidCallback? onAction;
  const SectionTitle(this.title, {super.key, this.action, this.onAction});
  @override
  Widget build(BuildContext context) => Row(children: [
        Expanded(child: Text(title, style: head(17))),
        if (action != null)
          TextButton(
            onPressed: onAction,
            style: TextButton.styleFrom(foregroundColor: C.green),
            child: Text(action!, style: const TextStyle(fontSize: 14.5)),
          ),
      ]);
}

class ErrorRetry extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const ErrorRetry(this.message, this.onRetry, {super.key});
  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.wifi_off_rounded, size: 44, color: C.muted),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center, style: const TextStyle(color: C.muted, fontSize: 15)),
            const SizedBox(height: 16),
            OutlinedButton(
              onPressed: onRetry,
              style: OutlinedButton.styleFrom(foregroundColor: C.green, side: const BorderSide(color: C.green)),
              child: const Text('Try again'),
            ),
          ]),
        ),
      );
}

void toast(BuildContext context, String msg) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating));
}
