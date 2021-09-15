Pod::Spec.new do |spec|
  spec.name = "Treetracker-Core"
  spec.version = "0.0.1"
  spec.license = { :type => "GNU", :file => "LICENSE" }
  spec.homepage = "https://github.com/Greenstand/treetracker-ios-core"
  spec.summary = "Greenstand Treetracker core library."
  spec.platform = :ios, "11.0"
  spec.authors = { "Alex Cornforth" => "alexcornforth@me.com" }
  spec.source = { :git => "https://github.com/Greenstand/treetracker-ios-core.git", :tag => s.version.to_s }
  spec.source_files  = "treetracker-core/**/*.{h,m,swift}"
  spec.resources = "Resources/*"
  spec.dependency "AWSS3", "2.16.0"
end
