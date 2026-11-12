// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
struct ReleaseNotesView:View{
    @ObservedObject var model:ScopeModel
    var body:some View{VStack(alignment:.leading,spacing:16){HStack{Text("ScopeMac — What’s New").font(.title2.bold());Spacer();Button("Done"){model.releaseNotesVisible=false}};ScrollView{Text(Self.notes).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}}.padding(24).frame(width:620,height:500)}
    static let notes="""
    ScopeMac \(AppVersion.marketing) — first release

    • Two-channel capture and DSO2D15 instrument controls.
    • Measurements, FFT, cursors and reference traces.
    • Snapshot recording, offline playback and trends.
    • PNG/CSV export and offline demo mode.
    • Dark, Medium and Light themes.

    Requires Apple Silicon and macOS 14 or later.
    Independent experimental software. Not affiliated with Hantek.
    """
}
