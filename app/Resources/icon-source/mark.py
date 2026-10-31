import numpy as np
from PIL import Image
S=1024; SS=3; N=S*SS
xs=(np.arange(N)+.5)/SS; X,Y=np.meshgrid(xs,xs)   # 1024 grid, y down
aa=1.0/SS
def cov(d): return np.clip(.5-d/(2*aa)*1.0,0,1)      # d: signed distance in grid units
def circle(cx,cy,r): return np.hypot(X-cx,Y-cy)-r
def ring(cx,cy,r,t): return np.abs(np.hypot(X-cx,Y-cy)-r)-t/2
def seg(ax,ay,bx,by,r):
    px,py=X-ax,Y-ay; dx,dy=bx-ax,by-ay; h=np.clip((px*dx+py*dy)/(dx*dx+dy*dy),0,1)
    return np.hypot(px-h*dx,py-h*dy)-r
# macOS tile: superellipse 824 wide, centred.
tile=np.clip((1-(np.abs((X-512)/412)**5.0+np.abs((Y-512)/412)**5.0))*400/1,0,1)
def vgrad(top,bot):
    t=np.clip((Y-100)/824,0,1)[...,None]; return np.array(top)[None,None]*(1-t)+np.array(bot)[None,None]*t
def over(base,col,a):
    a=a[...,None]; c=np.array(col)[None,None] if not isinstance(col,np.ndarray) else col
    return base*(1-a)+c*a
def blur_glow(d,sig): return np.exp(-(np.maximum(d,0)/sig)**2)
def finish(rgb,name):
    # A faint light along the top edge, as on Apple's own tiles.
    rim=np.clip(1-((np.abs((X-512)/408)**5.0+np.abs((Y-512)/408)**5.0)),0,1)
    edge=(rim<0.05)*sstep_top()
    rgb=rgb+edge[...,None]*0.05
    out=np.dstack([np.clip(rgb,0,1),tile])
    pm=out[...,:3]*out[...,3:]
    pm=pm.reshape(S,SS,S,SS,3).mean((1,3)); a=out[...,3].reshape(S,SS,S,SS).mean((1,3))
    c=np.where(a[...,None]>1e-3,pm/np.maximum(a[...,None],1e-3),0)
    Image.fromarray((np.clip(np.dstack([c,a]),0,1)*255+.5).astype('uint8'),'RGBA').save(name)
def sstep_top(): return np.clip((512-Y)/412,0,1)
c=lambda h:[int(h[i:i+2],16)/255 for i in (1,3,5)]
CX,CY,R=462,462,176; T=50; H0=(CX+(R+T*0.1)*.7071,CY+(R+T*0.1)*.7071); H1=(CX+(R+156)*.7071,CY+(R+156)*.7071)
def mark(base,col,t=T,r=R):
    d=np.minimum(ring(CX,CY,r,t),seg(H0[0],H0[1],H1[0],H1[1],t/2)); return over(base,col,cov(d)),d
# 1 Found: a calm ink tile, a warm white lens, one point of light inside it: the thing you remembered.
b=vgrad(c('#1b1e2b'),c('#0c0d14'))
g=np.exp(-(np.hypot(X-CX,Y-CY)/190)**2)[...,None]*np.array(c('#2c3350'))[None,None]*.55; b=b+g
b,_=mark(b,c('#f6f3ec'))
b=over(b,c('#ffb86b'),cov(circle(CX+34,CY-34,30)))
finish(b,'a.png')
# 2 Blue calm: deep blue tile, white mark, nothing else.
b=vgrad(c('#2f54eb'),c('#1a2fa8'))
b,_=mark(b,c('#ffffff'),t=46)
finish(b,'b.png')
# 3 Paper: warm white tile, ink mark, one blue point.
b=vgrad(c('#fdfcf9'),c('#ece9e1'))
b,_=mark(b,c('#16181f'))
b=over(b,c('#2f54eb'),cov(circle(CX+34,CY-34,30)))
finish(b,'c.png')
# 4 Dusk: the lens itself glows softly, as if it lights what it looks at. No outline tricks.
b=vgrad(c('#161a2c'),c('#0a0b12'))
ld=np.clip(1-np.hypot(X-CX+40,Y-CY+50)/330,0,1)[...,None]
lens=np.array(c('#6d7cff'))[None,None]*ld*1.05+np.array(c('#1a1f3a'))[None,None]
inside=cov(circle(CX,CY,R))
b=over(b,lens,inside)
b,_=mark(b,c('#f4f5fa'),t=44)
finish(b,'d.png')
