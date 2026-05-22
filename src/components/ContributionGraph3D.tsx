import React, { useEffect, useMemo, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { Canvas, useThree } from '@react-three/fiber'
import { OrthographicCamera, OrbitControls } from '@react-three/drei'
import type { OrbitControls as OrbitControlsImpl } from 'three-stdlib'
import * as THREE from 'three'
import type { GridLayout } from '../lib/grid'
import { formatCost, formatMonthDay, humanizeTokens } from '../lib/format'

interface Props {
  grid: GridLayout
  activeLight?: string
  activeDark?: string
  accent?: string
}

const CELL = 1
const GAP = 0.15
const STEP = CELL + GAP
const BASE_HEIGHT = 0.35
const MAX_HEIGHT = 4.0

// Per-face shading: top is lighter than sides for a stylized 3D tile look.
const COLOR_INACTIVE_TOP = new THREE.Color('#ffffff')
const COLOR_INACTIVE_SIDE = new THREE.Color('#eaedf2')

function darken(c: THREE.Color, factor: number): THREE.Color {
  return new THREE.Color(c.r * factor, c.g * factor, c.b * factor)
}

interface HoverInfo {
  date: string
  tokens: number
  cost: number
  x: number
  y: number
}

interface CamState {
  px: number; py: number; pz: number
  tx: number; ty: number; tz: number
  zoom: number
}

const STORAGE_KEY = 'tokcat:orbit:v1'

function loadCam(): CamState | null {
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    if (!raw) return null
    return JSON.parse(raw)
  } catch {
    return null
  }
}

function saveCam(s: CamState) {
  try { localStorage.setItem(STORAGE_KEY, JSON.stringify(s)) } catch {}
}

