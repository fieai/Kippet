import AppKit
import SwiftUI

struct ShelfCard: View {
    let clip: Clip
    let detection: DetectedContent?
    let isSelected: Bool
    let shortcut: Int?
    let commandHeld: Bool
    let shelfIsOpen: Bool
    let onSource: (ClipSource) -> Void
    let onDragState: (Bool) -> Void
    @State private var hovering = false

    private var tint: Color { ShelfTheme.tint(for: clip.storedPayload.kind) }
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: ShelfTheme.cardRadius, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 11)
                .padding(.top, 10)
                .padding(.bottom, 8)
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            meta
                .padding(.horizontal, 11)
                .padding(.vertical, 8)
        }
        .background {
            shape.fill(ShelfTheme.cardFill)
            // A whisper of the content color washes down from the top edge.
            shape.fill(LinearGradient(colors: [tint.opacity(0.12), tint.opacity(0)],
                                      startPoint: .top, endPoint: .center))
        }
        .clipShape(shape)
        .overlay {
            shape
                .strokeBorder(isSelected ? ShelfTheme.accent : Color.primary.opacity(hovering ? 0.16 : 0.08),
                              lineWidth: isSelected ? 2 : 1)
                .allowsHitTesting(false)
        }
        .shadow(color: isSelected ? ShelfTheme.accent.opacity(0.32) : .black.opacity(hovering ? 0.16 : 0.08),
                radius: isSelected ? 12 : hovering ? 9 : 3, y: isSelected ? 6 : hovering ? 4 : 1)
        .offset(y: isSelected ? -5 : hovering ? -2 : 0)
        .contentShape(shape)
        .onHover { hovering = $0 }
        .animation(ShelfMotion.lift, value: isSelected)
        .animation(ShelfMotion.lift, value: hovering)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let source = clip.source {
                Button { onSource(source) } label: { icon(source) }
                    .buttonStyle(.plain)
                    .help(L("只看来自「%@」的记录", source.name))
                    .accessibilityLabel(L("按来源筛选 %@", source.name))
            } else {
                icon(nil).accessibilityHidden(true)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(clip.title ?? clip.sourceName ?? clip.storedPayload.kind.label)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 2) {
                    if clip.title != nil, let source = clip.sourceName {
                        Text("\(source) ·").lineLimit(1)
                    }
                    Text("\(Text(clip.date, style: .relative))前")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help(clip.date.formatted(date: .abbreviated, time: .shortened))
            }
            Spacer(minLength: 0)
            if let shortcut {
                Text("⌘\(shortcut)")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(commandHeld ? Color.white : .secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(commandHeld ? ShelfTheme.accent : Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .scaleEffect(commandHeld ? 1.12 : 1)
                    .animation(ShelfMotion.lift, value: commandHeld)
                    .accessibilityLabel(L("快贴快捷键 Command %lld", shortcut))
            }
            ShelfDragHandle(item: .card(clip), onDragState: onDragState)
                .frame(width: 14, height: 26)
                .overlay {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .opacity(hovering || isSelected ? 1 : 0.35)
                        .allowsHitTesting(false)
                }
                .help("拖出卡片")
        }
    }

    private var meta: some View {
        HStack(spacing: 5) {
            Label(detection?.label ?? clip.storedPayload.kind.label, systemImage: detection?.symbol ?? clip.storedPayload.kind.symbol)
                .font(.system(size: 10, weight: .semibold))
                .lineLimit(1)
                .foregroundStyle(tint)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(tint.opacity(0.12), in: Capsule())
            if let detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            if let expiry = clip.expiresAt {
                ClipExpiryBadge(expiry: expiry, tint: tint, shelfIsOpen: shelfIsOpen)
            }
            Spacer(minLength: 0)
            if let groups = clip.groupIDs, !groups.isEmpty {
                Image(systemName: "folder.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("已加入收藏分组")
            }
            if clip.isFavorite {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("已加星标")
            }
        }
        .animation(ShelfMotion.lift, value: clip.isFavorite)
    }

    private var detail: String? {
        switch clip.storedPayload {
        case let .text(text, _, _): L("%lld 字", text.count)
        case let .files(urls): urls.count > 1 ? L("%lld 个文件", urls.count) : nil
        case let .link(value): URLComponents(string: value)?.scheme?.uppercased()
        case .image: nil
        }
    }

    @ViewBuilder
    private func icon(_ source: ClipSource?) -> some View {
        if let appIcon = ShelfIconCache.shared.image(for: source?.bundleIdentifier) {
            Image(nsImage: appIcon)
                .resizable()
                .scaledToFit()
                .frame(width: 30, height: 30)
                .shadow(color: .black.opacity(0.12), radius: 1.5, y: 1)
        } else {
            Image(systemName: clip.storedPayload.kind.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    @ViewBuilder
    private var preview: some View {
        if clip.hasPendingSyncImage || clip.hasPreviewImage {
            ShelfThumbnail(clip: clip, maxPixelSize: 440, fills: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06))
                }
                .overlay(alignment: .topTrailing) {
                    if clip.barcodePayloads?.isEmpty == false {
                        Image(systemName: "qrcode")
                            .font(.system(size: 11, weight: .semibold))
                            .padding(5)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: ShelfTheme.chipRadius))
                            .padding(5)
                            .accessibilityLabel("含二维码内容")
                    }
                }
                .padding(.horizontal, 9)
        } else if case let .link(value) = clip.storedPayload {
            VStack(alignment: .leading, spacing: 6) {
                if let host = URLComponents(string: value)?.host {
                    Label {
                        Text(host.hasPrefix("www.") ? String(host.dropFirst(4)) : host)
                            .lineLimit(1)
                    } icon: {
                        Image(systemName: "globe")
                            .foregroundStyle(tint)
                    }
                    .font(.system(size: 14, weight: .semibold))
                }
                Text(value)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
            .padding(.horizontal, 12)
            .padding(.top, 2)
        } else {
            if let detection {
                DetectedContentView(detection: detection, source: clip.storedPayload.previewText)
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
            } else {
                Text(String(clip.storedPayload.previewText.prefix(640)))
                    .font(.system(size: 12.5))
                    .lineSpacing(2.5)
                    .lineLimit(9)
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    // Long text fades into the meta row rather than ending on a hard cut.
                    .mask {
                        LinearGradient(stops: [.init(color: .black, location: 0.72), .init(color: .clear, location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                    }
            }
        }
    }
}

private struct ClipExpiryBadge: View {
    let expiry: Date
    let tint: Color
    let shelfIsOpen: Bool
    @State private var inViewport = false

    var body: some View {
        Group {
            if shelfIsOpen, inViewport {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    badge(at: context.date)
                }
            } else {
                badge(at: .now)
            }
        }
        .fixedSize()
        .onGeometryChange(for: Bool.self) { geometry in
            let viewport = CGRect(origin: .zero, size: geometry.bounds(of: .scrollView)?.size ?? .zero)
            return geometry.frame(in: .scrollView).intersects(viewport)
        } action: { inViewport = $0 }
    }

    private func badge(at date: Date) -> some View {
        let remaining = max(0, expiry.timeIntervalSince(date))
        let countdown = Duration.seconds(remaining.rounded(.up)).formatted(.time(pattern: .minuteSecond))
        let color = remaining <= 15 ? ShelfTheme.warning : tint
        return Label(countdown, systemImage: "timer")
            .font(.system(size: 10, weight: .semibold))
            .monospacedDigit()
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
            .accessibilityLabel(L("删除倒计时 %@", countdown))
    }
}

@MainActor
private final class ShelfIconCache {
    static let shared = ShelfIconCache()
    private let cache = NSCache<NSString, Entry>()

    private init() { cache.countLimit = 100 }

    func image(for bundleIdentifier: String?) -> NSImage? {
        guard let bundleIdentifier else { return nil }
        let key = bundleIdentifier as NSString
        if let entry = cache.object(forKey: key) { return entry.image }
        let image = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        cache.setObject(Entry(image: image), forKey: key)
        return image
    }

    private final class Entry {
        let image: NSImage?
        init(image: NSImage?) { self.image = image }
    }
}
