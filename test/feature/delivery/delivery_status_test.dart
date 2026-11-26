import 'package:flutter_test/flutter_test.dart';
import 'package:geoloc/feature/delivery/domain/delivery_status.dart';

void main() {
  group('partner actions', () {
    test('follow pickup, then drop-off, then verification', () {
      var status = DeliveryStatus.assigned;
      for (final action in [
        DeliveryAction.accept,
        DeliveryAction.arriveAtPickup,
        DeliveryAction.confirmPickup,
        DeliveryAction.arriveAtDropoff,
        DeliveryAction.complete,
      ]) {
        final next = DeliveryTransitions.resultOf(status, action);
        expect(next, isNotNull, reason: '$action from $status');
        status = next!;
      }
      expect(status, DeliveryStatus.completed);
    });

    test('only the next step is offered for each status', () {
      expect(DeliveryTransitions.actionsFor(DeliveryStatus.assigned), {
        DeliveryAction.accept,
        DeliveryAction.reject,
      });
      expect(DeliveryTransitions.actionsFor(DeliveryStatus.accepted), {
        DeliveryAction.arriveAtPickup,
      });
      expect(DeliveryTransitions.actionsFor(DeliveryStatus.atPickup), {
        DeliveryAction.confirmPickup,
      });
      expect(DeliveryTransitions.actionsFor(DeliveryStatus.atDropoff), {
        DeliveryAction.complete,
      });
    });

    test('completing is impossible before reaching the drop-off', () {
      for (final status in [
        DeliveryStatus.assigned,
        DeliveryStatus.accepted,
        DeliveryStatus.atPickup,
        DeliveryStatus.inTransit,
      ]) {
        expect(
          DeliveryTransitions.allows(status, DeliveryAction.complete),
          isFalse,
          reason: '$status',
        );
      }
    });

    test('skipping pickup is impossible', () {
      expect(
        DeliveryTransitions.allows(
          DeliveryStatus.accepted,
          DeliveryAction.arriveAtDropoff,
        ),
        isFalse,
      );
      expect(
        DeliveryTransitions.canTransition(
          DeliveryStatus.accepted,
          DeliveryStatus.inTransit,
        ),
        isFalse,
      );
    });

    test('accepting twice is not a valid transition', () {
      expect(
        DeliveryTransitions.allows(
          DeliveryStatus.accepted,
          DeliveryAction.accept,
        ),
        isFalse,
      );
    });

    test('terminal states allow nothing', () {
      for (final status in DeliveryStatus.values.where((s) => s.isTerminal)) {
        expect(DeliveryTransitions.actionsFor(status), isEmpty);
        for (final to in DeliveryStatus.values) {
          expect(DeliveryTransitions.canTransition(status, to), isFalse);
        }
      }
    });
  });

  test('only the backend can expire or cancel', () {
    expect(
      DeliveryTransitions.canTransition(
        DeliveryStatus.assigned,
        DeliveryStatus.expired,
      ),
      isTrue,
    );
    expect(
      DeliveryTransitions.canTransition(
        DeliveryStatus.inTransit,
        DeliveryStatus.cancelled,
      ),
      isTrue,
    );
    for (final status in DeliveryStatus.values) {
      final reachable = DeliveryTransitions.actionsFor(status)
          .map((a) => DeliveryTransitions.resultOf(status, a));
      expect(reachable, isNot(contains(DeliveryStatus.cancelled)));
      expect(reachable, isNot(contains(DeliveryStatus.expired)));
    }
  });

  test('wire values round-trip and unknown values are rejected', () {
    for (final status in DeliveryStatus.values) {
      expect(DeliveryStatus.fromWire(status.wire), status);
    }
    expect(() => DeliveryStatus.fromWire('teleported'), throwsFormatException);
  });

  test('current stop and en-route flags', () {
    expect(DeliveryStatus.accepted.currentStop, StopKind.pickup);
    expect(DeliveryStatus.atPickup.currentStop, StopKind.pickup);
    expect(DeliveryStatus.inTransit.currentStop, StopKind.dropoff);
    expect(DeliveryStatus.completed.currentStop, isNull);
    expect(DeliveryStatus.atPickup.isEnRoute, isFalse);
    expect(DeliveryStatus.inTransit.isEnRoute, isTrue);
    expect(DeliveryStatus.assigned.isActive, isFalse);
    expect(DeliveryStatus.atDropoff.isActive, isTrue);
  });
}
