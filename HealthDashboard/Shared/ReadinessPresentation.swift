import Foundation

struct ReadinessPresentation: Equatable {
    let headline: String
    let subline: String
    let explanation: String
    let confidenceLine: String
    let driverLine: String
    let guidanceButtonTitle: String
}

enum ReadinessMessageState {
    case greenPush
    case greenNoPush
    case yellowIsolated
    case yellowCluster
    case yellowLoad     // yellow with zero negative recovery drivers → load-driven caution
    case gateHold       // rawTruth green, display held amber for one-day confirmation
    case red
    case sick
    case highPain
}

extension ReadinessResult {

    private func driverDisplay(_ driver: ReadinessDriver) -> String {
        switch driver.label {
        case "RHR", "Wrist Temp", "Respiratory Rate", "Pain", "Sick":
            return "\(driver.label) ↑"
        case "HRV", "Sleep", "Sleep Efficiency", "SpO2":
            return "\(driver.label) ↓"
        default:
            return driver.label
        }
    }

    private func presentationDriverSummary(for messageState: ReadinessMessageState) -> String {
        let negatives = drivers.filter { $0.isNegative }

        switch messageState {
        case .greenPush:
            return "Recovery aligned"

        case .greenNoPush:
            if negatives.isEmpty {
                return "Stable, not elevated"
            }

            // Green should not read like a warning state.
            // These are watch items, not the reason for readiness.
            return "Minor watch item: \(negatives.prefix(2).map { driverDisplay($0) }.joined(separator: ", "))"

        case .yellowIsolated:
            if let driver = negatives.first {
                return "\(driverDisplay(driver)) (isolated)"
            }
            return "One recovery signal off"

        case .yellowCluster:
            if !negatives.isEmpty {
                return negatives.map { driverDisplay($0) }.joined(separator: ", ")
            }
            return "Several recovery signals off"

        case .yellowLoad:
            // No negative recovery drivers — the caution is load, not recovery.
            return "Elevated training load"

        case .gateHold:
            // Raw verdict is green; any drivers present are soft, non-verdict-moving.
            if negatives.isEmpty {
                return "Recovery aligned"
            }
            return "Minor watch item: \(negatives.prefix(2).map { driverDisplay($0) }.joined(separator: ", "))"

        case .red, .sick, .highPain:
            if !negatives.isEmpty {
                return negatives.map { driverDisplay($0) }.joined(separator: ", ")
            }
            return "Recovery compromised"
        }
    }

