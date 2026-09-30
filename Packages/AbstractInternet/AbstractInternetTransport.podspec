Pod::Spec.new do |s|
  s.name = 'AbstractInternetTransport'
  s.version = '1.0.0'
  s.summary = 'Abstract shared Apple internet transport'
  s.license = { :type => 'MIT' }
  s.author = 'Abstract'
  s.homepage = 'https://useabstract.app'
  s.source = { :git => 'https://github.com/endeken-com/abstract.git' }
  s.platform = :ios, '15.1'
  s.swift_version = '5.9'
  s.static_framework = true
  s.dependency 'IrohLib', '1.1.0'
  s.source_files = 'Sources/AbstractInternet/*.swift'
end
