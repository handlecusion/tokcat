import React from 'react'
import {
  AbsoluteFill,
  Easing,
  Img,
  interpolate,
  staticFile,
  useCurrentFrame,
} from 'remotion'

const ease = Easing.bezier(0.16, 1, 0.3, 1)

function fade(frame: number, start: number, end: number, from = 0, to = 1) {
  return interpolate(frame, [start, end], [from, to], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: ease,
  })
}

function move(frame: number, start: number, end: number, from: number, to: number) {
  return interpolate(frame, [start, end], [from, to], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
    easing: ease,
  })
}

const c = {
  deep: '#000000',
  ghost: '#ffffff',
  slate: '#a1a1a1',
  pale: '#f4f0ff',
  glow: '#bbdef2',
  flare: '#d1aad7',
  crimson: '#ff6467',
  golden: '#ffd600',
  emerald: '#72ce7b',
  panel: 'rgba(255,255,255,0.055)',
  line: 'rgba(255,255,255,0.15)',
}

const clients = [
  ['Claude Code', 92, c.glow],
  ['Codex', 68, c.flare],
  ['Cursor', 54, c.emerald],
  ['Gemini', 38, c.golden],
] as const

const cells = Array.from({ length: 14 * 8 }, (_, i) => {
  const x = i % 14
  const y = Math.floor(i / 14)
  const active = (x * 3 + y * 7) % 10
  return {
    x,
    y,
    opacity: active === 0 ? 0.08 : 0.16 + (active % 5) * 0.13,
    color: active % 4 === 0 ? c.glow : active % 4 === 1 ? c.flare : active % 4 === 2 ? c.emerald : c.ghost,
  }
})

