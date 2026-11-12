// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit

enum AboutWindow {
    private static var controller:NSWindowController?
    static func show(model:ScopeModel){
        if let controller{controller.window?.makeKeyAndOrderFront(nil);return}
        let content=NSHostingController(rootView:AboutView(model:model))
        let window=NSWindow(contentViewController:content)
        window.title="About ScopeMac";window.styleMask=[.titled,.closable];window.setContentSize(NSSize(width:560,height:620));window.center();window.isReleasedWhenClosed=false
        controller=NSWindowController(window:window);controller?.showWindow(nil)
    }
}
private struct AboutDocument:Identifiable{let id=UUID();let title:String;let text:String}
struct AboutView:View {
    @ObservedObject var model:ScopeModel
    @State private var document:AboutDocument?
    private var version:String{Bundle.main.object(forInfoDictionaryKey:"CFBundleShortVersionString") as? String ?? AppVersion.marketing}
    private var build:String{Bundle.main.object(forInfoDictionaryKey:"CFBundleVersion") as? String ?? AppVersion.build}
    var body:some View{
        VStack(spacing:18){
            Image(nsImage:NSImage(named:NSImage.applicationIconName) ?? NSImage()).resizable().frame(width:76,height:76)
            VStack(spacing:5){Text("ScopeMac").font(.largeTitle.bold());Text("Version \(version) · Build \(build)").font(.caption).foregroundStyle(.secondary);Text("Native macOS oscilloscope app for Hantek DSO2D15").font(.subheadline)}
            Divider()
            VStack(alignment:.leading,spacing:12){
                HStack{Text("Developer").foregroundStyle(.secondary).frame(width:85,alignment:.leading);Text("Tommy Frossman").fontWeight(.medium)}
                HStack{Text("Website").foregroundStyle(.secondary).frame(width:85,alignment:.leading);Link("scopemac.kladhest.se",destination:URL(string:"https://scopemac.kladhest.se")!)}
                HStack{Text("Source").foregroundStyle(.secondary).frame(width:85,alignment:.leading);Link("github.com/kladhest-se/scopemac",destination:URL(string:"https://github.com/kladhest-se/scopemac")!)}
                HStack(alignment:.top){Text("License").foregroundStyle(.secondary).frame(width:85,alignment:.leading);Text("GNU General Public License\nVersion 3 or later (GPL-3.0-or-later)")}
            }.font(.callout).frame(maxWidth:.infinity,alignment:.leading)
            HStack{Button("Read GPL license"){showDocument("LICENSE",title:"GNU General Public License")};Button("Acknowledgements"){showDocument("NOTICE.md",title:"Acknowledgements and third-party licenses")}}
            Text("SwiftUI/AppKit interface and Metal renderer developed for ScopeMac. USB/protocol behavior was adapted from our experimental DSO2D15 additions to a local OpenHantek6022 checkout. Includes libusb (LGPL-2.1-or-later).").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Text("Independent experimental software. Not affiliated with or endorsed by Hantek.").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength:0)
        }.padding(28).frame(width:560,height:620).background(model.theme.background).preferredColorScheme(model.theme.scheme)
        .sheet(item:$document){doc in VStack(alignment:.leading,spacing:12){HStack{Text(doc.title).font(.headline);Spacer();Button("Done"){document=nil}};ScrollView{Text(doc.text).font(.system(.caption,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}}.padding(20).frame(width:660,height:520)}
    }
    private func showDocument(_ name:String,title:String){
        let url=Bundle.main.resourceURL?.appendingPathComponent(name)
        let text=url.flatMap{try? String(contentsOf:$0,encoding:.utf8)} ?? "Document unavailable in this development executable. See LICENSE and NOTICE.md in the source distribution."
        document=AboutDocument(title:title,text:text)
    }
}
