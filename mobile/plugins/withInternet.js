const { withPodfile } = require('expo/config-plugins');
module.exports = config => withPodfile(config, config => {
  const marker = "  use_expo_modules!";
  const pods = "  pod 'IrohLib', :path => '../../Packages/Iroh'\n  pod 'AbstractInternetTransport', :path => '../../Packages/AbstractInternet'";
  if (!config.modResults.contents.includes("pod 'IrohLib'")) {
    config.modResults.contents = config.modResults.contents.replace(marker, marker + '\n' + pods);
  }
  return config;
});