export const TokcatLandingMotion = () => {
  const frame = useCurrentFrame()
  const drift = interpolate(frame, [0, 210], [0, -42], {
    extrapolateLeft: 'clamp',
    extrapolateRight: 'clamp',
  })
  const shimmer = interpolate(Math.sin(frame / 16), [-1, 1], [0.22, 0.48])
  const dashboardOpacity = fade(frame, 0, 32, 0.7, 1)
  const clientOpacity = fade(frame, 62, 92)
  const privacyOpacity = fade(frame, 118, 150)

  return (
    <AbsoluteFill
      style={{
        background: c.deep,
        color: c.ghost,
        fontFamily:
          "Inter, -apple-system, BlinkMacSystemFont, 'SF Pro Display', 'SF Pro Text', 'Helvetica Neue', Arial, sans-serif",
        overflow: 'hidden',
      }}
    >
      <div
        style={{
          position: 'absolute',
          inset: 0,
          backgroundImage:
            'linear-gradient(rgba(255,255,255,0.055) 1px, transparent 1px), linear-gradient(90deg, rgba(255,255,255,0.055) 1px, transparent 1px)',
          backgroundSize: '72px 72px',
          transform: `translateY(${drift}px)`,
          opacity: 0.55,
        }}
      />
      <div
        style={{
          position: 'absolute',
          inset: 0,
          background:
            'radial-gradient(circle at 76% 24%, rgba(187,222,242,0.18), transparent 330px), radial-gradient(circle at 21% 75%, rgba(209,170,215,0.12), transparent 360px)',
        }}
      />

      <div
        style={{
          position: 'absolute',
          right: 78,
          top: 96,
          width: 460,
          height: 460,
          transform: `rotate(${move(frame, 0, 210, -8, 9)}deg)`,
          opacity: shimmer,
          clipPath: 'polygon(21% 0%, 92% 16%, 74% 100%, 0% 76%)',
          background:
            'linear-gradient(135deg, rgba(187,222,242,0.72), rgba(209,170,215,0.32) 45%, rgba(255,255,255,0.08))',
          filter: 'blur(0.2px)',
        }}
      />
      <div
        style={{
          position: 'absolute',
          right: 454,
          bottom: 78,
          width: 240,
          height: 240,
          opacity: 0.23,
          clipPath: 'polygon(50% 0%, 100% 38%, 82% 100%, 12% 86%, 0% 28%)',
          background:
            'linear-gradient(160deg, rgba(255,255,255,0.48), rgba(26,26,26,0.72) 52%, rgba(187,222,242,0.42))',
        }}
      />

      <div
        style={{
          position: 'absolute',
          right: 112,
          top: 132,
          width: 700,
          height: 610,
          opacity: dashboardOpacity,
          transform: `translate(${move(frame, 0, 36, 42, 0)}px, ${move(frame, 0, 36, 18, 0)}px) scale(${move(
            frame,
            0,
            36,
            0.97,
            1
          )})`,
        }}
      >
        <div
          style={{
            position: 'absolute',
            inset: 0,
            borderRadius: 8,
            border: `1px solid ${c.line}`,
            background: 'rgba(2,2,2,0.78)',
            boxShadow: 'rgba(255,255,255,0.1) 0 1px 1px 0 inset',
            padding: 22,
          }}
        >
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 18 }}>
            <span style={{ width: 8, height: 8, borderRadius: 99, background: c.crimson }} />
            <span style={{ width: 8, height: 8, borderRadius: 99, background: c.golden }} />
            <span style={{ width: 8, height: 8, borderRadius: 99, background: c.emerald }} />
            <div style={{ flex: 1 }} />
            <span style={{ color: c.slate, fontSize: 15 }}>3D contribution graph</span>
          </div>
          <Img
            src={staticFile('remotion/dashboard-3d.png')}
            style={{
              width: '100%',
              height: 502,
              objectFit: 'cover',
              borderRadius: 8,
              border: `1px solid ${c.line}`,
              filter: 'grayscale(1) invert(1) contrast(1.08) brightness(0.82)',
              opacity: 0.92,
            }}
          />
        </div>
      </div>

      <div
        style={{
          position: 'absolute',
          right: 116,
          bottom: 66,
          width: 310,
          opacity: clientOpacity,
          transform: `translateY(${move(frame, 62, 92, 34, 0)}px)`,
        }}
      >
        <div
          style={{
            borderRadius: 8,
            border: `1px solid ${c.line}`,
            background: 'rgba(2,2,2,0.9)',
            boxShadow: 'rgba(255,255,255,0.1) 0 1px 1px 0 inset',
            padding: 18,
          }}
        >
          <div style={{ fontSize: 18, marginBottom: 14 }}>Client mix</div>
          {clients.map(([label, value, color], index) => (
            <div key={label} style={{ marginBottom: index === clients.length - 1 ? 0 : 13 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', color: c.pale, fontSize: 14, marginBottom: 7 }}>
                <span>{label}</span>
                <span style={{ color: c.slate }}>{value}%</span>
              </div>
              <div style={{ height: 7, borderRadius: 4, background: 'rgba(255,255,255,0.1)', overflow: 'hidden' }}>
                <div
                  style={{
                    width: `${interpolate(frame, [74, 120], [0, value], {
                      extrapolateLeft: 'clamp',
                      extrapolateRight: 'clamp',
                      easing: ease,
                    })}%`,
                    height: '100%',
                    background: color,
                    opacity: 0.92,
                  }}
                />
              </div>
            </div>
          ))}
        </div>
      </div>

      <div
        style={{
          position: 'absolute',
          left: 594,
          bottom: 70,
          width: 286,
          opacity: clientOpacity,
          transform: `translateY(${move(frame, 72, 106, 28, 0)}px)`,
        }}
      >
        <div
          style={{
            borderRadius: 8,
            border: `1px solid ${c.line}`,
            background: 'rgba(2,2,2,0.9)',
            boxShadow: 'rgba(255,255,255,0.1) 0 1px 1px 0 inset',
            padding: 18,
          }}
        >
          <div style={{ display: 'flex', alignItems: 'baseline', gap: 8 }}>
            <span style={{ fontSize: 46, lineHeight: 1, fontWeight: 400, color: c.ghost }}>
              {Math.round(interpolate(frame, [78, 126], [0, 2514], { extrapolateRight: 'clamp', easing: ease })).toLocaleString(
                'en-US'
              )}
            </span>
            <span style={{ color: c.slate, fontSize: 16 }}>USD</span>
          </div>
          <div style={{ color: c.slate, fontSize: 16, lineHeight: 1.45, marginTop: 10 }}>Four month AI coding spend surfaced from local logs.</div>
        </div>
      </div>

      <div
        style={{
          position: 'absolute',
          left: 594,
          top: 166,
          width: 286,
          opacity: privacyOpacity,
          transform: `translateY(${move(frame, 118, 150, -22, 0)}px)`,
        }}
      >
        <div
          style={{
            borderRadius: 8,
            border: `1px solid ${c.line}`,
            background: 'rgba(2,2,2,0.88)',
            boxShadow: 'rgba(255,255,255,0.1) 0 1px 1px 0 inset',
            padding: 18,
          }}
        >
          <div style={{ fontSize: 18, marginBottom: 15 }}>No telemetry</div>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(14, 1fr)', gap: 4 }}>
            {cells.map((cell) => (
              <span
                key={`${cell.x}-${cell.y}`}
                style={{
                  width: 12,
                  height: 12,
                  borderRadius: 4,
                  background: cell.color,
                  opacity: cell.opacity * fade(frame, 126 + cell.x, 160 + cell.y),
                }}
              />
            ))}
          </div>
        </div>
      </div>
    </AbsoluteFill>
  )
}
