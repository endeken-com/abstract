Pod::Spec.new do |s|
  s.name = 'AbstractInternet'
  s.version = '1.0.0'
  s.summary = 'Abstract internet transport'
  s.description = 'Iroh stream bridge for the Abstract mobile client.'
  s.license = { :type => 'MIT' }
  s.author = 'Abstract'
  s.homepage = 'https://useabstract.app'
  s.source = { :git => 'https://github.com/endeken-com/abstract.git' }
  s.platform = :ios, '15.1'
  s.swift_version = '5.9'
  s.static_framework = true
  s.dependency 'ExpoModulesCore'
  s.dependency 'AbstractInternetTransport'
  s.source_files = '*.swift'
end
