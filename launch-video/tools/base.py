#!/usr/bin/env python3
"""Cuts the raw recording into public/base.mp4 (screen and webcam, with voice) and public/screen.mp4
(screen only, webcam painted out, for zooming), and writes src/timeline.json for the captions."""
import json,subprocess,sys,os
from PIL import Image,ImageDraw,ImageFilter
ROOT=os.path.dirname(os.path.dirname(os.path.abspath(__file__)));P=ROOT+"/public/"
V=sys.argv[1]
CAM=(1237,656,374,374)
ZIP=(1396,172,172,146)     # private desktop file: painted out
PATCH=(1215,172)           # wallpaper next to it
STILL=43.0                 # the cat results stay behind the closing words
SEG=[(0,.52,0),(.70,2.3,0),(3.0,5.9,0),(8.5,9.6,0),(10.75,13.36,0),(13.85,14.21,0),(14.85,15.25,0),(15.57,18.0,0),
(18.85,20.35,0),(20.75,22.25,0),(26.25,33.4,0),(33.75,35.0,0),(35.85,39.3,0),(41.35,43.92,1),
(69.0,69.38,1),(71.1,72.75,1),(73.5,76.35,1),(77.2,79.22,1),(80.3,81.88,1)]
CAP=[(0,2.3,"So I tried some little {experiment}"),(3.0,5.9,"So basically, Apple {Spotlight} search,"),
(10.75,12.45,"I mean, it {takes time},"),(12.45,18.0,"or it doesn't {fetch} actual files that are there"),
(18.85,20.35,"So what we've {built} is"),(20.75,26.85,"a {slightly different} search bar,"),
(26.85,27.65,"or whatever you call it"),(27.65,28.7,"like, for example,"),
(29.95,33.4,"it then {real-time} looks at all the {pictures}"),(33.75,35.0,"These are, for example, some of the pictures"),
(35.85,37.75,"and literally {every picture} has like an"),(37.75,39.3,"{orange cat} in between"),
(41.35,43.92,"and it's a little {faster}"),(69.0,69.38,"So yeah,"),(71.1,72.75,"it's {live}, it's in {beta}"),
(73.5,76.35,"a short, fun little {project} that I've done"),(77.2,78.15,"See if it works out"),(78.15,81.88,"and please do share {feedback}")]
def m(t):
    o=0
    for a,b,_ in SEG:
        if a<=t<=b: return round(o+t-a,3)
        if t<a: return round(o,3)
        o+=b-a
    return round(o,3)
T=sum(b-a for a,b,_ in SEG);HOLD=1.4
json.dump({"total":round(T+HOLD,3),"caps":[{"from":m(a),"to":m(b),"text":t} for a,b,t in CAP],
 "marks":{"spotlightIn":m(8.5),"spotlightOut":m(18.85),"oursIn":m(20.75),"oursOut":m(27.65),"zoom":m(30.3),"cats":m(35.85),"catsOut":m(41.35),"faster":m(41.35),"fasterOut":m(69.0),"end":m(77.2)}},
 open(ROOT+"/src/timeline.json","w"),indent=1)
# feathered mask for the painted-out desktop file
zw,zh=ZIP[2],ZIP[3];im=Image.new("L",(zw,zh),0);ImageDraw.Draw(im).rectangle((12,12,zw-12,zh-12),fill=255)
im.filter(ImageFilter.GaussianBlur(7)).save("/tmp/zipmask.png")
n=len(SEG);f=[]
f.append(f"[0:v]split[raw][forp];[forp]crop={zw}:{zh}:{PATCH[0]}:{PATCH[1]},hflip,format=yuva420p[p0];[p0][1:v]alphamerge[p1];[raw][p1]overlay={ZIP[0]}:{ZIP[1]},split={n+1}[still]"+"".join(f"[v{i}]" for i in range(n)))
k=sum(1 for s in SEG if s[2])
f.append(f"[still]trim=start={STILL}:end={STILL+.04},setpts=PTS-STARTPTS,tpad=stop=-1:stop_mode=clone,trim=duration={T+1},setpts=N/30/TB,split={k}"+"".join(f"[s{i}]" for i,s in enumerate(SEG) if s[2]))
cx,cy,cw,ch=CAM
for i,(a,b,st) in enumerate(SEG):
    d=b-a;tr=f"[v{i}]trim={a}:{b},setpts=PTS-STARTPTS"
    if st:
        f.append(tr+f",crop={cw}:{ch}:{cx}:{cy}[c{i}]")
        f.append(f"[s{i}]trim=duration={d},setpts=PTS-STARTPTS[bg{i}];[bg{i}][c{i}]overlay={cx}:{cy}:shortest=1[o{i}]")
    else: f.append(tr+f"[o{i}]")
    fd=.012
    f.append(f"[0:a]atrim={a}:{b},asetpts=PTS-STARTPTS,afade=t=in:d={fd},afade=t=out:st={max(0,d-fd)}:d={fd}[a{i}]")
f.append("".join(f"[o{i}][a{i}]" for i in range(n))+f"concat=n={n}:v=1:a=1[b0][a0]")
f.append(f"[b0]tpad=stop_mode=clone:stop_duration={HOLD},split[bo][bp]")
f.append(f"[a0]loudnorm=I=-16:TP=-1.5:LRA=11,apad=pad_dur={HOLD}[ao]")
f.append(f"[bp]split[bq][bs];[bq]crop={cw}:{ch}:863:680,hflip[patch];[bs][patch]overlay={cx}:{cy}[so]")
open("/tmp/base.txt","w").write(";\n".join(f))
subprocess.run(["ffmpeg","-v","error","-y","-i",V,"-loop","1","-i","/tmp/zipmask.png","-filter_complex_script","/tmp/base.txt",
 "-map","[bo]","-map","[ao]","-r","30","-c:v","libx264","-crf","15","-preset","fast","-pix_fmt","yuv420p","-c:a","aac","-b:a","192k","-ar","48000","-shortest",P+"base.mp4",
 "-map","[so]","-r","30","-c:v","libx264","-crf","15","-preset","fast","-pix_fmt","yuv420p","-an",P+"screen.mp4"],check=True)
print("total",round(T+HOLD,2))
