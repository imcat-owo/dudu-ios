// Extracted from OpenMinis Views/Chat/SelectableMarkdownView.swift (engine part, no UI).
// renderMarkdownBlocks + MarkdownNSRenderer + CodeBlockAttachment + VideoAttachment.
// Dudu's UI is written separately; these are the non-UI rendering primitives.
import UIKit

/// Intended for one-shot rendering of completed messages (e.g. caching in AIChatViewModel).
@MainActor
func renderMarkdownBlocks(_ blocks: [BlockNode]) -> NSAttributedString {
    let renderer = MarkdownNSRenderer(baseFontSize: FontSettings.shared.scaledMessage(16.5))
    return renderer.render(blocks: blocks)
}

// MARK: - MarkdownNSRenderer

/// Converts `[BlockNode]` → `NSMutableAttributedString` for display in a UITextView.
final class MarkdownNSRenderer {
    private(set) var theme: SelectableMarkdownTheme

    /// Assistant message this renderer belongs to. Set by `SelectableMarkdownView`
    /// before each `render(blocks:)` call so inline image attachments can route
    /// tap gestures back to a paged gallery of all sibling images in the message.
    /// nil for contexts that don't provide a message (e.g. standalone previews).
    var messageId: UUID?
    /// Block identity for table slot-cache disambiguation. Set per render()
    /// call; when non-nil the slot key is simply messageId:blockId — immune
    /// to content collisions between tables with identical rows.
    var blockId: UUID?

    init(baseFontSize: CGFloat? = nil) {
        self.theme = SelectableMarkdownTheme(baseFontSize: baseFontSize)
    }

    func updateFontSize(_ size: CGFloat) {
        theme = SelectableMarkdownTheme(baseFontSize: size)
    }
    private var bodyLineSpacing: CGFloat { theme.baseFontSize * 0.25 }
    /// minisChat list item: .em(0.25) top margin
    private var listItemTopMargin: CGFloat { theme.baseFontSize * 0.25 }
    /// minisChat headings: .em(1) top and bottom
    private var headingTopMargin: CGFloat { theme.baseFontSize }
    private var headingBottomMargin: CGFloat { theme.baseFontSize }

    /// Reuse existing media attachments across re-renders to avoid reload flicker during streaming.
    var imageAttachmentCache: [String: ImageAttachment] = [:]
    var videoAttachmentCache: [String: VideoAttachment] = [:]
    var audioAttachmentCache: [String: AudioAttachment] = [:]
    /// Reuse code block attachments by index to preserve ObjectIdentifier across streaming re-renders.
    var codeBlockAttachmentCache: [Int: CodeBlockAttachment] = [:]
    /// Content hashes for code blocks, keyed by sequential index.
    var codeBlockContentHashes: [Int: Int] = [:]
    /// Reuse table attachments by content hash so the same table layout
    /// can be reused even when re-rendered in a different message slot
    /// or after the renderer was wiped for an unrelated reason.
    ///
    /// HangFix(2026-05-14): the previous `[Int: …]` keyed by streaming
    /// index meant that whenever `isNewMessage` triggered a renderer wipe
    /// (e.g. when the cell is reused with a different assistant message),
    /// every TableAttachment was rebuilt and its `cachedLayout` reset to
    /// nil — forcing typesetter to run a full per-cell `boundingRect`
    /// pass on each `attachmentBounds` query. On a 6-table message that
    /// was 27 s of main-thread typesetter pin (ips Minis-2026-05-14-094312).
    /// Keying by contentHash lets re-rendered identical tables hit the
    /// previously-built attachment + its `cachedLayout`.
    var tableAttachmentCache: [Int: TableAttachment] = [:]
    /// LRU eviction order for `tableAttachmentCache` so the cache can't
    /// grow without bound when the user scrolls through long history.
    /// Most-recently-touched contentHash sits at the end.
    var tableAttachmentLRU: [Int] = []
    private let tableAttachmentCacheCap = 64
    /// HangFix(2026-05-14) — per-slot identity preservation for in-progress
    /// streaming tables. When a table at the same `tableIndex` keeps
    /// growing row-by-row, its content hash changes every flush but it's
    /// the *same* visual table. Calling `update()` on the existing
    /// TableAttachment instance preserves NSTextAttachment identity, which
    /// keeps `updateUIView`'s prefix-equality fast path alive and lets
    /// `updateAttachmentViews` swap only the affected TableScrollView in
    /// place rather than tearing down every attachment view. Without this,
    /// every streamed token rebuilds every attachment subview → flicker +
    /// O(N) work per flush.
    /// Key: "<messageUUID>:<tableIndex>". Without messageId, two different
    /// messages that both have a table at idx=2 would falsely share a
    /// slot during render — the new message's first render would call
    /// `update()` on the previous message's table data. Tracking by
    /// (messageId, idx) keeps streaming-growth detection scoped to the
    /// single message that's actually growing.
    var tableSlotCache: [String: TableAttachment] = [:]
    /// Map TableAttachment instance → its current contentHash key in
    /// `tableAttachmentCache` so we can re-key when `update()` mutates an
    /// in-place attachment. Keyed by ObjectIdentifier hashValue.
    var tableAttachmentReverseKey: [ObjectIdentifier: Int] = [:]
    var mathAttachmentCache: [String: MathAttachment] = [:]
    private var codeBlockIndex = 0
    private var tableIndex = 0

    private struct RenderedBlock {
        let attributed: NSAttributedString
        let topMargin: CGFloat?
        let bottomMargin: CGFloat?
        let isBlockAttachment: Bool

        init(attributed: NSAttributedString, topMargin: CGFloat?, bottomMargin: CGFloat?, isBlockAttachment: Bool = false) {
            self.attributed = attributed
            self.topMargin = topMargin
            self.bottomMargin = bottomMargin
            self.isBlockAttachment = isBlockAttachment
        }
    }

    func render(blocks: [BlockNode]) -> NSAttributedString {
        codeBlockIndex = 0
        tableIndex = 0
        let t0 = CFAbsoluteTimeGetCurrent()
        let tableCountBefore = tableAttachmentCache.count

        let result = renderBlockSequence(blocks, listDepth: 0, quoteDepth: 0, tightSpacing: false).attributed
        let elapsed = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        // Only log noisy cases to keep signal-to-noise high: slow renders, or
        // renders that touched tables (streaming table bug suspect).
        if elapsed >= 20 || tableIndex > 0 {
            let level = elapsed >= 100 ? "🔥" : ""
            // [T-ios-markdown-rerender-burst] Include messageId + rendererPtr so
            // we can distinguish "1 textView rendering N times" from "N
            // different textViews rendering the same content" (cell reuse vs
            // SwiftUI re-invalidation of the same coordinator).
            let mid = messageId?.uuidString.prefix(8) ?? "?"
            let rId = String(ObjectIdentifier(self).hashValue & 0xFFFFFF, radix: 16)
            Self.rendererLogger.info("[RND]\(level) mid=\(mid) rnd=\(rId) blocks=\(blocks.count) tables=\(tableIndex) codeBlocks=\(codeBlockIndex) attrLen=\(result.length) \(String(format: "%.1f", elapsed))ms tableCache=\(tableCountBefore)→\(tableAttachmentCache.count)")
        }
        return result
    }

    fileprivate static let rendererLogger = AppLogger(category: "MarkdownRenderer")

    // MARK: Block Rendering

    private func renderBlock(_ block: BlockNode, listDepth: Int, quoteDepth: Int) -> RenderedBlock {
        switch block {
        case .paragraph(let content):
            return renderParagraph(content, quoteDepth: quoteDepth)
        case .heading(let level, let content):
            return renderHeading(level: level, content: content, quoteDepth: quoteDepth)
        case .codeBlock(let fenceInfo, let content):
            return renderCodeBlockAttachment(fenceInfo: fenceInfo, content: content, quoteDepth: quoteDepth)
        case .blockquote(let children):
            return renderBlockquote(children: children, listDepth: listDepth, quoteDepth: quoteDepth)
        case .bulletedList(let isTight, let items):
            return renderBulletedList(isTight: isTight, items: items, listDepth: listDepth, quoteDepth: quoteDepth)
        case .numberedList(let isTight, let start, let items):
            return renderNumberedList(isTight: isTight, start: start, items: items, listDepth: listDepth, quoteDepth: quoteDepth)
        case .taskList(let isTight, let items):
            return renderTaskList(isTight: isTight, items: items, listDepth: listDepth, quoteDepth: quoteDepth)
        case .table(let alignments, let rows):
            return renderTableAttachment(alignments: alignments, rows: rows)
        case .thematicBreak:
            return renderThematicBreakAttachment()
        case .htmlBlock(let content):
            return renderHTMLBlock(content, quoteDepth: quoteDepth)
        case .mathBlock(let content):
            return renderMathBlockAttachment(latex: content)
        }
    }

    private func renderBlockSequence(_ blocks: [BlockNode], listDepth: Int, quoteDepth: Int, tightSpacing: Bool) -> RenderedBlock {
        mergeRenderedBlocks(
            blocks.map { renderBlock($0, listDepth: listDepth, quoteDepth: quoteDepth) },
            tightSpacing: tightSpacing
        )
    }

    private func mergeRenderedBlocks(_ blocks: [RenderedBlock], tightSpacing: Bool) -> RenderedBlock {
        guard let first = blocks.first else {
            return RenderedBlock(attributed: NSAttributedString(), topMargin: nil, bottomMargin: nil)
        }

        let result = NSMutableAttributedString(attributedString: first.attributed)
        for i in 1..<blocks.count {
            let previous = blocks[i - 1]
            let current = blocks[i]
            let suppressBottom = tightSpacing && !previous.isBlockAttachment && !current.isBlockAttachment
            let previousBottom = suppressBottom ? 0 : (previous.bottomMargin ?? 0)
            let spacing = max(current.topMargin ?? 0, previousBottom)
            // Apply spacing as paragraphSpacing on the last paragraph of the accumulated result
            addSpacingAfterBlock(result, spacing: spacing)
            result.append(blockSeparator(height: spacing))
            result.append(current.attributed)
        }

        return RenderedBlock(
            attributed: result,
            topMargin: first.topMargin,
            bottomMargin: blocks.last?.bottomMargin
        )
    }

    private func blockSeparator(height: CGFloat) -> NSAttributedString {
        // Strategy: inject paragraphSpacing (after) on the previous block's trailing \n,
        // rather than trying to create an independent spacer paragraph.
        // This is handled by addSpacingAfterLastParagraph on the previous block.
        // Here we just return a plain \n to separate paragraphs.
        let separator = NSMutableAttributedString(string: "\n")
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 0
        style.maximumLineHeight = 0.01
        style.lineSpacing = 0
        separator.addAttributes([
            .font: UIFont.systemFont(ofSize: 0.01),
            .paragraphStyle: style,
        ], range: NSRange(location: 0, length: 1))
        return separator
    }

