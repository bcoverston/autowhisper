#!/usr/bin/env python3
"""Suggest speaker-matching parameters from the calibration log.

Joins match-decisions.jsonl with match-corrections.jsonl to recover ground truth
for each auto-match decision, then suggests a threshold and margin that would
drive confirmed false positives to zero (see docs/CALIBRATION.md). Read-only:
prints numbers, changes nothing. Take them to Settings → Speaker matching.

Usage:
  python3 Scripts/calibrate-matching.py [LOG_DIR]

LOG_DIR defaults to ~/Library/Application Support/autowhisper.
"""
import json
import os
import sys

DEFAULT_DIR = os.path.expanduser("~/Library/Application Support/autowhisper")
MIN_FIRM = 20  # below this, trust the strict defaults, not the data


def read_jsonl(path):
    if not os.path.exists(path):
        return []
    out = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    out.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return out


def label_decisions(decisions, corrections):
    """Attach ground truth: was `candidate` actually this speaker?

    Returns lists of (topSim, margin) for firm positives, firm negatives, and
    presumed positives (matched-but-uncorrected — weak, used only for the cost
    estimate).
    """
    # index corrections by (session, fromLabel)
    corr = {}
    for c in corrections:
        corr.setdefault((c["session"], c["fromLabel"]), []).append(c)

    firm_pos, firm_neg, presumed_pos = [], [], []
    for d in decisions:
        margin = None
        if d.get("runnerUpSim") is not None:
            margin = d["topSim"] - d["runnerUpSim"]
        feat = (d["topSim"], margin)
        cs = corr.get((d["session"], d["assignedLabel"]), [])
        if d["matched"]:
            wrong = any(c["action"] in ("misidentified", "reassigned") for c in cs)
            (firm_neg if wrong else presumed_pos).append(feat)
        else:
            tagged = [c for c in cs if c["action"] == "tagged"]
            if not tagged:
                continue  # unknown — Speaker N left untouched tells us nothing
            # rejected candidate was right iff the user tagged it as that candidate
            right = any(c["toLabel"] == d["candidate"] for c in tagged)
            (firm_pos if right else firm_neg).append(feat)
    return firm_pos, firm_neg, presumed_pos


def summarize(name, feats):
    sims = [s for s, _ in feats]
    margins = [m for _, m in feats if m is not None]
    if not sims:
        print(f"  {name:24} (none)")
        return
    def stats(xs):
        xs = sorted(xs)
        return f"min={xs[0]:.3f} med={xs[len(xs)//2]:.3f} max={xs[-1]:.3f}"
    print(f"  {name:24} n={len(sims):3d}  topSim[{stats(sims)}]"
          + (f"  margin[{stats(margins)}]" if margins else ""))


def main():
    log_dir = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_DIR
    decisions = read_jsonl(os.path.join(log_dir, "match-decisions.jsonl"))
    corrections = read_jsonl(os.path.join(log_dir, "match-corrections.jsonl"))
    print(f"log dir: {log_dir}")
    print(f"decisions: {len(decisions)}   corrections: {len(corrections)}\n")
    if not decisions:
        print("No decisions logged yet — run some sessions with enrolled voices first.")
        return

    firm_pos, firm_neg, presumed_pos = label_decisions(decisions, corrections)
    print("Ground-truth groups (firm = established by a correction):")
    summarize("firm positive", firm_pos)      # candidate really was the speaker
    summarize("firm negative", firm_neg)      # candidate was NOT the speaker
    summarize("presumed positive", presumed_pos)  # matched, never corrected (weak)

    firm = [(s, m, True) for s, m in firm_pos] + [(s, m, False) for s, m in firm_neg]
    print(f"\nfirm labeled decisions: {len(firm)}")
    if len(firm) < MIN_FIRM:
        print(f"→ below {MIN_FIRM}; not enough to tune. Keep the strict defaults "
              "(0.65 / 0.06) and gather more corrections.")
        return

    # Grid search over (threshold, margin) minimizing an asymmetric cost on the
    # firm set: a false positive (auto-labeled but wrong) costs FP_COST× a false
    # negative (should have matched — one click to fix). Tie-break toward the
    # LOOSEST gate that reaches the min cost, so we don't over-tighten (overfit).
    FP_COST = 10

    def confusion(t, m):
        fp = fn = tp = tn = 0
        for s, mg, correct in firm:
            pred = s >= t and (mg is None or mg >= m)
            if correct:
                tp, fn = (tp + 1, fn) if pred else (tp, fn + 1)
            else:
                fp, tn = (fp + 1, tn) if pred else (fp, tn + 1)
        return fp, fn, tp, tn

    t_grid = [round(0.40 + 0.01 * i, 2) for i in range(0, 46)]   # 0.40..0.85
    m_grid = [round(0.00 + 0.01 * i, 2) for i in range(0, 21)]   # 0.00..0.20
    best = None
    for t in t_grid:
        for m in m_grid:
            fp, fn, tp, tn = confusion(t, m)
            # key: min cost, then loosest (lowest t, lowest m)
            key = (FP_COST * fp + fn, t, m)
            if best is None or key < best[0]:
                best = (key, t, m, (fp, fn, tp, tn))

    _, t, m, (fp, fn, tp, tn) = best
    print(f"\nsuggested threshold ≥ {t:.2f}   margin ≥ {m:.2f}")
    print(f"  on the firm set: {tp} correct kept, {tn} wrong rejected, "
          f"{fp} false positive(s), {fn} good match(es) sacrificed")
    if fp > 0:
        print("  ⚠ some confirmed-wrong matches can't be separated by any gate "
              "(high similarity AND clear runner-up) — enroll more speech for the "
              "confused voices; the threshold can't fix genuinely-overlapping data.")
    lost = sum(1 for s, _ in presumed_pos if s < t or False)
    if presumed_pos:
        print(f"  ~{lost} of {len(presumed_pos)} presumed-good auto-labels would become "
              "one-click tags under this threshold")

    print("\nApply in Settings → Speaker matching (or edit "
          "SpeakerStore.defaultMatchThreshold / defaultMatchMargin for the shipped default).")


if __name__ == "__main__":
    main()
