// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
struct WindowLayoutBridge:NSViewRepresentable {
    @ObservedObject var model:ScopeModel
    func makeNSView(context:Context)->LayoutObserverView{let v=LayoutObserverView();v.model=model;return v}
    func updateNSView(_ view:LayoutObserverView,context:Context){view.model=model;let changed=view.visible != model.inspectorVisible || abs(view.desiredWidth-model.sidebarWidth)>1;view.visible=model.inspectorVisible;view.desiredWidth=model.sidebarWidth;if changed{view.configureLater()}}
}
final class LayoutObserverView:NSView {
    weak var model:ScopeModel?
    var visible=true,desiredWidth=280.0
    private weak var observedWindow:NSWindow?,split:NSSplitView?
    private var observer:NSObjectProtocol?
    private var closeObserver:NSObjectProtocol?
    override func hitTest(_ point:NSPoint)->NSView?{nil}
    override func viewDidMoveToWindow(){super.viewDidMoveToWindow();configureLater()}
    func configureLater(){DispatchQueue.main.asyncAfter(deadline:.now()+0.05){[weak self] in self?.configure()}}
    private func findSplit(_ root:NSView)->NSSplitView?{if let s=root as? NSSplitView,s.isVertical,s.subviews.count==2{return s};for v in root.subviews{if let s=findSplit(v){return s}};return nil}
    private func configure(){
        guard let window,let model else{return}
        if observedWindow !== window{if let closeObserver{NotificationCenter.default.removeObserver(closeObserver)};closeObserver=NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:window,queue:.main){_ in NSApp.terminate(nil)};observedWindow=window;_=window.setFrameUsingName("ScopeMac.mainWindow");window.setFrameAutosaveName("ScopeMac.mainWindow")}
        guard visible,let content=window.contentView,let current=findSplit(content) else{return}
        if split !== current{if let observer{NotificationCenter.default.removeObserver(observer)};split=current
            observer=NotificationCenter.default.addObserver(forName:NSSplitView.didResizeSubviewsNotification,object:current,queue:.main){[weak self] _ in
                guard let self,let split=self.split,split.subviews.count==2,let model=self.model else{return};let width=Double(split.subviews[1].frame.width);guard width>=259,width<=461,abs(width-model.sidebarWidth)>1 else{return};model.sidebarWidth=width
            }
        }
        current.layoutSubtreeIfNeeded();let position=max(660,current.bounds.width-CGFloat(model.sidebarWidth)-current.dividerThickness);if abs(Double(current.subviews[1].frame.width)-model.sidebarWidth)>1{current.setPosition(position,ofDividerAt:0)}
    }
    deinit{if let observer{NotificationCenter.default.removeObserver(observer)};if let closeObserver{NotificationCenter.default.removeObserver(closeObserver)}}
}
