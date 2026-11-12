// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import Metal
if CommandLine.arguments.contains("--self-test") {
    do { try runTests(); print("ScopeMac protocol, calibration, analysis and performance tests passed."); exit(0) }
    catch { fputs("TEST FAILED: \(error)\n",stderr); exit(1) }
} else if CommandLine.arguments.contains("--gpu-test") {
    guard let device = MTLCreateSystemDefaultDevice() else { fputs("Metal device unavailable in this execution environment\n",stderr); exit(2) }
    do { let library = try device.makeLibrary(source:Renderer.shader,options:nil); guard library.makeFunction(name:"scopeVertex") != nil else { exit(1) }; print("Metal shader compiled on \(device.name)"); exit(0) } catch { fputs("\(error)\n",stderr); exit(1) }
} else { ScopeMacApp.main() }
