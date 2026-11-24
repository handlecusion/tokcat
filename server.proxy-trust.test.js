import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import http from 'node:http'
import test from 'node:test'
import express from 'express'
import proxyaddr from 'proxy-addr'

// CVE-2026-90711 / GHSA-jqcg-44mw-7w3h: proxy-addr < 2.0.8 compiled a
// short-prefix IPv4-mapped IPv6 trust subnet (and any IPv6 subnet whose
// leading bits are zero) so that it matched every IPv4 address. Express then
// treated the connecting client as a trusted proxy and returned the
// client-supplied X-Forwarded-For as req.ip.

const SPOOFED_CLIENT = '8.8.8.8'
const SPOOF_HEADERS = {
  'x-forwarded-for': SPOOFED_CLIENT,
  'x-forwarded-proto': 'https',
  'x-forwarded-host': 'evil.example',
}

function createProbe(trustProxy) {
  const app = express()
  app.set('trust proxy', trustProxy)
  app.get('/whoami', (req, res) => {
    res.json({
      ip: req.ip,
      ips: req.ips,
      protocol: req.protocol,
      hostname: req.hostname,
    })
  })
  return app
}

function listen(app) {
  return new Promise((resolve, reject) => {
    const server = http.createServer(app)
    server.once('error', reject)
    server.listen(0, '127.0.0.1', () => resolve(server))
  })
}

function whoami(server, headers) {
  const { port } = server.address()
  return new Promise((resolve, reject) => {
    const req = http.request(
      { hostname: '127.0.0.1', port, path: '/whoami', headers },
      (res) => {
        const chunks = []
        res.on('data', (chunk) => chunks.push(chunk))
        res.on('end', () => {
          resolve(JSON.parse(Buffer.concat(chunks).toString()))
        })
      },
    )
    req.on('error', reject)
    req.end()
  })
}

async function withServer(trustProxy, run) {
  const server = await listen(createProbe(trustProxy))
  try {
    return await run(server)
  } finally {
    await new Promise((resolve, reject) => {
      server.close((err) => (err ? reject(err) : resolve()))
    })
  }
}

test('dev server keeps trust proxy disabled', () => {
  const source = readFileSync(new URL('./server.js', import.meta.url), 'utf8')
  assert.match(source, /app\.set\(\s*'trust proxy'\s*,\s*false\s*\)/)
  assert.equal(
    (source.match(/app\.set\(\s*'trust proxy'/g) || []).length,
    1,
  )
})

test('trust proxy false ignores spoofed forwarded headers', async () => {
  const body = await withServer(false, (server) => whoami(server, SPOOF_HEADERS))
  assert.equal(body.ip, '127.0.0.1')
  assert.deepEqual(body.ips, [])
  assert.equal(body.protocol, 'http')
  assert.notEqual(body.hostname, 'evil.example')
})

test('short-prefix mapped IPv6 trust subnets do not match IPv4', () => {
  const shortMapped = proxyaddr.compile('::ffff:10.0.0.0/8')
  const zeroLeading = proxyaddr.compile('::/1')
  for (const addr of ['8.8.8.8', '10.1.2.3', '127.0.0.1', '192.168.1.10']) {
    assert.equal(shortMapped(addr, 0), false, `${addr} matched ::ffff:10.0.0.0/8`)
    assert.equal(zeroLeading(addr, 0), false, `${addr} matched ::/1`)
  }

  // The same 10.0.0.0/8 block written so the prefix covers the ::ffff: marker.
  const mappedTenSlashEight = proxyaddr.compile('::ffff:10.0.0.0/104')
  assert.equal(mappedTenSlashEight('10.1.2.3', 0), true)
  assert.equal(mappedTenSlashEight('8.8.8.8', 0), false)
  assert.equal(mappedTenSlashEight('127.0.0.1', 0), false)

  const plainTenSlashEight = proxyaddr.compile('10.0.0.0/8')
  assert.equal(plainTenSlashEight('10.1.2.3', 0), true)
  assert.equal(plainTenSlashEight('8.8.8.8', 0), false)
})

test('a short-prefix mapped trust subnet does not honor X-Forwarded-For', async () => {
  for (const trustProxy of ['::ffff:10.0.0.0/8', '::/1']) {
    const body = await withServer(trustProxy, (server) => whoami(server, SPOOF_HEADERS))
    assert.equal(body.ip, '127.0.0.1', trustProxy)
    assert.deepEqual(body.ips, [], trustProxy)
    assert.equal(body.protocol, 'http', trustProxy)
    assert.notEqual(body.hostname, 'evil.example', trustProxy)
  }
})

test('loopback trust still honors forwarded headers from a loopback peer', async () => {
  const body = await withServer('loopback', (server) => whoami(server, SPOOF_HEADERS))
  assert.equal(body.ip, SPOOFED_CLIENT)
  assert.deepEqual(body.ips, [SPOOFED_CLIENT])
  assert.equal(body.protocol, 'https')
  assert.equal(body.hostname, 'evil.example')
})
