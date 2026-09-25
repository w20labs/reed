import XCTest
@testable import Reed

/// The built-in vocabulary pass is pure and deterministic, so coverage is
/// generated from the table itself: every `always` entry, every `gated` entry
/// in both states, and every `never` exclusion.
final class BuiltinVocabTests: XCTestCase {
    private let allDomains = Set(VocabDomain.allCases)

    private func apply(_ text: String, active: Set<VocabDomain> = [.general]) -> CorrectionResult {
        CorrectionPass.apply(text, active: active)
    }

    // MARK: - table loops

    func testEveryAlwaysEntrySubstitutesWhenItsDomainIsActive() {
        for (domain, entries) in VocabularyData.always {
            for entry in entries {
                let source = entry.source.joined(separator: " ")
                let out = apply("please check \(source) for details", active: allDomains).text
                XCTAssertTrue(out.contains(entry.replacement),
                              "\(domain).always \(source) → expected \(entry.replacement) in: \(out)")
            }
        }
    }

    func testNonGeneralAlwaysEntriesAreInertWhileTheirDomainIsInactive() {
        for (domain, entries) in VocabularyData.always where domain != .general {
            for entry in entries {
                let source = entry.source.joined(separator: " ")
                let input = "please check \(source) for details"
                XCTAssertEqual(apply(input).text, input,
                               "\(domain).always \(source) fired without its domain")
            }
        }
    }

    func testEveryGatedEntryInBothStates() {
        for (domain, entries) in VocabularyData.gated {
            for entry in entries {
                let source = entry.source.joined(separator: " ")
                let input = "we discussed \(source) yesterday"
                XCTAssertEqual(apply(input).text, input,
                               "gated \(source) fired while \(domain) inactive")
                let out = apply(input, active: allDomains).text
                XCTAssertTrue(out.contains(entry.replacement),
                              "gated \(source) → expected \(entry.replacement) in: \(out)")
            }
        }
    }

    func testEveryNeverSourceSurvivesEvenWithAllDomainsActive() {
        // The regression tests that matter most (spec §7): these were all
        // candidates, and each was rejected for a documented reason.
        for source in VocabularyData.neverSources {
            let input = "we talked about \(source) at length yesterday."
            XCTAssertEqual(apply(input, active: allDomains).text, input,
                           "never-listed \(source) was altered")
        }
    }

    // MARK: - matching mechanics

    func testLongestMatchWins() {
        let out = apply("my air pods pro died").text
        XCTAssertTrue(out.contains("AirPods Pro"), out)
        XCTAssertFalse(out.contains("AirPods Pro Pro"), out)
    }

    func testNeverMatchesInsideAWord() {
        let input = "the kiosk is open"   // "ios" inside "kiosk"
        XCTAssertEqual(apply(input, active: allDomains).text, input)
    }

    func testCapitalizationOnlyEntryIsIdempotentAndQuiet() {
        let input = "we run Kubernetes at scale"
        let result = apply(input, active: allDomains)
        XCTAssertEqual(result.text, input)
        XCTAssertTrue(result.substitutions.isEmpty, "no-op substitution recorded")
    }

    func testSubstitutionRecordIsComplete() {
        let result = apply("open x code now", active: allDomains)
        XCTAssertEqual(result.text, "open Xcode now")
        XCTAssertEqual(result.substitutions.count, 1)
        let sub = result.substitutions[0]
        XCTAssertEqual(sub.original, "x code")
        XCTAssertEqual(sub.replacement, "Xcode")
        XCTAssertEqual(sub.domain, .engineering)
        let start = result.text.index(result.text.startIndex, offsetBy: sub.range.lowerBound)
        let end = result.text.index(result.text.startIndex, offsetBy: sub.range.upperBound)
        XCTAssertEqual(String(result.text[start..<end]), "Xcode")
    }

