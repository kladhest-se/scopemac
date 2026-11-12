import AppKit
let image=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:1024,pixelsHigh:1024,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:image)
NSColor(calibratedRed:0.035,green:0.07,blue:0.12,alpha:1).setFill();NSBezierPath(roundedRect:NSRect(x:24,y:24,width:976,height:976),xRadius:190,yRadius:190).fill()
NSColor(calibratedRed:0.10,green:0.20,blue:0.28,alpha:1).setStroke()
for i in 1...7{let line=NSBezierPath();line.move(to:NSPoint(x:120+i*98,y:145));line.line(to:NSPoint(x:120+i*98,y:880));line.lineWidth=2;line.stroke()}
for i in 0...6{let line=NSBezierPath();line.move(to:NSPoint(x:120,y:180+i*110));line.line(to:NSPoint(x:905,y:180+i*110));line.lineWidth=2;line.stroke()}
let wave=NSBezierPath();wave.move(to:NSPoint(x:110,y:350));for (x,y) in [(230,350),(230,740),(430,740),(430,350),(610,350),(610,740),(800,740),(800,350),(915,350)]{wave.line(to:NSPoint(x:x,y:y))};wave.lineWidth=25;wave.lineJoinStyle = .round;NSColor(calibratedRed:1,green:0.78,blue:0.2,alpha:1).setStroke();wave.stroke()
try image.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
