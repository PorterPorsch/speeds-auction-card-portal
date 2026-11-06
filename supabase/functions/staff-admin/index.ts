// Supabase Edge Function: staff-admin
// Lets a portal admin create staff logins, reset passwords, and turn logins on/off.
// The secret key stays here on the server — it never goes to the browser.
import { createClient } from 'npm:@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const reply = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, 'Content-Type': 'application/json' } });

const PERMS = ['perm_import', 'perm_photos', 'perm_print', 'perm_edit', 'perm_archive', 'perm_admin'];

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const url = Deno.env.get('SUPABASE_URL')!;
    let secret = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
    if (!secret) { try { secret = JSON.parse(Deno.env.get('SUPABASE_SECRET_KEYS') || '{}').default || ''; } catch { /* ignore */ } }
    const admin = createClient(url, secret, { auth: { persistSession: false } });

    // who is calling?
    const token = (req.headers.get('Authorization') || '').replace(/^Bearer\s+/i, '');
    const { data: who, error: whoErr } = await admin.auth.getUser(token);
    if (whoErr || !who?.user) return reply({ error: 'Not signed in' }, 401);
    const { data: me } = await admin.from('staff').select('*').eq('user_id', who.user.id).maybeSingle();
    if (!me || !me.active || !me.perm_admin) return reply({ error: 'Only an admin can manage users' }, 403);

    const body = await req.json();
    const perms = (src: Record<string, unknown>) => Object.fromEntries(PERMS.map(p => [p, !!src?.[p]]));

    if (body.action === 'create') {
      const email = String(body.email || '').trim().toLowerCase();
      const password = String(body.password || '');
      if (!email || password.length < 8) return reply({ error: 'Email and a password of at least 8 characters are required' }, 400);
      const { data, error } = await admin.auth.admin.createUser({ email, password, email_confirm: true });
      if (error) return reply({ error: error.message }, 400);
      const row = { user_id: data.user.id, email, full_name: String(body.full_name || '').trim(), active: true, ...perms(body.perms) };
      const { error: e2 } = await admin.from('staff').insert(row);
      if (e2) { await admin.auth.admin.deleteUser(data.user.id); return reply({ error: e2.message }, 400); }
      return reply({ ok: true, staff: row });
    }

    if (body.action === 'reset_password') {
      const password = String(body.password || '');
      if (password.length < 8) return reply({ error: 'Password must be at least 8 characters' }, 400);
      const { error } = await admin.auth.admin.updateUserById(body.user_id, { password });
      if (error) return reply({ error: error.message }, 400);
      return reply({ ok: true });
    }

    if (body.action === 'set_active') {
      if (body.user_id === who.user.id && !body.active) return reply({ error: "You can't turn off your own login" }, 400);
      const { error } = await admin.auth.admin.updateUserById(body.user_id, { ban_duration: body.active ? 'none' : '876000h' });
      if (error) return reply({ error: error.message }, 400);
      await admin.from('staff').update({ active: !!body.active }).eq('user_id', body.user_id);
      return reply({ ok: true });
    }

    return reply({ error: 'Unknown action' }, 400);
  } catch (e) {
    return reply({ error: String((e as Error)?.message || e) }, 500);
  }
});