    func testIdempotence() {
        let inputs = ["email jane dot doe at example dot com about the air pods",
                      "the invoice is two hundred fifty dollars at three thirty p m",
                      "we merged the pull request and deployed to kubernetes",
                      "case number a b c one two three four is on file"]
        for input in inputs {
            let once = apply(input, active: allDomains).text
            let twice = apply(once, active: allDomains).text
            XCTAssertEqual(once, twice, "not idempotent for: \(input)")
        }
    }

    func testPerformanceTypicalSentence() {
        let sentence = "please check the air pods and email jane at example dot com about version two point five"
        _ = apply(sentence, active: allDomains)   // warm the static index
        let start = Date()
        let reps = 500
        for _ in 0..<reps { _ = apply(sentence, active: allDomains) }
        let perCall = Date().timeIntervalSince(start) / Double(reps) * 1000
        // Spec target is <1 ms on Apple Silicon (release); debug builds are
        // slower, so the assert allows 2 ms and the release headroom is real.
        XCTAssertLessThan(perCall, 2.0, "\(perCall) ms per call")
    }
}

/// Formatter: every example pair from the YAML plus the adversarial
/// near-misses.
final class SpokenFormatterTests: XCTestCase {
    private func apply(_ text: String, legal: Bool = false) -> String {
        var active: Set<VocabDomain> = [.general]
        if legal { active.insert(.immigration) }
        return CorrectionPass.apply(text, active: active).text
    }

    /// A dictation ENDING on "dot" after a domain run — a closing period
    /// transcribed as the word — subscripted past the token array and killed
    /// the whole app mid-dictation (review 2026-08-26; tld(at:) had no bounds
    /// check). The trailing "dot" stays unformatted; the point is no trap.
    func testTrailingDotAfterDomainDoesNotCrash() {
        XCTAssertEqual(apply("example dot com dot"), "example dot com dot")
        XCTAssertEqual(apply("jane at example dot com dot"), "jane at example dot com dot")
    }

    func testDomainExamples() {
        XCTAssertEqual(apply("example dot com"), "example.com")
        XCTAssertEqual(apply("acme legal dot com"), "acmelegal.com")
        XCTAssertEqual(apply("w twenty labs dot a i"), "w20labs.ai")
        XCTAssertEqual(apply("docs dot example dot com slash pricing"),
                       "docs.example.com/pricing")
    }

    func testEmailExamples() {
        XCTAssertEqual(apply("jane at example dot com"), "jane@example.com")
        XCTAssertEqual(apply("jane dot doe at example dot com"), "jane.doe@example.com")
    }

    func testPhoneExample() {
        XCTAssertEqual(apply("five five five one two three four five six seven"),
                       "(555) 123-4567")
    }

    func testIdentifierExample() {
        XCTAssertEqual(apply("case number a b c one two three four"),
                       "case number ABC1234")
    }

    func testVersionExamples() {
        XCTAssertEqual(apply("version two point five"), "v2.5")
        XCTAssertEqual(apply("version one point zero point three"), "v1.0.3")
    }

    func testLegalFormRequiresActiveLegalDomain() {
        XCTAssertEqual(apply("form i four eighty five", legal: true), "Form I-485")
        XCTAssertEqual(apply("form i four eighty five"), "form i four eighty five")
    }

    func testCurrencyExamples() {
        XCTAssertEqual(apply("two hundred fifty dollars"), "$250")
        XCTAssertEqual(apply("one point five million dollars"), "$1.5 million")
    }

    func testTimeExamples() {
        XCTAssertEqual(apply("three thirty p m"), "3:30 PM")
        XCTAssertEqual(apply("nine a m"), "9:00 AM")
    }

    func testAdversarialNearMisses() {
        for input in ["back in the dot com era",
                      "a real dot com story",
                      "meet me at noon today",
                      "it cost ten ninety nine at the store",
                      "three thirty in the afternoon",
                      "the case number is unknown"] {
            XCTAssertEqual(apply(input, legal: true), input, "should not fire: \(input)")
        }
    }

