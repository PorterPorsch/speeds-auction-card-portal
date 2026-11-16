// Supabase Edge Function: read-bidder-number
// Looks at one auction photo and reads the bidder number written on the sticker on the person's chest.
// It only reads the number — it never tries to recognize the person.
// Needs one secret:  ANTHROPIC_API_KEY   (optional: READ_MODEL to change the model)
import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

const PROMPT = `This photo was taken at an auto auction check-in. The person is wearing a white sticker on their chest
(printed "Speeds Auto Auction" at the top) with a bidder number handwritten on it in marker. They may also be holding a
sheet of paper with the same number written at the top.
Read that handwritten bidder number. Ignore every other number in the picture (phone numbers, signs, clothing, dates).
Answer with JSON only: {"number":"<digits exactly as written, or empty string>","confident":true|false}
Set confident to false if any digit is covered, smudged, cut off, or could be read two ways, or if there is no sticker.`;

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const url = Deno.env.get('SUPABASE_URL')!;
    let secret = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
    if (!secret) { try { secret = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') || '{}').default || ''; } catch { /* ignore */ } }
    const admin = createClient(url, secret, { auth: { persistSession: false } });

    // only signed-in staff who can work with photos
    const token = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
    const { data: who, error: whoErr } = await admin.auth.getUser(token);
    if (whoErr || !who?.user) return reply({ error: 'Not signed in' }, 401);
    const { data: me } = await admin.from('staff').select('*').eq('user_id', who.user.id).maybeSingle();
    if (!me || !me.active || !(me.perm_photos || me.perm_admin)) return reply({ error: 'No permission for photos' }, 403);

    const key = Deno.env.get('ANTHROPIC_API_KEY');
    if (!key) return reply({ error: 'not_configured' });

    const { image } = await req.json();
    if (typeof image !== 'string' || image.length < 1000 || image.length > 4_000_000) return reply({ error: 'Bad image' }, 400);

    const r = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: { 'x-api-key': key, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
      body: JSON.stringify({
        model: Deno.env.get('READ_MODEL') || 'claude-haiku-5-5',
        max_tokens: 60,
        messages: [{ role: 'user', content: [
          { type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: image } },
          { type: 'text', text: PROMPT },
        ] }],
      }),
    });
    if (!r.ok) return reply({ error: `Reader error ${r.status}`, detail: (await r.text()).slice(0, 300) }, 502);
    const out = await r.json();
    const text = (out?.content || []).map((c: { text?: string }) => c.text || '').join('');
    let number = '', confident = false;
    try {
      const j = JSON.parse(text.slice(text.indexOf('{'), text.lastIndexOf('}') + 1));
      number = String(j.number ?? '').replace(/[^0-9*]/g, '');
      confident = j.confident === true && number.length >= 2;
    } catch { /* leave blank — a person will type it */ }
    return reply({ number, confident });
  } catch (e) {
    return reply({ error: String((e as Error)?.message || e) }, 500);
  }
});
