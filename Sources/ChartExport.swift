// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
func traceColor(_ index: Int,theme:ScopeTheme = .dark) -> SIMD4<Float> {
    if theme == .light{return [SIMD4<Float>(0.64,0.48,0,1),SIMD4<Float>(0.02,0.48,0.20,1),SIMD4<Float>(0.72,0.18,0.48,1),SIMD4<Float>(0.30,0.27,0.72,1)][index%4]}
    return [SIMD4<Float>(1,0.79,0.22,1),SIMD4<Float>(0.20,0.90,0.40,1),SIMD4<Float>(1,0.40,0.76,1),SIMD4<Float>(0.64,0.58,1,1)][index%4]
}
enum ChartExport {
    static func png(plot: PlotData,title: String,measurements: String,receivedUTC: Double,cursors: (Double,Double)? = nil) throws -> Data {
        let width=1600,height=1000
        guard let bitmap=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:width,pixelsHigh:height,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0),let graphics=NSGraphicsContext(bitmapImageRep:bitmap) else {throw ScopeError("Cannot create image buffer")}
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=graphics;defer{NSGraphicsContext.restoreGraphicsState()}
        let palette=plot.theme.plotRGB,ink:NSColor=plot.theme == .light ? .black:.white,secondary:NSColor=plot.theme == .light ? .darkGray:.lightGray
        let c=graphics.cgContext;c.setFillColor(NSColor(calibratedRed:palette[0],green:palette[1],blue:palette[2],alpha:1).cgColor);c.fill(CGRect(x:0,y:0,width:width,height:height))
        func text(_ string: String,_ rect: NSRect,_ size: CGFloat=16,_ color: NSColor? = nil) {
            c.saveGState();defer{c.restoreGState()}
            let style=NSMutableParagraphStyle();style.lineBreakMode = .byWordWrapping
            (string as NSString).draw(in:rect,withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:size,weight:.regular),.foregroundColor:color ?? ink,.paragraphStyle:style])
        }
        text("ScopeMac · "+title,NSRect(x:90,y:945,width:1420,height:32),24)
        let date=ISO8601DateFormatter().string(from:Date(timeIntervalSince1970:receivedUTC))
        text("Host receipt: "+date+" · USB snapshot",NSRect(x:90,y:915,width:1420,height:24),14,secondary)
        let area=CGRect(x:100,y:190,width:1440,height:700)
        let grid=plot.theme.grid;c.setStrokeColor(CGColor(red:CGFloat(grid.x),green:CGFloat(grid.y),blue:CGFloat(grid.z),alpha:1));c.setLineWidth(1)
        for tick in axisTicks(plot.xMin,plot.xMax,target:6,scale:plot.isFFT ? 0.001:1000){let x=area.minX+area.width*(tick.value-plot.xMin)/(plot.xMax-plot.xMin);c.move(to:CGPoint(x:x,y:area.minY));c.addLine(to:CGPoint(x:x,y:area.maxY));c.strokePath();text(tick.label,NSRect(x:x-25,y:155,width:90,height:24),14,secondary)}
        for tick in axisTicks(plot.yMin,plot.yMax,target:8){let y=area.minY+area.height*(tick.value-plot.yMin)/(plot.yMax-plot.yMin);c.move(to:CGPoint(x:area.minX,y:y));c.addLine(to:CGPoint(x:area.maxX,y:y));c.strokePath();text(tick.label,NSRect(x:8,y:y-10,width:88,height:24),14,secondary)}
        if plot.yMin<=0 && plot.yMax>=0{let y=area.minY+area.height*(-plot.yMin)/(plot.yMax-plot.yMin);let zero=plot.theme.zero;c.setStrokeColor(CGColor(red:CGFloat(zero.x),green:CGFloat(zero.y),blue:CGFloat(zero.z),alpha:1));c.move(to:CGPoint(x:area.minX,y:y));c.addLine(to:CGPoint(x:area.maxX,y:y));c.strokePath()}
        text(plot.isFFT ? "Frequency (kHz) · Amplitude (dBV RMS)":"Time (ms) · Voltage (V)",NSRect(x:560,y:125,width:650,height:24),16,secondary)
        c.saveGState();c.clip(to:area);c.setLineWidth(1.5)
        for (ch,values) in plot.values.enumerated() where values.count>1 {
            let color=traceColor(ch<plot.colorIndices.count ? plot.colorIndices[ch]:ch,theme:plot.theme);c.setStrokeColor(CGColor(red:CGFloat(color.x),green:CGFloat(color.y),blue:CGFloat(color.z),alpha:1))
            let origin=ch<plot.traceStarts.count ? plot.traceStarts[ch]:plot.sampleStart,step=ch<plot.traceSteps.count ? plot.traceSteps[ch]:plot.sampleStep
            let begin=max(0,min(values.count-1,Int(floor((plot.xMin-origin)/step))-1)),end=max(begin+1,min(values.count,Int(ceil((plot.xMax-origin)/step))+2))
            let strideSize=max(1,(end-begin)/2880);var started=false
            func add(_ i: Int) {guard values[i].isFinite else{c.strokePath();started=false;return};let point=CGPoint(x:area.minX+(origin+Double(i)*step-plot.xMin)/(plot.xMax-plot.xMin)*area.width,y:area.minY+(values[i]-plot.yMin)/(plot.yMax-plot.yMin)*area.height);if started{c.addLine(to:point)}else{c.move(to:point);started=true}}
            for i in stride(from:begin,to:end,by:strideSize) {let stop=min(end,i+strideSize);var low=i,high=i;for j in i..<stop{if values[j]<values[low]{low=j};if values[j]>values[high]{high=j}};add(min(low,high));if low != high{add(max(low,high))}}
            add(end-1);c.strokePath()
        }
        if plot.isFFT {
            let color=traceColor(plot.colorIndices.first ?? 0,theme:plot.theme);c.setStrokeColor(CGColor(red:CGFloat(color.x),green:CGFloat(color.y),blue:CGFloat(color.z),alpha:1))
            let peaks=plot.peaks.filter{$0.frequency>=plot.xMin && $0.frequency<=plot.xMax}
            let anchors=peaks.map{CGPoint(x:area.minX+($0.frequency-plot.xMin)/(plot.xMax-plot.xMin)*area.width,y:area.minY+($0.db-plot.yMin)/(plot.yMax-plot.yMin)*area.height)}
            let labels=peaks.map{formatFrequency($0.frequency)},sizes=labels.map{CGSize(width:CGFloat($0.count)*8+8,height:20)}
            let centers=layoutPointLabels(anchors:anchors,sizes:sizes,bounds:area,yDown:false)
            for i in peaks.indices {
                c.strokeEllipse(in:CGRect(x:anchors[i].x-4,y:anchors[i].y-4,width:8,height:8))
                if let center=centers[i] {text(labels[i],NSRect(x:center.x-sizes[i].width/2+4,y:center.y-sizes[i].height/2,width:sizes[i].width,height:sizes[i].height),13)}
            }
        }
        if let cursors,!plot.isFFT {
            for (index,x) in [cursors.0,cursors.1].enumerated() where x>=plot.xMin && x<=plot.xMax {
                let px=area.minX+(x-plot.xMin)/(plot.xMax-plot.xMin)*area.width
                c.setStrokeColor((index==0 ? ink:NSColor.systemPink).cgColor);c.setLineDash(phase:0,lengths:[6,4]);c.move(to:CGPoint(x:px,y:area.minY));c.addLine(to:CGPoint(x:px,y:area.maxY));c.strokePath();c.setLineDash(phase:0,lengths:[])
                text(index==0 ? "A":"B",NSRect(x:px+5,y:area.maxY-24,width:24,height:22),15)
            }
        }
        c.restoreGState()
        text(measurements,NSRect(x:90,y:48,width:1420,height:60),16)
        text(plot.isFFT ? "FFT spectrum · Hann window · DC removed" : title == "CH1 + CH2" ? "Math: CH1 + CH2" : plot.values.count>2 ? "Yellow CH1 · Green CH2 · Pink reference CH1 · Violet reference CH2 (trigger aligned)":"Yellow CH1 · Green CH2",NSRect(x:90,y:12,width:1420,height:26),13,secondary)
        guard let data=bitmap.representation(using:.png,properties:[:])else{throw ScopeError("Cannot encode PNG")};return data
    }
}
