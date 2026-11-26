import 'package:riverpod/riverpod.dart';

import '../data/delivery_api.dart';
import '../delivery_providers.dart';

class AvailabilityState {
  const AvailabilityState({
    this.online = false,
    this.updating = false,
    this.error,
  });

  /// What the backend last confirmed. Starts offline on every launch: the
  /// partner chooses to go online, the app never does it for them.
  final bool online;
  final bool updating;
  final DeliveryException? error;
}

class AvailabilityController extends Notifier<AvailabilityState> {
  @override
  AvailabilityState build() => const AvailabilityState();

  Future<void> setOnline(bool online) async {
    if (state.updating || (state.online == online && state.error == null)) {
      return;
    }
    final previous = state.online;
    state = AvailabilityState(online: previous, updating: true);
    try {
      await ref.read(deliveryRepositoryProvider).setAvailability(online);
      if (!ref.mounted) return;
      state = AvailabilityState(online: online);
    } on DeliveryException catch (e) {
      if (!ref.mounted) return;
      state = AvailabilityState(online: previous, error: e);
    }
  }
}
