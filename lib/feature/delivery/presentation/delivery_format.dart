import '../data/delivery_api.dart';
import '../domain/delivery.dart';
import '../domain/delivery_status.dart';

String formatDistance(double meters) {
  if (meters < 1000) return '${(meters / 10).round() * 10} m';
  if (meters < 10000) return '${(meters / 1000).toStringAsFixed(1)} km';
  return '${(meters / 1000).round()} km';
}

String formatMoney(Money money) {
  const symbols = {'INR': '₹', 'USD': r'$', 'EUR': '€', 'GBP': '£'};
  final whole = money.amount == money.amount.roundToDouble();
  final value = whole
      ? money.amount.round().toString()
      : money.amount.toStringAsFixed(2);
  final symbol = symbols[money.currency];
  return symbol == null ? '$value ${money.currency}' : '$symbol$value';
}

String formatClock(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(t.hour)}:${two(t.minute)}';
}

String formatWhen(DateTime time, DateTime now) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final t = time.toLocal();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(t.year, t.month, t.day);
  final clock = formatClock(t);
  if (day == today) return 'Today, $clock';
  if (day == today.subtract(const Duration(days: 1))) {
    return 'Yesterday, $clock';
  }
  final date = '${t.day} ${months[t.month - 1]}';
  return t.year == now.year ? '$date, $clock' : '$date ${t.year}, $clock';
}

String statusLabel(DeliveryStatus status) => switch (status) {
  DeliveryStatus.assigned => 'New request',
  DeliveryStatus.accepted => 'Heading to pickup',
  DeliveryStatus.atPickup => 'At pickup',
  DeliveryStatus.inTransit => 'Heading to drop-off',
  DeliveryStatus.atDropoff => 'At drop-off',
  DeliveryStatus.completed => 'Delivered',
  DeliveryStatus.rejected => 'Declined',
  DeliveryStatus.expired => 'Expired',
  DeliveryStatus.cancelled => 'Cancelled',
};

/// What the partner should do next, as the screen's main heading.
String stageTitle(DeliveryStatus status) => switch (status) {
  DeliveryStatus.accepted => 'Head to pickup',
  DeliveryStatus.atPickup => 'Collect the parcel',
  DeliveryStatus.inTransit => 'Head to drop-off',
  DeliveryStatus.atDropoff => 'Hand over the parcel',
  DeliveryStatus.completed => 'Delivered',
  DeliveryStatus.cancelled => 'Delivery cancelled',
  _ => statusLabel(status),
};

String parcelLine(ParcelInfo parcel) {
  final count = parcel.itemCount;
  final weight = parcel.weightKg;
  return [
    parcel.description,
    if (count != null && count > 1) '$count items',
    if (weight != null) '${weight.toStringAsFixed(1)} kg',
  ].join(', ');
}

String errorMessage(DeliveryException e) => switch (e.code) {
  DeliveryErrorCode.network =>
    'No connection. Check your internet and try again.',
  DeliveryErrorCode.timeout => 'The server took too long to answer. Try again.',
  DeliveryErrorCode.unauthorized =>
    'Your session has ended. Sign in again to continue.',
  DeliveryErrorCode.forbidden ||
  DeliveryErrorCode.notFound => "This delivery isn't assigned to you any more.",
  DeliveryErrorCode.offerUnavailable => 'This request is no longer available.',
  DeliveryErrorCode.invalidTransition =>
    'This delivery changed on the server. Showing its latest status.',
  DeliveryErrorCode.tooFarFromStop =>
    "Your location doesn't match the stop yet. Move closer and try again.",
  DeliveryErrorCode.invalidOtp => _wrongCode(e.attemptsRemaining),
  DeliveryErrorCode.otpLocked =>
    'Too many incorrect codes. Contact support to complete this delivery.',
  DeliveryErrorCode.validation =>
    'The server rejected this request. Contact support if it keeps happening.',
  DeliveryErrorCode.invalidResponse =>
    'The server sent an answer the app could not read. Try again.',
  DeliveryErrorCode.server ||
  DeliveryErrorCode.unknown => 'Something went wrong on our side. Try again.',
};

String _wrongCode(int? left) => switch (left) {
  null => "That code didn't match. Check it with the recipient.",
  1 => "That code didn't match. 1 try left.",
  _ => "That code didn't match. $left tries left.",
};