    func presentation(manual: ManualReadinessInputs) -> ReadinessPresentation {
        let negativeDrivers = drivers.filter { $0.isNegative }

        let confidenceLabel = confidence.title
            .replacingOccurrences(of: " confidence", with: "")

        let confidenceLine = "Confidence: \(confidenceLabel)"

        let messageState: ReadinessMessageState = {
            if manual.isSick {
                return .sick
            }

            if manual.painLevel >= 7 {
                return .highPain
            }

            if action == .red {
                return .red
            }

            // Gate hold: raw verdict is green but the display is held amber for one-day
            // confirmation. `action` reads green (see ReadinessEngine) while `truth` reads
            // amber — narrate the split instead of a caution or a bare green.
            if truth == .yellow && rawTruth == .green {
                return .gateHold
            }

            if action == .yellow {
                // count==0 is a load-driven yellow (no negative recovery drivers) — it must
                // NOT fall into the recovery "cluster" copy the old ternary misrouted it to.
                switch negativeDrivers.count {
                case 0:  return .yellowLoad
                case 1:  return .yellowIsolated
                default: return .yellowCluster
                }
            }

            if canPushKeyLift {
                return .greenPush
            }

            return .greenNoPush
        }()

        let headline: String
        let subline: String
        let baseExplanation: String
        let guidanceButtonTitle: String

        switch messageState {
        case .sick:
            headline = "Reduce cost today"
            subline = "Sickness is active"
            baseExplanation = "Your body is actively fighting something. Training should support recovery, not compete with it. Skip hard training."
            guidanceButtonTitle = "View recovery guidance"

        case .highPain:
            headline = "Reduce cost today"
            subline = "Pain is high"
            baseExplanation = "Pain is high enough to override normal readiness. Reduce load, range, or volume. Do not train through worsening symptoms."
            guidanceButtonTitle = "View training guidance"

        case .red:
            headline = "Reduce cost today"
            subline = "Recovery is compromised"
            baseExplanation = "Multiple recovery systems are under strain. Use the lowest-cost version of training today, or take a recovery day."
            guidanceButtonTitle = "View recovery guidance"

        case .yellowCluster:
            headline = "Train with guardrails"
            subline = "Reduce effort today"
            baseExplanation = "Multiple recovery signals are outside their normal range. Run a controlled session: no grinders, no intensifiers, no extra volume."
            guidanceButtonTitle = "View training guidance"

        case .yellowLoad:
            headline = "Train with guardrails"
            subline = ReadinessLoadCopy.subline
            baseExplanation = ReadinessLoadCopy.explanation
            guidanceButtonTitle = "View training guidance"

        case .gateHold:
            // Deferred to the engine's single-source hold copy so the card and the Watch
            // (which reads actionTitle/actionMessage) narrate the split identically.
            headline = ReadinessHoldCopy.title
            subline = ReadinessHoldCopy.subline
            baseExplanation = ReadinessHoldCopy.message
            guidanceButtonTitle = "View training guidance"

        case .yellowIsolated:
            headline = "Train with guardrails"
            subline = "Do not push today"
            baseExplanation = isolatedYellowExplanation(negativeDrivers: negativeDrivers)
            guidanceButtonTitle = "View training guidance"

        case .greenPush:
            headline = "Train normally"
            subline = "Push allowed today"
            baseExplanation = "Recovery signals are aligned. Run the plan as written. You may push one key lift if execution stays clean."
            guidanceButtonTitle = "View training guidance"

        case .greenNoPush:
            headline = "Train normally"
            subline = "Not a push day"
            baseExplanation = greenNoPushExplanation(negativeDrivers: negativeDrivers)
            guidanceButtonTitle = "View training guidance"
        }

        let confidenceModifier: String = {
            switch confidence {
            case .high:
                return ""
            case .medium:
                return " Some signals are mixed, so treat this as a directional read, not absolute."
            case .low:
                return " Data is limited or inconsistent today. Lean more on how you actually feel."
            }
        }()

        let driverLine = "Driver: \(presentationDriverSummary(for: messageState))"

        return ReadinessPresentation(
            headline: headline,
            subline: subline,
            explanation: baseExplanation + confidenceModifier,
            confidenceLine: confidenceLine,
            driverLine: driverLine,
            guidanceButtonTitle: guidanceButtonTitle
        )
    }

    private func isolatedYellowExplanation(negativeDrivers: [ReadinessDriver]) -> String {
        guard let driver = negativeDrivers.first else {
            return "One recovery signal is off. This isn’t a full recovery issue, but it’s not a push day either."
        }

        switch driver.label {
        case "Wrist Temp":
            return "Wrist temperature is elevated while other signals are stable. This can indicate early stress or incomplete recovery."
        case "Respiratory Rate":
            return "Respiratory rate is elevated while other signals are stable. Use caution and monitor how you feel."
        case "HRV":
            return "HRV is down without a broader recovery collapse. Train with guardrails and avoid pushing."
        case "RHR":
            return "Resting heart rate is elevated while other signals are mostly stable. Use caution today."
        case "Sleep", "Sleep Efficiency":
            return "Sleep is compromised. Train if you feel okay, but keep effort controlled."
        case "SpO2":
            return "SpO2 is lower than usual, but this signal can be noisy. Watch for repeat patterns."
        case "Pain":
            return "Pain is elevated. Train around it and avoid movements that increase symptoms."
        default:
            return "One recovery signal is off. This isn’t a full recovery issue, but it’s not a push day either."
        }
    }

    private func greenNoPushExplanation(negativeDrivers: [ReadinessDriver]) -> String {
        guard let driver = negativeDrivers.first else {
            return "Recovery is stable, but not strong enough to justify pushing. Run the plan cleanly."
        }

        switch driver.label {
        case "HRV":
            return "HRV dipped, but other recovery signals are strong. This looks like normal variation, not fatigue."
        case "Wrist Temp":
            return "Wrist temperature is elevated while other signals are stable. Use caution today."
        case "Respiratory Rate":
            return "Respiratory rate is elevated, but other recovery signals are stable. Use caution today."
        case "SpO2":
            return "SpO2 is lower than usual, but this signal can be noisy. Watch for repeat patterns."
        case "RHR":
            return "Resting heart rate is mildly elevated, but the broader recovery picture is stable."
        case "Sleep", "Sleep Efficiency":
            return "Sleep is a little off, but the broader recovery picture is stable. Keep execution clean."
        default:
            return "One recovery signal is off, but the broader picture is stable. Train normally, but don’t chase hero sets."
        }
    }

