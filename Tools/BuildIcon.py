"""Rebuild the code-drawn application icon using macOS Command Line Tools."""
from pathlib import Path
import subprocess, struct
root=Path(__file__).resolve().parent.parent
folder=root/'build/AppIcon.iconset';folder.mkdir(parents=True,exist_ok=True)
subprocess.run(['xcrun','swift','-module-cache-path',str(root/'build/ModuleCache'),str(root/'Tools/MakeIcon.swift'),str(root/'Resources/AppIcon.png')],check=True)
for base in [16,32,128,256,512]:
    for scale in [1,2]:
        name=f'icon_{base}x{base}'+('@2x' if scale==2 else '')+'.png'
        subprocess.run(['sips','-z',str(base*scale),str(base*scale),str(root/'Resources/AppIcon.png'),'--out',str(folder/name)],check=True,capture_output=True)
chunks=[]
for kind,name in [('icp4','icon_16x16.png'),('icp5','icon_32x32.png'),('icp6','icon_32x32@2x.png'),('ic07','icon_128x128.png'),('ic08','icon_256x256.png'),('ic09','icon_512x512.png'),('ic10','icon_512x512@2x.png'),('ic11','icon_16x16@2x.png'),('ic12','icon_32x32@2x.png'),('ic13','icon_128x128@2x.png'),('ic14','icon_256x256@2x.png')]:
    data=(folder/name).read_bytes();chunks.append(kind.encode()+struct.pack('>I',len(data)+8)+data)
data=b''.join(chunks);(root/'Resources/AppIcon.icns').write_bytes(b'icns'+struct.pack('>I',len(data)+8)+data)
