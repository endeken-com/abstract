Pod::Spec.new do |s|
  s.name = 'IrohLib'
  s.version = '1.1.0'
  s.summary = 'Pinned upstream Iroh bindings'
  s.license = { :type => 'MIT OR Apache-2.0', :file => 'LICENSE-MIT' }
  s.author = 'n0'
  s.homepage = 'https://github.com/n0-computer/iroh-ffi'
  s.source = { :git => 'https://github.com/n0-computer/iroh-ffi.git', :tag => 'v1.1.0' }
  s.platform = :ios, '15.1'
  s.swift_version = '5.9'
  s.static_framework = true
  s.source_files = 'Sources/IrohLib/*.swift'
  s.vendored_frameworks = 'Iroh.xcframework'
  s.frameworks = 'SystemConfiguration', 'Network'
end
