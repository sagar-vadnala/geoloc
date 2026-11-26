import 'delivery_status.dart';
import 'geo.dart';

/// A pickup or drop-off point.
///
/// Before acceptance the backend only sends the drop-off [area]; the exact
/// [address] and [location] are revealed once the partner has accepted.
class DeliveryStop {
  const DeliveryStop({
    required this.kind,
    required this.name,
    this.address,
    this.area,
    this.location,
    this.instructions,
    this.geofenceRadiusMeters,
  });

  final StopKind kind;

  /// Business name for a pickup, the recipient's first name for a drop-off.
  final String name;
  final String? address;

  /// Neighbourhood or locality, safe to show before acceptance.
  final String? area;
  final GeoPoint? location;
  final String? instructions;

  /// Per-stop arrival radius chosen by the backend (large sites, malls).
  final double? geofenceRadiusMeters;

  factory DeliveryStop.fromJson(StopKind kind, Map<String, dynamic> json) {
    final location = json['location'];
    return DeliveryStop(
      kind: kind,
      name: json['name'] as String? ?? '',
      address: json['address'] as String?,
      area: json['area'] as String?,
      location: location is Map<String, dynamic>
          ? GeoPoint.fromJson(location)
          : null,
      instructions: _nonEmpty(json['instructions']),
      geofenceRadiusMeters: (json['geofenceRadiusMeters'] as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toJson() => {
    'name': name,
    if (address != null) 'address': address,
    if (area != null) 'area': area,
    if (location != null) 'location': location!.toJson(),
    if (instructions != null) 'instructions': instructions,
    if (geofenceRadiusMeters != null)
      'geofenceRadiusMeters': geofenceRadiusMeters,
  };
}

class Money {
  const Money(this.amount, this.currency);

  final num amount;

  /// ISO 4217 code, e.g. INR.
  final String currency;

  factory Money.fromJson(Map<String, dynamic> json) =>
      Money(json['amount'] as num, json['currency'] as String);

  Map<String, dynamic> toJson() => {'amount': amount, 'currency': currency};
}

class ParcelInfo {
  const ParcelInfo({required this.description, this.itemCount, this.weightKg});

  final String description;
  final int? itemCount;
  final double? weightKg;

  factory ParcelInfo.fromJson(Map<String, dynamic> json) => ParcelInfo(
    description: json['description'] as String? ?? '',
    itemCount: json['itemCount'] as int?,
    weightKg: (json['weightKg'] as num?)?.toDouble(),
  );

  Map<String, dynamic> toJson() => {
    'description': description,
    if (itemCount != null) 'itemCount': itemCount,
    if (weightKg != null) 'weightKg': weightKg,
  };
}

/// How the handover must be proven. Only OTP is implemented; photo is part of
/// the contract so the backend can introduce it without an app migration.
enum VerificationMethod {
  otp('otp'),
  photo('photo');

  const VerificationMethod(this.wire);
  final String wire;

  static VerificationMethod fromWire(String? value) =>
      values.firstWhere((m) => m.wire == value, orElse: () => otp);
}

class VerificationRequirement {
  const VerificationRequirement({
    this.method = VerificationMethod.otp,
    this.otpLength = 4,
  });

  final VerificationMethod method;
  final int otpLength;

  factory VerificationRequirement.fromJson(Map<String, dynamic>? json) =>
      VerificationRequirement(
        method: VerificationMethod.fromWire(json?['method'] as String?),
        otpLength: json?['otpLength'] as int? ?? 4,
      );

  Map<String, dynamic> toJson() => {
    'method': method.wire,
    'otpLength': otpLength,
  };
}

/// A delivery the partner has accepted (or completed, for history).
class Delivery {
  const Delivery({
    required this.id,
    required this.reference,
    required this.status,
    required this.pickup,
    required this.dropoff,
    this.parcel,
    this.tripDistanceMeters,
    this.estimatedMinutes,
    this.payout,
    this.verification = const VerificationRequirement(),
    this.acceptedAt,
    this.pickedUpAt,
    this.completedAt,
    this.cancelReason,
  });

  final String id;

  /// Short order reference shown to people, e.g. ORD-48213.
  final String reference;
  final DeliveryStatus status;
  final DeliveryStop pickup;
  final DeliveryStop dropoff;
  final ParcelInfo? parcel;
  final double? tripDistanceMeters;
  final int? estimatedMinutes;
  final Money? payout;
  final VerificationRequirement verification;
  final DateTime? acceptedAt;
  final DateTime? pickedUpAt;
  final DateTime? completedAt;
  final String? cancelReason;

  /// The stop the partner is heading to or standing at.
  DeliveryStop? get currentStop => switch (status.currentStop) {
    StopKind.pickup => pickup,
    StopKind.dropoff => dropoff,
    null => null,
  };

  factory Delivery.fromJson(Map<String, dynamic> json) => Delivery(
    id: json['id'] as String,
    reference: json['reference'] as String? ?? json['id'] as String,
    status: DeliveryStatus.fromWire(json['status'] as String),
    pickup: DeliveryStop.fromJson(
      StopKind.pickup,
      json['pickup'] as Map<String, dynamic>,
    ),
    dropoff: DeliveryStop.fromJson(
      StopKind.dropoff,
      json['dropoff'] as Map<String, dynamic>,
    ),
    parcel: json['parcel'] == null
        ? null
        : ParcelInfo.fromJson(json['parcel'] as Map<String, dynamic>),
    tripDistanceMeters: (json['tripDistanceMeters'] as num?)?.toDouble(),
    estimatedMinutes: json['estimatedMinutes'] as int?,
    payout: json['payout'] == null
        ? null
        : Money.fromJson(json['payout'] as Map<String, dynamic>),
    verification: VerificationRequirement.fromJson(
      json['verification'] as Map<String, dynamic>?,
    ),
    acceptedAt: _date(json['acceptedAt']),
    pickedUpAt: _date(json['pickedUpAt']),
    completedAt: _date(json['completedAt']),
    cancelReason: _nonEmpty(json['cancelReason']),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'reference': reference,
    'status': status.wire,
    'pickup': pickup.toJson(),
    'dropoff': dropoff.toJson(),
    if (parcel != null) 'parcel': parcel!.toJson(),
    if (tripDistanceMeters != null) 'tripDistanceMeters': tripDistanceMeters,
    if (estimatedMinutes != null) 'estimatedMinutes': estimatedMinutes,
    if (payout != null) 'payout': payout!.toJson(),
    'verification': verification.toJson(),
    if (acceptedAt != null) 'acceptedAt': acceptedAt!.toIso8601String(),
    if (pickedUpAt != null) 'pickedUpAt': pickedUpAt!.toIso8601String(),
    if (completedAt != null) 'completedAt': completedAt!.toIso8601String(),
    if (cancelReason != null) 'cancelReason': cancelReason,
  };
}

/// An incoming request the partner can accept or reject.
class DeliveryOffer {
  const DeliveryOffer({
    required this.id,
    required this.reference,
    required this.pickup,
    required this.dropoffArea,
    required this.expiresIn,
    this.distanceToPickupMeters,
    this.tripDistanceMeters,
    this.estimatedMinutes,
    this.payout,
    this.parcel,
  });

  /// The delivery id; accepting the offer accepts this delivery.
  final String id;
  final String reference;
  final DeliveryStop pickup;

  /// Only the locality: the exact drop-off is revealed after acceptance.
  final String dropoffArea;

  /// Time left when the server sent the offer. Relative rather than absolute
  /// so a wrong clock on the phone cannot extend or cut the window.
  final Duration expiresIn;
  final double? distanceToPickupMeters;
  final double? tripDistanceMeters;
  final int? estimatedMinutes;
  final Money? payout;
  final ParcelInfo? parcel;

  factory DeliveryOffer.fromJson(Map<String, dynamic> json) => DeliveryOffer(
    id: json['id'] as String,
    reference: json['reference'] as String? ?? json['id'] as String,
    pickup: DeliveryStop.fromJson(
      StopKind.pickup,
      json['pickup'] as Map<String, dynamic>,
    ),
    dropoffArea: json['dropoffArea'] as String? ?? '',
    expiresIn: Duration(seconds: (json['expiresInSeconds'] as num).round()),
    distanceToPickupMeters: (json['distanceToPickupMeters'] as num?)
        ?.toDouble(),
    tripDistanceMeters: (json['tripDistanceMeters'] as num?)?.toDouble(),
    estimatedMinutes: json['estimatedMinutes'] as int?,
    payout: json['payout'] == null
        ? null
        : Money.fromJson(json['payout'] as Map<String, dynamic>),
    parcel: json['parcel'] == null
        ? null
        : ParcelInfo.fromJson(json['parcel'] as Map<String, dynamic>),
  );
}

class OffersResult {
  const OffersResult({required this.offers, this.pollAfter});

  final List<DeliveryOffer> offers;

  /// Server hint for the next poll; the app's default applies when null.
  final Duration? pollAfter;
}

class HistoryPage {
  const HistoryPage({required this.items, this.nextCursor});

  final List<Delivery> items;

  /// Opaque cursor for the next page; null when this was the last page.
  final String? nextCursor;
}

class PartnerSummary {
  const PartnerSummary({
    required this.completedToday,
    required this.completedThisWeek,
  });

  final int completedToday;
  final int completedThisWeek;

  factory PartnerSummary.fromJson(Map<String, dynamic> json) => PartnerSummary(
    completedToday: json['completedToday'] as int? ?? 0,
    completedThisWeek: json['completedThisWeek'] as int? ?? 0,
  );
}

DateTime? _date(Object? value) =>
    value is String ? DateTime.tryParse(value) : null;

String? _nonEmpty(Object? value) =>
    value is String && value.trim().isNotEmpty ? value : null;
