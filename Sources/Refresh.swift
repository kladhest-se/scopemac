// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
func refreshDelay(interval: Double, elapsed: Double) -> Double {
    // Target start-to-start cadence. Never overlap captures or spin when USB is slower.
    max(0.005,max(0,min(60,interval))-max(0,elapsed))
}
