module.exports = {
  expo: {
    name: 'Abstract', slug: 'abstract-mobile', scheme: 'abstract', version: '0.1.0',
    orientation: 'portrait', icon: './assets/icon.png', userInterfaceStyle: 'dark',
    ios: {
      bundleIdentifier: 'sh.abstract.mobile', supportsTablet: true,
      infoPlist: {
        NSLocalNetworkUsageDescription: 'Abstract finds your Macs on the local network so you can pair and manage chats.',
        NSBonjourServices: ['_abstract._tcp']
      }
    },
    android: {
      package: 'sh.abstractapp.mobile',
      versionCode: Number(process.env.MOBILE_ANDROID_VERSION_CODE || 1),
      permissions: ['INTERNET', 'ACCESS_NETWORK_STATE', 'ACCESS_WIFI_STATE', 'CHANGE_WIFI_MULTICAST_STATE', 'NEARBY_WIFI_DEVICES']
    },
    plugins: ['./plugins/withLocalNetwork', './plugins/withInternet', 'expo-font']
  }
};
