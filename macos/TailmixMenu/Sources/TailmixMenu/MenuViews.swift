#if canImport(AppKit)
import AppKit

/// Metrics shared by the custom menu-item views, chosen to line their text up
/// with native item titles in a menu without a state column (the main menu
/// sets showsStateColumn to false).
enum MenuMetrics {
    /// From the item's left edge to where native titles start, measured on
    /// macOS 26 without a state column.
    static let leadingInset: CGFloat = 14.5
    /// The same, in a submenu that has a state column (checkmarks).
    static let leadingInsetWithStateColumn: CGFloat = 28.5
    static let trailingInset: CGFloat = 14
    /// The height of a native single-line menu item.
    static let rowHeight: CGFloat = 22
    static let titleFont = NSFont.menuFont(ofSize: 0)
    static let smallFont = NSFont.menuFont(ofSize: NSFont.smallSystemFontSize)
}

private func menuLabel(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
    let label = NSTextField(labelWithString: text)
    label.font = font
    label.textColor = color
    label.lineBreakMode = .byTruncatingTail
    label.setAccessibilityElement(false)
    return label
}

/// A line of styled text that is not clickable. A disabled NSMenuItem would
/// do, but AppKit dims its title again on top of the grey or amber colours.
final class MenuTextView: NSView {
    init(_ text: NSAttributedString, leadingInset: CGFloat = MenuMetrics.leadingInset, toolTip: String? = nil) {
        let label = NSTextField(labelWithAttributedString: text)
        label.lineBreakMode = .byTruncatingTail
        label.setAccessibilityElement(false)
        let labelHeight = ceil(label.intrinsicContentSize.height)
        let height = max(labelHeight + 6, 20)
        let width = leadingInset + ceil(label.intrinsicContentSize.width) + MenuMetrics.trailingInset
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        autoresizingMask = [.width]
        self.toolTip = toolTip
        label.frame = NSRect(x: leadingInset, y: floor((height - labelHeight) / 2),
                             width: width - leadingInset - MenuMetrics.trailingInset, height: labelHeight)
        label.autoresizingMask = [.width]
        addSubview(label)

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text.string)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// "tailmix" over a grey status line. Not clickable.
final class MenuHeaderView: NSView {
    init(title: String, status: String) {
        let titleLabel = menuLabel(title, font: MenuMetrics.titleFont, color: .labelColor)
        let statusLabel = menuLabel(status, font: MenuMetrics.smallFont, color: .secondaryLabelColor)
        let titleHeight = ceil(titleLabel.intrinsicContentSize.height)
        let statusHeight = ceil(statusLabel.intrinsicContentSize.height)
        let verticalInset: CGFloat = 4
        let height = verticalInset * 2 + titleHeight + statusHeight
        let width = MenuMetrics.leadingInset + MenuMetrics.trailingInset
            + ceil(max(titleLabel.intrinsicContentSize.width, statusLabel.intrinsicContentSize.width))
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        autoresizingMask = [.width]

        let labelWidth = width - MenuMetrics.leadingInset - MenuMetrics.trailingInset
        statusLabel.frame = NSRect(x: MenuMetrics.leadingInset, y: verticalInset, width: labelWidth, height: statusHeight)
        titleLabel.frame = NSRect(x: MenuMetrics.leadingInset, y: verticalInset + statusHeight, width: labelWidth, height: titleHeight)
        for label in [titleLabel, statusLabel] {
            label.autoresizingMask = [.width]
            addSubview(label)
        }

        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("\(title), \(status)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

/// A profile's name with a toggle on the right. Clicking anywhere on the
/// row, or the switch, calls onToggle. The row draws the menu's selection
/// when its item is highlighted, by the keyboard or the pointer, so Return
/// (which sends the item's action) has a visible target.
final class ProfileSwitchView: NSView {
    private let isEnabled: Bool
    private let onToggle: () -> Void
    private let label: NSTextField
    private let toggleView: MenuToggle

    init(name: String, isOn: Bool, isEnabled: Bool, toolTip: String?, onToggle: @escaping () -> Void) {
        self.isEnabled = isEnabled
        self.onToggle = onToggle

        let label = menuLabel(name, font: MenuMetrics.titleFont,
                              color: isEnabled ? .labelColor : .disabledControlTextColor)
        self.label = label
        let toggle = MenuToggle(isOn: isOn, isEnabled: isEnabled)
        self.toggleView = toggle
        let switchSize = MenuToggle.size
        let gap: CGFloat = 12
        let labelHeight = ceil(label.intrinsicContentSize.height)
        let width = MenuMetrics.leadingInset + ceil(label.intrinsicContentSize.width) + gap
            + switchSize.width + MenuMetrics.trailingInset
        let height = MenuMetrics.rowHeight
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        autoresizingMask = [.width]
        self.toolTip = toolTip

        let switchX = width - MenuMetrics.trailingInset - switchSize.width
        toggle.frame = NSRect(x: switchX, y: floor((height - switchSize.height) / 2),
                              width: switchSize.width, height: switchSize.height)
        toggle.autoresizingMask = [.minXMargin]
        label.frame = NSRect(x: MenuMetrics.leadingInset, y: floor((height - labelHeight) / 2),
                             width: switchX - gap - MenuMetrics.leadingInset, height: labelHeight)
        label.autoresizingMask = [.width]
        addSubview(label)
        addSubview(toggle)

        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilitySubrole(.toggle)
        setAccessibilityLabel(name)
        setAccessibilityValue(isOn)
        setAccessibilityEnabled(isEnabled)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var isHighlighted: Bool { isEnabled && (enclosingMenuItem?.isHighlighted ?? false) }

    override func viewWillDraw() {
        super.viewWillDraw()
        label.textColor = !isEnabled ? .disabledControlTextColor
            : isHighlighted ? .selectedMenuItemTextColor : .labelColor
        toggleView.isHighlighted = isHighlighted
    }

    /// The rounded, inset selection of native menu items since macOS 11.
    override func draw(_ dirtyRect: NSRect) {
        guard isHighlighted else { return }
        NSColor.selectedContentBackgroundColor.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 5, dy: 0), xRadius: 4, yRadius: 4).fill()
    }

    // Take the click instead of letting the menu treat it as a selection.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        toggle()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        toggle()
        return true
    }

    /// The handler rebuilds the menu that owns this view, so it runs after
    /// the current event finishes.
    private func toggle() {
        guard isEnabled else { return }
        let onToggle = self.onToggle
        DispatchQueue.main.async { onToggle() }
    }
}
/// A switch drawn by hand. NSSwitch draws its "on" track in the accent
/// colour only in the key window, and a menu never is, so it looked grey.
/// It only draws; the row it sits in takes the clicks.
final class MenuToggle: NSView {
    static let size = NSSize(width: 32, height: 18)
    private static let knobInset: CGFloat = 2

    private let isOn: Bool
    private let isEnabled: Bool
    var isHighlighted = false {
        didSet { if isHighlighted != oldValue { needsDisplay = true } }
    }

    init(isOn: Bool, isEnabled: Bool) {
        self.isOn = isOn
        self.isEnabled = isEnabled
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isEnabled ? 1 : 0.5
        let track = NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        let trackColor: NSColor
        if isHighlighted {
            // The row's selection is the accent colour; a translucent white
            // track stays visible on it.
            trackColor = .white.withAlphaComponent(isOn ? 0.45 : 0.2)
        } else {
            trackColor = isOn ? .controlAccentColor : .quaternaryLabelColor
        }
        trackColor.withAlphaComponent(trackColor.alphaComponent * alpha).setFill()
        track.fill()

        let diameter = bounds.height - Self.knobInset * 2
        let x = isOn ? bounds.maxX - Self.knobInset - diameter : Self.knobInset
        let knob = NSRect(x: x, y: Self.knobInset, width: diameter, height: diameter)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = .black.withAlphaComponent(0.3 * alpha)
        shadow.shadowOffset = NSSize(width: 0, height: -0.5)
        shadow.shadowBlurRadius = 1
        shadow.set()
        NSColor.white.withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: knob).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
}
#endif