    /// Sets `paragraphSpacing` on the last paragraph of the attributed string
    /// so TextKit adds space after it.
    private func addSpacingAfterBlock(_ attrStr: NSMutableAttributedString, spacing: CGFloat) {
        guard attrStr.length > 0 else { return }
        // Find the last paragraph's range
        let text = attrStr.string as NSString
        let lastParaRange = text.paragraphRange(for: NSRange(location: max(text.length - 1, 0), length: 0))
        let style: NSMutableParagraphStyle
        if let existing = attrStr.attribute(.paragraphStyle, at: lastParaRange.location, effectiveRange: nil) as? NSParagraphStyle {
            style = existing.mutableCopy() as! NSMutableParagraphStyle
        } else {
            style = NSMutableParagraphStyle()
        }
        style.paragraphSpacing = spacing
        attrStr.addAttribute(.paragraphStyle, value: style, range: lastParaRange)
    }

    // MARK: Paragraph

    private func renderParagraph(_ inlines: [InlineNode], quoteDepth: Int) -> RenderedBlock {
        var baseAttrs = baseAttributes(quoteDepth: quoteDepth)
        let style: NSMutableParagraphStyle
        if let existing = baseAttrs[.paragraphStyle] as? NSParagraphStyle {
            style = existing.mutableCopy() as! NSMutableParagraphStyle
        } else {
            style = NSMutableParagraphStyle()
        }
        style.lineSpacing = bodyLineSpacing
        baseAttrs[.paragraphStyle] = style
        return RenderedBlock(
            attributed: renderInlines(inlines, baseAttributes: baseAttrs),
            topMargin: 0,
            bottomMargin: 12
        )
    }

    // MARK: Heading

    private func renderHeading(level: Int, content: [InlineNode], quoteDepth: Int) -> RenderedBlock {
        var attrs = baseAttributes(quoteDepth: quoteDepth)
        attrs[.font] = theme.headingFont(level: level)
        let style = NSMutableParagraphStyle()
        // minisChat doesn't set relativeLineSpacing for headings
        style.lineSpacing = 0
        if quoteDepth > 0 {
            style.headIndent = CGFloat(quoteDepth) * Self.quoteIndentPerLevel
            style.firstLineHeadIndent = style.headIndent
        }
        attrs[.paragraphStyle] = style
        return RenderedBlock(
            attributed: renderInlines(content, baseAttributes: attrs),
            topMargin: headingTopMargin,
            bottomMargin: headingBottomMargin
        )
    }

    // MARK: Code Block (NSTextAttachment)

