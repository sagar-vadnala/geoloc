import 'package:material_ui/material_ui.dart';

import 'location/presentation/location_gate.dart';
import 'location/presentation/tracking_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const LocationGate(child: TrackingScreen());
  }
}
