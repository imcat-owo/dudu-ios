// MathAttachment + SelectableMarkdownTheme
// Extracted from OpenMinis Views/Chat/SelectableMarkdownView.swift (GPL-3.0).
// Non-UI logic: math formula attachment renderer used by MathRenderScheduler.
// No SwiftUI views copied. SelectableMarkdownTheme is a plain data struct;
// minisInlineCodeBackgroundColor widened from private to internal for cross-file use.
import UIKit

// MARK: - Inline code background
/// theme and the layout manager's fillBackgroundRectArray (the actual paint
/// site) so the two can never drift. [T-ai-theme-reach][v3] Now follows the
/// theme pack's mutedSurface (AI themes can restyle inline code); a bare
/// UIColor(dynamicProvider:) wrapper keeps resolution live per trait change.
let minisInlineCodeBackgroundColor = UIColor { traits in
    AppearanceStudio.uiColorSnapshot(.mutedSurface, scope: .chat)
        .resolvedColor(with: traits)
}

// MARK: - SelectableMarkdownTheme
/// Mirrors the `.minisChat` MarkdownUI theme using UIKit types.
struct SelectableMarkdownTheme {
    let baseFontSize: CGFloat
    let codeBlockCornerRadius: CGFloat = 8
    let inlineCodeCornerRadius: CGFloat = 5

    init(baseFontSize: CGFloat? = nil) {
        self.baseFontSize = baseFontSize ?? 16.5
    }

    var baseFont: UIFont { AppearanceFontFamily.resolved().uiFont(size: baseFontSize) }
    // [T-ai-text-color-role] Was hardcoded `.label` / `.secondaryLabel` —
    // AI text colour now follows the studio's chat-scope text roles, so it
    // edits from the palette ("主文字"/"次文字") and AI theme packs.
    var labelColor: UIColor { AppearanceStudio.uiColorSnapshot(.primaryText, scope: .chat) }
    var secondaryLabelColor: UIColor { AppearanceStudio.uiColorSnapshot(.secondaryText, scope: .chat) }
    var accentColor: UIColor { AppearanceStudio.uiColorSnapshot(.warning) }
    var linkColor: UIColor { AppearanceStudio.uiColorSnapshot(.accent) }
    // [T-ai-theme-reach] Code-block background used to hardcode black/dark-gray.
    // It now follows the theme pack's card surface token (AI themes can restyle
    // code blocks); the light-mode default stays deliberately DARK (code
    // aesthetic) via the pack's own default, not a hardcoded value here.
    var codeBlockBackground: UIColor {
        AppearanceStudio.uiColorSnapshot(.surface, scope: .chat)
    }
    var codeBlockTextColor: UIColor { AppearanceStudio.uiColorSnapshot(.success) }
    var inlineCodeBackground: UIColor { minisInlineCodeBackgroundColor }
    var inlineCodeColor: UIColor { AppearanceStudio.uiColorSnapshot(.warning) }
    var blockquoteBarColor: UIColor { AppearanceStudio.uiColorSnapshot(.warning).withAlphaComponent(0.5) }
    // [T-ai-theme-reach] Table borders used to hardcode `.label` — they now
    // follow the theme's 次文字 role so an AI theme pack can tint tables.
    var tableBorderColor: UIColor { AppearanceStudio.uiColorSnapshot(.secondaryText, scope: .chat).withAlphaComponent(0.35) }

    func headingFont(level: Int) -> UIFont {
        let size: CGFloat
        let weight: UIFont.Weight
        switch level {
        case 1: size = baseFontSize * 1.5; weight = .bold
        case 2: size = baseFontSize * 1.3; weight = .bold
        case 3: size = baseFontSize * 1.15; weight = .semibold
        case 5: size = baseFontSize * 0.875; weight = .semibold
        case 6: size = baseFontSize * 0.85; weight = .semibold
        default: size = baseFontSize; weight = .semibold // H4 and fallback
        }
        return AppearanceFontFamily.resolved().uiFont(size: size, weight: weight)
    }

