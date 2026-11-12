// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// Both channels share a sample clock, allowing math, cursors and FFT comparisons.
func demoCapture(elapsed: Double) -> Capture {
    let time=elapsed.isFinite ? max(0,elapsed):0
    let amplitude=1+0.12*sin(time*0.7)
    let duty=0.5+0.12*sin(time*0.4)
    let frequency=1000+80*sin(time*0.25)
    let rate=500000.0
    var pulse=[Double](),sine=[Double]()
    pulse.reserveCapacity(4000);sine.reserveCapacity(4000)
    for i in 0..<4000 {
        let phase=Double(i)*frequency/rate
        pulse.append(phase-floor(phase)<duty ? 5*amplitude:0)
        let angle=2*Double.pi*phase
        sine.append(2*amplitude*sin(angle+0.6*sin(time*0.3))+0.2*sin(3*angle)+0.15*sin(time*0.5))
    }
    var capture=Capture(volts:[pulse,sine],rate:rate,trigger:0,raw:Data())
    capture.synthetic=true
    return capture
}
