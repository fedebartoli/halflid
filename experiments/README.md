# Experiments

Throwaway programs from the first days of the project. They are kept because the notes in [`docs/FINDINGS.md`](../docs/FINDINGS.md)
and [`docs/DECISIONS.md`](../docs/DECISIONS.md) quote their results, so that anyone can repeat the measurement. They are not
part of Half Lid, are not built by `scripts/build.sh`, are not supported, and are not kept up to date.

## `lid-control/lidtest.swift`

Which mechanism keeps a MacBook awake with the lid closed, and what does the system power log say about each. The header lists
the modes. Read it before running anything.

- It changes the lid policy of the whole Mac while it runs and puts it back when it ends. Run it on a desk, never in a bag.
- The mode `pmset-for` runs `sudo pmset -a disablesleep 1` and asks for your administrator password. The other modes need no
  password.
- Everything it does is also covered, in a safer form, by the product's own tests and by `scripts/lid-check.sh`, which only
  watches and changes nothing.

## `ui-memory/*.swift`

The four smallest menu bar apps used to measure what an interface costs in memory (AppKit and SwiftUI, with and without a
settings window). They change nothing on the Mac. Build one with `swiftc -O file.swift -o /tmp/probe` (`swiftui.swift` also
needs `-parse-as-library`) and look at it with `footprint`. The table in `docs/FINDINGS.md`, section 4, is made from them.
