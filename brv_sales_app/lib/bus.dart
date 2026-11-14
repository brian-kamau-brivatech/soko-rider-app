import 'package:flutter/foundation.dart';

/// Bumped after anything that changes figures (sale, refund, stock, payment): screens reload.
final ValueNotifier<int> dataVersion = ValueNotifier<int>(0);
void changed() => dataVersion.value++;
