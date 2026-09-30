// Golden outputs for ReadinessParityTests, captured on main @ 9fd10da BEFORE any engine edit
// (ReadinessResult + DailyVerdictRecord per fixture; record.dateISO omitted — wall-clock date;
// result.flags sorted — the engine emits them in Dictionary-hash order, which varies per process).
// Do not regenerate against a modified engine: that defeats the parity check.

enum ReadinessParityGolden {
    static let json = #"""
{
  "green_missing_signals": {
    "record": {
      "hrvConcern": false,
      "hrvDown10": false,
      "hrvDownTrend": false,
      "rawRecovery": -1,
      "rawRecoveryTruth": "green",
      "rawTotal": -1,
      "rawTruth": "green",
      "rhrUp4": false,
      "rrUp10": false,
      "sick": false,
      "sleepEffLow": false,
      "sleepShort1": false,
      "tempUp03": false
    },
    "result": {
      "action": "green",
      "actionMessage": "Recovery is green today. We’re confirming it with another day of data before clearing the badge to green — train normally and keep it clean, no extra cost or hero sets.",
      "actionTitle": "Recovery looks good — confirming",
      "canPushKeyLift": false,
      "cardioLoad": 0,
      "confidence": "low",
      "drivers": [
        {
          "consecutiveDays": 0,
          "impact": 1,
          "isNegative": true,
          "label": "Sleep Efficiency",
          "reason": "Fragmented sleep — even with adequate duration."
        }
      ],
      "effBase": 0.9195402298850576,
      "effCur": 0.8620689655172414,
      "effDelta": -0.05747126436781613,
      "flags": [
        "Sleep quality ↓"
      ],
      "mechanicalLoad": 0,
      "rawTruth": "green",
      "sleepDelta": -0.5,
      "totalScore": -1,
      "truth": "yellow"
    }
  },
  "green_neutral": {
    "record": {
      "hrvConcern": false,
      "hrvDown10": false,
      "hrvDownTrend": false,
      "rawRecovery": 0,
      "rawRecoveryTruth": "green",
      "rawTotal": 0,
      "rawTruth": "green",
      "rhrUp4": false,
      "rrUp10": false,
      "sick": false,
      "sleepEffLow": false,
      "sleepShort1": false,
      "tempUp03": false
    },
    "result": {
      "action": "green",
      "actionMessage": "Recovery is green today. We’re confirming it with another day of data before clearing the badge to green — train normally and keep it clean, no extra cost or hero sets.",
      "actionTitle": "Recovery looks good — confirming",
      "canPushKeyLift": false,
      "cardioLoad": 0,
      "confidence": "high",
      "drivers": [],
      "effBase": 0.9195402298850576,
      "effCur": 0.9195402298850576,
      "effDelta": 0,
      "flags": [],
      "hrvDelta": 0,
      "mechanicalLoad": 0,
      "rawTruth": "green",
      "rhrDelta": 0,
      "rrDelta": 0,
      "sleepDelta": 0,
      "tempDelta": 0,
      "totalScore": 0,
      "truth": "yellow"
    }
  },
  "out_of_range_hrv_rhr": {
    "record": {
      "hrvConcern": false,
      "hrvDown10": false,
      "hrvDownTrend": false,
      "rawRecovery": 0,
      "rawRecoveryTruth": "green",
      "rawTotal": 0,
      "rawTruth": "green",
      "rhrUp4": false,
      "rrUp10": false,
      "sick": false,
      "sleepEffLow": false,
      "sleepShort1": false,
      "tempUp03": false
    },
    "result": {
      "action": "green",
      "actionMessage": "Recovery is green today. We’re confirming it with another day of data before clearing the badge to green — train normally and keep it clean, no extra cost or hero sets.",
      "actionTitle": "Recovery looks good — confirming",
      "canPushKeyLift": false,
      "cardioLoad": 0,
      "confidence": "high",
      "drivers": [],
      "effBase": 0.9195402298850576,
      "effCur": 0.9195402298850576,
      "effDelta": 0,
      "flags": [],
      "hrvDelta": 270,
      "mechanicalLoad": 0,
      "rawTruth": "green",
      "rhrDelta": -45,
      "rrDelta": 0,
      "sleepDelta": 0,
      "tempDelta": 0,
      "totalScore": 0,
      "truth": "yellow"
    }
  },
  "red_high_pain": {
    "record": {
      "hrvConcern": false,
      "hrvDown10": false,
      "hrvDownTrend": false,
      "rawRecovery": -3,
      "rawRecoveryTruth": "green",
      "rawTotal": -3,
      "rawTruth": "green",
      "rhrUp4": false,
      "rrUp10": false,
      "sick": false,
      "sleepEffLow": false,
      "sleepShort1": false,
      "tempUp03": false
    },
    "result": {
      "action": "red",
      "actionMessage": "Reduce: choose the lowest-cost version of training (lighter loads and/or fewer sets). No intensifiers, no grinders.",
      "actionTitle": "Reduce cost today",
      "canPushKeyLift": false,
      "cardioLoad": 0,
      "confidence": "medium",
      "drivers": [
        {
          "consecutiveDays": 0,
          "impact": 3,
          "isNegative": true,
          "label": "Pain",
          "reason": "Reported pain is elevated — train around it."
        }
      ],
      "effBase": 0.9195402298850576,
      "effCur": 0.9195402298850576,
      "effDelta": 0,
      "flags": [
        "Pain ↑"
      ],
      "hrvDelta": 0,
      "mechanicalLoad": 0,
      "rawTruth": "green",
      "rhrDelta": 0,
      "rrDelta": 0,
      "sleepDelta": 0,
      "tempDelta": 0,
      "totalScore": -3,
      "truth": "yellow"
    }
  },
  "red_load_recovery_green": {
    "record": {
      "hrvConcern": false,
      "hrvDown10": false,
      "hrvDownTrend": false,
      "rawRecovery": -2,
      "rawRecoveryTruth": "green",
      "rawTotal": -7,
      "rawTruth": "red",
      "rhrUp4": false,
      "rrUp10": false,
      "sick": false,
      "sleepEffLow": false,
      "sleepShort1": false,
      "tempUp03": false
    },
    "result": {
      "action": "red",
      "actionMessage": "Reduce: choose the lowest-cost version of training (lighter loads and/or fewer sets). No intensifiers, no grinders.",
      "actionTitle": "Reduce cost today",
      "canPushKeyLift": false,
      "cardioLoad": 130,
      "confidence": "medium",
      "drivers": [
        {
          "consecutiveDays": 0,
          "impact": 2,
          "isNegative": true,
          "label": "Pain",
          "reason": "Reported pain is elevated — train around it."
        }
      ],
      "effBase": 0.9195402298850576,
      "effCur": 0.9195402298850576,
      "effDelta": 0,
      "flags": [
        "Pain ↑"
      ],
      "hrvDelta": 0,
      "mechanicalLoad": 0,
      "rawTruth": "red",
      "rhrDelta": 0,
      "rrDelta": 0,
      "sleepDelta": 0,
      "tempDelta": 0,
      "totalScore": -7,
      "truth": "red"
    }
  },
  "red_recovery_cluster": {
    "record": {
      "hrvConcern": true,
      "hrvDown10": true,
      "hrvDownTrend": false,
      "rawRecovery": -9,
      "rawRecoveryTruth": "red",
      "rawTotal": -9,
      "rawTruth": "red",
      "rhrUp4": true,
      "rrUp10": true,
      "sick": false,
      "sleepEffLow": false,
      "sleepShort1": true,
      "tempUp03": false
    },
    "result": {
      "action": "red",
      "actionMessage": "Reduce: choose the lowest-cost version of training (lighter loads and/or fewer sets). No intensifiers, no grinders.",
      "actionTitle": "Reduce cost today",
      "canPushKeyLift": false,
      "cardioLoad": 0,
      "confidence": "high",
      "drivers": [
        {
          "consecutiveDays": 1,
          "impact": 3,
          "isNegative": true,
          "label": "RHR",
          "reason": "Elevated vs baseline — may reflect fatigue, illness, or strain."
        },
        {
          "consecutiveDays": 1,
          "impact": 2,
          "isNegative": true,
          "label": "Sleep",
          "reason": "Short vs target — recovery and performance both take a hit."
        },
        {
          "consecutiveDays": 1,
          "impact": 2,
          "isNegative": true,
          "label": "Respiratory Rate",
          "reason": "Elevated overnight — frequently precedes other symptoms."
        }
      ],
      "effBase": 0.9195402298850576,
      "flags": [
        "HRV ↓",
        "RHR ↑",
        "Resp Rate ↑",
        "Sleep ↓"
      ],
      "hrvDelta": -8,
      "mechanicalLoad": 0,
      "rawTruth": "red",
      "rhrDelta": 8,
      "rrDelta": 2.1999999999999993,
      "sleepDelta": -2.5,
      "tempDelta": 0,
      "totalScore": -9,
      "truth": "red"
    }
  },
  "red_sick": {
    "record": {
      "hrvConcern": false,
      "hrvDown10": false,
      "hrvDownTrend": false,
      "rawRecovery": -4,
      "rawRecoveryTruth": "yellow",
      "rawTotal": -4,
      "rawTruth": "yellow",
      "rhrUp4": false,
      "rrUp10": false,
      "sick": true,
      "sleepEffLow": false,
      "sleepShort1": false,
      "tempUp03": false
    },
    "result": {
      "action": "red",
      "actionMessage": "Reduce: choose the lowest-cost version of training (lighter loads and/or fewer sets). No intensifiers, no grinders.",
      "actionTitle": "Reduce cost today",
      "canPushKeyLift": false,
      "cardioLoad": 0,
      "confidence": "medium",
      "drivers": [
        {
          "consecutiveDays": 1,
          "impact": 4,
          "isNegative": true,
          "label": "Sick",
          "reason": "Marked sick — recovery takes priority over training."
        }
      ],
      "effBase": 0.9195402298850576,
      "effCur": 0.9195402298850576,
      "effDelta": 0,
      "flags": [
        "Sick"
      ],
      "hrvDelta": 0,
      "mechanicalLoad": 0,
      "rawTruth": "yellow",
      "rhrDelta": 0,
      "rrDelta": 0,
      "sleepDelta": 0,
      "tempDelta": 0,
      "totalScore": -4,
      "truth": "yellow"
    }
  },
  "yellow_cluster": {
    "record": {
      "hrvConcern": true,
      "hrvDown10": true,
      "hrvDownTrend": false,
      "rawRecovery": -3,
      "rawRecoveryTruth": "yellow",
      "rawTotal": -3,
      "rawTruth": "yellow",
      "rhrUp4": true,
      "rrUp10": false,
      "sick": false,
      "sleepEffLow": false,
      "sleepShort1": false,
      "tempUp03": false
    },
    "result": {
      "action": "yellow",
      "actionMessage": "Run the plan, but avoid top-end effort. Stay honest with RIR and skip any push or intensifier work. If something feels off early, adjust instead of forcing it.",
      "actionTitle": "Train with guardrails",
      "canPushKeyLift": false,
      "cardioLoad": 0,
      "confidence": "high",
      "drivers": [
        {
          "consecutiveDays": 1,
          "impact": 2,
          "isNegative": true,
          "label": "RHR",
          "reason": "Elevated vs baseline — may reflect fatigue, illness, or strain."
        },
        {
          "consecutiveDays": 1,
          "impact": 1,
          "isNegative": true,
          "label": "HRV",
          "reason": "Below baseline — often an early stress or recovery signal."
        }
      ],
      "effBase": 0.9195402298850576,
      "effCur": 0.9195402298850576,
      "effDelta": 0,
      "flags": [
        "HRV ↓",
        "RHR ↑"
      ],
      "hrvDelta": -5,
      "mechanicalLoad": 0,
      "rawTruth": "yellow",
      "rhrDelta": 5,
      "rrDelta": 0,
      "sleepDelta": 0,
      "tempDelta": 0,
      "totalScore": -3,
      "truth": "yellow"
    }
  },
  "yellow_isolated_rr": {
    "record": {
      "hrvConcern": false,
      "hrvDown10": false,
      "hrvDownTrend": false,
      "rawRecovery": -1,
      "rawRecoveryTruth": "green",
      "rawTotal": -1,
      "rawTruth": "green",
      "rhrUp4": false,
      "rrUp10": false,
      "sick": false,
      "sleepEffLow": false,
      "sleepShort1": false,
      "tempUp03": false
    },
    "result": {
      "action": "green",
      "actionMessage": "Recovery is green today. We’re confirming it with another day of data before clearing the badge to green — train normally and keep it clean, no extra cost or hero sets.",
      "actionTitle": "Recovery looks good — confirming",
      "canPushKeyLift": false,
      "cardioLoad": 0,
      "confidence": "medium",
      "drivers": [
        {
          "consecutiveDays": 0,
          "impact": 1,
          "isNegative": true,
          "label": "Respiratory Rate",
          "reason": "Elevated overnight — frequently precedes other symptoms."
        }
      ],
      "effBase": 0.9195402298850576,
      "effCur": 0.9195402298850576,
      "effDelta": 0,
      "flags": [
        "Resp Rate ↑"
      ],
      "hrvDelta": 0,
      "mechanicalLoad": 0,
      "rawTruth": "green",
      "rhrDelta": 0,
      "rrDelta": 1.5,
      "sleepDelta": 0,
      "tempDelta": 0,
      "totalScore": -1,
      "truth": "yellow"
    }
  },
  "yellow_load_only": {
    "record": {
      "hrvConcern": false,
      "hrvDown10": false,
      "hrvDownTrend": false,
      "rawRecovery": 0,
      "rawRecoveryTruth": "green",
      "rawTotal": -4,
      "rawTruth": "yellow",
      "rhrUp4": false,
      "rrUp10": false,
      "sick": false,
      "sleepEffLow": false,
      "sleepShort1": false,
      "tempUp03": false
    },
    "result": {
      "action": "yellow",
      "actionMessage": "Run the plan, but avoid top-end effort. Stay honest with RIR and skip any push or intensifier work. If something feels off early, adjust instead of forcing it.",
      "actionTitle": "Train with guardrails",
      "canPushKeyLift": false,
      "cardioLoad": 90,
      "confidence": "high",
      "drivers": [],
      "effBase": 0.9195402298850576,
      "effCur": 0.9195402298850576,
      "effDelta": 0,
      "flags": [],
      "hrvDelta": 0,
      "mechanicalLoad": 0,
      "rawTruth": "yellow",
      "rhrDelta": 0,
      "rrDelta": 0,
      "sleepDelta": 0,
      "tempDelta": 0,
      "totalScore": -4,
      "truth": "yellow"
    }
  }
}
"""#
}
