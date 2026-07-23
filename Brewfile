# Shannon – developer dependencies
# Sets up the full dev environment for building Shannon and the Pill app.
# Usage: brew bundle install

# C++ build toolchain (required by Formula/shannon.rb)
brew "cmake"
brew "ninja"
brew "libomp"

# XcodeGen: generates .xcodeproj from project.yml for Pill/, iOS/, iPad/
brew "xcodegen"

# Swift formatter (run before commits on Swift source)
brew "swiftformat"

# GitHub CLI – used to cut releases and upload DMG artifacts
brew "gh"

# Fastlane: CI/CD automation for Pill, iOS, iPad, and TestFlight builds.
brew "fastlane"

# ios-deploy: used by fastlane's install_on_device action to sideload .ipa files
# onto connected iPhones and iPads without going through Xcode.
brew "ios-deploy"
