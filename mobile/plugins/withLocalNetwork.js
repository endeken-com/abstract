const { withAndroidManifest } = require('expo/config-plugins');
module.exports = config => withAndroidManifest(config, config => {
  const manifest = config.modResults.manifest;
  const permission = 'android.permission.CHANGE_WIFI_MULTICAST_STATE';
  manifest['uses-permission'] ||= [];
  if (!manifest['uses-permission'].some(item => item.$['android:name'] === permission)) {
    manifest['uses-permission'].push({ $: { 'android:name': permission } });
  }
  return config;
});