    private func renderCodeBlockAttachment(fenceInfo: String?, content: String, quoteDepth: Int = 0) -> RenderedBlock {
        // [T-ios-codeblock-default-text-lang] A fence with no info string (a bare
        // ``` block) has no language. Default it to "text" so every code block
        // shows a language label (and reserves the header space) uniformly —
        // an unlabeled block now reads as "text" instead of being blank.
        let parsedLang = fenceInfo?.split(separator: " ").first.map(String.init)
        let language = (parsedLang?.isEmpty == false) ? parsedLang : "text"
        let trimmed = content.hasSuffix("\n") ? String(content.dropLast()) : content
        let idx = codeBlockIndex
        codeBlockIndex += 1

        var hasher = Hasher()
        hasher.combine(trimmed)
        hasher.combine(language)
        let contentHash = hasher.finalize()

        let attachment: CodeBlockAttachment
        if let cached = codeBlockAttachmentCache[idx], codeBlockContentHashes[idx] == contentHash {
            // Exact same content — reuse object so TextKit skips attachmentBounds recalc
            cached.blockIndex = idx
            attachment = cached
        } else {
            // Content changed or first time — create fresh object so TextKit recalculates bounds.
            // The previous view will be updated in-place by updateAttachmentViews via codeBlockViewCache.
            attachment = CodeBlockAttachment(code: trimmed, language: language, theme: theme, quoteDepth: quoteDepth, contentFingerprint: contentHash)
            attachment.blockIndex = idx
            codeBlockAttachmentCache[idx] = attachment
            codeBlockContentHashes[idx] = contentHash
        }

        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font, value: theme.baseFont, range: NSRange(location: 0, length: result.length))
        return RenderedBlock(
            attributed: result,
            topMargin: 6,
            bottomMargin: 4,
            isBlockAttachment: true
        )
    }

    // MARK: Blockquote

    private func renderBlockquote(children: [BlockNode], listDepth: Int, quoteDepth: Int) -> RenderedBlock {
        let newDepth = quoteDepth + 1
        let renderedChildren = renderBlockSequence(children, listDepth: listDepth, quoteDepth: newDepth, tightSpacing: false)
        let result = NSMutableAttributedString(attributedString: renderedChildren.attributed)
        // Mark the entire range with blockquote depth for bar drawing
        let fullRange = NSRange(location: 0, length: result.length)
        if fullRange.length > 0 {
            // Only fill in ranges that are missing a depth or carry a
            // shallower one. Children have already been rendered at
            // `newDepth + 1`…, so a blanket addAttribute (replace semantics)
            // used to stomp a nested quote's depth=2 back down to the outer
            // depth=1 — the text still indented for two levels (paragraph
            // style records that separately) but only one bar was drawn.
            var deeperRanges: [NSRange] = []
            result.enumerateAttribute(.blockquoteDepth, in: fullRange, options: []) { value, range, _ in
                let existing = (value as? Int) ?? 0
                if existing < newDepth { deeperRanges.append(range) }
            }
            for range in deeperRanges {
                result.addAttribute(.blockquoteDepth, value: newDepth, range: range)
            }
            // minisChat blockquote uses secondaryText color
            result.addAttribute(.foregroundColor, value: theme.secondaryLabelColor, range: fullRange)
        }
        // Blockquote inherits margins from children (no explicit markdownMargin in minisChat)
        return RenderedBlock(
            attributed: result,
            topMargin: renderedChildren.topMargin,
            bottomMargin: renderedChildren.bottomMargin
        )
    }

    // MARK: Bulleted List

    private func renderBulletedList(isTight: Bool, items: [RawListItem], listDepth: Int, quoteDepth: Int) -> RenderedBlock {
        var renderedItems: [RenderedBlock] = []
        let itemStartIndent = CGFloat(quoteDepth) * Self.quoteIndentPerLevel + CGFloat(listDepth) * Self.listIndentPerLevel
        let itemContentIndent = itemStartIndent + Self.listIndentPerLevel

        // HangFix(2026-05-13, re-restored 2026-05-14 with .ips evidence) —
        // Bullet glyphs MUST be Unicode characters, NOT NSTextAttachments.
        // Build 13 reverted bullets to SF-symbol NSTextAttachments per
        // user request to restore visual size — within 90s of install the
        // device hit a fresh 0x8BADF00D watchdog (ips Minis-2026-05-14-
        // 163330). Main-thread frame #1: `NSConcreteTextStorage
        // attribute:atIndex:effectiveRange:` — fillLayoutHole scanning
        // attribute runs. A 6-item list produces 6 image-attachment runs;
        // typesetter cost is O(glyphs × runs) and explodes whenever
        // setSize: forces a full re-layout.
        //
        // To keep bullets visually prominent (the original complaint about
        // "list got smaller") without paying the attachment-run tax, render the
        // Unicode glyph at 1.25× baseFont with bold weight + a small
        // baseline offset so it reads as an emphasized punctuation mark.
        // Depth → glyph:
        //   0  filled circle   "•"  U+2022
        //   1  hollow circle   "◦"  U+25E6
        //   2+ filled square   "▪"  U+25AA
        let bulletGlyph: String
        switch listDepth {
        case 0: bulletGlyph = "\u{2022}"   // •
        case 1: bulletGlyph = "\u{25E6}"   // ◦
        default: bulletGlyph = "\u{25AA}"  // ▪
        }
        let bulletColor = quoteDepth > 0 ? theme.secondaryLabelColor : theme.labelColor
        var bulletAttrs = baseAttributes(quoteDepth: quoteDepth)
        bulletAttrs[.foregroundColor] = bulletColor
        // 1.25× bold makes the Unicode bullet read at roughly the same
        // visual weight as the prior SF-symbol filled circle.
        bulletAttrs[.font] = UIFont.systemFont(ofSize: theme.baseFontSize * 1.25, weight: .bold)
        // Small negative baseline offset so the bullet sits near the
        // body text's x-height rather than its cap-height.
        bulletAttrs[.baselineOffset] = -theme.baseFontSize * 0.05

        for item in items {
            let itemResult = NSMutableAttributedString()
            itemResult.append(NSAttributedString(string: bulletGlyph, attributes: bulletAttrs))
            itemResult.append(NSAttributedString(string: "  ", attributes: baseAttributes(quoteDepth: quoteDepth)))
            let child = renderListItemChildren(item.children, listDepth: listDepth + 1, quoteDepth: quoteDepth, isTight: isTight)
            itemResult.append(child.attributed)
            applyListIndent(
                to: itemResult,
                firstLineIndent: itemStartIndent,
                continuationIndent: itemContentIndent
            )
            renderedItems.append(
                RenderedBlock(
                    attributed: itemResult,
                    topMargin: listItemTopMargin,
                    bottomMargin: child.bottomMargin
                )
            )
        }
        let merged = mergeRenderedBlocks(renderedItems, tightSpacing: isTight)
        return RenderedBlock(
            attributed: merged.attributed,
            topMargin: merged.topMargin,
            bottomMargin: max(merged.bottomMargin ?? 0, 16)
        )
    }

    // MARK: Numbered List

    private func renderNumberedList(isTight: Bool, start: Int, items: [RawListItem], listDepth: Int, quoteDepth: Int) -> RenderedBlock {
        var renderedItems: [RenderedBlock] = []
        let itemStartIndent = CGFloat(quoteDepth) * Self.quoteIndentPerLevel + CGFloat(listDepth) * Self.listIndentPerLevel
        let itemContentIndent = itemStartIndent + Self.listIndentPerLevel

        for (i, item) in items.enumerated() {
            let number = "\(start + i). "
            let itemResult = NSMutableAttributedString(string: number, attributes: baseAttributes(quoteDepth: quoteDepth))
            let child = renderListItemChildren(item.children, listDepth: listDepth + 1, quoteDepth: quoteDepth, isTight: isTight)
            itemResult.append(child.attributed)
            applyListIndent(
                to: itemResult,
                firstLineIndent: itemStartIndent,
                continuationIndent: itemContentIndent
            )
            renderedItems.append(
                RenderedBlock(
                    attributed: itemResult,
                    topMargin: listItemTopMargin,
                    bottomMargin: child.bottomMargin
                )
            )
        }
        let merged = mergeRenderedBlocks(renderedItems, tightSpacing: isTight)
        return RenderedBlock(
            attributed: merged.attributed,
            topMargin: merged.topMargin,
            bottomMargin: max(merged.bottomMargin ?? 0, 16)
        )
    }

    // MARK: Task List

    private func renderTaskList(isTight: Bool, items: [RawTaskListItem], listDepth: Int, quoteDepth: Int) -> RenderedBlock {
        var renderedItems: [RenderedBlock] = []
        let itemStartIndent = CGFloat(quoteDepth) * Self.quoteIndentPerLevel + CGFloat(listDepth) * Self.listIndentPerLevel
        let itemContentIndent = itemStartIndent + Self.listIndentPerLevel

        for item in items {
            let checkbox = item.isCompleted ? "☑ " : "☐ "
            let itemResult = NSMutableAttributedString(string: checkbox, attributes: baseAttributes(quoteDepth: quoteDepth))
            let child = renderListItemChildren(item.children, listDepth: listDepth + 1, quoteDepth: quoteDepth, isTight: isTight)
            itemResult.append(child.attributed)
            applyListIndent(
                to: itemResult,
                firstLineIndent: itemStartIndent,
                continuationIndent: itemContentIndent
            )
            renderedItems.append(
                RenderedBlock(
                    attributed: itemResult,
                    topMargin: listItemTopMargin,
                    bottomMargin: child.bottomMargin
                )
            )
        }
        let merged = mergeRenderedBlocks(renderedItems, tightSpacing: isTight)
        return RenderedBlock(
            attributed: merged.attributed,
            topMargin: merged.topMargin,
            bottomMargin: max(merged.bottomMargin ?? 0, 16)
        )
    }

    private func renderListItemChildren(_ children: [BlockNode], listDepth: Int, quoteDepth: Int, isTight: Bool) -> RenderedBlock {
        renderBlockSequence(children, listDepth: listDepth, quoteDepth: quoteDepth, tightSpacing: isTight)
    }

    private func applyListIndent(to attributed: NSMutableAttributedString, firstLineIndent: CGFloat, continuationIndent: CGFloat) {
        guard attributed.length > 0 else { return }

        let text = attributed.string as NSString
        let total = NSRange(location: 0, length: text.length)
        var cursor = total.location
        var isFirstParagraph = true

        while cursor < NSMaxRange(total) {
            let paragraphRange = text.paragraphRange(for: NSRange(location: cursor, length: 0))
            let effectiveRange = NSIntersectionRange(paragraphRange, total)
            guard effectiveRange.length > 0 else { break }

            let style: NSMutableParagraphStyle
            if let existing = attributed.attribute(.paragraphStyle, at: effectiveRange.location, effectiveRange: nil) as? NSParagraphStyle {
                style = existing.mutableCopy() as! NSMutableParagraphStyle
            } else {
                style = NSMutableParagraphStyle()
            }
            style.lineSpacing = max(style.lineSpacing, bodyLineSpacing)
            style.headIndent = max(style.headIndent, continuationIndent)
            if isFirstParagraph {
                style.firstLineHeadIndent = max(style.firstLineHeadIndent, firstLineIndent)
                isFirstParagraph = false
            } else {
                style.firstLineHeadIndent = max(style.firstLineHeadIndent, continuationIndent)
            }
            attributed.addAttribute(.paragraphStyle, value: style, range: effectiveRange)

            cursor = NSMaxRange(paragraphRange)
        }
    }

    // MARK: Table (NSTextAttachment)

    private func renderTableAttachment(alignments: [RawTableColumnAlignment], rows: [RawTableRow]) -> RenderedBlock {
        let idx = tableIndex
        tableIndex += 1

        var hasher = Hasher()
        hasher.combine(alignments)
        hasher.combine(rows)
        let contentHash = hasher.finalize()

        // [ios_session_open_last_cell_occluded] Slot key. The slot cache (Step 2
        // below) keeps a TableAttachment's identity stable while its content GROWS
        // during streaming, so a still-arriving table updates in place instead of
        // rebuilding every token. It must therefore be keyed by something that:
        //   (a) stays the SAME as one table streams in, but
        //   (b) DIFFERS between two genuinely distinct tables in the same message.
        //
        // The old key was "messageId:tableIndex". `tableIndex` resets to 0 at the
        // top of every `render(blocks:)` call — and in the V3 cell-per-block list
        // each assistant block (each table) is rendered by its OWN render() call,
        // so every table got tableIndex == 0. Two different tables in one message
        // therefore collided on "messageId:0", shared one attachment via Step 2,
        // and `update()`-overwrote each other → the on-screen table showed another
        // table's content (correct on first paint, swapped after a reuse pass):
        // two distinct tables in one message both keyed "<msgId>:0", same slot,
        // same shared TableAttachment, content flipping between them.
        //
        // Fix: always include tableIndex in the slot key. tableIndex
        // increments within a single render() call, so two tables in the
        // same block (same render pass) always get distinct keys — even if
        // their content is byte-for-byte identical.
        //
        // When blockId is available (V3 cell-per-block), include it to
        // also disambiguate tables across blocks that happen to share the
        // same tableIndex (e.g. each block's render() resets idx to 0).
        //
        // tableIndex resets per render() call, which is the right scope:
        // a streaming re-render of the same block sees the same table at
        // the same idx, so the slot key stays stable for in-place update.
        let slotKey = "\(messageId?.uuidString ?? "nil"):\(blockId?.uuidString ?? "_"):\(idx)"

        let attachment: TableAttachment
        // Step 1: same-content cache (any slot, any message). Lets the
        // SAME identical table that already lives in another cell share
        // its precomputed `cachedLayout` — the historical-message hang
        // fix from the 27s ips capture.
        if let cached = tableAttachmentCache[contentHash] {
            attachment = cached
            // Refresh LRU position.
            if let pos = tableAttachmentLRU.firstIndex(of: contentHash) {
                tableAttachmentLRU.remove(at: pos)
            }
            tableAttachmentLRU.append(contentHash)
            // Also pin this attachment to the current (message,slot) so
            // subsequent streaming growth at this slot updates it in
            // place rather than creating a new attachment instance.
            tableSlotCache[slotKey] = cached
            tableAttachmentReverseKey[ObjectIdentifier(cached)] = contentHash
            Self.rendererLogger.info("[RND] table#\(idx) CACHE HIT rows=\(rows.count) cols=\(alignments.count) hash=\(contentHash)")
        } else if let slotAttachment = tableSlotCache[slotKey] {
            // Step 2: streaming growth — same (message,slot), new content
            // hash. Mutate in place to keep NSTextAttachment identity
            // stable so the updateUIView prefix-equality fast path stays
            // alive and updateAttachmentViews swaps only this attachment's
            // TableScrollView (not every attachment view in the cell).
            // Without this, every streamed token would rebuild every
            // attachment subview — flicker + O(N) work per flush.
            slotAttachment.update(alignments: alignments, rows: rows)
            attachment = slotAttachment
            // Re-key the by-content cache: drop the old hash entry (if
            // any), insert under the new hash, refresh LRU.
            if let oldHash = tableAttachmentReverseKey[ObjectIdentifier(slotAttachment)] {
                if let pos = tableAttachmentLRU.firstIndex(of: oldHash) {
                    tableAttachmentLRU.remove(at: pos)
                }
                tableAttachmentCache.removeValue(forKey: oldHash)
            }
            tableAttachmentCache[contentHash] = slotAttachment
            tableAttachmentLRU.append(contentHash)
            tableAttachmentReverseKey[ObjectIdentifier(slotAttachment)] = contentHash
            Self.rendererLogger.info("[RND] table#\(idx) CACHE UPDATE rows=\(rows.count) cols=\(alignments.count) newHash=\(contentHash)")
        } else {
            // Step 3: brand new — neither same content nor same slot
            // recognized. Create a fresh TableAttachment.
            attachment = TableAttachment(alignments: alignments, rows: rows, theme: theme)
            tableAttachmentCache[contentHash] = attachment
            tableAttachmentLRU.append(contentHash)
            tableSlotCache[slotKey] = attachment
            tableAttachmentReverseKey[ObjectIdentifier(attachment)] = contentHash
            // LRU evict — keep the by-content cache bounded.
            while tableAttachmentLRU.count > tableAttachmentCacheCap {
                let evict = tableAttachmentLRU.removeFirst()
                if let dropped = tableAttachmentCache.removeValue(forKey: evict) {
                    tableAttachmentReverseKey.removeValue(forKey: ObjectIdentifier(dropped))
                    // Drop matching slot entries that point at the same
                    // attachment we just evicted — keeps tableSlotCache
                    // consistent with tableAttachmentCache.
                    for (slot, att) in tableSlotCache where att === dropped {
                        tableSlotCache.removeValue(forKey: slot)
                    }
                }
            }
            Self.rendererLogger.info("[RND] table#\(idx) CACHE MISS rows=\(rows.count) cols=\(alignments.count) newHash=\(contentHash) cacheSize=\(tableAttachmentCache.count)")
        }

        // Wrap the table attachment with U+2028 (LINE SEPARATOR) on both
        // sides. This forces TextKit1 to place the attachment in its own
        // line fragment and prevents `_fillLayoutHole` from trying to merge
        // it with adjacent content. Without these separators, when a tall
        // table (observed at ≥ 9 rows ~ 400pt) arrives via streaming,
        // TextKit1's line-break-fitting routine enters an infinite loop
        // inside `_performTextKit1LayoutCalculation` and hangs the main
        // thread long enough to trip the 10s scene-update watchdog
        // (0x8BADF00D). The U+2028 wrap was verified to work around this
        // on iOS 26 TextKit1. Replace with TextKit2 long-term.
        let result = NSMutableAttributedString()
        let separatorPara = NSMutableParagraphStyle()
        separatorPara.paragraphSpacing = 0
        separatorPara.paragraphSpacingBefore = 0
        separatorPara.lineSpacing = 0
        // Tiny font collapses the U+2028 line fragment to ~0pt. The separator's
        // only job is to force TextKit1 to place the table attachment in its own
        // line fragment (workaround for the 9+-row _fillLayoutHole hang); it
        // should not contribute visible vertical space. Previously used
        // theme.baseFont (16.5pt), which ate ~20pt above and below every table.
        let sepAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 0.01),
            .paragraphStyle: separatorPara,
        ]
        result.append(NSAttributedString(string: "\u{2028}", attributes: sepAttrs))
        let attachPart = NSMutableAttributedString(attachment: attachment)
        attachPart.addAttribute(.font, value: theme.baseFont, range: NSRange(location: 0, length: attachPart.length))
        result.append(attachPart)
        result.append(NSAttributedString(string: "\u{2028}", attributes: sepAttrs))
        return RenderedBlock(
            attributed: result,
            topMargin: theme.baseFontSize * 0.6,
            bottomMargin: theme.baseFontSize * 0.6,
            isBlockAttachment: true
        )
    }

    // MARK: Thematic Break (NSTextAttachment)

    private func renderThematicBreakAttachment() -> RenderedBlock {
        let attachment = ThematicBreakAttachment(theme: theme)
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font, value: theme.baseFont, range: NSRange(location: 0, length: result.length))
        return RenderedBlock(attributed: result, topMargin: 16, bottomMargin: 16, isBlockAttachment: true)
    }

    // MARK: HTML Block

    private func renderHTMLBlock(_ content: String, quoteDepth: Int) -> RenderedBlock {
        var attrs = baseAttributes(quoteDepth: quoteDepth)
        let style: NSMutableParagraphStyle
        if let existing = attrs[.paragraphStyle] as? NSParagraphStyle {
            style = existing.mutableCopy() as! NSMutableParagraphStyle
        } else {
            style = NSMutableParagraphStyle()
        }
        style.lineSpacing = bodyLineSpacing
        attrs[.paragraphStyle] = style
        return RenderedBlock(
            attributed: NSAttributedString(string: content, attributes: attrs),
            topMargin: 0,
            bottomMargin: 16
        )
    }

    // MARK: Media Attachments (inline .image nodes rendered as block-level attachments)

    private func renderImageAttachment(source: String) -> NSAttributedString {
        let attachment: ImageAttachment
        if let cached = imageAttachmentCache[source] {
            AppLogger(category: "AttachHotPath").info("[IMG][RENDER] REUSE src=\(ImageAttachment.shortSrc(source)) ptr=\(ObjectIdentifier(cached).hashValue & 0xFFFFFF) loaded=\(cached.loadedImage != nil)")
            imgLogger.info("[MinisImage][RenderAttach] REUSE cached attachment src=\(source) loaded=\(cached.loadedImage != nil) imgSize=\(cached.loadedImage.map { "\($0.size.width)x\($0.size.height)" } ?? "nil")")
            // Keep messageId fresh on reused attachments — the same renderer
            // instance may survive across different messages during cell reuse.
            cached.messageId = messageId
            // Fingerprint check: if the underlying file has been rewritten
            // since we last loaded (size or mtime changed), drop the
            // cached bitmap so the next draw re-reads from disk.
            let currentFp = minisMediaCacheKey(for: source)
            if let loadedFp = cached.loadedFingerprint, loadedFp != currentFp {
                AppLogger(category: "AttachHotPath").info("[IMG][RENDER] FINGERPRINT-DROP src=\(ImageAttachment.shortSrc(source)) old=\(loadedFp) new=\(currentFp) — bitmap invalidated, will reload")
                imgLogger.info("[MinisImage][RenderAttach] FINGERPRINT CHANGED src=\(source) old=\(loadedFp) new=\(currentFp) — invalidating cached image")
                cached.invalidateLoadedImage()
            }
            attachment = cached
        } else {
            AppLogger(category: "AttachHotPath").info("[IMG][RENDER] CREATE src=\(ImageAttachment.shortSrc(source)) cacheCount=\(self.imageAttachmentCache.count) — fresh ImageAttachment, ObjectIdentifier changed, view WILL be rebuilt")
            imgLogger.info("[MinisImage][RenderAttach] CREATE new ImageAttachment src=\(source) cacheCount=\(self.imageAttachmentCache.count)")
            attachment = ImageAttachment(source: source, theme: theme, messageId: messageId)
            imageAttachmentCache[source] = attachment
        }
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font, value: theme.baseFont, range: NSRange(location: 0, length: result.length))
        return result
    }

    private func renderVideoAttachment(source: String) -> NSAttributedString {
        let attachment: VideoAttachment
        if let cached = videoAttachmentCache[source] {
            attachment = cached
        } else {
            attachment = VideoAttachment(source: source, theme: theme)
            videoAttachmentCache[source] = attachment
        }
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font, value: theme.baseFont, range: NSRange(location: 0, length: result.length))
        return result
    }

    private func renderAudioAttachment(source: String) -> NSAttributedString {
        let attachment: AudioAttachment
        if let cached = audioAttachmentCache[source] {
            attachment = cached
        } else {
            attachment = AudioAttachment(source: source, theme: theme)
            audioAttachmentCache[source] = attachment
        }
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font, value: theme.baseFont, range: NSRange(location: 0, length: result.length))
        return result
    }

    // MARK: Inline Rendering

    /// Build the URL stored in a markdown link's `.link` attribute, undoing a
    /// double percent-encoding when present.
    ///
    /// [T-ios-file-preview-stale-cache] file_write returns a singly-encoded
    /// minis_url (e.g. `minis-clone://workspace/GitHub%E7%83%AD….md`). When the model
    /// embeds it in `[text](url)` and it passes through the markdown render
    /// pipeline, the literal `%` can get re-encoded to `%25`, yielding a
    /// double-encoded destination (`…%25E7…`). `URL(string:).path` then only
    /// peels one layer, leaving `%E7…`, which matches no file on disk — so the
    /// tap falls through to the parent workspace folder (the reported `.bin`
    /// folder symptom) instead of previewing the file. Detect that case and
    /// decode one extra layer before building the URL, so the `.link` carries
    /// the correct singly-encoded URL the tap handler / resolver expects. The
    /// resolver-side `subPathCandidates` tolerance stays as a backstop.
    private func normalizedLinkURL(from destination: String) -> URL? {
        let fallback = URL(string: destination)
        // Only minis-clone:// links are affected; everything else is untouched.
        guard destination.hasPrefix("minis-clone://") else {
            return fallback
        }
        // [T-minis-url-fullwidth-pipe-ios] URL(string:) returned nil — on iOS
        // Foundation this happens when the destination carries raw non-ASCII in
        // the path (e.g. a filename with U+FF5C `｜`, CJK, emoji that the LLM
        // emitted unencoded inside a minis-clone:// link). The link would otherwise be
        // dead (no .link attribute → not tappable). Percent-encode the path
        // portion segment-by-segment and retry. Idempotent: a segment that is
        // ALREADY validly encoded is left untouched, so an already-%EF%BD%9C URL
        // is never double-encoded (it also wouldn't reach here, since URL(string:)
        // accepts it — this is belt-and-suspenders).
        guard let base = fallback else {
            return encodeRawMinisURL(destination)
        }
        // A correctly singly-encoded minis_url decodes cleanly: `base.path`
        // contains no stray `%`. A double-encoded one (`%25E7…`) peels only one
        // layer here, leaving a literal `%E7…` in `.path`. That residual `%` is
        // the double-encoding signal — decode one more layer. A filename that
        // legitimately contains `%` is recovered to the same path either way
        // (the `%XX` of a real byte can't reappear), and the resolve-time
        // existence check (subPathCandidates) remains the final disambiguator.
        guard base.path.contains("%"),
              let once = destination.removingPercentEncoding,
              once.hasPrefix("minis-clone://"),
              let fixed = URL(string: once) else {
            return base
        }
        return fixed
    }


    private func renderInlines(_ inlines: [InlineNode], baseAttributes attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for inline in inlines {
            result.append(renderInline(inline, attributes: attrs))
        }
        return result
    }

    /// [T-ios-inline-code-long-path-wrap] Insert zero-width spaces after the
    /// separators inside an inline code span so TextKit can wrap a long token.
    ///
    /// Problem: a path like `/tmp/android_backup_tg_feedback_triage_2026.md` is
    /// a single unbreakable "word" under `.byWordWrapping` except at `/`. On a
    /// narrow screen TextKit therefore breaks after `/tmp/` — leaving half the
    /// first line empty and a full-width background pill around four visible
    /// characters — and then, since the 45-char remainder still overflows, it
    /// falls back to breaking mid-token, stranding a character or two on a
    /// third line. That is exactly the reported rendering.
    ///
    /// Fix: give TextKit legal break opportunities at the separators a reader
    /// already perceives as segment boundaries (`/ _ - .`), so a long span
    /// fills each line and breaks where a human would. U+200B is zero-width, so
    /// the rendered span is pixel-identical when it does NOT need to wrap —
    /// verified equal to 3 decimal places against the unmodified string — and
    /// short spans keep laying out on one line exactly as before.
    ///
    /// Copy safety: `plainTextWithTables` (the single choke point for selection
    /// copy, Read Selection and Add to Chat Input) already strips U+200B and
    /// U+200A, because the CJK emphasis pre-pass [T-md-cjk-emphasis-pairs]
    /// injects the same character. Tap-to-copy is unaffected either way — it
    /// reads the pristine string from `.inlineCodeText`, which is deliberately
    /// still set from the ORIGINAL `code`, not this padded form.
    ///
    /// Scope: body inline code only. Table-cell inline code (`renderCellInline`)
    /// is left alone — cell width is driven by measured content rather than a
    /// fixed container, so it has neither the symptom nor the same wrap model.
    static func breakableInlineCode(_ code: String) -> String {
        // Nothing to gain on spans that cannot overflow a line; skip the work
        // and keep the string byte-identical for the overwhelmingly common case.
        guard code.count > 24 else { return code }
        var out = ""
        out.reserveCapacity(code.count * 2)
        for ch in code {
            out.append(ch)
            // Only after a separator, never before: breaking before `/` would
            // orphan the separator onto the next line, which reads worse.
            if ch == "/" || ch == "_" || ch == "-" || ch == "." {
                out.append("\u{200B}")
            }
        }
        return out
    }

    private func renderInline(_ node: InlineNode, attributes attrs: [NSAttributedString.Key: Any]) -> NSAttributedString {
        switch node {
        case .text(let text):
            return NSAttributedString(string: text, attributes: attrs)

        case .code(let code):
            var codeAttrs = attrs
            codeAttrs[.font] = theme.inlineCodeFont
            codeAttrs[.foregroundColor] = theme.inlineCodeColor
            codeAttrs[.inlineCodeBackground] = true
            codeAttrs[.inlineCodeText] = code
            // Set .backgroundColor to trigger fillBackgroundRectArray in MinisLayoutManager
            // The actual color is drawn there with rounded corners; this just triggers the callback.
            codeAttrs[.backgroundColor] = theme.inlineCodeBackground
            // Add hair spaces for visual padding inside the background highlight.
            return NSAttributedString(string: "\u{200A}\(Self.breakableInlineCode(code))\u{200A}",
                                      attributes: codeAttrs)

        case .emphasis(let children):
            var emphAttrs = attrs
            if let font = attrs[.font] as? UIFont {
                emphAttrs[.font] = font.withTraits(.traitItalic)
            }
            return renderInlines(children, baseAttributes: emphAttrs)

        case .strong(let children):
            var strongAttrs = attrs
            if let font = attrs[.font] as? UIFont {
                let descriptor = font.fontDescriptor.addingAttributes([
                    .traits: [UIFontDescriptor.TraitKey.weight: UIFont.Weight.bold]
                ])
                strongAttrs[.font] = UIFont(descriptor: descriptor, size: font.pointSize)
            }
            return renderInlines(children, baseAttributes: strongAttrs)

        case .strikethrough(let children):
            var strikeAttrs = attrs
            strikeAttrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            return renderInlines(children, baseAttributes: strikeAttrs)

        case .link(let destination, let children):
            var linkAttrs = attrs
            if let url = normalizedLinkURL(from: destination) {
                linkAttrs[.link] = url
            }
            linkAttrs[.foregroundColor] = theme.linkColor
            linkAttrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            return renderInlines(children, baseAttributes: linkAttrs)

        case .image(let source, let children):
            let ext = URL(string: source)?.pathExtension.lowercased() ?? ""
            let altText = children.plainText
            imgLogger.info("[MinisImage][InlineParse] .image node src=\(source) ext=\(ext) alt=\(altText)")
            if nativeAudioExts.contains(ext) {
                return renderAudioAttachment(source: source)
            } else if nativeVideoExts.contains(ext) {
                return renderVideoAttachment(source: source)
            } else if nativeImageExts.contains(ext) || ext.isEmpty {
                imgLogger.info("[MinisImage][InlineParse] routing to IMAGE attachment src=\(source)")
                return renderImageAttachment(source: source)
            } else {
                // Unknown extension — render as image attachment (best guess)
                imgLogger.info("[MinisImage][InlineParse] unknown ext=\(ext), routing to IMAGE attachment (best guess) src=\(source)")
                return renderImageAttachment(source: source)
            }

        case .html(let html):
            return NSAttributedString(string: html, attributes: attrs)

        case .softBreak:
            return NSAttributedString(string: " ", attributes: attrs)

        case .lineBreak:
            return NSAttributedString(string: "\n", attributes: attrs)

        case .inlineMath(let latex):
            return renderInlineMathAttachment(latex: latex)
        }
    }

    // MARK: Helpers

    /// Per-depth indent: 3pt bar + 10pt leading padding (matches minisChat blockquote padding)
    private static let quoteIndentPerLevel: CGFloat = 13
    private static let listIndentPerLevel: CGFloat = 24

    private func baseAttributes(quoteDepth: Int) -> [NSAttributedString.Key: Any] {
        var attrs: [NSAttributedString.Key: Any] = [
            .font: theme.baseFont,
            .foregroundColor: quoteDepth > 0 ? theme.secondaryLabelColor : theme.labelColor,
        ]
        if quoteDepth > 0 {
            attrs[.blockquoteDepth] = quoteDepth
            let style = NSMutableParagraphStyle()
            let indent = CGFloat(quoteDepth) * Self.quoteIndentPerLevel
            style.headIndent = indent
            style.firstLineHeadIndent = indent
            style.lineSpacing = bodyLineSpacing
            attrs[.paragraphStyle] = style
        }
        return attrs
    }

    // MARK: Math Attachments

    private func renderMathBlockAttachment(latex: String) -> RenderedBlock {
        let key = "D:\(Int(theme.baseFontSize)):" + latex
        let attachment: MathAttachment
        if let cached = mathAttachmentCache[key] {
            attachment = cached
        } else {
            attachment = MathAttachment(latex: latex, isBlock: true, theme: theme)
            mathAttachmentCache[key] = attachment
        }
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font, value: theme.baseFont, range: NSRange(location: 0, length: result.length))
        return RenderedBlock(attributed: result, topMargin: bodyLineSpacing, bottomMargin: bodyLineSpacing, isBlockAttachment: true)
    }

    private func renderInlineMathAttachment(latex: String) -> NSAttributedString {
        let key = "I:\(Int(theme.baseFontSize)):" + latex
        let attachment: MathAttachment
        if let cached = mathAttachmentCache[key] {
            attachment = cached
        } else {
            attachment = MathAttachment(latex: latex, isBlock: false, theme: theme)
            mathAttachmentCache[key] = attachment
        }
        let result = NSMutableAttributedString(attachment: attachment)
        result.addAttribute(.font, value: theme.baseFont, range: NSRange(location: 0, length: result.length))
        return result
    }
}

