module.exports = {
  expo: {
    name: 'Abstract', slug: 'abstract-mobile', scheme: 'abstract', version: '0.1.0',
    orientation: 'portrait', icon: './assets/icon-dark.png', userInterfaceStyle: 'dark',
    ios: {
      bundleIdentifier: 'sh.abstract.mobile', supportsTablet: true,
      // Light and dark home screens; scripts/make-icons.sh makes both.
      icon: { light: './assets/icon-light.png', dark: './assets/icon-dark.png' },
      infoPlist: {
        NSLocalNetworkUsageDescription: 'Abstract finds your Macs on the local network so you can pair and manage chats.',
        NSBonjourServices: ['_abstract._tcp']
      }
    },
    android: {
      package: 'sh.abstractapp.mobile',
      adaptiveIcon: {
        backgroundImage: './assets/icon-dark.png',
        foregroundImage: './assets/icon-clear.png',
        monochromeImage: './assets/icon-arc.png'
      },
      versionCode: Number(process.env.MOBILE_ANDROID_VERSION_CODE || 1),
      softwareKeyboardLayoutMode: 'resize',
      permissions: ['INTERNET', 'ACCESS_NETWORK_STATE', 'ACCESS_WIFI_STATE', 'CHANGE_WIFI_MULTICAST_STATE', 'NEARBY_WIFI_DEVICES']
    },
    plugins: ['./plugins/withLocalNetwork', './plugins/withInternet', 'expo-font',
      ['expo-image-picker', { photosPermission: 'Abstract attaches the photos you choose to your message.', cameraPermission: false, microphonePermission: false }]]
  }
};
