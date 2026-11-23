import AppKit
import SwiftUI

/// A lane's icon: an SF Symbol, or one of the SVG icons bundled with
/// AgentsMate.
///
/// It is stored as a short string, `sf:hammer` or `svg:rocket`, so an app can
/// keep it in its own model beside the lane's colour. A string with no prefix
/// is read as an SF Symbol name, so a value saved from ``AgentLane/symbol``
/// parses too.
public enum LaneIcon: Hashable, Sendable, Codable {
    /// An SF Symbol, by name.
    case symbol(String)
    /// A bundled SVG icon, by file name without the extension.
    case bundled(String)

    /// The string form kept in storage: `sf:name` or `svg:name`.
    public var stringValue: String {
        switch self {
        case .symbol(let name): "sf:" + name
        case .bundled(let name): "svg:" + name
        }
    }

    /// Reads the string form. Nil when it is empty or has no name.
    public init?(_ string: String) {
        let text = string.trimmingCharacters(in: .whitespacesAndNewlines)
        func name(after prefix: String) -> String? {
            let rest = String(text.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            return rest.isEmpty ? nil : rest
        }
        if text.hasPrefix("svg:") {
            guard let n = name(after: "svg:") else { return nil }
            self = .bundled(n)
        } else if text.hasPrefix("sf:") {
            guard let n = name(after: "sf:") else { return nil }
            self = .symbol(n)
        } else if !text.isEmpty, !text.contains(":") {
            self = .symbol(text)
        } else {
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let icon = LaneIcon(string) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                    debugDescription: "Not a lane icon: \(string)"))
        }
        self = icon
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stringValue)
    }

    /// The name, without its kind.
    public var name: String {
        switch self {
        case .symbol(let n), .bundled(let n): n
        }
    }

    /// A readable name for VoiceOver and tooltips, such as "Git branch".
    public var title: String { Self.title(forName: name) }

    static func title(forName name: String) -> String {
        let words = name.replacingOccurrences(of: ".", with: " ").replacingOccurrences(of: "-", with: " ")
        guard let first = words.first else { return name }
        return first.uppercased() + words.dropFirst()
    }
}

/// The bundled SVG icons and how they are drawn.
public enum LaneIconLibrary {
    /// The bundled icon names, in the order the picker shows them.
    public static var bundledNames: [String] { names }

    /// Whether a bundled icon of this name exists.
    public static func hasBundled(_ name: String) -> Bool { url(forBundled: name) != nil }

    /// A template image of a bundled icon, to be tinted by the view that
    /// draws it. Nil when there is no such icon or it cannot be read.
    public static func bundledImage(_ name: String) -> NSImage? { cache.image(named: name) }

    /// A template image of an SF Symbol. Nil when the name is not a symbol
    /// on this Mac.
    public static func symbolImage(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    /// Whether the icon can be drawn on this Mac.
    public static func isAvailable(_ icon: LaneIcon) -> Bool {
        switch icon {
        case .symbol(let name): symbolImage(name) != nil
        case .bundled(let name): bundledImage(name) != nil
        }
    }

    /// The Lucide licence text that ships with the bundled icons.
    static var licenceURL: URL? {
        resources?.url(forResource: "LICENSE-lucide", withExtension: "txt", subdirectory: "LaneIcons")
    }

    static func url(forBundled name: String) -> URL? {
        guard !name.contains("/"), !name.contains(".") else { return nil }
        return resources?.url(forResource: name, withExtension: "svg", subdirectory: "LaneIcons")
    }

    /// The package's resource bundle, or nil when the app did not ship it.
    ///
    /// `Bundle.module` traps when the bundle is missing, which takes the whole
    /// app down for want of an icon. This looks where SwiftPM and Xcode put it
    /// (inside Contents/Resources, beside the executable, at the app's root)
    /// and lets a missing icon fall back to a placeholder instead.
    static let resources: Bundle? = {
        let name = "AgentsMate_AgentsMate.bundle"
        let candidates: [URL?] = [
            Bundle.main.resourceURL,
            Bundle.main.bundleURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
            Bundle(for: BundleToken.self).resourceURL,
            Bundle(for: BundleToken.self).bundleURL.deletingLastPathComponent(),
        ]
        for base in candidates.compactMap({ $0 }) {
            if let bundle = Bundle(url: base.appendingPathComponent(name)) { return bundle }
        }
        return nil
    }()

    private final class BundleToken {}

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var images: [String: NSImage] = [:]

        func image(named name: String) -> NSImage? {
            lock.lock()
            defer { lock.unlock() }
            if let hit = images[name] { return hit }
            guard let url = LaneIconLibrary.url(forBundled: name), let image = NSImage(contentsOf: url),
                  image.size.width > 0 else { return nil }
            image.isTemplate = true
            images[name] = image
            return image
        }
    }

    private static let cache = Cache()
}

