// SPDX-License-Identifier: GPL-3.0-or-later
struct AcquisitionControls {
    var connected:Bool
    var state:String
    var busy:Bool
    var canRun:Bool{connected && !busy && state == "STOP"}
    var canStop:Bool{connected && !busy && state == "RUN"}
}
