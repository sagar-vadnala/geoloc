import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geoloc/feature/location/data/location_api.dart';
import 'package:geoloc/feature/location/data/location_record.dart';
import 'package:mocktail/mocktail.dart';

class MockDio extends Mock implements Dio {}

void main() {
  late MockDio dio;
  late DioLocationApi api;
  final options = RequestOptions(path: '/locations/batch');
  final records = [
    LocationRecord(
      id: 'a',
      latitude: 18.52,
      longitude: 73.85,
      recordedAt: DateTime.utc(2026, 1, 1),
    ),
  ];

  void postThrows(DioException error) {
    when(() => dio.post<Map<String, dynamic>>(any(), data: any(named: 'data')))
        .thenThrow(error);
  }

  Future<ApiException> uploadError() async {
    try {
      await api.uploadBatch(records);
    } on ApiException catch (e) {
      return e;
    }
    fail('expected an ApiException');
  }

  setUp(() {
    dio = MockDio();
    api = DioLocationApi(dio);
  });

  test('parses accepted, duplicate and rejected ids', () async {
    when(() => dio.post<Map<String, dynamic>>(any(), data: any(named: 'data')))
        .thenAnswer(
          (_) async => Response(
            requestOptions: options,
            statusCode: 200,
            data: {
              'accepted': ['a'],
              'duplicates': ['b'],
              'rejected': [
                {'id': 'c', 'reason': 'latitude out of range'},
              ],
            },
          ),
        );

    final result = await api.uploadBatch(records);

    expect(result.accepted, {'a'});
    expect(result.duplicates, {'b'});
    expect(result.rejected, {'c': 'latitude out of range'});
  });

  test('sends the records under a "locations" key', () async {
    when(() => dio.post<Map<String, dynamic>>(any(), data: any(named: 'data')))
        .thenAnswer(
          (_) async => Response(
            requestOptions: options,
            data: {
              'accepted': ['a'],
            },
          ),
        );

    await api.uploadBatch(records);

    final body =
        verify(
              () => dio.post<Map<String, dynamic>>(
                '/locations/batch',
                data: captureAny(named: 'data'),
              ),
            ).captured.single
            as Map<String, dynamic>;
    expect(body['locations'], [records.single.toApiJson()]);
  });

  group('transport failures keep the data for a retry', () {
    for (final type in [
      DioExceptionType.connectionTimeout,
      DioExceptionType.sendTimeout,
      DioExceptionType.receiveTimeout,
      DioExceptionType.transformTimeout,
      DioExceptionType.connectionError,
      DioExceptionType.cancel,
      DioExceptionType.unknown,
    ]) {
      test(type.name, () async {
        postThrows(DioException(requestOptions: options, type: type));

        final error = await uploadError();

        expect(error.retryable, isTrue);
      });
    }
  });

  group('HTTP errors', () {
    Future<ApiException> errorFor(int status) {
      postThrows(
        DioException(
          requestOptions: options,
          type: DioExceptionType.badResponse,
          response: Response(requestOptions: options, statusCode: status),
        ),
      );
      return uploadError();
    }

    test('5xx and 429 are retried', () async {
      expect((await errorFor(503)).retryable, isTrue);
      expect((await errorFor(500)).retryable, isTrue);
      expect((await errorFor(429)).retryable, isTrue);
    });

    test('a 400 or 422 means the payload itself is wrong', () async {
      final error = await errorFor(422);
      expect(error.retryable, isFalse);
      expect(error.message, 'Server responded 422');
      expect((await errorFor(400)).retryable, isFalse);
    });
  });
}
