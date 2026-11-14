import 'dart:async';
import 'package:flutter/foundation.dart';

/// Bumped after anything that changes figures (sale, refund, stock, payment): screens reload.
final ValueNotifier<int> dataVersion = ValueNotifier<int>(0);
void changed() {
  dataVersion.value++;
  _settle?.cancel();
  _settle = Timer(const Duration(milliseconds: 250), () => dataSettled.value++);
}

/// Bumped once things go quiet after a burst of changes (a sync applying hundreds of rows):
/// heavy screens (dashboard, reports, stock lists) reload once instead of once per change.
final ValueNotifier<int> dataSettled = ValueNotifier<int>(0);
Timer? _settle;