// MARK: - Code Block Attachment

final class CodeBlockAttachment: NSTextAttachment {
    var code: String
    let language: String?
    let theme: SelectableMarkdownTheme
    let quoteDepth: Int
    /// Sequential index for view reuse across re-renders (set by MarkdownNSRenderer).
    var blockIndex: Int = 0
    /// [CodeGenDedup] Hash of (code, language), computed once by the renderer
    /// at creation. Folded into the invalidateCellSizeIfNeeded dedupe
    /// fingerprint so in-place code growth during streaming — which changes
    /// neither textStorage.length nor width — still defeats [SKIP-DEDUPE]
    /// and re-invalidates the host cell's height (the TableGenDedup
    /// counterpart for code blocks).
    let contentFingerprint: Int

    /// Left inset for blockquote nesting (matches text indent).
    var leftInset: CGFloat { CGFloat(quoteDepth) * 13 }

    init(code: String, language: String?, theme: SelectableMarkdownTheme, quoteDepth: Int = 0, contentFingerprint: Int = 0) {
        self.code = code
        self.language = language
        self.theme = theme
        self.quoteDepth = quoteDepth
        self.contentFingerprint = contentFingerprint
        super.init(data: nil, ofType: nil)
        // Provide a transparent image so UIKit doesn't draw a default placeholder
        self.image = Self.transparentImage
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static let transparentImage: UIImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
    }()

