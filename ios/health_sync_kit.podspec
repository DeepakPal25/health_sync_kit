Pod::Spec.new do |s|
  s.name             = 'health_sync_kit'
  s.version          = '0.1.0'
  s.summary          = 'HealthKit + Health Connect for Flutter with a built-in analytics layer.'
  s.description      = <<-DESC
Typed health data (activity, vitals, body, sleep, nutrition, workouts),
de-duplicated daily statistics, incremental sync and analytics (sleep score,
readiness, streaks, anomalies, training load). Flutter port of HealthSyncKit.
                       DESC
  s.homepage         = 'https://github.com/DeepakPal25/health_sync_kit'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Deepak Pal' => 'https://github.com/DeepakPal25' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'Flutter'
  s.frameworks       = 'HealthKit'
  s.platform         = :ios, '13.0'
  s.swift_version    = '5.9'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
end
