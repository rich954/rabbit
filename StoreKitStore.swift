import Foundation
import StoreKit
import ComposeApp

/// The App Store, for the Kotlin licence code ([[licensing-paywall]]).
///
/// StoreKit 2 is Swift-only, so this class exists; it implements the Kotlin `AppleStore` protocol and is
/// handed to Kotlin in `iOSApp.init`. It REPORTS what StoreKit says and decides nothing - trial, grace and
/// read-only are Kotlin's `LicencePolicy`, the same rules Android runs. Transactions are verified on the
/// phone by StoreKit (signed by Apple); nothing goes to a server of ours, because there isn't one.
///
/// Every reply goes back on the main thread.
final class StoreKitStore: NSObject, AppleStore {
    private let lock = NSLock()
    private var products: [String: Product] = [:]
    private var updates: Task<Void, Never>?

    private func onMain(_ work: @escaping () -> Void) { DispatchQueue.main.async(execute: work) }

    private func cached(_ id: String) -> Product? {
        lock.lock(); defer { lock.unlock() }
        return products[id]
    }

    private func remember(_ found: [Product]) {
        lock.lock(); defer { lock.unlock() }
        for p in found { products[p.id] = p }
    }

    // MARK: plans and prices

    func loadProducts(ids: [String], reply: AppleProductsReply) {
        Task {
            do {
                let found = try await Product.products(for: ids)
                remember(found)
                var out: [AppleProduct] = []
                for p in found {
                    guard let sub = p.subscription else { continue }
                    // A free trial is only offered to an Apple ID that has not had one in this group.
                    var trial: Int32 = 0
                    if let intro = sub.introductoryOffer, intro.paymentMode == .freeTrial {
                        if await sub.isEligibleForIntroOffer { trial = Int32(Self.days(intro.period)) }
                    }
                    out.append(AppleProduct(
                        productId: p.id,
                        displayPrice: p.displayPrice,
                        periodUnit: Self.unit(sub.subscriptionPeriod.unit),
                        periodValue: Int32(sub.subscriptionPeriod.value),
                        trialDays: trial
                    ))
                }
                onMain { reply.products(list: out) }
            } catch {
                onMain { reply.products(list: nil) }
            }
        }
    }

    // MARK: what this Apple ID holds

    func loadEntitlement(ids: [String], reply: AppleEntitlementReply) {
        Task {
            var best: Transaction?
            var others = false
            // Live subscriptions only - StoreKit includes one in its billing grace period, and leaves out
            // anything expired or refunded.
            for await result in Transaction.currentEntitlements {
                guard case .verified(let t) = result, t.productType == .autoRenewable else { continue }
                if ids.contains(t.productID) {
                    if t.revocationDate == nil, best == nil || t.purchaseDate > best!.purchaseDate { best = t }
                } else {
                    others = true
                }
            }

            if let t = best {
                var renews = true
                if let group = t.subscriptionGroupID,
                   let statuses = try? await Product.SubscriptionInfo.status(for: group) {
                    for s in statuses {
                        if case .verified(let info) = s.renewalInfo, info.originalTransactionID == t.originalID {
                            renews = info.willAutoRenew
                        }
                    }
                }
                let ms = Int64(t.originalPurchaseDate.timeIntervalSince1970 * 1000)
                let e = AppleEntitlement(state: "active", originalPurchaseMs: ms, productId: t.productID, willAutoRenew: renews)
                onMain { reply.entitlement(e: e) }
                return
            }

            // Nothing live. Never subscribed is simply "none"; but a shooter who HAS subscribed may have
            // renewed while this phone was offline, and StoreKit only learns that from the store - so ask
            // it, and if it cannot be asked, say "unreachable" and let the licence's offline grace decide.
            var group: String?
            for id in ids {
                if let r = await Transaction.latest(for: id), case .verified(let t) = r { group = t.subscriptionGroupID ?? group }
            }
            guard let g = group else {
                let e = AppleEntitlement(state: others ? "wrongProduct" : "none", originalPurchaseMs: 0, productId: nil, willAutoRenew: false)
                onMain { reply.entitlement(e: e) }
                return
            }
            do {
                let statuses = try await Product.SubscriptionInfo.status(for: g)
                // The live status carries its OWN transaction - whichever plan it is on. (Looking up the first
                // product id instead reported a live quarterly subscriber as lapsed.)
                if let s = statuses.first(where: { $0.state == .subscribed || $0.state == .inGracePeriod }),
                   case .verified(let t) = s.transaction {
                    var renews = true
                    if case .verified(let info) = s.renewalInfo { renews = info.willAutoRenew }
                    let ms = Int64(t.originalPurchaseDate.timeIntervalSince1970 * 1000)
                    let e = AppleEntitlement(state: "active", originalPurchaseMs: ms, productId: t.productID, willAutoRenew: renews)
                    onMain { reply.entitlement(e: e) }
                } else {
                    let e = AppleEntitlement(state: "none", originalPurchaseMs: 0, productId: nil, willAutoRenew: false)
                    onMain { reply.entitlement(e: e) }
                }
            } catch {
                let e = AppleEntitlement(state: "unreachable", originalPurchaseMs: 0, productId: nil, willAutoRenew: false)
                onMain { reply.entitlement(e: e) }
            }
        }
    }

    // MARK: buying, restoring, listening

    func purchase(productId: String, reply: ApplePurchaseReply) {
        Task {
            do {
                var product = cached(productId)
                if product == nil {
                    let found = try await Product.products(for: [productId])
                    remember(found)
                    product = found.first
                }
                guard let p = product else { onMain { reply.outcome(code: "failed") }; return }
                let result = try await p.purchase()
                switch result {
                case .success(let verification):
                    if case .verified(let t) = verification {
                        await t.finish()
                        onMain { reply.outcome(code: "purchased") }
                    } else {
                        onMain { reply.outcome(code: "failed") }
                    }
                case .pending:
                    onMain { reply.outcome(code: "pending") }
                case .userCancelled:
                    onMain { reply.outcome(code: "cancelled") }
                @unknown default:
                    onMain { reply.outcome(code: "failed") }
                }
            } catch {
                onMain { reply.outcome(code: "failed") }
            }
        }
    }

    func restore(reply: AppleDoneReply) {
        Task {
            try? await AppStore.sync()
            onMain { reply.done() }
        }
    }

    func listen(changed: AppleDoneReply) {
        updates?.cancel()
        updates = Task.detached {
            for await result in Transaction.updates {
                if case .verified(let t) = result { await t.finish() }
                DispatchQueue.main.async { changed.done() }
            }
        }
    }

    // MARK: periods

    private static func unit(_ u: Product.SubscriptionPeriod.Unit) -> String {
        switch u {
        case .day: return "day"
        case .week: return "week"
        case .month: return "month"
        case .year: return "year"
        @unknown default: return "month"
        }
    }

    private static func days(_ p: Product.SubscriptionPeriod) -> Int {
        switch p.unit {
        case .day: return p.value
        case .week: return p.value * 7
        case .month: return p.value * 30
        case .year: return p.value * 365
        @unknown default: return p.value
        }
    }
}