    static let topMargin: CGFloat = 6
    static let bottomMargin: CGFloat = 4

    /// Associated-object key retaining the copy-tap gesture target
    /// for the button's lifetime (see makeView).
    static var copyTapHandlerKey: UInt8 = 0
    /// Associated-object key for the settle `DispatchWorkItem`
    /// (debounced highlight + auto-collapse after streaming stops).
    static var settleWorkKey: UInt8 = 0
    /// Associated-object key for the wrapper's collapsed flag (Bool).
    static var wrapperCollapsedKey: UInt8 = 0
    /// Associated-object key for the wrapper's full content height (CGFloat).
    static var wrapperFullHeightKey: UInt8 = 0
    /// Associated-object key for the `onHeightChanged: () -> Void` closure,
    /// wired by the renderer (see updateAttachmentViews) — called after a
    /// manual collapse toggle so the host cell re-measures.
    static var heightChangedKey: UInt8 = 0
    /// Tag for the collapsed-state fade mask inside the container.
    static let fadeViewTag = 9871
    /// Tag for the header collapse chevron.
    static let chevronTag = 9872

    // MARK: [chat-ui] collapse state (Kelivo-style)

    /// Lines beyond which a code block becomes collapsible.
    static let collapseLineThreshold = 12
    /// Lines shown while collapsed.
    static let collapsedVisibleLines = 8
    /// fingerprint(code+language) → collapsed. Bounded (400) like the tool-group map.
    static var collapseState: [Int: Bool] = [:]
    /// Fingerprints the user toggled manually — the settle pass won't override these.
    static var manualCollapse: Set<Int> = []
    /// Bumped on every manual toggle; folded into the cell-size dedup
    /// fingerprint so a toggle defeats SKIP-DEDUPE and re-measures.
    static var collapseGeneration: UInt64 = 0

    static func fingerprint(code: String, language: String?) -> Int {
        var hasher = Hasher()
        hasher.combine(code)
        hasher.combine(language ?? "")
        return hasher.finalize()
    }

    static func setCollapseState(fingerprint fp: Int, collapsed: Bool, manual: Bool) {
        if collapseState.count > 400, let oldest = collapseState.keys.first {
            collapseState.removeValue(forKey: oldest)
        }
        collapseState[fp] = collapsed
        if manual {
            if manualCollapse.count > 400 { manualCollapse.removeFirst() }
            manualCollapse.insert(fp)
        }
    }

    static var metricsKey: UInt8 = 0
    static var toggleDebounceKey: UInt8 = 0

    /// Layout inputs cached on the wrapper so collapse toggles and streaming
    /// growth can re-layout without the attachment instance.
    final class CodeLayoutMetrics {
        let fullWidth: CGFloat
        let inset: CGFloat
        let contentWidth: CGFloat
        let topOffset: CGFloat
        var fullHeight: CGFloat
        var fittingWidth: CGFloat
        var collapsedHeight: CGFloat
        let maxCodeHeight: CGFloat
        let bottomPadding: CGFloat
        let language: String?
        let theme: SelectableMarkdownTheme
        init(fullWidth: CGFloat, inset: CGFloat, contentWidth: CGFloat, topOffset: CGFloat,
             fullHeight: CGFloat, fittingWidth: CGFloat, collapsedHeight: CGFloat,
             maxCodeHeight: CGFloat, bottomPadding: CGFloat,
             language: String?, theme: SelectableMarkdownTheme) {
            self.fullWidth = fullWidth
            self.inset = inset
            self.contentWidth = contentWidth
            self.topOffset = topOffset
            self.fullHeight = fullHeight
            self.fittingWidth = fittingWidth
            self.collapsedHeight = collapsedHeight
            self.maxCodeHeight = maxCodeHeight
            self.bottomPadding = bottomPadding
            self.language = language
            self.theme = theme
        }
    }

