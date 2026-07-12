# Calibrating speaker-matching parameters

autowhisper auto-labels a voice by matching its embedding against enrolled
profiles, accepting the match only when

    topSim ≥ sameVoiceThreshold   AND   (topSim − runnerUpSim) ≥ voiceMatchMargin

The defaults (`0.65` / `0.06`) are deliberately strict guesses. This document is
how you replace the guesses with values **derived from your own corrections** —
without ever letting the app auto-tune itself (that would overfit to the last few
mistakes and drift). You look at the data, you move the sliders.

## Philosophy

- **Manual, not automatic.** Corrections feed a log, not the live thresholds. The
  app only ever *suggests*; you decide.
- **Asymmetric cost.** A false positive (labeling B as "Ann") is expensive — the
  transcript is silently wrong and you must notice and fix it. A false negative
  (leaving Ann as "Speaker 3") is cheap — one click to tag. So we tune to keep
  **false positives near zero**, accepting some false negatives.
- **Firm signal = corrections.** A matched label you never corrected is only
  *presumed* right (you may not have looked). A correction is ground truth. Tune
  against the corrections.

## The log

Two append-only JSONL files in `~/Library/Application Support/autowhisper/`
(Settings → Speaker matching → *Reveal calibration log*):

**`match-decisions.jsonl`** — one line per auto-match decision, at decision time:

| field          | meaning                                                        |
|----------------|----------------------------------------------------------------|
| `ts`           | ISO-8601 timestamp                                             |
| `session`      | session id (join key)                                          |
| `assignedLabel`| what was written: a name (`"Ann"`) if matched, else `"Speaker N"` |
| `candidate`    | the best-scoring profile considered, matched **or rejected**   |
| `topSim`       | cosine similarity to `candidate`                               |
| `runnerUpSim`  | similarity to the 2nd-best profile (may be null)               |
| `matched`      | `true` → auto-labeled to `candidate`                           |
| `threshold`    | `sameVoiceThreshold` in force at that moment                   |
| `marginGate`   | `voiceMatchMargin` in force at that moment                     |

`threshold`/`marginGate` are stamped per decision because you may retune between
sessions — calibration must know which gate produced each outcome.

**`match-corrections.jsonl`** — one line per correction you make:

| field       | meaning                                                        |
|-------------|----------------------------------------------------------------|
| `session`   | session id (join key)                                          |
| `fromLabel` | the label you corrected                                        |
| `toLabel`   | the label you set instead                                      |
| `action`    | `misidentified` \| `tagged` \| `reassigned`                    |

## Turning the log into ground truth

Join each decision to corrections in the **same session** where
`correction.fromLabel == decision.assignedLabel`. Then the true answer to *"was
`candidate` actually this speaker?"* is:

| decision       | correction on that label            | candidate was… | signal              |
|----------------|-------------------------------------|----------------|---------------------|
| matched        | `misidentified` or `reassigned`     | **wrong**      | false positive (firm) |
| matched        | none                                | right          | presumed positive (weak) |
| not matched    | `tagged` → `toLabel == candidate`   | **right**      | false negative (firm) |
| not matched    | `tagged` → `toLabel != candidate`   | wrong          | true negative (firm) |
| not matched    | none                                | unknown        | discard             |

The **firm** rows are what you tune on. Presumed positives are useful only for
estimating how many good matches a stricter gate would cost you.

## Choosing the parameters

The accept rule has two knobs, and which one to move depends on *how* the wrong
matches fail:

- **Threshold (`sameVoiceThreshold`)** handles wrong matches with a **low**
  `topSim` — a stranger who simply isn't that close to anyone. Raise it above
  their similarity.
- **Margin (`voiceMatchMargin`)** handles the *similar-voices* failure — a wrong
  match with a **high** `topSim` but a **close** `runnerUpSim` (two profiles the
  voice sits between). Threshold can't fix this without also rejecting good high-
  similarity matches; the margin can, because good matches have a clear winner.

The script searches both together. It sweeps every `(threshold, margin)` pair over
the firm set and scores each by an **asymmetric cost** — a false positive counts
`FP_COST×` (default 10×) a false negative, encoding "a wrong label is far worse
than a missed one." It reports the gate with the lowest cost, breaking ties toward
the **loosest** setting that reaches it (so it never tightens more than the data
justifies — the guard against overfitting). The confusion counts it prints let you
see the trade: how many good matches a stricter gate would turn into one-click tags.

**Sanity floor:** it refuses to suggest anything below ~20 firm labeled decisions,
and if some confirmed-wrong matches can't be separated by *any* gate (high
similarity *and* a clear runner-up — genuinely overlapping voices), it says so —
the fix there is enrolling more speech for the confused voices, not a knob.

## Doing it with the script

```
python3 Scripts/calibrate-matching.py
```

It joins the two logs, prints the firm-labeled counts, the `topSim`/margin
distributions for correct vs wrong candidates, and a **suggested threshold and
margin** using the rules above. It never writes anything — you take its numbers to
Settings → Speaker matching and move the sliders (or, to change the shipped
defaults, edit `SpeakerStore.defaultMatchThreshold` / `defaultMatchMargin`).

## When there isn't enough data

Everything above needs corrections to exist. Until then the strict defaults are
the right call: they bias to "Speaker N", which is the cheap error. Enrolling
more speech per voice (Reassign/Assign folds it into that voice's centroid) is
the other lever — it sharpens one profile locally and doesn't move any global
knob, so it can't drift.
