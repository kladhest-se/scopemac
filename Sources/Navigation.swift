// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
struct Viewport {
    var lower: Double
    var upper: Double
    var width: Double { upper-lower }
    func clamped(to full: Viewport) -> Viewport {
        let span = min(max(width,full.width/1000),full.width)
        let start = min(max(lower,full.lower),full.upper-span)
        return Viewport(lower:start,upper:start+span)
    }
    func zoomed(factor: Double, anchor: Double, within full: Viewport) -> Viewport {
        let fraction = min(1,max(0,anchor)), span = min(full.width,max(full.width/1000,width/max(0.001,factor)))
        let pivot = lower+width*fraction
        return Viewport(lower:pivot-span*fraction,upper:pivot+span*(1-fraction)).clamped(to:full)
    }
    func panned(fraction: Double, within full: Viewport) -> Viewport {
        Viewport(lower:lower+fraction*width,upper:upper+fraction*width).clamped(to:full)
    }
}
struct RenderTiming {
    var geometryMS = 0.0
    var submitMS = 0.0
    var gpuMS: Double? = nil
    var rebuilt = false
}
func monotonic() -> Double { ProcessInfo.processInfo.systemUptime }