/// Draws a lane's icon in a colour.
///
/// SF Symbols and bundled icons both come out as template images, so the
/// colour is whatever `tint` is, or the accent colour when it is nil.
public struct LaneIconView: View {
    let icon: LaneIcon
    let tint: Color?
    let size: CGFloat

    public init(icon: LaneIcon, tint: Color? = nil, size: CGFloat = 16) {
        self.icon = icon
        self.tint = tint
        self.size = size
    }

    /// Takes the colour as `#RRGGBB`, as ``AgentLane/tintHex`` has it.
    public init(icon: LaneIcon, tintHex: String?, size: CGFloat = 16) {
        self.init(icon: icon, tint: tintHex.flatMap(Color.init(laneHex:)), size: size)
    }

    public var body: some View {
        content
            .foregroundStyle(tint ?? Color.accentColor)
            .frame(width: size, height: size)
            .accessibilityElement()
            .accessibilityLabel(icon.title)
            .accessibilityAddTraits(.isImage)
    }

    @ViewBuilder
    private var content: some View {
        switch icon {
        case .symbol(let name):
            Image(systemName: name)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: size * 0.85))
        case .bundled(let name):
            if let image = LaneIconLibrary.bundledImage(name) {
                Image(nsImage: image)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .padding(size * 0.06)
            } else {
                Image(systemName: "questionmark.square.dashed")
                    .font(.system(size: size * 0.85))
            }
        }
    }
}

public extension AgentLane {
    /// The icon the lane starts with: ``icon`` when the app set one, else the
    /// SF Symbol named by ``symbol``.
    var resolvedIcon: LaneIcon { icon ?? .symbol(symbol) }
}

/// The preset colours the picker offers, as `#RRGGBB`.
public enum LaneIconColors {
    public static let presets: [(name: String, hex: String)] = [
        ("Red", "#E5484D"), ("Orange", "#F76B15"), ("Amber", "#F5A524"), ("Yellow", "#E5C100"),
        ("Lime", "#7DB80F"), ("Green", "#30A46C"), ("Teal", "#12A594"), ("Cyan", "#0EA5C6"),
        ("Blue", "#0A84FF"), ("Indigo", "#5B5BD6"), ("Purple", "#8E4EC6"), ("Pink", "#E93D82"),
        ("Gray", "#7C8089"),
    ]

    /// `#RRGGBB` for a colour, or nil when it cannot be expressed in sRGB.
    static func hex(from color: Color) -> String? {
        guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return nil }
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
    }

    static func normalised(_ hex: String?) -> String? {
        guard let hex, let color = Color(laneHex: hex) else { return nil }
        return Self.hex(from: color)
    }
}

extension LaneIconLibrary {
    static let names: [String] = """
    anchor atom axe award banana bean beaker beer bell bike bird bolt bomb bone book book-open bookmark bot box boxes \
    brain briefcase brush bubbles bug building cake calculator calendar camera candy car carrot castle cat \
    chart-bar chart-line check cherry circle-play clapperboard clock clover cloud cloud-lightning cloud-rain cloud-sun \
    code code-xml coffee cog coins compass component cookie cpu crosshair crown cup-soda database dessert diamond \
    dice-5 dices dna dog donut drama drumstick drum dumbbell egg eye factory feather ferris-wheel fingerprint-pattern \
    fish flag flame flask-conical flower flower-2 folder footprints frame gamepad gamepad-2 gauge gavel gem ghost gift \
    git-branch git-merge git-pull-request glasses globe graduation-cap grape hammer hand-metal handshake hard-drive \
    headphones heart hexagon house ice-cream-cone image infinity key keyboard lamp landmark languages laptop layers \
    leaf library life-buoy lightbulb link lock lollipop magnet map map-pin medal megaphone message-circle mic \
    microscope milestone moon moon-star mountain mountain-snow mouse-pointer-2 music navigation network newspaper \
    octagon orbit origami package palette panda paperclip party-popper paw-print pen-tool pencil pi piano pickaxe \
    pill pizza plane plug popcorn puzzle rabbit radar radio rainbow rat recycle rocket rose ruler sailboat salad \
    satellite satellite-dish scale school scissors scroll search send server settings shapes share shell shield \
    shield-check ship shirt shovel shrimp shrub siren skull slice smile snail snowflake sofa soup spade sparkle \
    sparkles speaker sprout square squirrel star store sun sunrise sunset sword swords syringe tablet-smartphone tag \
    target telescope tent terminal test-tube-diagonal thermometer ticket timer toolbox tornado train-front \
    trending-up tree-deciduous tree-pine trees trophy truck turtle tv umbrella unplug user users utensils vault \
    video volleyball wallet wand wand-sparkles waves webhook wheat wind wine workflow worm wrench zap
    """
        .split(whereSeparator: { $0 == " " || $0 == "\n" })
        .map(String.init)
}
