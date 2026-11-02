import React from "react";
import { AbsoluteFill, Easing, Img, OffthreadVideo, interpolate, spring, staticFile, useCurrentFrame, useVideoConfig } from "remotion";
import t from "./timeline.json";

const AMBER = "#FFB42E";
const CREAM = "#FBF6EC";
const INK = "#15161C";
const FONT = "-apple-system, 'SF Pro Display', 'Helvetica Neue', sans-serif";
const CAM = { x: 1237, y: 656, w: 374, h: 374 };
const ZOOM = { scale: 1.443, x: 548, y: 101 };   // moves the search panel to the upper left
const m = t.marks;

const useT = () => useCurrentFrame() / 30;

/** 0 to 1 at `from`, back to 0 at `to`. */
const window01 = (s: number, from: number, to: number, fade = 0.28) =>
  interpolate(s, [from, from + fade, to - fade, to], [0, 1, 1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });

const useSpring = (at: number) => {
  const f = useCurrentFrame();
  const { fps } = useVideoConfig();
  return spring({ frame: f - Math.round(at * 30), fps, config: { damping: 15, stiffness: 120 } });
};

const Screen: React.FC = () => {
  const s = useT();
  const e = interpolate(s, [m.zoom, m.zoom + 0.7], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp", easing: Easing.bezier(0.4, 0, 0.2, 1) });
  const scale = 1 + (ZOOM.scale - 1) * e;
  const endBlur = interpolate(s, [m.end, m.end + 0.5], [0, 16], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  return (
    <AbsoluteFill style={{ filter: endBlur ? `blur(${endBlur}px)` : undefined }}>
      <OffthreadVideo muted src={staticFile(s < m.zoom ? "base.mp4" : "screen.mp4")}
        style={{ width: 1660, height: 1080, transformOrigin: "0 0", transform: `translate(${-ZOOM.x * e}px, ${-ZOOM.y * e}px) scale(${scale})` }} />
    </AbsoluteFill>
  );
};

const Cam: React.FC = () => (
  <div style={{ position: "absolute", left: CAM.x + 3, top: CAM.y + 3, width: CAM.w - 6, height: CAM.h - 6, borderRadius: 86, overflow: "hidden", boxShadow: "0 18px 50px rgba(0,0,0,.35)" }}>
    <OffthreadVideo src={staticFile("base.mp4")} style={{ position: "absolute", left: -CAM.x - 3, top: -CAM.y - 3, width: 1660, height: 1080, maxWidth: "none" }} />
  </div>
);

const Pill: React.FC<{ from: number; to: number; top: number; icon?: boolean; muted?: boolean; children: React.ReactNode }> = ({ from, to, top, icon, muted, children }) => {
  const s = useT();
  const o = window01(s, from, to);
  if (!o) return null;
  return (
    <div style={{ position: "absolute", top, left: 830, transform: `translate(-50%, ${(1 - o) * 10}px)`, opacity: o, display: "flex", alignItems: "center", gap: 12,
      padding: icon ? "8px 24px 8px 10px" : "10px 26px", borderRadius: 40, background: muted ? "rgba(21,22,28,.72)" : CREAM, color: muted ? "#fff" : INK,
      fontFamily: FONT, fontWeight: 600, fontSize: 30, boxShadow: "0 10px 30px rgba(0,0,0,.25)" }}>
      {icon ? <Img src={staticFile("icon.png")} style={{ width: 40, height: 40 }} /> : null}
      {children}
    </div>
  );
};

/** Says what this is while Krishna opens with "some little experiment". */
const Opening: React.FC = () => {
  const s = useT();
  const o = window01(s, 0.1, 3.3, 0.35);
  const p = useSpring(0.1);
  if (!o) return null;
  return (
    <div style={{ position: "absolute", left: 830, top: 250, transform: `translate(-50%, ${(1 - p) * 24}px)`, opacity: o, display: "flex", alignItems: "center", gap: 28,
      padding: "28px 44px 28px 30px", borderRadius: 40, background: "rgba(251,246,236,.94)", boxShadow: "0 24px 70px rgba(0,0,0,.3)", fontFamily: FONT, color: INK, whiteSpace: "nowrap" }}>
      <Img src={staticFile("icon.png")} style={{ width: 104, height: 104 }} />
      <div>
        <div style={{ fontSize: 50, fontWeight: 700, letterSpacing: -0.5 }}>Search your Mac</div>
        <div style={{ fontSize: 50, fontWeight: 700, letterSpacing: -0.5, color: "#C97F00" }}>by what you remember</div>
      </div>
    </div>
  );
};

/** The two real cat photos from the results, large enough to see on a phone. */
const Cats: React.FC = () => {
  const s = useT();
  const o = window01(s, m.cats, m.catsOut, 0.3);
  const a = useSpring(m.cats);
  const b = useSpring(m.cats + 0.25);
  if (!o) return null;
  const card = (src: string, x: number, y: number, r: number, k: number) => (
    <div style={{ position: "absolute", left: x, top: y, width: 270, height: 300, padding: 10, background: CREAM, borderRadius: 24, boxShadow: "0 20px 50px rgba(0,0,0,.35)", transform: `rotate(${r * k}deg) scale(${0.8 + 0.2 * k})`, opacity: Math.min(k * 1.5, 1) }}>
      <Img src={staticFile(src)} style={{ width: "100%", height: "100%", objectFit: "cover", borderRadius: 16 }} />
    </div>
  );
  return <AbsoluteFill style={{ opacity: o }}>{card("cat1.jpg", 1170, 90, -5, a)}{card("cat2.jpg", 1360, 270, 5, b)}</AbsoluteFill>;
};

/** Rings the real time and file count in the panel footer while he says "a little faster". */
const FooterRing: React.FC = () => {
  const s = useT();
  const o = window01(s, m.faster, m.fasterOut, 0.25);
  if (!o) return null;
  return <div style={{ position: "absolute", left: 160, top: 802, width: 290, height: 40, borderRadius: 14, border: `4px solid ${AMBER}`, opacity: o, boxShadow: "0 0 24px rgba(255,180,46,.6)" }} />;
};

const EndCard: React.FC = () => {
  const s = useT();
  const p = useSpring(m.end);
  const o = interpolate(s, [m.end, m.end + 0.4], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  if (!o) return null;
  return (
    <AbsoluteFill style={{ background: `rgba(21,22,28,${0.28 * o})` }}>
      <div style={{ position: "absolute", left: 90, top: 250, width: 1060, opacity: o, transform: `translateY(${(1 - p) * 24}px)`, fontFamily: FONT, color: "#fff" }}>
        <div style={{ display: "flex", alignItems: "center", gap: 30 }}>
          <Img src={staticFile("icon.png")} style={{ width: 150, height: 150 }} />
          <div style={{ fontSize: 92, fontWeight: 700, letterSpacing: -1.5 }}>SearchBetter</div>
        </div>
        <div style={{ marginTop: 34, fontSize: 44, fontWeight: 500 }}>Free and open source, for M1 or newer Macs.</div>
        <div style={{ marginTop: 14, fontSize: 44, fontWeight: 700, color: AMBER }}>Link in the post.</div>
      </div>
    </AbsoluteFill>
  );
};

const Caption: React.FC = () => {
  const s = useT();
  const c = t.caps.find((x) => s >= x.from && s < x.to);
  if (!c) return null;
  const o = interpolate(s, [c.from, c.from + 0.1], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const parts = c.text.split(/(\{[^}]+\})/).filter(Boolean);
  return (
    <div style={{ position: "absolute", left: 30, width: 1190, bottom: 34, textAlign: "center", opacity: o, fontFamily: FONT, fontWeight: 700, fontSize: 56, lineHeight: 1.15, color: "#fff",
      textShadow: "0 0 3px #000, 0 0 3px #000, 0 2px 8px rgba(0,0,0,.95), 0 0 22px rgba(0,0,0,.55)" }}>
      {parts.map((p, i) => p.startsWith("{") ? <span key={i} style={{ color: AMBER }}>{p.slice(1, -1)}</span> : <span key={i}>{p}</span>)}
    </div>
  );
};

export const Teaser: React.FC = () => (
  <AbsoluteFill style={{ background: "#000" }}>
    <Screen />
    <Opening />
    <Pill from={m.spotlightIn} to={m.spotlightOut} top={160} muted>Apple Spotlight</Pill>
    <Pill from={m.oursIn} to={m.oursOut} top={192} icon>SearchBetter</Pill>
    <Cats />
    <FooterRing />
    <EndCard />
    <Cam />
    <Caption />
  </AbsoluteFill>
);
