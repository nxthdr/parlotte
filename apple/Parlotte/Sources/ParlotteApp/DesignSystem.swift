import SwiftUI

// MARK: - Spacing

enum Spacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
}

// MARK: - Corner Radius

enum Radius {
    static let sm: CGFloat = 6
    static let md: CGFloat = 10
    static let lg: CGFloat = 14
    static let xl: CGFloat = 20
    static let pill: CGFloat = 999
}

// MARK: - Semantic Colors

enum AppColor {
    // Accent — warm indigo instead of system blue
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(red: 0.48, green: 0.45, blue: 1.0, alpha: 1.0)   // lighter indigo for dark
            : NSColor(red: 0.35, green: 0.30, blue: 0.85, alpha: 1.0)  // deeper indigo for light
    })

    // Surfaces
    static let sidebarBackground = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(white: 0.10, alpha: 1.0)
            : NSColor(white: 0.95, alpha: 1.0)
    })

    static let surfaceRaised = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(white: 0.16, alpha: 1.0)
            : NSColor(white: 1.0, alpha: 1.0)
    })

    static let surfaceHover = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(white: 1.0, alpha: 0.06)
            : NSColor(white: 0.0, alpha: 0.04)
    })

    static let border = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(white: 1.0, alpha: 0.10)
            : NSColor(white: 0.0, alpha: 0.10)
    })

    static let borderSubtle = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(white: 1.0, alpha: 0.06)
            : NSColor(white: 0.0, alpha: 0.06)
    })

    // Text
    static let textPrimary = Color.primary
    static let textSecondary = Color.secondary
    static let textTertiary = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(white: 1.0, alpha: 0.35)
            : NSColor(white: 0.0, alpha: 0.35)
    })

    // Unread badge
    static let unreadBadge = accent

    // Online / offline status
    static let online = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
            ? NSColor(red: 0.30, green: 0.85, blue: 0.50, alpha: 1.0)
            : NSColor(red: 0.20, green: 0.70, blue: 0.35, alpha: 1.0)
    })
    static let offline = Color.orange
    /// Initial sync in progress (authenticated but not yet syncing).
    static let connecting = Color.yellow
}

// MARK: - Typography

extension Font {
    // Room list
    static let roomName = Font.system(size: 14, weight: .semibold)
    static let roomPreview = Font.system(size: 12.5, weight: .regular)
    static let roomTimestamp = Font.system(size: 11, weight: .regular)

    // Messages
    static let senderName = Font.system(size: 13, weight: .semibold)
    static let messageBody = Font.system(size: 14, weight: .regular)
    static let messageTimestamp = Font.system(size: 11, weight: .regular)

    // Headers
    static let roomTitle = Font.system(size: 16, weight: .semibold)
    static let roomTopic = Font.system(size: 12, weight: .regular)

    // Sidebar
    static let sidebarDisplayName = Font.system(size: 14, weight: .semibold)
    static let sidebarHandle = Font.system(size: 12, weight: .regular)
}

// MARK: - Avatar Sizes

enum AvatarSize {
    static let message: CGFloat = 36
    static let messageInitialFont: CGFloat = 15
    static let roomList: CGFloat = 36
    static let roomListInitialFont: CGFloat = 15
    static let roomHeader: CGFloat = 28
    static let sidebarHeader: CGFloat = 36
    static let profile: CGFloat = 96
}

// MARK: - Layout Constants

enum Layout {
    static let sidebarWidth: CGFloat = 280
    static let avatarGutter: CGFloat = 12   // space between avatar and text column
    static let messageIndent: CGFloat = AvatarSize.message + avatarGutter  // grouped msg left indent
    static let roomRowHeight: CGFloat = 56
}
