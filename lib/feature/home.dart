import 'package:material_ui/material_ui.dart';

import 'delivery/presentation/dashboard_screen.dart';
import 'location/presentation/location_gate.dart';

/// The app only works with location access, so the gate comes first.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const LocationGate(child: DashboardScreen());
  }
}