    func testProseAtYieldsDomainNotEmail() {
        XCTAssertEqual(apply("we are at example dot com"), "we are at example.com")
    }

    func testFormedDomainEmailJoins() {
        // Field 2026-08-19: ASR emits the domain already formed.
        XCTAssertEqual(apply("email jane at example.com today"),
                       "email jane@example.com today")
        // Case normalization rides the join.
        XCTAssertEqual(apply("email jane at Example.Com today"),
                       "email jane@example.com today")
        // The prose guard still holds on formed domains.
        XCTAssertEqual(apply("we are at example.com today"),
                       "we are at example.com today")
        // Non-TLD dotted tokens never join ("at 5.30" class).
        // ITN (2026-08-29): the recognizer's dot is a colon under a time cue; still no domain join.
        XCTAssertEqual(apply("arrive at 5.30 sharp"), "arrive at 5:30 sharp")
    }

    func testLockedSpanBlocksTermCorrection() {
        // "airpods" inside a formatted domain must stay lowercase — the
        // formatter's span is locked against the vocabulary.
        let out = apply("email jane at airpods dot com today")
        XCTAssertEqual(out, "email jane@airpods.com today")
    }

    func testFormattedSpanRecord() {
        let result = CorrectionPass.apply("visit example dot com", active: [.general])
        XCTAssertEqual(result.formattedSpans.count, 1)
        XCTAssertEqual(result.formattedSpans[0].pattern, "domain_name")
    }
}

/// Domain activation: threshold, strength requirement, deactivation, and the
/// bootstrap path.
final class CorrectionSessionTests: XCTestCase {
    func testWeakAnchorsAloneNeverActivate() {
        // The "will/trust" fix: everyday modals must not summon estate mode.
        let session = CorrectionSession()
        for _ in 0..<6 {
            _ = session.apply("I will trust you to handle the estate sale")
        }
        XCTAssertFalse(session.active.contains(.estate))
        // And a gated estate term stays untouched.
        let out = session.apply("the settler moved west")
        XCTAssertTrue(out.text.contains("settler"))
    }

    func testTwoDistinctAnchorsWithOneStrongActivate() {
        let session = CorrectionSession()
        _ = session.apply("the probate hearing is on Monday")
        _ = session.apply("the trustee filed the petition")
        XCTAssertTrue(session.active.contains(.estate))
        let out = session.apply("the settler objected")
        XCTAssertTrue(out.text.contains("settlor"), out.text)
    }

    func testSameAnchorRepeatedIsNotDistinct() {
        let session = CorrectionSession()
        for _ in 0..<4 { _ = session.apply("probate takes time") }
        XCTAssertFalse(session.active.contains(.estate))
    }

    func testDeactivationAfterQuietSegments() {
        let session = CorrectionSession()
        _ = session.apply("the probate hearing with the trustee")
        XCTAssertTrue(session.active.contains(.estate))
        for _ in 0..<CorrectionSession.deactivationQuietSegments {
            _ = session.apply("nothing legal here at all")
        }
        XCTAssertFalse(session.active.contains(.estate))
    }

    func testMultipleDomainsActiveAtOnce() {
        let session = CorrectionSession()
        _ = session.apply("the pull request broke Kubernetes")
        _ = session.apply("USCIS moved the priority date")
        XCTAssertTrue(session.active.contains(.engineering))
        XCTAssertTrue(session.active.contains(.immigration))
    }

    func testCanonicalValuesBootstrapTheirDomain() {
        // Anchors produced by the domain's own always-map count once the
        // domain is substituting; natural anchors get it started.
        let session = CorrectionSession()
        _ = session.apply("we merged the pull request after the stack trace was clean")
        XCTAssertTrue(session.active.contains(.engineering))
        let out = session.apply("open x code and check swift u i")
        XCTAssertTrue(out.text.contains("Xcode"), out.text)
        XCTAssertTrue(out.text.contains("SwiftUI"), out.text)
    }
}