export function ContributionGraph3D({ grid, activeLight = '#bfdbfe', activeDark = '#1e3a8a', accent = '#2563eb' }: Props) {
  const [hover, setHover] = useState<HoverInfo | null>(null)
  const wrapRef = useRef<HTMLDivElement | null>(null)
  const controlsRef = useRef<OrbitControlsImpl | null>(null)
  const invalidateRef = useRef<(() => void) | null>(null)

  const totalWidth = grid.cols * STEP
  const totalDepth = grid.rows * STEP
  const offsetX = -totalWidth / 2
  const offsetZ = -totalDepth / 2
  const max = Math.max(grid.maxTokens, 1)

  const colorActiveLight = useMemo(() => new THREE.Color(activeLight), [activeLight])
  const colorActiveDark = useMemo(() => new THREE.Color(activeDark), [activeDark])

  const cells = useMemo(() => {
    return grid.cells.map((c, i) => {
      if (!c.inYear) return null
      const x = offsetX + c.col * STEP + STEP / 2
      const z = offsetZ + c.row * STEP + STEP / 2
      let height = BASE_HEIGHT
      let isActive = false
      let topColor = COLOR_INACTIVE_TOP
      let sideColor = COLOR_INACTIVE_SIDE
      if (c.active) {
        const norm = Math.pow(c.tokens / max, 0.6)
        height = BASE_HEIGHT + norm * MAX_HEIGHT
        isActive = true
        const t = Math.min(1, Math.max(0, Math.pow(c.tokens / max, 0.5)))
        topColor = new THREE.Color().lerpColors(colorActiveLight, colorActiveDark, t)
        sideColor = darken(topColor, 0.78)
      }
      return { c, i, x, z, height, isActive, topColor, sideColor }
    })
  }, [grid, max, offsetX, offsetZ, colorActiveLight, colorActiveDark])

  // Initial camera placement
  const initialCam = useMemo<CamState>(() => {
    const saved = loadCam()
    if (saved) return saved
    return {
      px: totalWidth * 0.7,
      py: totalWidth * 0.45,
      pz: totalWidth * 0.7,
      tx: 0, ty: 0, tz: 0,
      zoom: 10,
    }
  }, [totalWidth])

  function persist() {
    const ctrl = controlsRef.current
    if (!ctrl) return
    const cam = ctrl.object as THREE.OrthographicCamera
    saveCam({
      px: cam.position.x, py: cam.position.y, pz: cam.position.z,
      tx: ctrl.target.x, ty: ctrl.target.y, tz: ctrl.target.z,
      zoom: cam.zoom,
    })
  }

  function fitView() {
    const ctrl = controlsRef.current
    const wrap = wrapRef.current
    if (!ctrl || !wrap) return
    const cam = ctrl.object as THREE.OrthographicCamera
    ctrl.target.set(0, 0, 0)
    cam.position.set(totalWidth * 0.7, totalWidth * 0.45, totalWidth * 0.7)
    cam.up.set(0, 1, 0)
    cam.lookAt(0, 0, 0)
    cam.updateMatrixWorld(true)
    const w = wrap.clientWidth, h = wrap.clientHeight
    if (!w || !h) { ctrl.update(); persist(); return }
    // Frame the active tiles when any exist, so most days at a glance shows
    // the populated cluster rather than the empty future. Fall back to the
    // full grid AABB when there's nothing active yet.
    const corners: THREE.Vector3[] = []
    const activeCells = cells.filter(
      (item): item is NonNullable<typeof cells[number]> => !!item && item.isActive,
    )
    if (activeCells.length > 0) {
      const halfCell = CELL / 2
      for (const item of activeCells) {
        for (const dx of [-halfCell, halfCell]) {
          for (const dz of [-halfCell, halfCell]) {
            for (const sy of [0, item.height]) {
              corners.push(new THREE.Vector3(item.x + dx, sy, item.z + dz))
            }
          }
        }
      }
    } else {
      const halfX = totalWidth / 2
      const halfZ = totalDepth / 2
      for (const sx of [-halfX, halfX]) {
        for (const sz of [-halfZ, halfZ]) {
          for (const sy of [0, MAX_HEIGHT]) {
            corners.push(new THREE.Vector3(sx, sy, sz))
          }
        }
      }
    }
    const inv = new THREE.Matrix4().copy(cam.matrixWorld).invert()
    let minSx = Infinity, maxSx = -Infinity, minSy = Infinity, maxSy = -Infinity
    for (const c of corners) {
      const v = c.clone().applyMatrix4(inv)
      if (v.x < minSx) minSx = v.x
      if (v.x > maxSx) maxSx = v.x
      if (v.y < minSy) minSy = v.y
      if (v.y > maxSy) maxSy = v.y
    }
    const screenW = Math.max(maxSx - minSx, 0.0001)
    const screenH = Math.max(maxSy - minSy, 0.0001)
    const padding = 0.85
    const zoomX = (w * padding) / screenW
    const zoomY = (h * padding) / screenH
    cam.zoom = Math.min(zoomX, zoomY)
    // Center the AABB by adjusting target
    const centerSx = (minSx + maxSx) / 2
    const centerSy = (minSy + maxSy) / 2
    if (Math.abs(centerSx) > 0.001 || Math.abs(centerSy) > 0.001) {
      const camRight = new THREE.Vector3(1, 0, 0).applyQuaternion(cam.quaternion)
      const camUp = new THREE.Vector3(0, 1, 0).applyQuaternion(cam.quaternion)
      const offset = new THREE.Vector3()
        .addScaledVector(camRight, centerSx)
        .addScaledVector(camUp, centerSy)
      ctrl.target.add(offset)
      cam.position.add(offset)
    }
    cam.updateProjectionMatrix()
    ctrl.update()
    persist()
    invalidateRef.current?.()
  }

  // Auto-fit on first mount when canvas size is known
  const didFitRef = useRef(false)
  useEffect(() => {
    const wrap = wrapRef.current
    if (!wrap) return
    const tryFit = () => {
      if (didFitRef.current) return
      if (loadCam()) { didFitRef.current = true; return }
      if (!wrap.clientWidth || !wrap.clientHeight) return
      if (!controlsRef.current) return
      didFitRef.current = true
      fitView()
    }
    tryFit()
    const ro = new ResizeObserver(tryFit)
    ro.observe(wrap)
    return () => ro.disconnect()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  return (
    <div className="graph-3d-wrap" ref={wrapRef}>
      <Canvas
        dpr={[1, 2]}
        frameloop="demand"
        gl={{ antialias: true, alpha: true, preserveDrawingBuffer: true }}
        style={{ width: '100%', height: '100%' }}
        onCreated={(state) => {
          invalidateRef.current = state.invalidate
        }}
      >
        <OrthographicCamera
          makeDefault
          position={[initialCam.px, initialCam.py, initialCam.pz]}
          zoom={initialCam.zoom}
          near={-1000}
          far={1000}
        />
        <OrbitControls
          ref={controlsRef as any}
          target={[initialCam.tx, initialCam.ty, initialCam.tz]}
          enableRotate
          enablePan
          enableZoom
          zoomToCursor
          panSpeed={1.0}
          rotateSpeed={0.7}
          zoomSpeed={1.0}
          minZoom={1}
          maxZoom={80}
          onChange={() => { invalidateRef.current?.(); persist() }}
        />
        <ambientLight intensity={0.7} />
        <directionalLight position={[20, 30, 15]} intensity={0.8} />
        <directionalLight position={[-15, 20, -10]} intensity={0.25} />

        {cells.map(item => {
          if (!item) return null
          const { c, x, z, height, isActive, topColor, sideColor } = item
          return (
            <mesh
              key={c.date}
              position={[x, height / 2, z]}
              onPointerOver={(e) => {
                e.stopPropagation()
                if (!isActive) return
                setHover({
                  date: c.date,
                  tokens: c.tokens,
                  cost: c.cost,
                  x: e.clientX,
                  y: e.clientY,
                })
              }}
              onPointerOut={() => setHover(null)}
              onPointerMove={(e) => {
                if (!isActive) return
                setHover(h => h ? { ...h, x: e.clientX, y: e.clientY } : null)
              }}
            >
              <boxGeometry args={[CELL, height, CELL]} />
              {/* face order: +X, -X, +Y(top), -Y(bottom), +Z, -Z */}
              <meshStandardMaterial attach="material-0" color={sideColor} roughness={0.6} metalness={0.04} />
              <meshStandardMaterial attach="material-1" color={sideColor} roughness={0.6} metalness={0.04} />
              <meshStandardMaterial attach="material-2" color={topColor} roughness={0.5} metalness={0.04} />
              <meshStandardMaterial attach="material-3" color={sideColor} roughness={0.6} metalness={0.04} />
              <meshStandardMaterial attach="material-4" color={sideColor} roughness={0.6} metalness={0.04} />
              <meshStandardMaterial attach="material-5" color={sideColor} roughness={0.6} metalness={0.04} />
            </mesh>
          )
        })}
      </Canvas>
      {hover &&
        createPortal(
          <div
            className="graph-tooltip"
            style={{ left: hover.x + 12, top: hover.y + 12 }}
          >
            <div className="tt-date">{formatMonthDay(hover.date)}</div>
            <div className="tt-line">{humanizeTokens(hover.tokens)} tokens</div>
            <div className="tt-line">{formatCost(hover.cost)}</div>
          </div>,
          document.body,
        )}
      <div style={{
        position: 'absolute',
        top: 8,
        right: 8,
        zIndex: 10,
        display: 'flex',
        gap: 6,
      }}>
        <button
          onClick={fitView}
          style={{
            border: `1px solid ${accent}`,
            background: 'rgba(255,255,255,0.7)',
            color: accent,
            borderRadius: 4,
            padding: '4px 10px',
            cursor: 'pointer',
            fontSize: 11,
            fontWeight: 600,
          }}
        >
          Fit
        </button>
        <button
          onClick={() => {
            try { localStorage.removeItem(STORAGE_KEY) } catch {}
            didFitRef.current = false
            fitView()
          }}
          style={{
            border: '1px solid #d1d5db',
            background: '#f9fafb',
            color: '#374151',
            borderRadius: 4,
            padding: '4px 10px',
            cursor: 'pointer',
            fontSize: 11,
          }}
        >
          Reset
        </button>
      </div>
    </div>
  )
}
