import Foundation
import MaxMiCore

/// Per-region budgeting: how a page's rendered size is shared out and trimmed.
/// Split out of `GenericPageExtractor` verbatim — no behaviour change.
extension GenericPageExtractor {
    /// Rendered cost of a region's blocks. Sizing goes through the renderer so nothing has to
    /// re-render a page, and so a block never costs less than it prints.
    static func renderedSize(_ blocks: [Block]) -> Int {
        ContentRenderer.renderBlocks(blocks).count
    }

    /// `main` gets `totalBudget × mainShare`, `dialog` gets `× dialogShare`, all other regions
    /// share `× restShare` proportionally to their unbounded rendered size. Unused shares roll
    /// over rather than being lost:
    ///
    /// - `.dialog` is sized first and may borrow `main`'s whole share — and `rest`'s too when
    ///   there is no other region, so a bare alert window gets the full budget. A dialog is
    ///   short and is usually the most important thing on screen, so it is trimmed last and
    ///   only when even the rollover is not enough.
    /// - whatever `.dialog` and the rest regions leave unspent rolls into `main`, which is
    ///   therefore also what pays for a dialog that overflows its own share.
    ///
    /// Rest regions never grow past `restShare`: a long sidebar must not crowd out a short body.
    static func applyBudgets(_ regions: [Region], options: Options) -> (regions: [Region], truncated: Bool) {
        let total = max(1, options.totalBudget)
        let mainShare = budgetShare(total, options.mainShare)
        let dialogShare = budgetShare(total, options.dialogShare)
        let restShare = budgetShare(total, options.restShare)
        var truncated = false

        let rest = regions.filter { $0.kind != .main && $0.kind != .dialog }
        let dialogResult = trim(regions.first(where: { $0.kind == .dialog })?.blocks ?? [],
                                to: dialogShare + mainShare + (rest.isEmpty ? restShare : 0))
        truncated = truncated || dialogResult.truncated
        var mainAllowance = mainShare + dialogShare - renderedSize(dialogResult.blocks)

        let restSizes = rest.map { renderedSize($0.blocks) }
        let restTotal = restSizes.reduce(0, +)
        var trimmedRest: [Region] = []
        var restUsed = 0
        if restTotal <= restShare {
            trimmedRest = rest
            restUsed = restTotal
        } else {
            for (region, unbounded) in zip(rest, restSizes) {
                // restTotal > restShare >= 0 here, but the guard keeps the division total.
                let share = restTotal > 0
                    ? Int(Double(restShare) * Double(unbounded) / Double(restTotal))
                    : 0
                let result = trim(region.blocks, to: share)
                truncated = truncated || result.truncated
                if !result.blocks.isEmpty {
                    trimmedRest.append(Region(kind: region.kind, blocks: result.blocks))
                }
                restUsed += renderedSize(result.blocks)
            }
        }
        mainAllowance = max(0, mainAllowance + restShare - restUsed)

        let mainResult = trim(regions.first(where: { $0.kind == .main })?.blocks ?? [], to: mainAllowance)
        truncated = truncated || mainResult.truncated

        var out: [Region] = []
        for kind in ContentRenderer.regionOrder {
            switch kind {
            case .main:
                if !mainResult.blocks.isEmpty { out.append(Region(kind: .main, blocks: mainResult.blocks)) }
            case .dialog:
                if !dialogResult.blocks.isEmpty {
                    out.append(Region(kind: .dialog, blocks: dialogResult.blocks))
                }
            default:
                if let region = trimmedRest.first(where: { $0.kind == kind }) { out.append(region) }
            }
        }
        return (out, truncated)
    }

    /// One share of the budget. `Options` is public and mutable, so a nonsensical fraction must
    /// not be able to trap `Int(_:)` — `extract` is total.
    static func budgetShare(_ total: Int, _ fraction: Double) -> Int {
        guard fraction.isFinite, fraction > 0 else { return 0 }
        return Int(Double(total) * min(fraction, 1))
    }

    /// Drops whole blocks from the END of the list, so what survives is the top of the page.
    /// Never splits a block, so a single block larger than the allowance is kept whole.
    static func trim(_ blocks: [Block], to allowance: Int) -> (blocks: [Block], truncated: Bool) {
        var kept: [Block] = []
        var used = 0
        for block in blocks {
            let cost = ContentRenderer.renderBlock(block).count + (kept.isEmpty ? 0 : 1)
            if !kept.isEmpty, used + cost > allowance { break }
            kept.append(block)
            used += cost
        }
        return (kept, kept.count != blocks.count)
    }
}