    var inlineCodeFont: UIFont {
        let size = baseFontSize * 0.845
        if let menlo = UIFont(name: "Menlo", size: size) {
            let descriptor = menlo.fontDescriptor.addingAttributes([
                .cascadeList: [UIFontDescriptor(fontAttributes: [.name: "PingFang SC"])]
            ])
            return UIFont(descriptor: descriptor, size: size)
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    var codeBlockFont: UIFont {
        let size = baseFontSize * 0.85
        // Use Menlo as the base monospaced font, with PingFang SC as CJK fallback.
        // PingFang SC's CJK glyphs are exactly 2x the width of Menlo's ASCII glyphs
        // at the same point size, enabling proper table alignment in code blocks.
        if let menlo = UIFont(name: "Menlo", size: size) {
            let descriptor = menlo.fontDescriptor.addingAttributes([
                .cascadeList: [UIFontDescriptor(fontAttributes: [.name: "PingFang SC"])]
            ])
            return UIFont(descriptor: descriptor, size: size)
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }
}

// MARK: - Math Attachment
// MARK: - Math Attachment

final class MathAttachment: NSTextAttachment {
    let latex: String
    let isBlock: Bool
    let theme: SelectableMarkdownTheme
    private(set) var renderedImage: UIImage?
    private(set) var renderedSize: CGSize = .zero
    /// [issue #117-4] Baseline offset from the rendered image's bottom edge,
    /// straight out of SwiftMath's typesetter. 0 = unknown (Unicode fallback),
    /// in which case `attachmentBounds` falls back to an approximation.
    private(set) var renderedBaselineFromBottom: CGFloat = 0
    private var didAttemptRender = false
    private var isKaTeXPending = false
    /// Both SwiftMath and KaTeX failed — show raw LaTeX fallback.
    private(set) var renderFailed = false
    var onLoad: (() -> Void)?

    init(latex: String, isBlock: Bool, theme: SelectableMarkdownTheme) {
        self.latex = latex
        self.isBlock = isBlock
        self.theme = theme
        super.init(data: nil, ofType: nil)
        self.image = Self.transparentImage
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static let transparentImage: UIImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
    }()

    private static let inlinePlaceholderHeight: CGFloat = 20
    private static let blockPlaceholderHeight: CGFloat = 44

    /// [T-ios-math-sync-render-at-measure] One-shot guard so a failed sync
    /// render is not retried on every glyph pass (render() does not cache
    /// failures, so retrying would re-parse per typeset).
    private var didAttemptSyncRender = false

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect, glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        // [T-ios-math-sync-render-at-measure] Render HERE, synchronously, before
        // ever answering with a placeholder.
        //
        // Why: the placeholder heights (44pt block / 20pt inline) participate in
        // the FIRST measurement of the cell, and that number is cached above us
        // by SwiftUI's hosting-configuration view graph — a cache that only
        // invalidates on a SwiftUI-visible state change, which a UIKit-side
        // async render completion is not. Six successive fixes cleared every
        // cache we own (layout memo 22df168cf, TextKit re-typeset c7ee9f16a,
        // representable size cache 48043be1e) and the device number never
        // moved: cell 6166 vs canvas 7154.7, both before and after, because
        // every fresh parse re-measured with placeholders and every correction
        // dead-ended at the SwiftUI layout cache. The only durable fix is for
        // the first measure to be RIGHT.
        //
        // Why this is affordable: SwiftMathRenderer.render is synchronous and
        // NSCache-backed (256 entries, keyed latex+mode+fontSize). The
        // scheduler's own telemetry on the failing device: 55 formulas in
        // 123ms wall, avg 0.62ms — and that work was ALREADY being done
        // moments after the measure; this moves it before the measure and the
        // cache makes every later parse of the same formula free. KaTeX
        // (WebView, truly async) stays on the scheduler path: if sync render
        // fails we fall through to the placeholder exactly as before.
        // Main-thread only — MTMathUILabel is UIKit.
        if renderedImage == nil, !renderFailed, !isKaTeXPending,
           !didAttemptSyncRender {
            if Thread.isMainThread {
                didAttemptSyncRender = true
                // Mirror performRender's chain exactly. This MUST include
                // renderFallback: SwiftMath cannot render CJK, so render()
                // returns nil for precisely the formulas this bug ships with
                // (`N_{A流}`, `公司整体股权市值 = …`) — instrumented on device:
                // every CJK formula logged "sync render FAILED" while ASCII
                // (`P_A`, `R`) rendered, which is why the placeholder height
                // still won the first measure. renderFallback is equally
                // synchronous and NSCache-backed ("F:" key).
                let result = SwiftMathRenderer.render(latex: latex, displayMode: isBlock, fontSize: theme.baseFontSize)
                    ?? SwiftMathRenderer.renderFallback(latex: latex, displayMode: isBlock, fontSize: theme.baseFontSize)
                if let result {
                    applyResult(result)
                    // Scheduler no longer needs to touch this attachment.
                    didAttemptRender = true
                    MathAttachment.syncRenderHits &+= 1
                    if MathAttachment.syncRenderHits <= 5 || MathAttachment.syncRenderHits % 50 == 0 {
                        AppLogger(category: "MathSync").info("[MathSync] SYNC-RENDERED #\(MathAttachment.syncRenderHits) h=\(String(format: "%.1f", result.image.size.height)) isBlock=\(self.isBlock) latex=\(self.latex.prefix(24))")
                    }
                } else {
                    AppLogger(category: "MathSync").info("[MathSync] sync render FAILED (falls to scheduler) latex=\(self.latex.prefix(24))")
                }
            } else {
                // [T-ios-math-sync-render-at-measure] Diagnostic: if measures
                // reach attachmentBounds OFF-MAIN, the sync path can never help
                // them and the placeholder participates in that measurement.
                MathAttachment.offMainSkips &+= 1
                if MathAttachment.offMainSkips <= 5 || MathAttachment.offMainSkips % 50 == 0 {
                    AppLogger(category: "MathSync").info("[MathSync] OFF-MAIN skip #\(MathAttachment.offMainSkips) — placeholder used in this measurement thread=\(Thread.current)")
                }
            }
        }
        if let img = renderedImage {
            let imgW = min(img.size.width, lineFrag.width)
            let imgH = img.size.height
            if isBlock {
                return CGRect(x: 0, y: 0, width: lineFrag.width, height: imgH)
            } else {
                // [issue #117-4] TRUE BASELINE ALIGNMENT.
                //
                // attachmentBounds' y is the offset from the surrounding text's
                // baseline to the image's BOTTOM edge (positive = up). So to
                // seat the formula's own baseline on the text baseline, the
                // bottom edge must sit `baselineFromBottom` BELOW it:
                //
                //     y = -baselineFromBottom
                //
                // and everything follows from the typesetter: `x` (no descender)
                // renders with a baseline at the image bottom → y ≈ 0, sitting
                // flush on the line; `y`/`p` carry a real descent → the tail
                // drops below the baseline exactly as in running text; `x²` gets
                // its extra height entirely above → the base `x` lands on the
                // baseline, pixel-aligned with a standalone `x`; an inline
                // fraction's denominator descends below the baseline, which is
                // the correct TeX behaviour (the fraction bar rides the math
                // axis ≈0.25em above the baseline) and NOT something to "fix" —
                // TextKit grows the line fragment to fit it.
                //
                // The previous cap-height/x-height centring could not express
                // any of this: it pinned a fixed fraction of the image height
                // regardless of where the content's baseline actually was,
                // leaving a 0–4pt residual that varied with the formula
                // (≈+2.4pt for bare lowercase, ≈+4pt with descenders, ≈0 with
                // superscripts).
                // >0 rather than >=0: an exactly-zero descent is also how
                // "unknown" is spelled (the Unicode fallback), and a formula
                // whose real descent rounds to 0 is indistinguishable from the
                // baseline sitting at the image bottom — which is what the
                // y=0 branch below produces anyway for that case.
                if renderedBaselineFromBottom > 0 {
                    return CGRect(x: 0, y: -renderedBaselineFromBottom, width: imgW, height: imgH)
                }
                // Unknown baseline (Unicode fallback bitmap — drawn by UIKit,
                // not SwiftMath). Approximate: that path draws a single text
                // line with 1pt top padding, so its baseline sits one descender
                // plus that padding up from the bottom.
                let fallbackFont = UIFont.systemFont(ofSize: theme.baseFontSize)
                let approxBaseline = min(abs(fallbackFont.descender) + 1, imgH)
                return CGRect(x: 0, y: -approxBaseline, width: imgW, height: imgH)
            }
        }
        if renderFailed {
            let fallbackFont = UIFont.monospacedSystemFont(ofSize: theme.baseFontSize * 0.85, weight: .regular)
            if isBlock {
                let constraintSize = CGSize(width: lineFrag.width, height: .greatestFiniteMagnitude)
                let textHeight = (latex as NSString).boundingRect(with: constraintSize, options: [.usesLineFragmentOrigin], attributes: [.font: fallbackFont], context: nil).height
                return CGRect(x: 0, y: 0, width: lineFrag.width, height: max(ceil(textHeight), Self.blockPlaceholderHeight))
            } else {
                // [T-ios-math-inline-fallback-width] Measure the actual fallback
                // text width so the label doesn't overflow. The old hardcoded 40pt
                // caused "G(..." truncation artifacts when the LaTeX string was
                // wider than 40pt.
                let textSize = (latex as NSString).size(withAttributes: [.font: fallbackFont])
                let w = min(ceil(textSize.width) + 4, lineFrag.width)
                let h = max(ceil(textSize.height), Self.inlinePlaceholderHeight)
                // [issue #117-4] Baseline-align the raw-LaTeX label too. This
                // branch draws monospaced TEXT, so its baseline is one
                // descender up from the bottom of the drawn line; `h` may have
                // been floored up to the placeholder height, and that extra
                // padding lands below the text, so count it in.
                let lineHeight = ceil(textSize.height)
                let baselineFromBottom = abs(fallbackFont.descender) + max(0, h - lineHeight)
                return CGRect(x: 0, y: -baselineFromBottom, width: w, height: h)
            }
        }
        if isBlock {
            return CGRect(x: 0, y: 0, width: lineFrag.width, height: Self.blockPlaceholderHeight)
        }
        return CGRect(x: 0, y: 0, width: 40, height: Self.inlinePlaceholderHeight)
    }

    /// Enqueue this attachment for async rendering. Idempotent — subsequent
    /// calls are no-ops once `didAttemptRender` is set. The actual render work
    /// is batched by `MathRenderScheduler` so a document with hundreds of
    /// formulas doesn't block the main thread. See `performRender()` for the
    /// synchronous render body.
    func beginRenderingIfNeeded() {
        MathAttachment.beginCount &+= 1
        if MathAttachment.beginCount <= 3 || MathAttachment.beginCount % 50 == 0 {
            AppLogger(category: "MathSched").info("[MathSched] beginRenderingIfNeeded #\(MathAttachment.beginCount) rendered=\(renderedImage != nil) attempted=\(didAttemptRender) katex=\(isKaTeXPending) isBlock=\(isBlock) latex=\(latex.prefix(30))")
        }
        guard renderedImage == nil, !didAttemptRender, !isKaTeXPending else { return }
        didAttemptRender = true
        MathRenderScheduler.shared.enqueue(self)
    }

    nonisolated(unsafe) static var beginCount: Int = 0
    // [T-ios-math-sync-render-at-measure] diagnostics
    nonisolated(unsafe) static var syncRenderHits: Int = 0
    nonisolated(unsafe) static var offMainSkips: Int = 0

    /// Synchronous render body. Called by `MathRenderScheduler` on the main
    /// thread from inside a yielding batch loop — do not call directly.
    func performRender() {
        if let result = SwiftMathRenderer.render(latex: latex, displayMode: isBlock, fontSize: theme.baseFontSize) {
            applyResult(result)
        } else if let fallback = SwiftMathRenderer.renderFallback(latex: latex, displayMode: isBlock, fontSize: theme.baseFontSize) {
            applyResult(fallback)
        } else {
            renderFailed = true
        }
        onLoad?()
    }

    private func applyResult(_ result: SwiftMathRenderResult) {
        renderedImage = result.image
        renderedSize = result.size
        renderedBaselineFromBottom = result.baselineFromBottom
        if inlineDrawable {
            self.image = result.image
        }
    }

    /// When true, `performRender` writes the rendered image into
    /// `NSTextAttachment.image` so UILabel / UITextView draw the formula
    /// via TextKit. Main-flow attachments leave this false and rely on a
    /// dedicated UIImageView overlay built in `updateAttachmentViews`.
    var inlineDrawable: Bool = false

    /// [T-ios-math-invisible-dark-mode] Drop the rendered bitmap so the next
    /// pass re-renders it in the current interface style.
    ///
    /// The image bakes in a concrete text color (it must — see
    /// `SwiftMathRenderer.interfaceStyle`), which makes it style-specific.
    /// `SwiftMathRenderer`'s own NSCache is already keyed by style, but THIS
    /// object holds a rendered image directly, and the Theme picker only flips
    /// `window.overrideUserInterfaceStyle` (ContentView.swift:6948) — nothing
    /// re-parses the markdown. Without this reset, formulas already on screen
    /// when the user switches theme keep their old-color bitmap and go blank.
    ///
    /// Deliberately keeps `renderFailed`: a formula SwiftMath cannot parse
    /// fails identically in both styles, and re-attempting it on every theme
    /// flip would just re-run the parse to reach the same answer.
    func invalidateRenderForInterfaceStyleChange() {
        guard renderedImage != nil else { return }
        renderedImage = nil
        renderedSize = .zero
        renderedBaselineFromBottom = 0
        didAttemptRender = false
        didAttemptSyncRender = false
        if inlineDrawable { self.image = nil }
        needsViewRebuild = true
    }

    /// [T-ios-math-invisible-dark-mode] Set when the cached bitmap was dropped
    /// and the overlay view built from it must be discarded too.
    ///
    /// BLOCK formulas don't draw through TextKit — `updateAttachmentViews`
    /// builds a dedicated `UIImageView` overlay per attachment and reuses it
    /// while the attachment's object identity is unchanged. That reuse check
    /// asks "is there a rendered image but no image view?", which a
    /// just-invalidated attachment fails (its image is nil), so the overlay
    /// holding the OLD-color bitmap survived and display formulas stayed blank
    /// after a live theme switch even though inline ones re-rendered correctly.
    /// Mirrors `ImageAttachment.needsViewRebuild`, which exists for the same
    /// reason (a file rewritten under a stable attachment identity).
    var needsViewRebuild: Bool = false

    func makeView(width: CGFloat) -> UIView {
        // Attempt render if not yet done (e.g. attachment reappeared after recycle)
        if renderedImage == nil && !didAttemptRender && !isKaTeXPending {
            beginRenderingIfNeeded()
        }

        if let img = renderedImage {
            let imgW = img.size.width
            let imgH = img.size.height
            let imgView = UIImageView(image: img)
            imgView.contentMode = .scaleAspectFit
            if isBlock {
                let clampedW = min(imgW, width)
                let container = UIView(frame: CGRect(x: 0, y: 0, width: width, height: imgH))
                imgView.frame = CGRect(x: (width - clampedW) / 2, y: 0, width: clampedW, height: imgH)
                container.addSubview(imgView)
                return container
            } else {
                // Use actual image size — the passed-in width may be stale from
                // placeholder bounds if SwiftMath rendered synchronously after the
                // layout pass already computed attachment bounds with nil image.
                imgView.frame = CGRect(x: 0, y: 0, width: imgW, height: imgH)
                return imgView
            }
        }
        // Placeholder while KaTeX renders, or final fallback: raw LaTeX
        let label = UILabel()
        label.text = latex
        label.font = .monospacedSystemFont(ofSize: theme.baseFontSize * 0.85, weight: .regular)
        label.textColor = theme.secondaryLabelColor
        label.numberOfLines = 0
        if isBlock {
            label.textAlignment = .center
            let fittingSize = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            let height = max(ceil(fittingSize.height), Self.blockPlaceholderHeight)
            label.frame = CGRect(x: 0, y: 0, width: width, height: height)
        } else {
            label.sizeToFit()
            label.frame = CGRect(x: 0, y: 0, width: min(label.frame.width, width), height: max(label.frame.height, Self.inlinePlaceholderHeight))
        }
        return label
    }
}