    // MARK: - Driver-row display (Phase 1 messaging-consistency)
    // Presentation-only. Tone derives from the score's VERDICT CONTRIBUTION,
    // never from raw sign(score). The sleep row LABEL is routed through the
    // composite's per-axis scores so it names the axis that actually scored low.
    // Driver presence/sign is unchanged (still owned by the engine's
    // sleepEffScore) — this is tone + label only.

    enum DriverSentiment: Equatable { case positive, calm, warn }

    struct DriverDisplay: Equatable {
        let label: String
        let sentiment: DriverSentiment
        let subtitle: String
        let consecutiveDays: Int
    }

    private func sentiment(for driver: ReadinessDriver) -> DriverSentiment {
        guard driver.isNegative else { return .positive }
        // Warn is reserved for non-Green cards. On a Green card every negative
        // driver was, by definition, discounted by the verdict, so it reads
        // calm — otherwise an orange row would contradict the Green
        // reconciliation line. A sustained streak is carried by the "Nth day"
        // badge, not by alarm color.
        return action == .green ? .calm : .warn
    }

    private func driverSubtitle(for driver: ReadinessDriver, sentiment: DriverSentiment) -> String {
        switch driver.label {
        case "HRV":
            if sentiment == .positive {
                // Non-negative HRV driver (above baseline). Must not inherit the
                // negative-dip fallthrough — that put a below-baseline string under
                // the green up-arrow.
                return "Above your baseline — good sign."
            }
            if sentiment == .warn {
                return driver.consecutiveDays >= 2
                    ? "Below baseline \(driver.consecutiveDays) days running — watch recovery."
                    : "Below baseline enough to weigh on today's read."
            }
            // .calm: clamped single-day dip that didn't move the verdict.
            return "Slightly below your baseline — within normal range."

        case "Sleep Efficiency":
            return sleepQualitySubtitle()

        default:
            // Non-sleep, non-HRV rows keep the engine's reading-derived reason.
            return driver.reason
        }
    }

    // The "Sleep Efficiency" readiness driver fires off the ENGINE's sleepEffScore,
    // which is an EFFICIENCY signal (asleep / inBed vs baseline). So this row is
    // always about efficiency — the subtitle is anchored there and never renamed
    // to another axis (the driver isn't those) nor suppressed to "close to your
    // norm" while the engine's down-driver is on screen.
    //
    // The sleep composite is consulted ONLY to refine the efficiency wording when
    // it AGREES efficiency is low. After the SPT change, engine efficiency (inBed)
    // and composite efficiency (SPT-trimmed) diverge by construction on couch-
    // sleep nights: the engine sees low efficiency, the composite does not. On
    // those nights the honest readiness line is still efficiency — the composite's
    // disagreement must not silence the engine's row.
    //
    // 70 mirrors SleepQualityEngine.verdictGood (the composite→"Good" band cutoff).
    // Inlined rather than referenced because this Shared file also compiles into
    // the widget target, which does not include the engine.
    private static let weakAxisThreshold: Double = 70

    private func sleepQualitySubtitle() -> String {
        let compositeAgreesEfficiencyLow = sleepQuality?.subScores.contains {
            $0.axis == .efficiency && $0.available && $0.score < Self.weakAxisThreshold
        } ?? false

        // Both variants are efficiency-worded; the composite only strengthens the
        // felt descriptor when it independently confirms the low efficiency.
        return compositeAgreesEfficiencyLow
            ? "Restless — lower sleep efficiency than your norm."
            : "Lower sleep efficiency than your norm."
    }

    func driverDisplays() -> [DriverDisplay] {
        drivers.map { d in
            let s = sentiment(for: d)
            return DriverDisplay(
                label: d.label,
                sentiment: s,
                subtitle: driverSubtitle(for: d, sentiment: s),
                consecutiveDays: d.consecutiveDays
            )
        }
    }

    // Green shipping with >=1 down-driver must say so, so the headline doesn't
    // read as self-contradictory. Derived from the same drivers set.
    var reconciliationLine: String? {
        guard action == .green else { return nil }
        let downs = drivers.filter { $0.isNegative }
        guard !downs.isEmpty else { return nil }
        return downs.count == 1
            ? "One signal is slightly soft, but not enough to change today's call."
            : "A couple of signals are slightly soft, but not enough to change today's call."
    }
}
