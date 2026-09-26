import math, random, sys
out = sys.argv[1]
W = 1024; cx, cy, R = 512, 375, 238
N = 8
scales = [1.0, 0.64, 0.36]
def pt(r, a): return (cx + r*math.cos(a), cy + r*math.sin(a))
rings = []
for k, s in enumerate(scales):
    off = -math.pi/2 + k*math.pi/N
    rings.append([pt(R*s - (14 if k == 0 else 0), off + i*2*math.pi/N) for i in range(N)])
web = []
for k in range(1, len(rings)):
    for i in range(N):
        a = rings[k][i]; b0 = rings[k-1][i]; b1 = rings[k-1][(i+1) % N]
        web.append(f'M{b0[0]:.1f},{b0[1]:.1f} L{a[0]:.1f},{a[1]:.1f} L{b1[0]:.1f},{b1[1]:.1f}')
inner = rings[-1]
web_d = ' '.join(web)

random.seed(7)
stars = []
for _ in range(38):
    x, y = random.uniform(40, 984), random.uniform(40, 984)
    if math.hypot(x-cx, y-cy) < R+60 or (y > 600 and abs(x-cx) < 260): continue
    r = random.choice([2, 2.5, 3, 4])
    stars.append(f'<circle cx="{x:.0f}" cy="{y:.0f}" r="{r}" fill="#fff" opacity="{random.uniform(.35,.9):.2f}"/>')

def feather(x, top, length, color, tilt):
    w = length*0.27
    L = length
    body = (f'M0,0 C{w*0.9:.1f},{L*0.18:.1f} {w*1.05:.1f},{L*0.62:.1f} {w*0.35:.1f},{L*0.96:.1f} '
            f'Q0,{L*1.04:.1f} {-w*0.35:.1f},{L*0.96:.1f} '
            f'C{-w*1.05:.1f},{L*0.62:.1f} {-w*0.9:.1f},{L*0.18:.1f} 0,0 Z')
    barbs = ''.join(f'<path d="M0,{L*t:.1f} L{side*w*0.75:.1f},{L*(t+0.10):.1f}" stroke="#1b1745" stroke-opacity=".28" stroke-width="5" stroke-linecap="round"/>'
                    for t in (0.28, 0.46, 0.64) for side in (1, -1))
    return (f'<g transform="translate({x:.1f},{top:.1f}) rotate({tilt})">'
            f'<path d="{body}" fill="{color}"/>{barbs}'
            f'<path d="M0,-6 L0,{L*0.97:.1f}" stroke="#fff6e0" stroke-width="6" stroke-linecap="round" opacity=".9"/></g>')

hang = []
for ang_deg, length, color, tilt, drop in ((138, 175, "#b99cf0", 6, 62), (90, 205, "#ff9d7a", 0, 72), (42, 175, "#6fd6e0", -6, 62)):
    a = math.radians(ang_deg)
    sx, sy = cx + (R+10)*math.cos(a), cy + (R+10)*math.sin(a)
    ty = sy + drop
    hang.append(f'<path d="M{sx:.1f},{sy:.1f} L{sx:.1f},{ty:.1f}" stroke="#f3d79a" stroke-width="7" stroke-linecap="round"/>')
    hang.append(f'<circle cx="{sx:.1f}" cy="{sy+drop*0.5:.1f}" r="13" fill="#fff1cc"/>')
    hang.append(feather(sx, ty, length, color, tilt))

svg = f'''<svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
<defs>
 <linearGradient id="sky" x1="0" y1="0" x2="0" y2="1">
  <stop offset="0" stop-color="#2b2474"/><stop offset=".55" stop-color="#1a1650"/><stop offset="1" stop-color="#0c0a2a"/></linearGradient>
 <radialGradient id="glow" cx="{cx}" cy="{cy}" r="420" gradientUnits="userSpaceOnUse">
  <stop offset="0" stop-color="#8f7cff" stop-opacity=".55"/><stop offset=".6" stop-color="#5b4bd6" stop-opacity=".18"/><stop offset="1" stop-color="#5b4bd6" stop-opacity="0"/></radialGradient>
 <linearGradient id="gold" x1="0" y1="0" x2="1" y2="1">
  <stop offset="0" stop-color="#fff3cf"/><stop offset=".5" stop-color="#f5cf7e"/><stop offset="1" stop-color="#e3a95a"/></linearGradient>
 <filter id="soft" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="10"/></filter>
</defs>
<rect width="1024" height="1024" fill="url(#sky)"/>
<rect width="1024" height="1024" fill="url(#glow)"/>
{''.join(stars)}
<circle cx="{cx}" cy="{cy}" r="{R}" fill="none" stroke="#f5cf7e" stroke-width="40" opacity=".45" filter="url(#soft)"/>
<circle cx="{cx}" cy="{cy}" r="{R-14}" fill="#0e0b33" opacity=".35"/>
<path d="{web_d}" fill="none" stroke="#e9e2ff" stroke-width="8" stroke-linejoin="round" stroke-linecap="round" opacity=".8"/>
{''.join(hang)}
<circle cx="{cx}" cy="{cy}" r="{R}" fill="none" stroke="url(#gold)" stroke-width="30"/>
<g transform="translate({cx},{cy})">
 <circle r="62" fill="#fff4d6" opacity=".25" filter="url(#soft)"/>
 <path d="M18,-50 A52,52 0 1 0 50,22 A40,40 0 1 1 18,-50 Z" fill="#fff4d6"/>
</g>
</svg>'''
open(out, 'w').write(f'<!doctype html><html><body style="margin:0;background:#0c0a2a">{svg}</body></html>')
