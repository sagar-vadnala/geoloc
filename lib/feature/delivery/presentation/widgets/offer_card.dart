import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../../../core/theme.dart';
import '../../application/offers_controller.dart';
import '../../domain/geo.dart';
import '../delivery_format.dart';
import 'stop_line.dart';

/// One incoming request: what, where, how far, and a countdown.
class OfferCard extends StatefulWidget {
  const OfferCard({
    super.key,
    required this.view,
    required this.now,
    required this.partnerPosition,
    required this.accepting,
    required this.otherBusy,
    required this.onAccept,
    required this.onReject,
  });

  final OfferView view;
  final DateTime Function() now;
  final GeoPoint? partnerPosition;

  /// This offer is being accepted.
  final bool accepting;

  /// Another offer is being accepted, so this one can't be touched.
  final bool otherBusy;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  @override
  State<OfferCard> createState() => _OfferCardState();
}

class _OfferCardState extends State<OfferCard> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {});
      if (widget.view.isExpired(widget.now())) _ticker?.cancel();
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme;
    final status = StatusColors.of(context);
    final offer = widget.view.offer;
    final now = widget.now();
    final remaining = widget.view.remaining(now);
    final expired = widget.view.isExpired(now);
    final windowMs = widget.view.window.inMilliseconds;
    final fraction = windowMs <= 0
        ? 0.0
        : (remaining.inMilliseconds / windowMs).clamp(0.0, 1.0);
    final urgent = remaining < const Duration(seconds: 10);

    final pickupDistance = switch ((
      widget.partnerPosition,
      offer.pickup.location,
    )) {
      (final GeoPoint me, final GeoPoint stop) => me.distanceTo(stop),
      _ => offer.distanceToPickupMeters,
    };

    final facts = [
      if (offer.tripDistanceMeters != null)
        '${formatDistance(offer.tripDistanceMeters!)} trip',
      if (offer.estimatedMinutes != null) 'about ${offer.estimatedMinutes} min',
    ].join(', ');

    return Semantics(
      container: true,
      label: expired ? 'Expired request' : 'Delivery request',
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: status.line),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // The remaining time drains along the top edge.
              Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: fraction,
                  child: Container(
                    height: 4,
                    color: urgent ? status.failed : theme.colorScheme.primary,
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        Expanded(
                          child: Text(
                            expired
                                ? 'No longer available'
                                : '${remaining.inSeconds} s to respond',
                            style: text.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: expired
                                  ? status.muted
                                  : urgent
                                  ? status.failed
                                  : null,
                            ),
                          ),
                        ),
                        if (offer.payout != null)
                          Text(
                            formatMoney(offer.payout!),
                            style: text.headlineMedium?.copyWith(fontSize: 24),
                          ),
                      ],
                    ),
                    Text(offer.reference, style: text.bodySmall),
                    const SizedBox(height: 14),
                    StopLine(
                      label: pickupDistance == null
                          ? 'Pickup'
                          : 'Pickup, ${formatDistance(pickupDistance)} away',
                      title: offer.pickup.name,
                      subtitle: offer.pickup.address ?? offer.pickup.area,
                      filled: true,
                      showConnector: true,
                    ),
                    StopLine(
                      label: 'Drop-off',
                      title: offer.dropoffArea,
                      subtitle: 'Exact address shown after you accept',
                      filled: false,
                    ),
                    if (facts.isNotEmpty || offer.parcel != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        [
                          if (facts.isNotEmpty) facts,
                          if (offer.parcel != null) parcelLine(offer.parcel!),
                        ].join('. '),
                        style: text.bodyMedium,
                      ),
                    ],
                    if (offer.pickup.instructions != null) ...[
                      const SizedBox(height: 6),
                      Text(offer.pickup.instructions!, style: text.bodySmall),
                    ],
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          flex: 2,
                          child: OutlinedButton(
                            onPressed:
                                expired || widget.accepting || widget.otherBusy
                                ? null
                                : widget.onReject,
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size.fromHeight(56),
                            ),
                            child: const Text('Reject'),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          flex: 3,
                          child: FilledButton(
                            onPressed:
                                expired || widget.accepting || widget.otherBusy
                                ? null
                                : widget.onAccept,
                            style: FilledButton.styleFrom(
                              minimumSize: const Size.fromHeight(56),
                            ),
                            child: widget.accepting
                                ? const SizedBox.square(
                                    dimension: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Text('Accept'),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
