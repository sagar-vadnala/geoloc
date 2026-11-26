import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geoloc/core/theme.dart';
import 'package:geoloc/feature/delivery/delivery_bootstrap.dart';
import 'package:geoloc/feature/delivery/delivery_config.dart';
import 'package:geoloc/feature/home.dart';
import 'package:geoloc/feature/location/data/sqlite_location_store.dart';
import 'package:geoloc/feature/location/providers.dart';
import 'package:material_ui/material_ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final store = await SqliteLocationStore.open();
  runApp(
    ProviderScope(
      overrides: [
        locationStoreProvider.overrideWithValue(store),
        ...deliveryOverrides(DeliveryConfig.fromEnvironment()),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Geoloc',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      home: const HomeScreen(),
    );
  }
}
