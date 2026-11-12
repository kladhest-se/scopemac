// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import MetalKit

struct MetalPlot: NSViewRepresentable {
    let data: PlotData
    var onTiming: (RenderTiming) -> Void
    func makeCoordinator() -> Renderer { Renderer() }
    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame:.zero,device:MTLCreateSystemDefaultDevice())
        view.isPaused = true; view.enableSetNeedsDisplay = true; view.colorPixelFormat = .bgra8Unorm
        let rgb=data.theme.plotRGB;view.clearColor = MTLClearColor(red:rgb[0],green:rgb[1],blue:rgb[2],alpha:1)
        view.sampleCount = 4; context.coordinator.setup(view); view.delegate = context.coordinator
        context.coordinator.data = data; context.coordinator.onTiming = onTiming
        if let error = context.coordinator.failure {
            let label = NSTextField(wrappingLabelWithString: error); label.textColor = .systemOrange; label.frame = NSRect(x:20,y:20,width:440,height:80); view.addSubview(label)
        }
        return view
    }
    func updateNSView(_ view: MTKView, context: Context) {
        context.coordinator.onTiming = onTiming
        let rgb=data.theme.plotRGB;view.clearColor=MTLClearColor(red:rgb[0],green:rgb[1],blue:rgb[2],alpha:1)
        if context.coordinator.data.id != data.id { context.coordinator.data = data; context.coordinator.dirty = true; view.needsDisplay = true }
    }
}
final class Renderer: NSObject, MTKViewDelegate {
    var data = PlotData(), dirty = true
    var failure: String?
    var onTiming: ((RenderTiming) -> Void)?
    private var drawSequence = 0, completedSequence = 0
    private var pipeline: MTLRenderPipelineState?, queue: MTLCommandQueue?
    private var buffers = [(MTLBuffer,Int,SIMD4<Float>)]()
    static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    vertex float4 scopeVertex(uint id [[vertex_id]], const device float2 *points [[buffer(0)]]) { return float4(points[id],0,1); }
    fragment float4 scopeFragment(constant float4 &color [[buffer(0)]]) { return color; }
    """
    func setup(_ view: MTKView) {
        guard let device = view.device else { failure = "Metal is unavailable. ScopeMac requires a Metal-capable GPU."; return }
        do { let library = try device.makeLibrary(source:Self.shader,options:nil)
            let p = MTLRenderPipelineDescriptor(); p.vertexFunction = library.makeFunction(name:"scopeVertex"); p.fragmentFunction = library.makeFunction(name:"scopeFragment"); p.colorAttachments[0].pixelFormat = view.colorPixelFormat; p.rasterSampleCount = view.sampleCount
            pipeline = try device.makeRenderPipelineState(descriptor:p); queue = device.makeCommandQueue()
        } catch { failure = "Metal renderer could not start: " + error.localizedDescription; NSLog("ScopeMac Metal setup: %@",error.localizedDescription) }
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { dirty = true }
    func draw(in view: MTKView) {
        let start=monotonic(); var timing=RenderTiming()
        guard let pipeline, let queue, let device = view.device, let descriptor = view.currentRenderPassDescriptor, let drawable = view.currentDrawable, let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor:descriptor) else { return }
        if dirty {
            let geometryStart=monotonic(); timing.rebuilt=true
            buffers.removeAll(); let width = max(1,view.bounds.width), height = max(1,view.bounds.height)
            func segment(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ thickness: Float, into points: inout [SIMD2<Float>]) {
                let dx = (b.x-a.x)*Float(width), dy = (b.y-a.y)*Float(height), length = max(0.00001,sqrt(dx*dx+dy*dy))
                let normal = SIMD2<Float>(-dy/length*thickness/Float(width),dx/length*thickness/Float(height))
                points += [a+normal,a-normal,b+normal,b+normal,a-normal,b-normal]
            }
            func store(_ points: [SIMD2<Float>], _ color: SIMD4<Float>) {
                if !points.isEmpty, let buffer = device.makeBuffer(bytes:points,length:points.count*MemoryLayout<SIMD2<Float>>.stride,options:.storageModeShared) { buffers.append((buffer,points.count,color)) }
            }
            var grid = [SIMD2<Float>]()
            for tick in axisTicks(data.xMin,data.xMax,target:6,scale:data.isFFT ? 0.001:1000){let x=Float((tick.value-data.xMin)/(data.xMax-data.xMin)*2-1);segment(SIMD2(x,-1),SIMD2(x,1),0.5,into:&grid)}
            for tick in axisTicks(data.yMin,data.yMax,target:8){let y=Float((tick.value-data.yMin)/(data.yMax-data.yMin)*2-1);segment(SIMD2(-1,y),SIMD2(1,y),0.5,into:&grid)}
            store(grid,data.theme.grid)
            if data.yMin<=0 && data.yMax>=0{var zero=[SIMD2<Float>]();let y=Float((0-data.yMin)/(data.yMax-data.yMin)*2-1);segment(SIMD2(-1,y),SIMD2(1,y),0.7,into:&zero);store(zero,data.theme.zero)}
            for (ch,values) in data.values.enumerated() where values.count > 1 {
                var points = [SIMD2<Float>](), previous: SIMD2<Float>?
                let sampleStart=ch < data.traceStarts.count ? data.traceStarts[ch]:data.sampleStart
                let sampleStep=ch < data.traceSteps.count ? data.traceSteps[ch]:data.sampleStep
                let first=max(0,min(values.count-1,Int(floor((data.xMin-sampleStart)/sampleStep))-1))
                let endIndex=max(first+1,min(values.count,Int(ceil((data.xMax-sampleStart)/sampleStep))+2))
                let strideSize = max(1,(endIndex-first)/max(1,Int(width*2)))
                func add(_ i: Int) {
                    let v = values[i]; guard v.isFinite else { previous = nil; return }
                    let p = SIMD2<Float>(Float((sampleStart+Double(i)*sampleStep-data.xMin)/(data.xMax-data.xMin)*2-1),Float((v-data.yMin)/(data.yMax-data.yMin)*2-1))
                    if let a = previous { segment(a,p,1.25,into:&points) }; previous = p
                }
                for i in stride(from:first,to:endIndex,by:strideSize) {
                    let end = min(endIndex,i+strideSize); var low=i,high=i
                    for j in i..<end { if values[j] < values[low] { low=j }; if values[j] > values[high] { high=j } }
                    add(min(low,high)); if low != high { add(max(low,high)) }
                }
                if (endIndex-1-first)%strideSize != 0 { add(endIndex-1) }
                store(points,traceColor(ch<data.colorIndices.count ? data.colorIndices[ch]:ch,theme:data.theme))
            }; dirty = false; timing.geometryMS=(monotonic()-geometryStart)*1000
        }
        encoder.setRenderPipelineState(pipeline)
        for (buffer,count,color) in buffers { var c = color; encoder.setVertexBuffer(buffer,offset:0,index:0); encoder.setFragmentBytes(&c,length:MemoryLayout<SIMD4<Float>>.stride,index:0); encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:count) }
        encoder.endEncoding(); command.present(drawable)
        timing.submitMS=max(0,(monotonic()-start)*1000-timing.geometryMS)
        drawSequence += 1; let sequence=drawSequence, measured=timing
        command.addCompletedHandler { [weak self] buffer in
            var result=measured
            if buffer.status == .completed && buffer.gpuEndTime > buffer.gpuStartTime && buffer.gpuStartTime > 0 { result.gpuMS=(buffer.gpuEndTime-buffer.gpuStartTime)*1000 }
            let completed=result
            DispatchQueue.main.async { guard let self, sequence >= self.completedSequence else { return }; self.completedSequence=sequence; self.onTiming?(completed) }
        }
        command.commit()
    }
}
struct Chart: View {
    @ObservedObject var model: ScopeModel
    var body: some View {
        GeometryReader { geometry in
            let left: CGFloat = 64, right: CGFloat = 18, top: CGFloat = 24, bottom: CGFloat = 44
            let width = max(1,geometry.size.width-left-right), height = max(1,geometry.size.height-top-bottom)
            let p = model.plot
            ZStack(alignment:.topLeading) {
                MetalPlot(data:p,onTiming:model.recordRender).frame(width:width,height:height).offset(x:left,y:top)
                ForEach(axisTicks(p.yMin,p.yMax,target:8)){tick in
                    Text(tick.label).font(.system(size:11,design:.monospaced)).foregroundStyle(.secondary)
                        .frame(width:left-8,alignment:.trailing).position(x:(left-8)/2,y:top+CGFloat((p.yMax-tick.value)/(p.yMax-p.yMin))*height)
                }
                ForEach(axisTicks(p.xMin,p.xMax,target:6,scale:p.isFFT ? 0.001:1000)){tick in
                    Text(tick.label).font(.system(size:11,design:.monospaced)).foregroundStyle(.secondary)
                        .position(x:left+CGFloat((tick.value-p.xMin)/(p.xMax-p.xMin))*width,y:top+height+15)
                }
                Text(p.isFFT ? "Frequency (kHz) · dBV RMS · Hann window, DC removed":"Time (ms) · Voltage (V)").font(.caption).foregroundStyle(.secondary).position(x:left+width/2,y:top+height+34)
                if model.cursors && !p.isFFT {
                    ForEach(0..<2) { index in
                        let x = index == 0 ? model.cursorA:model.cursorB
                        let px = left+CGFloat((x-p.xMin)/(p.xMax-p.xMin))*width
                        if px >= left && px <= left+width {
                            Path { path in path.move(to:CGPoint(x:px,y:top)); path.addLine(to:CGPoint(x:px,y:top+height)) }.stroke(index == 0 ? Color.primary:Color.pink,style:StrokeStyle(lineWidth:1,dash:[5,4]))
                            Text(index == 0 ? "A":"B").font(.system(size:12,weight:.bold)).frame(width:28,height:24).background(index == 0 ? Color.gray:Color.pink).clipShape(RoundedRectangle(cornerRadius:5)).position(x:px,y:top+12)
                        }
                    }

                }
                let visiblePeaks=p.peaks.filter{$0.frequency>=p.xMin && $0.frequency<=p.xMax}
                let peakAnchors=visiblePeaks.map{CGPoint(x:left+CGFloat(($0.frequency-p.xMin)/(p.xMax-p.xMin))*width,y:top+height-CGFloat(($0.db-p.yMin)/(p.yMax-p.yMin))*height)}
                let peakTexts=visiblePeaks.map{formatFrequency($0.frequency)}
                let peakSizes=peakTexts.map{CGSize(width:CGFloat($0.count)*6.6+10,height:18)}
                let peakLabels=layoutPointLabels(anchors:peakAnchors,sizes:peakSizes,bounds:CGRect(x:left,y:top,width:width,height:height))
                ForEach(Array(visiblePeaks.indices),id:\.self) {i in
                    Circle().stroke(channelTint(model.fftSource,theme:model.theme),lineWidth:1.5).frame(width:8,height:8).position(peakAnchors[i])
                    if let center=peakLabels[i] {
                        Text(peakTexts[i]).font(.caption2.monospacedDigit()).lineLimit(1).fixedSize().padding(.horizontal,4).padding(.vertical,2).foregroundStyle(.white).background(.black.opacity(0.75)).clipShape(RoundedRectangle(cornerRadius:3)).position(center)
                    }
                }.allowsHitTesting(false)
                ForEach(Array(model.hoverReadouts.indices),id:\.self){i in
                    let sample=model.hoverReadouts[i]
                    let x=left+CGFloat((sample.time-p.xMin)/(p.xMax-p.xMin))*width,y=top+height-CGFloat((sample.value-p.yMin)/(p.yMax-p.yMin))*height
                    if x>=left && x<=left+width && y>=top && y<=top+height{Circle().stroke(channelTint(sample.channel<p.colorIndices.count ? p.colorIndices[sample.channel]:sample.channel,theme:model.theme),lineWidth:2).frame(width:8,height:8).position(x:x,y:y)}
                }.allowsHitTesting(false)
                if !model.hoverReadouts.isEmpty{
                    Text(model.hoverReadouts.map{sample in
                        let name=p.isFFT ? "FFT CH\(model.fftSource+1)":model.mode == "CH1 + CH2" ? "Math":sample.channel<2 ? "CH\(sample.channel+1)":"Ref CH\(sample.channel-1)"
                        return name+" "+(p.isFFT ? formatFrequency(sample.time,digits:5)+String(format:" · %.4g dBV",sample.value):String(format:"%.5g ms · %.4g V",sample.time*1000,sample.value))
                    }.joined(separator:"   |   ")).font(.system(.caption,design:.monospaced)).lineLimit(1).minimumScaleFactor(0.7).padding(5).foregroundStyle(.white).background(.black.opacity(0.8)).clipShape(RoundedRectangle(cornerRadius:4)).frame(maxWidth:width-12).position(x:left+width/2,y:top+height-14).allowsHitTesting(false)
                }
                PlotInteraction(model:model).frame(width:width,height:height).offset(x:left,y:top)
                if p.values.allSatisfy(\.isEmpty) { Text(model.connected || model.demo || model.playbackLoaded ? "No samples for this view. Select an enabled source channel.":"Connect a scope or choose Demo").foregroundStyle(.secondary).position(x:left+width/2,y:top+height/2) }
            }
        }.frame(minHeight:220)
    }
}

struct PlotInteraction: NSViewRepresentable {
    @ObservedObject var model: ScopeModel
    func makeNSView(context: Context) -> PlotInputView { let view=PlotInputView(); view.model=model; return view }
    func updateNSView(_ view: PlotInputView, context: Context) { view.model=model }
}
final class PlotInputView: NSView {
    weak var model: ScopeModel?
    private var lastX: CGFloat=0
    private var movingCursor=false
    private var tracking:NSTrackingArea?
    private var lastHover=0.0
    override func updateTrackingAreas(){super.updateTrackingAreas();if let tracking{removeTrackingArea(tracking)};let area=NSTrackingArea(rect:.zero,options:[.activeInKeyWindow,.inVisibleRect,.mouseMoved,.mouseEnteredAndExited],owner:self,userInfo:nil);addTrackingArea(area);tracking=area}
    override func mouseMoved(with event:NSEvent){let now=monotonic();guard now-lastHover>=0.03 else{return};lastHover=now;model?.updateHover(fraction(event))}
    override func mouseExited(with event:NSEvent){model?.updateHover(nil)}
    override func mouseUp(with event:NSEvent){model?.updateHover(fraction(event))}
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    private func fraction(_ event: NSEvent) -> Double { min(1,max(0,Double(convert(event.locationInWindow,from:nil).x/max(1,bounds.width)))) }
    private func cursor(_ event: NSEvent) {
        guard let model else { return }; let p=model.plot, x=p.xMin+fraction(event)*(p.xMax-p.xMin)
        if model.selectedCursor == 0 { model.cursorA=x } else { model.cursorB=x }
    }
    override func mouseDown(with event: NSEvent) {
        guard let model else { return };model.updateHover(nil)
        if event.clickCount == 2 { model.fitPlot(); return }
        movingCursor=model.cursors && !model.plot.isFFT && !event.modifierFlags.contains(.option)
        lastX=convert(event.locationInWindow,from:nil).x
        if movingCursor { cursor(event) }
    }
    override func mouseDragged(with event: NSEvent) {
        if movingCursor { cursor(event); return }
        let x=convert(event.locationInWindow,from:nil).x
        model?.panPlot(fraction:Double((lastX-x)/max(1,bounds.width))); lastX=x
    }
    override func scrollWheel(with event: NSEvent) {
        guard let model else { return }
        if event.modifierFlags.contains(.shift) || abs(event.scrollingDeltaX)>abs(event.scrollingDeltaY) {
            let delta=event.modifierFlags.contains(.shift) ? event.scrollingDeltaY:event.scrollingDeltaX
            model.panPlot(fraction:Double(delta/max(1,bounds.width)))
        } else {
            let sensitivity=event.hasPreciseScrollingDeltas ? 0.008:0.08
            model.zoomPlot(factor:exp(min(0.5,max(-0.5,Double(event.scrollingDeltaY)*sensitivity))),anchor:fraction(event))
        }
    }
    override func magnify(with event: NSEvent) { model?.zoomPlot(factor:max(0.1,1+Double(event.magnification)),anchor:fraction(event)) }
}
