#
#  Podfile
#  Dock
#
#  Created by Pierluigi Galdi on 14/05/2020.
#  Copyright © 2020 Pierluigi Galdi. All rights reserved.
#

target 'Dock' do
  # Comment the next line if you don't want to use dynamic frameworks
  use_frameworks!

  # Pods for Dock
  pod 'PockKit', :git => 'git@github.com:pock/pockkit.git'

end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['MACOSX_DEPLOYMENT_TARGET'] = '13.0'
    end
  end
end
