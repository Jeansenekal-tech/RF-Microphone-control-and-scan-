// Trial issuer for Unique AV RF Scan Co-ord (Cloudflare Worker).
//
// The app calls POST / with {"fingerprint": "<sha256 hex>", "name": "<Mac name>"}.
// The worker returns {"key": "<licence key>"}: a new 60-day trial on first request, or the SAME
// trial licence again for a Mac that already had one (so reinstalling never restarts the trial).
//
// Secrets / vars (wrangler secret put …, see LICENSING.md):
//   KEYGEN_ACCOUNT_ID       Keygen account id
//   KEYGEN_TOKEN            Keygen product or admin token (SECRET – never put this in the app)
//   KEYGEN_TRIAL_POLICY_ID  id of the "Trial" policy (60 days, 1 machine, unique per policy)

const JSON_HEADERS = { 'Content-Type': 'application/json' }

function reply(body, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: JSON_HEADERS })
}

export default {
  async fetch(request, env) {
    if (request.method !== 'POST') return reply({ error: 'Use POST' }, 405)

    let input
    try { input = await request.json() } catch { return reply({ error: 'Invalid JSON' }, 400) }
    const fingerprint = String(input.fingerprint || '').toLowerCase()
    const name = String(input.name || 'Mac').slice(0, 80)
    if (!/^[0-9a-f]{64}$/.test(fingerprint)) return reply({ error: 'Invalid fingerprint' }, 400)

    const api = `https://api.keygen.sh/v1/accounts/${env.KEYGEN_ACCOUNT_ID}`
    const headers = {
      Authorization: `Bearer ${env.KEYGEN_TOKEN}`,
      Accept: 'application/vnd.api+json',
      'Content-Type': 'application/vnd.api+json',
    }
    const keygen = async (method, path, body) => {
      const r = await fetch(api + path, { method, headers, body: body ? JSON.stringify(body) : undefined })
      const j = await r.json().catch(() => ({}))
      return { ok: r.ok, status: r.status, json: j }
    }
    const errorOf = (res, fallback) => res.json?.errors?.[0]?.detail || fallback

    // 1. Has this Mac already had a trial? Look for machines with this fingerprint on a trial licence.
    const found = await keygen('GET', `/machines?fingerprint=${fingerprint}&limit=100`)
    if (!found.ok) return reply({ error: errorOf(found, 'Licence server error') }, 502)
    for (const m of found.json.data || []) {
      const licId = m.relationships?.license?.data?.id
      if (!licId) continue
      const lic = await keygen('GET', `/licenses/${licId}`)
      if (lic.ok && lic.json.data?.relationships?.policy?.data?.id === env.KEYGEN_TRIAL_POLICY_ID) {
        return reply({ key: lic.json.data.attributes.key, existing: true })
      }
    }

    // 2. New trial licence (60 days from creation, set on the Trial policy).
    const created = await keygen('POST', '/licenses', {
      data: {
        type: 'licenses',
        attributes: { name: `Trial – ${name}`, metadata: { trial: true, fingerprint } },
        relationships: { policy: { data: { type: 'policies', id: env.KEYGEN_TRIAL_POLICY_ID } } },
      },
    })
    if (!created.ok) return reply({ error: errorOf(created, 'Could not create trial') }, 502)
    const licence = created.json.data

    // 3. Activate this Mac on it straight away, so the fingerprint is recorded against the trial.
    const machine = await keygen('POST', '/machines', {
      data: {
        type: 'machines',
        attributes: { fingerprint, name, platform: 'macOS' },
        relationships: { license: { data: { type: 'licenses', id: licence.id } } },
      },
    })
    if (!machine.ok) {
      // e.g. fingerprint already used by another trial (uniqueness strategy) – don't leave a stray licence.
      await keygen('DELETE', `/licenses/${licence.id}`)
      return reply({ error: errorOf(machine, 'This Mac has already used its trial.') }, 409)
    }
    return reply({ key: licence.attributes.key })
  },
}
