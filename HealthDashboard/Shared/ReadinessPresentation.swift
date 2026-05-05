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
    case red
    case sick
    case highPain
}

extension ReadinessResult {

    private func driverDisplay(_ driver: ReadinessDriver) -> String {
        switch driver.label {
        case "RHR", "Wrist Temp", "Respiratory Rate", "Pain", "Sick":
            return "\(driver.label) ↑"
        case "HRV", "Sleep", "Sleep Quality", "SpO2":
            return "\(driver.label) ↓"
        default:
            return driver.label
        }
    }

    private var presentationDriverSummary: String {
        guard !drivers.isEmpty else {
            return "No meaningful deviations"
        }

        let negatives = drivers.filter { $0.isNegative }

        if negatives.count == 1, let driver = negatives.first {
            return "\(driverDisplay(driver)) (isolated)"
        }

        if !negatives.isEmpty {
            return negatives.map { driverDisplay($0) }.joined(separator: ", ")
        }

        return drivers.map { driverDisplay($0) }.joined(separator: ", ")
    }

    func presentation(manual: ManualReadinessInputs) -> ReadinessPresentation {
        let negativeDrivers = drivers.filter { $0.isNegative }

        let confidenceLabel = confidence.title
            .replacingOccurrences(of: " confidence", with: "")

        let confidenceLine = "Confidence: \(confidenceLabel)"
        let driverLine = "Driver: \(presentationDriverSummary)"

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

            if action == .yellow {
                return negativeDrivers.count == 1 ? .yellowIsolated : .yellowCluster
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
            baseExplanation = "Your body is actively fighting something. Training should support recovery, not compete with it."
            guidanceButtonTitle = "View recovery guidance"

        case .highPain:
            headline = "Reduce cost today"
            subline = "Pain is high"
            baseExplanation = "Pain is high enough to override normal readiness. Reduce load, range, or volume."
            guidanceButtonTitle = "View training guidance"

        case .red:
            headline = "Reduce cost today"
            subline = "Recovery is compromised"
            baseExplanation = "Multiple recovery systems are under strain. This is a cost-control day, not a performance day."
            guidanceButtonTitle = "View recovery guidance"

        case .yellowCluster:
            headline = "Train with guardrails"
            subline = "Multiple signals are off"
            baseExplanation = "Several recovery signals are below baseline. Keep the session productive, but avoid grinders, intensifiers, and extra volume."
            guidanceButtonTitle = "View training guidance"

        case .yellowIsolated:
            headline = "Train with guardrails"
            subline = "One signal is off"
            baseExplanation = isolatedYellowExplanation(negativeDrivers: negativeDrivers)
            guidanceButtonTitle = "View training guidance"

        case .greenPush:
            headline = "Train normally"
            subline = "Push allowed today"
            baseExplanation = "Recovery signals are aligned. You can push one key lift if execution stays clean."
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
        case "Sleep", "Sleep Quality":
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
        case "Sleep", "Sleep Quality":
            return "Sleep is a little off, but the broader recovery picture is stable. Keep execution clean."
        default:
            return "One recovery signal is off, but the broader picture is stable. Train normally, but don’t chase hero sets."
        }
    }
}
