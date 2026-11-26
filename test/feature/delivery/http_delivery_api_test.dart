import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoloc/feature/delivery/data/delivery_api.dart';
import 'package:geoloc/feature/delivery/data/http_delivery_api.dart';
import 'package:geoloc/feature/delivery/domain/delivery_status.dart';
import 'package:mocktail/mocktail.dart';

class MockDio extends Mock implements Dio {}

Map<String, dynamic> deliveryJson({String status = 'accepted'}) => {
  'id': 'dlv_1',
  'reference': 'ORD-1',
  'status': status,
  'pickup': {
    'name': 'Corner Bakehouse',
    'address': '3 Clock Tower Lane',
    'location': {'lat': 19.07, 'lng': 72.87},
    'geofenceRadiusMeters': 120,
  },
  'dropoff': {'name': 'Asha', 'area': 'Riverside'},
  'payout': {'amount': 85, 'currency': 'INR'},
  'verification': {'method': 'otp', 'otpLength': 6},
};

void main() {
  late MockDio dio;
  late HttpDeliveryApi api;
  final request = RequestOptions(path: '/');

  Response<Object?> ok(Object? data, {int status = 200}) =>
      Response(requestOptions: request, data: data, statusCode: status);

  DioException http(int status, [Object? body]) => DioException(
    requestOptions: request,
    type: DioExceptionType.badResponse,
    response: Response(requestOptions: request, statusCode: status, data: body),
  );

  void postThrows(DioException e) => when(
    () => dio.post<Object?>(
      any(),
      data: any(named: 'data'),
      options: any(named: 'options'),
    ),
  ).thenThrow(e);

  Future<DeliveryException> acceptError() async {
    try {
      await api.accept('dlv_1', idempotencyKey: 'k');
    } on DeliveryException catch (e) {
      return e;
    }
    fail('expected a DeliveryException');
  }

  setUpAll(() => registerFallbackValue(Options()));

  setUp(() {
    dio = MockDio();
    api = HttpDeliveryApi(dio);
  });

  test(
    'accept posts with an idempotency key and parses the delivery',
    () async {
      when(
        () => dio.post<Object?>(
          any(),
          data: any(named: 'data'),
          options: any(named: 'options'),
        ),
      ).thenAnswer((_) async => ok(deliveryJson()));

      final d = await api.accept('dlv_1', idempotencyKey: 'key-123');

      final captured =
          verify(
                () => dio.post<Object?>(
                  '/deliveries/dlv_1/accept',
                  data: any(named: 'data'),
                  options: captureAny(named: 'options'),
                ),
              ).captured.single
              as Options;
      expect(captured.headers?['Idempotency-Key'], 'key-123');
      expect(d.status, DeliveryStatus.accepted);
      expect(d.pickup.geofenceRadiusMeters, 120);
      expect(d.verification.otpLength, 6);
      expect(d.dropoff.address, isNull);
    },
  );

  test('complete sends the code and location', () async {
    when(
      () => dio.post<Object?>(
        any(),
        data: any(named: 'data'),
        options: any(named: 'options'),
      ),
    ).thenAnswer((_) async => ok(deliveryJson(status: 'completed')));

    await api.complete('dlv_1', const OtpProof('4821'), idempotencyKey: 'k');

    final body =
        verify(
              () => dio.post<Object?>(
                '/deliveries/dlv_1/complete',
                data: captureAny(named: 'data'),
                options: any(named: 'options'),
              ),
            ).captured.single
            as Map;
    expect(body, {'method': 'otp', 'otp': '4821'});
    expect(const OtpProof('4821').toString(), isNot(contains('4821')));
  });

  test('no active delivery is a 204', () async {
    when(() => dio.get<Object?>('/partner/deliveries/active'))
        .thenAnswer((_) async => ok(null, status: 204));

    expect(await api.fetchActive(), isNull);
  });

  test('history passes the cursor and reads the next one', () async {
    when(
      () => dio.get<Object?>(
        any(),
        queryParameters: any(named: 'queryParameters'),
      ),
    ).thenAnswer(
      (_) async => ok({
        'items': [deliveryJson(status: 'completed')],
        'nextCursor': 'c2',
      }),
    );

    final page = await api.fetchHistory(cursor: 'c1');

    final query =
        verify(
              () => dio.get<Object?>(
                '/partner/deliveries',
                queryParameters: captureAny(named: 'queryParameters'),
              ),
            ).captured.single
            as Map;
    expect(query['cursor'], 'c1');
    expect(query['status'], 'completed,cancelled');
    expect(page.items.single.status, DeliveryStatus.completed);
    expect(page.nextCursor, 'c2');
  });

  group('errors', () {
    test('offer taken or expired', () async {
      postThrows(
        http(409, {
          'error': {'code': 'offer_unavailable', 'message': 'taken'},
        }),
      );
      final e = await acceptError();
      expect(e.code, DeliveryErrorCode.offerUnavailable);
      expect(e.retryable, isFalse);
    });

    test('wrong code carries the attempts left', () async {
      postThrows(
        http(422, {
          'error': {'code': 'invalid_otp', 'attemptsRemaining': 2},
        }),
      );
      final e = await acceptError();
      expect(e.code, DeliveryErrorCode.invalidOtp);
      expect(e.attemptsRemaining, 2);
    });

    test('status codes without a body still map sensibly', () async {
      postThrows(http(401));
      expect((await acceptError()).code, DeliveryErrorCode.unauthorized);
      postThrows(http(409));
      expect((await acceptError()).code, DeliveryErrorCode.invalidTransition);
      postThrows(http(423));
      expect((await acceptError()).code, DeliveryErrorCode.otpLocked);
    });

    test('5xx and 429 are retryable', () async {
      postThrows(http(503));
      expect((await acceptError()).retryable, isTrue);
      postThrows(http(429));
      expect((await acceptError()).retryable, isTrue);
    });

    test('transport failures are retryable', () async {
      for (final type in [
        DioExceptionType.connectionError,
        DioExceptionType.connectionTimeout,
        DioExceptionType.receiveTimeout,
        DioExceptionType.transformTimeout,
        DioExceptionType.unknown,
      ]) {
        postThrows(DioException(requestOptions: request, type: type));
        final e = await acceptError();
        expect(e.retryable, isTrue, reason: type.name);
        expect(
          e.code,
          anyOf(DeliveryErrorCode.network, DeliveryErrorCode.timeout),
        );
      }
    });

    test('an unreadable response is reported, not crashed on', () async {
      when(
        () => dio.post<Object?>(
          any(),
          data: any(named: 'data'),
          options: any(named: 'options'),
        ),
      ).thenAnswer((_) async => ok({'id': 'dlv_1', 'status': 'beamed_up'}));
      expect((await acceptError()).code, DeliveryErrorCode.invalidResponse);
    });
  });
}