    /// Height of the first `lines` source lines (collapsed viewport).
    /// Same measurer as measureCodeHeight so the numbers agree.
    private func measurePrefixHeight(lines: Int) -> CGFloat {
        let prefix = code.components(separatedBy: "\n").prefix(lines).joined(separator: "\n")
        let codeStyle = NSMutableParagraphStyle()
        codeStyle.lineSpacing = 4
        codeStyle.lineBreakMode = .byClipping
        let attrStr = NSAttributedString(string: prefix.isEmpty ? " " : prefix, attributes: [
            .font: theme.codeBlockFont,
            .paragraphStyle: codeStyle,
        ])
        let tv = UITextView()
        tv.isScrollEnabled = false
        tv.textContainerInset = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainer.lineBreakMode = .byClipping
        tv.attributedText = attrStr
        return tv.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)).height
    }

    /// Re-layout the code view for a collapsed/expanded state.
    /// The wrapper's LOGICAL height is set immediately (the renderer reads
    /// view.frame right after layout to place the TextKit slot — same rule
    /// as the [CodeBlockGrow] comment in updateExistingView); only the
    /// visible children animate.
    static func applyCollapsedLayout(to wrapper: UIView, collapsed: Bool, animated: Bool) {
        guard let metrics = objc_getAssociatedObject(wrapper, &metricsKey) as? CodeLayoutMetrics,
              let container = wrapper.subviews.first,
              let scrollView = container.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView else { return }
        let visibleHeight = collapsed ? metrics.collapsedHeight : min(metrics.fullHeight, metrics.maxCodeHeight)
        let totalHeight = metrics.topOffset + visibleHeight + metrics.bottomPadding
        let applyFrames = {
            scrollView.frame = CGRect(x: 0, y: metrics.topOffset, width: metrics.contentWidth,
                                      height: visibleHeight + metrics.bottomPadding)
            // Collapsed: shrink the scrollable height so vertical scroll is
            // impossible, but keep horizontal panning for long lines.
            scrollView.contentSize = CGSize(width: metrics.fittingWidth,
                                            height: collapsed ? visibleHeight + metrics.bottomPadding : metrics.fullHeight)
            if collapsed { scrollView.contentOffset = .zero }
            if let fade = container.viewWithTag(fadeViewTag) {
                fade.isHidden = !collapsed
                fade.frame = CGRect(x: 0, y: metrics.topOffset + visibleHeight - 24,
                                    width: metrics.contentWidth, height: 24)
                fade.layer.sublayers?.first?.frame = fade.bounds
            }
            if let chevron = container.viewWithTag(chevronTag) as? UIImageView {
                chevron.image = UIImage(systemName: collapsed ? "chevron.down" : "chevron.up",
                                        withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
            }
            container.frame = CGRect(x: metrics.inset, y: topMargin, width: metrics.contentWidth, height: totalHeight)
        }
        // The wrapper's LOGICAL size is set immediately (the caller reads
        // view.frame right after layout to place the TextKit slot — same rule
        // as the [CodeBlockGrow] comment in updateExistingView); only the
        // visible children animate.
        wrapper.frame.size = CGSize(width: metrics.fullWidth, height: totalHeight + topMargin + bottomMargin)
        if animated {
            UIView.animate(withDuration: 0.22, delay: 0,
                           options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState],
                           animations: applyFrames)
        } else {
            applyFrames()
        }
        objc_setAssociatedObject(wrapper, &wrapperCollapsedKey, collapsed as Bool, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    /// Header-tap handler: flip the collapse state, re-layout, and ask the
    /// host cell to re-measure (via the generation-folded dedupe fingerprint).
    static func toggleCollapse(wrapper: UIView?, codeTextView: UITextView?) {
        guard let wrapper,
              let metrics = objc_getAssociatedObject(wrapper, &metricsKey) as? CodeLayoutMetrics else { return }
        let code = codeTextView?.text ?? ""
        let fp = fingerprint(code: code, language: metrics.language)
        let next = !(collapseState[fp] ?? false)
        setCollapseState(fingerprint: fp, collapsed: next, manual: true)
        collapseGeneration &+= 1
        applyCollapsedLayout(to: wrapper, collapsed: next, animated: true)
        var host: UIView? = wrapper.superview
        while let h = host, !(h is SelectableMarkdownTextView) { host = h.superview }
        (host as? SelectableMarkdownTextView)?.invalidateCellSizeIfNeeded()
    }

    /// Render `code` in a modal WKWebView (HTML preview entry).
    static func presentHTMLPreview(from button: UIButton, code: String) {
        let vc = UIViewController()
        vc.title = "HTML 预览"
        vc.view.backgroundColor = .systemBackground
        let webView = WKWebView(frame: .zero)
        webView.translatesAutoresizingMaskIntoConstraints = false
        vc.view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: vc.view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: vc.view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: vc.view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: vc.view.bottomAnchor),
        ])
        webView.loadHTMLString(code, baseURL: nil)
        let nav = UINavigationController(rootViewController: vc)
        vc.navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { _ in nav.dismiss(animated: true) })
        var presenter = button.window?.rootViewController
        while let next = presenter?.presentedViewController { presenter = next }
        presenter?.present(nav, animated: true)
    }

    /// Settle pass: runs 0.6s after the last streaming chunk (debounced).
    /// Applies syntax highlighting (skipped while streaming to avoid per-chunk
    /// re-tokenizing jank — Kelivo does the same) and auto-collapses long
    /// blocks unless the user manually toggled.
    static func applySettledState(to wrapper: UIView) {
        guard let metrics = objc_getAssociatedObject(wrapper, &metricsKey) as? CodeLayoutMetrics,
              let container = wrapper.subviews.first,
              let scrollView = container.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView,
              let codeTextView = scrollView.subviews.first(where: { $0 is UITextView }) as? UITextView else { return }
        let code = codeTextView.text ?? ""
        guard !code.isEmpty else { return }
        let highlighted = CodeSyntaxHighlighter.highlight(
            code, language: metrics.language, font: metrics.theme.codeBlockFont,
            plainColor: metrics.theme.codeBlockTextColor, background: metrics.theme.codeBlockBackground)
        let codeAttr = NSMutableAttributedString(attributedString: highlighted)
        let codeStyle = NSMutableParagraphStyle()
        codeStyle.lineSpacing = 4
        codeStyle.lineBreakMode = .byClipping
        codeAttr.addAttribute(.paragraphStyle, value: codeStyle,
                             range: NSRange(location: 0, length: codeAttr.length))
        codeTextView.attributedText = codeAttr

        let fp = fingerprint(code: code, language: metrics.language)
        let lines = code.components(separatedBy: "\n").count
        if lines > collapseLineThreshold, !manualCollapse.contains(fp), !(collapseState[fp] ?? false) {
            setCollapseState(fingerprint: fp, collapsed: true, manual: false)
            collapseGeneration &+= 1
            applyCollapsedLayout(to: wrapper, collapsed: true, animated: true)
            var host: UIView? = wrapper.superview
            while let h = host, !(h is SelectableMarkdownTextView) { host = h.superview }
            (host as? SelectableMarkdownTextView)?.invalidateCellSizeIfNeeded()
        }
    }

    /// Target object for the fallback tap gesture on the copy button —
    /// UITapGestureRecognizer needs an @objc target/action pair.
    final class CodeCopyTapHandler: NSObject {
        private let perform: () -> Void
        init(perform: @escaping () -> Void) { self.perform = perform }
        @objc func handleTap() { perform() }
    }

    /// [T-ios17-codeblock-copy-dead] Reference box for the double-fire guard:
    /// with both the control event AND the fallback gesture bound (see
    /// makeView), a version where the control path still works would invoke
    /// the copy twice per tap without it.
    final class CopyDebounce { var last = Date.distantPast }

    /// Cached content height from sizeThatFits, keyed by code hash + width.
    private var cachedContentHeight: (hash: Int, height: CGFloat)?

    /// Measure actual code text height using the same approach as makeView.
    private func measureCodeHeight() -> CGFloat {
        let codeHash = code.hashValue
        if let cached = cachedContentHeight, cached.hash == codeHash {
            return cached.height
        }
        let codeStyle = NSMutableParagraphStyle()
        codeStyle.lineSpacing = 4
        codeStyle.lineBreakMode = .byClipping
        let attrStr = NSAttributedString(string: code, attributes: [
            .font: theme.codeBlockFont,
            .paragraphStyle: codeStyle,
        ])
        let tv = UITextView()
        tv.isScrollEnabled = false
        tv.textContainerInset = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainer.lineBreakMode = .byClipping
        tv.attributedText = attrStr
        let h = tv.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)).height
        cachedContentHeight = (hash: codeHash, height: h)
        return h
    }

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect, glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        let width = lineFrag.width
        let topOffset: CGFloat = (language != nil && !language!.isEmpty) ? 28 : 12
        // [chat-ui] Collapsed blocks measure the 8-line viewport, not the full text.
        let collapsed = Self.collapseState[contentFingerprint] ?? false
        let contentHeight = collapsed ? measurePrefixHeight(lines: Self.collapsedVisibleLines) : measureCodeHeight()
        let bottomPadding: CGFloat = 12
        let maxCodeHeight: CGFloat = 400 - topOffset - bottomPadding
        let scrollHeight = min(contentHeight, maxCodeHeight)
        let totalHeight = topOffset + scrollHeight + bottomPadding
        let height = totalHeight + Self.topMargin + Self.bottomMargin
        return CGRect(x: 0, y: 0, width: width, height: height)
    }

    func makeView(width: CGFloat) -> UIView {
        let wrapper = UIView()
        wrapper.backgroundColor = .clear

        let inset = leftInset
        let contentWidth = width - inset

        let container = UIView()
        container.backgroundColor = theme.codeBlockBackground
        container.layer.cornerRadius = theme.codeBlockCornerRadius
        container.clipsToBounds = true

        var topOffset: CGFloat = 12
        let hasLanguage = language != nil && !language!.isEmpty

        // Language label
        if hasLanguage {
            let langLabel = UILabel()
            langLabel.text = language!.lowercased()
            langLabel.font = .systemFont(ofSize: 11, weight: .medium)
            langLabel.textColor = .white.withAlphaComponent(0.4)
            langLabel.frame = CGRect(x: 12, y: 8, width: contentWidth - 60, height: 16)
            container.addSubview(langLabel)
            topOffset = 28
        }

        // [chat-ui] Collapse bookkeeping (Kelivo-style). Fresh renders start
        // collapsed when long; a streaming first chunk is short, so this
        // doesn't fight the stream. State key = the attachment's content
        // fingerprint, like Kelivo's language+code-hash key.
        let lineCount = code.components(separatedBy: "\n").count
        let collapsible = lineCount > Self.collapseLineThreshold
        let fp = contentFingerprint
        if Self.collapseState[fp] == nil {
            Self.setCollapseState(fingerprint: fp, collapsed: collapsible, manual: false)
        }
        let collapsed = Self.collapseState[fp] ?? false
        let isHTML = (language ?? "").lowercased() == "html"

        // Scrollable code area (own the pan gesture here for reliable horizontal scroll)
        let scrollView = UIScrollView()
        scrollView.showsHorizontalScrollIndicator = true
        scrollView.showsVerticalScrollIndicator = true
        scrollView.alwaysBounceHorizontal = true
        scrollView.alwaysBounceVertical = true
        scrollView.clipsToBounds = true

        let codeTextView = UITextView()
        codeTextView.isEditable = false
        codeTextView.isSelectable = true
        codeTextView.isScrollEnabled = false // scrollView handles scrolling
        codeTextView.backgroundColor = .clear
        codeTextView.textContainerInset = UIEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        codeTextView.textContainer.lineFragmentPadding = 0
        codeTextView.textContainer.lineBreakMode = .byClipping

        // [chat-ui] Syntax-highlighted text (falls back to plain for
        // unknown languages / over-long input — never crashes).
        let codeStyle = NSMutableParagraphStyle()
        codeStyle.lineSpacing = 4
        codeStyle.lineBreakMode = .byClipping
        let highlighted = CodeSyntaxHighlighter.highlight(
            code, language: language, font: theme.codeBlockFont,
            plainColor: theme.codeBlockTextColor, background: theme.codeBlockBackground)
        let codeAttr = NSMutableAttributedString(attributedString: highlighted)
        codeAttr.addAttribute(.paragraphStyle, value: codeStyle,
                             range: NSRange(location: 0, length: codeAttr.length))
        codeTextView.attributedText = codeAttr

        // Measure content size (unconstrained width)
        let fitting = codeTextView.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        let contentHeight = fitting.height
        let fittingWidth = fitting.width
        codeTextView.frame = CGRect(x: 0, y: 0, width: fittingWidth, height: contentHeight)

        let maxCodeHeight: CGFloat = 400 - topOffset - 12
        let bottomPadding: CGFloat = 12
        let metrics = CodeLayoutMetrics(
            fullWidth: width, inset: inset, contentWidth: contentWidth, topOffset: topOffset,
            fullHeight: contentHeight, fittingWidth: fittingWidth,
            collapsedHeight: min(measurePrefixHeight(lines: Self.collapsedVisibleLines), maxCodeHeight),
            maxCodeHeight: maxCodeHeight, bottomPadding: bottomPadding,
            language: language, theme: theme)
        objc_setAssociatedObject(wrapper, &Self.metricsKey, metrics, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)

        scrollView.addSubview(codeTextView)
        scrollView.contentSize = CGSize(width: fittingWidth, height: contentHeight)
        container.addSubview(scrollView)
        wrapper.addSubview(container)

        // Collapsed fade mask (static gradient — never animated, so no
        // CAGradientLayer colorspace race; see ShimmerOverlay's note).
        let fade = UIView()
        fade.tag = Self.fadeViewTag
        fade.isUserInteractionEnabled = false
        let gradient = CAGradientLayer()
        let resolvedBg = theme.codeBlockBackground.resolvedColor(with: UITraitCollection.current)
        gradient.colors = [UIColor.clear.cgColor, resolvedBg.cgColor]
        fade.layer.addSublayer(gradient)
        container.addSubview(fade)

        // Initial layout (no animation on first paint).
        Self.applyCollapsedLayout(to: wrapper, collapsed: collapsed, animated: false)

        // Auto-scroll to bottom during streaming (only when expanded).
        if !collapsed {
            let bottomY = scrollView.contentSize.height - scrollView.bounds.height
            if bottomY > 0 {
                scrollView.contentOffset = CGPoint(x: 0, y: bottomY)
            }
        }

        // [chat-ui] Header tap → collapse toggle (long blocks only).
        if collapsible {
            let headerButton = UIButton(type: .custom)
            headerButton.backgroundColor = .clear
            headerButton.frame = CGRect(x: 0, y: 0, width: contentWidth, height: 28)
            headerButton.accessibilityLabel = collapsed ? "Expand code block" : "Collapse code block"
            let toggle: () -> Void = { [weak wrapper, weak codeTextView, weak headerButton] in
                guard let headerButton else { return }
                // Debounce: the dual bind below can deliver one physical tap twice.
                let now = Date()
                if let last = objc_getAssociatedObject(headerButton, &Self.toggleDebounceKey) as? Date,
                   now.timeIntervalSince(last) < 0.3 { return }
                objc_setAssociatedObject(headerButton, &Self.toggleDebounceKey, now, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                Self.toggleCollapse(wrapper: wrapper, codeTextView: codeTextView)
            }
            headerButton.addAction(UIAction { _ in toggle() }, for: .touchUpInside)
            let tapHandler = CodeCopyTapHandler(perform: toggle)
            let tap = UITapGestureRecognizer(target: tapHandler, action: #selector(CodeCopyTapHandler.handleTap))
            tap.cancelsTouchesInView = false
            headerButton.addGestureRecognizer(tap)
            objc_setAssociatedObject(headerButton, &Self.copyTapHandlerKey, tapHandler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            container.addSubview(headerButton)

            let chevron = UIImageView()
            chevron.tag = Self.chevronTag
            chevron.tintColor = .white.withAlphaComponent(0.4)
            chevron.contentMode = .center
            let rightButtons: CGFloat = isHTML ? 88 : 44
            chevron.frame = CGRect(x: contentWidth - rightButtons - 24, y: 6, width: 24, height: 16)
            container.addSubview(chevron)
            // Image (up/down) is set by applyCollapsedLayout — refresh once more
            // now that the chevron exists.
            Self.applyCollapsedLayout(to: wrapper, collapsed: collapsed, animated: false)
        }

        // Copy button — 44x44 hit area per Apple HIG, icon stays small visually
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 9, weight: .medium)
        let copyButton = UIButton(type: .system)
        copyButton.setImage(UIImage(systemName: "doc.on.doc", withConfiguration: iconConfig), for: .normal)
        copyButton.tintColor = .white.withAlphaComponent(0.5)
        copyButton.frame = CGRect(x: contentWidth - 44, y: 0, width: 44, height: 44)
        let debounce = CopyDebounce()
        let performCopy: () -> Void = { [weak codeTextView, weak copyButton] in
            // [T-ios17-codeblock-copy-dead] Double-fire guard: on versions
            // where the control event still works, a single tap now arrives
            // through BOTH the control path and the fallback gesture below.
            // The copy itself is idempotent, but guard anyway so the action
            // runs exactly once per physical tap.
            guard Date().timeIntervalSince(debounce.last) > 0.3 else { return }
            debounce.last = Date()
            // Read directly from the UITextView so we always copy the latest
            // content, even after updateExistingView replaced the attributed text.
            UIPasteboard.general.string = codeTextView?.text
            copyButton?.setImage(UIImage(systemName: "checkmark", withConfiguration: iconConfig), for: .normal)
            copyButton?.tintColor = AppearanceStudio.uiColorSnapshot(.success)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                copyButton?.setImage(UIImage(systemName: "doc.on.doc", withConfiguration: iconConfig), for: .normal)
                copyButton?.tintColor = .white.withAlphaComponent(0.5)
            }
        }
        copyButton.addAction(UIAction { _ in performCopy() }, for: .touchUpInside)
        // [T-ios16-codeblock-copy-regression] [T-ios17-codeblock-copy-dead]
        // ALWAYS also bind an independent tap gesture on the button, on every
        // OS version. History of this line:
        //   • iOS 16: .touchUpInside stopped firing (regressed between TF26
        //     and TF28) — the host text view's gesture/interaction graph
        //     cancels the control's touches. Fallback added, gated <17 on the
        //     assumption "iOS 17+ button works".
        //   • iOS 17: field report proved that assumption wrong — same dead
        //     button. The likely toucher is visible one screen up:
        //     addInteraction(_:) DROPS UIContextMenuInteraction on iOS 16 but
        //     KEEPS it on 17+, so 17 is exactly the version where the
        //     interaction's gesture graph exists AND no fallback was bound
        //     (18+ reworked the text-interaction stack and doesn't cancel).
        // A UITapGestureRecognizer attached to the button recognizes through
        // the gesture system rather than the control-event path, so it
        // survives the cancellation on every affected version. The version
        // gate is gone for good: it encoded a per-version guess that has now
        // been wrong twice, and the debounce in performCopy makes the
        // double-bind harmless where the control path does work.
        let tapHandler = CodeCopyTapHandler(perform: performCopy)
        let tap = UITapGestureRecognizer(target: tapHandler, action: #selector(CodeCopyTapHandler.handleTap))
        tap.cancelsTouchesInView = false
        copyButton.addGestureRecognizer(tap)
        objc_setAssociatedObject(copyButton, &Self.copyTapHandlerKey, tapHandler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        container.addSubview(copyButton)

        // [chat-ui] HTML preview button — renders the code in a WKWebView sheet.
        if isHTML {
            let previewButton = UIButton(type: .system)
            previewButton.setImage(UIImage(systemName: "eye", withConfiguration: iconConfig), for: .normal)
            previewButton.tintColor = .white.withAlphaComponent(0.5)
            previewButton.frame = CGRect(x: contentWidth - 88, y: 0, width: 44, height: 44)
            previewButton.accessibilityLabel = "Preview HTML"
            let showPreview: () -> Void = { [weak codeTextView, weak previewButton] in
                guard let previewButton else { return }
                let now = Date()
                if let last = objc_getAssociatedObject(previewButton, &Self.toggleDebounceKey) as? Date,
                   now.timeIntervalSince(last) < 0.5 { return }
                objc_setAssociatedObject(previewButton, &Self.toggleDebounceKey, now, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                Self.presentHTMLPreview(from: previewButton, code: codeTextView?.text ?? "")
            }
            previewButton.addAction(UIAction { _ in showPreview() }, for: .touchUpInside)
            let pvTapHandler = CodeCopyTapHandler(perform: showPreview)
            let pvTap = UITapGestureRecognizer(target: pvTapHandler, action: #selector(CodeCopyTapHandler.handleTap))
            pvTap.cancelsTouchesInView = false
            previewButton.addGestureRecognizer(pvTap)
            objc_setAssociatedObject(previewButton, &Self.copyTapHandlerKey, pvTapHandler, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            container.addSubview(previewButton)
        }

        return wrapper
    }

    /// Update the code text in an existing view created by `makeView(width:)` without recreating.
    ///
    /// [chat-ui] Streaming path: plain text only (highlighting is deferred to
    /// the debounced settle pass so per-chunk re-tokenizing doesn't jank the
    /// stream — Kelivo does the same). The view's current collapsed state is
    /// preserved and synced into the static map under the new fingerprint.
    func updateExistingView(_ wrapper: UIView) {
        guard let container = wrapper.subviews.first else { return }
        guard let scrollView = container.subviews.first(where: { $0 is UIScrollView }) as? UIScrollView else { return }
        guard let codeTextView = scrollView.subviews.first(where: { $0 is UITextView }) as? UITextView else { return }
        guard var metrics = objc_getAssociatedObject(wrapper, &Self.metricsKey) as? CodeLayoutMetrics else { return }

        let codeStyle = NSMutableParagraphStyle()
        codeStyle.lineSpacing = 4
        codeStyle.lineBreakMode = .byClipping
        let codeAttr = NSAttributedString(string: code, attributes: [
            .font: theme.codeBlockFont,
            .foregroundColor: theme.codeBlockTextColor,
            .paragraphStyle: codeStyle,
        ])
        codeTextView.attributedText = codeAttr

        let fitting = codeTextView.sizeThatFits(CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude))
        codeTextView.frame = CGRect(x: 0, y: 0, width: fitting.width, height: fitting.height)
        scrollView.contentSize = fitting

        // The fresh attachment has a new fingerprint, but the VIEW's visual
        // state is the truth mid-stream — sync the map so attachmentBounds
        // (called on the new attachment) agrees with the view.
        let fp = contentFingerprint
        let wrapperCollapsed = (objc_getAssociatedObject(wrapper, &Self.wrapperCollapsedKey) as? Bool) ?? false
        Self.setCollapseState(fingerprint: fp, collapsed: wrapperCollapsed,
                              manual: Self.manualCollapse.contains(fp))

        // Refresh metrics (content grew) and re-layout, preserving state.
        // [CodeBlockGrow] The wrapper's LOGICAL height is set immediately
        // (synchronously) because the caller reads `view.frame.size.height`
        // right after this returns to lay out the TextKit attachment slot +
        // the enclosing cell — animating that would desync the code frame
        // from the text flow. Only the visible children animate.
        let oldVisible = wrapperCollapsed ? metrics.collapsedHeight : min(metrics.fullHeight, metrics.maxCodeHeight)
        let oldTotal = metrics.topOffset + oldVisible + metrics.bottomPadding
        metrics.fullHeight = fitting.height
        metrics.fittingWidth = fitting.width
        metrics.collapsedHeight = min(measurePrefixHeight(lines: Self.collapsedVisibleLines), metrics.maxCodeHeight)
        let newTotal = metrics.topOffset + min(metrics.fullHeight, metrics.maxCodeHeight) + metrics.bottomPadding
        let heightGrew = newTotal > oldTotal + 0.5
        Self.applyCollapsedLayout(to: wrapper, collapsed: wrapperCollapsed, animated: heightGrew)

        // Auto-scroll to bottom during streaming (only when expanded).
        if !wrapperCollapsed {
            let bottomY = scrollView.contentSize.height - scrollView.bounds.height
            if bottomY > 0 {
                scrollView.contentOffset = CGPoint(x: scrollView.contentOffset.x, y: bottomY)
            }
        }

        // Debounced settle: highlight + auto-collapse long blocks.
        if let old = objc_getAssociatedObject(wrapper, &Self.settleWorkKey) as? DispatchWorkItem {
            old.cancel()
        }
        let work = DispatchWorkItem { [weak wrapper] in
            guard let wrapper else { return }
            Self.applySettledState(to: wrapper)
        }
        objc_setAssociatedObject(wrapper, &Self.settleWorkKey, work, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
}

// MARK: - Video Attachment

final class VideoAttachment: NSTextAttachment {
    let source: String
    let theme: SelectableMarkdownTheme
    private(set) var thumbnail: UIImage?
    private var isLoading = false
    private var resolvedURL: URL?
    var onLoad: (() -> Void)?

    init(source: String, theme: SelectableMarkdownTheme) {
        self.source = source
        self.theme = theme
        super.init(data: nil, ofType: nil)
        self.image = Self.transparentImage
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static let transparentImage: UIImage = {
        UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in }
    }()

    private static let placeholderHeight: CGFloat = 200

    override func attachmentBounds(for textContainer: NSTextContainer?, proposedLineFragment lineFrag: CGRect, glyphPosition position: CGPoint, characterIndex charIndex: Int) -> CGRect {
        let width = min(lineFrag.width, 400)
        if let thumb = thumbnail {
            let aspect = thumb.size.height / max(thumb.size.width, 1)
            let h = min(width * aspect, UIScreen.main.bounds.height / 2)
            // +24 for filename label below
            return CGRect(x: 0, y: 0, width: lineFrag.width, height: h + 24)
        }
        // [T-ios-video-squish] No thumbnail yet — use the recorded display
        // size (track-metadata probe or a previous run's thumbnail) so a
        // portrait video's placeholder already has the right aspect ratio
        // instead of the fixed 200pt box. Mirrors ImageAttachment's
        // recorded-size fallback (8f9ffc437).
        if let known = NativeMediaImageCache.shared.size(forSource: source),
           known.width > 0 {
            let aspect = known.height / known.width
            let h = min(width * aspect, UIScreen.main.bounds.height / 2)
            return CGRect(x: 0, y: 0, width: lineFrag.width, height: h + 24)
        }
        return CGRect(x: 0, y: 0, width: lineFrag.width, height: Self.placeholderHeight)
    }

    func beginLoadingIfNeeded() {
        guard thumbnail == nil, !isLoading else { return }
        isLoading = true

        let src = source
        Task.detached(priority: .userInitiated) {
            var fileURL: URL?
            if let url = URL(string: src), url.scheme == "minis-clone" {
                fileURL = resolveMinisFileURLForNativeText(url: url)
            } else if let url = URL(string: src) {
                fileURL = url
            }

            guard let fileURL else {
                await MainActor.run { self.isLoading = false }
                return
            }

            // Check thumbnail cache
            let cacheKey = fileURL.path
            if let cached = NativeMediaImageCache.shared.image(for: "thumb:" + cacheKey) {
                await MainActor.run {
                    self.thumbnail = cached
                    self.resolvedURL = fileURL
                    self.isLoading = false
                    self.onLoad?()
                    // Cell-side height re-measure: attachmentBounds now returns
                    // aspect-fit height instead of the 200pt placeholder, so
                    // the surrounding cell must invalidate its cached height.
                    // Without this, the cell stays at the placeholder height
                    // until some unrelated event (scroll, reconfigure) forces
                    // a re-measure (the "appears half-rendered, then snaps
                    // 10s later" bug).
                    NotificationCenter.default.post(name: .minisAttachmentSizeChanged, object: src)
                }
                return
            }

            let asset = AVAsset(url: fileURL)

            // [T-ios-video-squish] Probe the video track's display size BEFORE
            // generating the thumbnail. Track metadata (naturalSize +
            // preferredTransform) is read from the container header — far
            // lighter than AVAssetImageGenerator, which spins up a decoder for
            // a real frame. Recording it now lets attachmentBounds return the
            // true aspect ratio while the (slow) thumbnail is still cooking —
            // the 8f9ffc437 header-probe idea applied to video. Orientation is
            // handled by applying preferredTransform (portrait phone captures
            // store a landscape naturalSize + 90° transform).
            if NativeMediaImageCache.shared.size(forSource: src) == nil,
               let track = try? await asset.loadTracks(withMediaType: .video).first,
               let (natural, transform) = try? await track.load(.naturalSize, .preferredTransform) {
                let rect = CGRect(origin: .zero, size: natural).applying(transform)
                let displaySize = CGSize(width: abs(rect.width), height: abs(rect.height))
                if displaySize.width > 0, displaySize.height > 0 {
                    NativeMediaImageCache.shared.recordSize(displaySize, forSource: src)
                    imgLogger.info("[MinisVideo][Probe] track size=\(Int(displaySize.width))x\(Int(displaySize.height)) src=\(src) — publishing before thumbnail generation")
                    await MainActor.run {
                        NotificationCenter.default.post(name: .minisAttachmentSizeChanged, object: src)
                    }
                }
            }

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 400, height: 400)

            var thumb: UIImage?
            do {
                let (cgImage, _) = try await generator.image(at: .zero)
                thumb = UIImage(cgImage: cgImage)
            } catch {
                // Fallback: no thumbnail
            }

            if let thumb {
                NativeMediaImageCache.shared.set(thumb, for: "thumb:" + cacheKey)
                // Durable size record (the in-memory thumb cache dies on cold
                // start; the recorded size persists in UserDefaults). Also
                // covers assets whose track probe failed.
                NativeMediaImageCache.shared.recordSize(thumb.size, forSource: src)
            }

            await MainActor.run {
                self.thumbnail = thumb
                self.resolvedURL = fileURL
                self.isLoading = false
                self.onLoad?()
                if thumb != nil {
                    NotificationCenter.default.post(name: .minisAttachmentSizeChanged, object: src)
                }
            }
        }
    }

    func makeView(width: CGFloat) -> UIView {
        let maxW = min(width, 400)
        if let thumb = thumbnail {
            return makeThumbnailView(thumb, maxWidth: maxW, totalWidth: width)
        } else {
            return makePlaceholderView(maxWidth: maxW, totalWidth: width)
        }
    }

    private func makeThumbnailView(_ thumb: UIImage, maxWidth: CGFloat, totalWidth: CGFloat) -> UIView {
        let aspect = thumb.size.height / max(thumb.size.width, 1)
        let h = min(maxWidth * aspect, UIScreen.main.bounds.height / 2)

        let container = UIView(frame: CGRect(x: 0, y: 0, width: totalWidth, height: h + 24))
        container.backgroundColor = .clear

        let thumbView = UIImageView(image: thumb)
        thumbView.contentMode = .scaleAspectFill
        thumbView.frame = CGRect(x: 0, y: 0, width: maxWidth, height: h)
        thumbView.layer.cornerRadius = 8
        thumbView.clipsToBounds = true
        container.addSubview(thumbView)

        // Dark overlay
        let overlay = UIView(frame: thumbView.frame)
        overlay.backgroundColor = UIColor.black.withAlphaComponent(0.3)
        overlay.layer.cornerRadius = 8
        overlay.clipsToBounds = true
        container.addSubview(overlay)

        // Play icon
        let iconConfig = UIImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        let playIcon = UIImageView(image: UIImage(systemName: "play.circle.fill", withConfiguration: iconConfig))
        playIcon.tintColor = .white.withAlphaComponent(0.9)
        playIcon.sizeToFit()
        playIcon.center = CGPoint(x: maxWidth / 2, y: h / 2)
        container.addSubview(playIcon)

        // Filename label with film icon
        let filename = source.components(separatedBy: "/").last ?? source
        let filmIconCfg = UIImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        let filmIcon = UIImageView(image: UIImage(systemName: "film", withConfiguration: filmIconCfg))
        filmIcon.tintColor = .secondaryLabel
        filmIcon.frame = CGRect(x: 0, y: h + 6, width: 14, height: 12)
        container.addSubview(filmIcon)

        let label = UILabel()
        label.text = filename
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabel
        label.lineBreakMode = .byTruncatingMiddle
        label.frame = CGRect(x: 18, y: h + 4, width: maxWidth - 18, height: 16)
        container.addSubview(label)

        // Tap to play
        container.isUserInteractionEnabled = true
        let tap = VideoTapGesture(target: nil, action: nil)
        tap.fileURL = resolvedURL
        tap.addTarget(tap, action: #selector(VideoTapGesture.handleTap))
        container.addGestureRecognizer(tap)

        return container
    }

    private func makePlaceholderView(maxWidth: CGFloat, totalWidth: CGFloat) -> UIView {
        let h = Self.placeholderHeight
        let container = UIView(frame: CGRect(x: 0, y: 0, width: totalWidth, height: h))

        let bg = UIView(frame: CGRect(x: 0, y: 0, width: maxWidth, height: h))
        bg.backgroundColor = .secondarySystemBackground
        bg.layer.cornerRadius = 8
        bg.clipsToBounds = true
        container.addSubview(bg)

        let iconConfig = UIImage.SymbolConfiguration(pointSize: 44, weight: .regular)
        let icon = UIImageView(image: UIImage(systemName: "play.circle.fill", withConfiguration: iconConfig))
        icon.tintColor = .tertiaryLabel
        icon.sizeToFit()
        icon.center = CGPoint(x: bg.bounds.midX, y: bg.bounds.midY - 12)
        bg.addSubview(icon)

        let filename = source.components(separatedBy: "/").last ?? source
        let label = UILabel()
        label.text = filename
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.frame = CGRect(x: 8, y: icon.frame.maxY + 8, width: bg.bounds.width - 16, height: 16)
        bg.addSubview(label)

        return container
    }
}

private extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        let combined = fontDescriptor.symbolicTraits.union(traits)
        guard let descriptor = fontDescriptor.withSymbolicTraits(combined) else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}
