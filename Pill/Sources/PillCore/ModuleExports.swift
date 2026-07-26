// Re-export shared packages so ShannonPill (and other clients) only link PillCore.
// Xcode previously listed ShannonCore/ShannonTheme on both PillCore (framework)
// and ShannonPill (executable), which dual-linked the same @objc classes into
// Frameworks/PillCore.framework and MacOS/ShannonPill — probe then warned
// "Class … is implemented in both". One link site only.
@_exported import ShannonCore
@_exported import ShannonTheme
