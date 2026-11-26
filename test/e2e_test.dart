// Runs every end-to-end suite in integration_test/ under `flutter test`,
// headless and with fake time. On a device, run integration_test/ directly.
import '../integration_test/add_light_errors_e2e_test.dart' as add_light_errors;
import '../integration_test/app_security_e2e_test.dart' as app_security;
import '../integration_test/bridge_background_e2e_test.dart' as bridge_background;
import '../integration_test/bridge_discovery_e2e_test.dart' as bridge_discovery;
import '../integration_test/capabilities_e2e_test.dart' as capabilities;
import '../integration_test/clusters_e2e_test.dart' as clusters;
import '../integration_test/diagnostics_e2e_test.dart' as diagnostics;
import '../integration_test/diagnostics_share_e2e_test.dart' as diagnostics_share;
import '../integration_test/effects_settings_e2e_test.dart' as effects_settings;
import '../integration_test/emulator_e2e_test.dart' as emulator;
import '../integration_test/gradient_e2e_test.dart' as gradient;
import '../integration_test/group_detail_e2e_test.dart' as group_detail;
import '../integration_test/groups_e2e_test.dart' as groups;
import '../integration_test/home_profiles_e2e_test.dart' as home_profiles;
import '../integration_test/light_detail_e2e_test.dart' as light_detail;
import '../integration_test/music_sync_e2e_test.dart' as music_sync;
import '../integration_test/lights_e2e_test.dart' as lights;
import '../integration_test/pairing_e2e_test.dart' as pairing;
import '../integration_test/permissions_e2e_test.dart' as permissions;
import '../integration_test/plugins_e2e_test.dart' as plugins;
import '../integration_test/power_on_e2e_test.dart' as power_on;
import '../integration_test/profile_per_light_e2e_test.dart' as profile_per_light;
import '../integration_test/reconnect_e2e_test.dart' as reconnect;
import '../integration_test/rooms_profiles_e2e_test.dart' as rooms_profiles;
import '../integration_test/settings_states_e2e_test.dart' as settings_states;
import '../integration_test/skeleton_e2e_test.dart' as skeleton;

void main() {
  profile_per_light.main();
  skeleton.main();
  music_sync.main();
  plugins.main();
  lights.main();
  rooms_profiles.main();
  groups.main();
  clusters.main();
  effects_settings.main();
  emulator.main();
  pairing.main();
  permissions.main();
  diagnostics.main();
  capabilities.main();
  power_on.main();
  gradient.main();
  app_security.main();
  light_detail.main();
  diagnostics_share.main();
  settings_states.main();
  group_detail.main();
  home_profiles.main();
  add_light_errors.main();
  bridge_discovery.main();
  reconnect.main();
  bridge_background.main();
}
