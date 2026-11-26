/// Where a delivery is in its lifecycle. The backend owns these values; the
/// app only requests transitions and renders whatever the server returns.
enum DeliveryStatus {
  /// Offered to this partner, waiting for accept/reject. Expires.
  assigned('assigned'),

  /// Accepted; the partner is heading to the pickup.
  accepted('accepted'),

  /// The partner is within the pickup geofence.
  atPickup('arrived_at_pickup'),

  /// Parcel collected; heading to the drop-off.
  inTransit('in_transit'),

  /// The partner is within the drop-off geofence.
  atDropoff('arrived_at_dropoff'),

  /// Handed over and verified by the backend.
  completed('completed'),

  /// Declined by this partner.
  rejected('rejected'),

  /// Not answered before the offer timed out.
  expired('expired'),

  /// Cancelled by dispatch or the customer.
  cancelled('cancelled');

  const DeliveryStatus(this.wire);

  /// Value used in the API.
  final String wire;

  static DeliveryStatus fromWire(String value) {
    for (final status in values) {
      if (status.wire == value) return status;
    }
    throw FormatException('Unknown delivery status "$value"');
  }

  bool get isTerminal =>
      const {completed, rejected, expired, cancelled}.contains(this);

  /// Accepted and not finished: the partner is responsible for it.
  bool get isActive => !isTerminal && this != assigned;

  /// Moving towards a stop, so arrival detection should run.
  bool get isEnRoute => this == accepted || this == inTransit;

  /// The stop the partner is heading to or standing at.
  StopKind? get currentStop => switch (this) {
    accepted || atPickup => StopKind.pickup,
    inTransit || atDropoff => StopKind.dropoff,
    _ => null,
  };
}

enum StopKind {
  pickup('pickup'),
  dropoff('dropoff');

  const StopKind(this.wire);
  final String wire;
}

/// Things a delivery partner can ask the backend to do.
enum DeliveryAction {
  accept,
  reject,
  arriveAtPickup,
  confirmPickup,
  arriveAtDropoff,
  complete,
}

/// The delivery state machine.
///
/// The backend is the source of truth, but the app validates against the same
/// table so the UI never offers an action that cannot succeed and a stale
/// screen cannot fire an out-of-order request.
abstract final class DeliveryTransitions {
  /// Transitions the partner can trigger, by the action that triggers them.
  static const Map<DeliveryStatus, Map<DeliveryAction, DeliveryStatus>>
  _partner = {
    DeliveryStatus.assigned: {
      DeliveryAction.accept: DeliveryStatus.accepted,
      DeliveryAction.reject: DeliveryStatus.rejected,
    },
    DeliveryStatus.accepted: {
      DeliveryAction.arriveAtPickup: DeliveryStatus.atPickup,
    },
    DeliveryStatus.atPickup: {
      DeliveryAction.confirmPickup: DeliveryStatus.inTransit,
    },
    DeliveryStatus.inTransit: {
      DeliveryAction.arriveAtDropoff: DeliveryStatus.atDropoff,
    },
    DeliveryStatus.atDropoff: {
      DeliveryAction.complete: DeliveryStatus.completed,
    },
  };

  /// Transitions only the backend makes (timeouts, dispatch decisions).
  static const Map<DeliveryStatus, Set<DeliveryStatus>> _server = {
    DeliveryStatus.assigned: {DeliveryStatus.expired, DeliveryStatus.cancelled},
    DeliveryStatus.accepted: {DeliveryStatus.cancelled},
    DeliveryStatus.atPickup: {DeliveryStatus.cancelled},
    DeliveryStatus.inTransit: {DeliveryStatus.cancelled},
    DeliveryStatus.atDropoff: {DeliveryStatus.cancelled},
  };

  /// Actions the partner may take from [status].
  static Set<DeliveryAction> actionsFor(DeliveryStatus status) =>
      _partner[status]?.keys.toSet() ?? const {};

  static bool allows(DeliveryStatus status, DeliveryAction action) =>
      _partner[status]?.containsKey(action) ?? false;

  /// The status [action] leads to, or null if it is not allowed from [from].
  static DeliveryStatus? resultOf(DeliveryStatus from, DeliveryAction action) =>
      _partner[from]?[action];

  /// Whether any party may move a delivery from [from] to [to].
  static bool canTransition(DeliveryStatus from, DeliveryStatus to) =>
      (_partner[from]?.containsValue(to) ?? false) ||
      (_server[from]?.contains(to) ?? false);

  /// The arrival action for the stop a delivery is heading to.
  static DeliveryAction? arrivalActionFor(DeliveryStatus status) =>
      switch (status) {
        DeliveryStatus.accepted => DeliveryAction.arriveAtPickup,
        DeliveryStatus.inTransit => DeliveryAction.arriveAtDropoff,
        _ => null,
      };
}
