require 'json'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

Pod::Spec.new do |s|
  s.name = 'TetherdashNetworkBytes'
  s.version = package['version']
  s.summary = package['description']
  s.license = 'UNLICENSED'
  s.homepage = 'https://github.com/tom3281/tetherdash'
  s.author = 'tom3281'
  s.source = { :git => 'https://github.com/tom3281/tetherdash.git', :tag => s.version.to_s }
  s.source_files = 'ios/Plugin/**/*.{swift,h,m}'
  s.ios.deployment_target = '14.0'
  s.dependency 'Capacitor'
  s.swift_version = '5.1'
end
