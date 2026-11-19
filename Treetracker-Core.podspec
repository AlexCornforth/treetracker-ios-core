Pod::Spec.new do |spec|
  spec.name = "Treetracker-Core"
  spec.version = "0.2.0"
  spec.license = { :type => "GNU", :file => "LICENSE" }
  spec.homepage = "https://github.com/Greenstand/treetracker-ios-core"
  spec.summary = "Greenstand Treetracker core library."
  spec.platform = :ios, "13.0"
  spec.authors = { "Alex Cornforth" => "alexcornforth@me.com" }
  spec.swift_version = '5.0'
  spec.source = { :git => "https://github.com/Greenstand/treetracker-ios-core.git", :tag => "v0.2.0" }
  spec.source_files  = "treetracker-core/**/*.{h,m,swift}"
  spec.resources = "Resources/*"
  spec.dependency "AWSS3", "2.30.4"
  # Compile-time data-race checks for code that adopts Swift concurrency (the v2 uploader).
  spec.pod_target_xcconfig = { "SWIFT_STRICT_CONCURRENCY" => "targeted" }
end
