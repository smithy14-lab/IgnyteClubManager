import { supabase, supabaseConfigured } from './supabase';

export type Role = 'parent' | 'athlete' | 'coach' | 'admin' | 'owner';

export interface Profile {
  id: string;
  full_name: string;
  email: string;
  phone: string | null;
  role: Role;
}

export interface Athlete {
  id: string;
  parent_id: string | null;
  profile_id: string | null;
  name: string;
  dob: string;
  notes: string | null;
}

/**
 * Require a signed-in user on an app page. Redirects to /login when there is
 * no session (or to /setup guidance when Supabase env vars are missing).
 * Returns the user's profile.
 */
export async function requireAuth(roles?: Role[]): Promise<Profile> {
  if (!supabaseConfigured) {
    document.body.innerHTML =
      '<div style="padding:4rem 1.5rem;text-align:center;font-family:system-ui">' +
      '<h1 style="font-size:1.4rem">Ignyte Club Manager isn’t configured yet</h1>' +
      '<p style="margin-top:1rem;color:#9090a8">Copy <code>.env.example</code> to <code>.env</code>, add your Supabase URL and anon key, then rebuild. See the README.</p></div>';
    throw new Error('Supabase not configured');
  }
  const { data } = await supabase.auth.getSession();
  if (!data.session) {
    location.href = '/login?next=' + encodeURIComponent(location.pathname + location.search);
    throw new Error('redirecting');
  }
  const { data: profile, error } = await supabase
    .from('profiles')
    .select('*')
    .eq('id', data.session.user.id)
    .single();
  if (error || !profile) {
    await supabase.auth.signOut();
    location.href = '/login';
    throw new Error('redirecting');
  }
  // The platform owner can go anywhere.
  if (roles && profile.role !== 'owner' && !roles.includes(profile.role)) {
    location.href = '/dashboard';
    throw new Error('redirecting');
  }
  return profile as Profile;
}

/** Athletes the current user can book for (their children, or themself). */
export async function myAthletes(): Promise<Athlete[]> {
  const { data: session } = await supabase.auth.getSession();
  const uid = session.session?.user.id;
  if (!uid) return [];
  const { data } = await supabase
    .from('athletes')
    .select('*')
    .or(`parent_id.eq.${uid},profile_id.eq.${uid}`)
    .order('name');
  return (data ?? []) as Athlete[];
}

export function fmtDate(iso: string): string {
  return new Date(iso + 'T00:00:00').toLocaleDateString(undefined, {
    weekday: 'short',
    day: 'numeric',
    month: 'short',
  });
}

export function fmtTime(t: string): string {
  return t.slice(0, 5);
}

export function fmtDateTime(iso: string): string {
  return new Date(iso).toLocaleString(undefined, {
    weekday: 'short',
    day: 'numeric',
    month: 'short',
    hour: '2-digit',
    minute: '2-digit',
  });
}

export function ageFromDob(dob: string): number {
  const d = new Date(dob + 'T00:00:00');
  const now = new Date();
  let age = now.getFullYear() - d.getFullYear();
  const m = now.getMonth() - d.getMonth();
  if (m < 0 || (m === 0 && now.getDate() < d.getDate())) age--;
  return age;
}

export function esc(s: unknown): string {
  return String(s ?? '').replace(
    /[&<>"']/g,
    (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c] as string
  );
}

/** Tiny toast helper — every page uses it for success/error feedback. */
export function toast(message: string, type: 'ok' | 'err' = 'ok'): void {
  let host = document.getElementById('toast-host');
  if (!host) {
    host = document.createElement('div');
    host.id = 'toast-host';
    host.style.cssText =
      'position:fixed;bottom:1.25rem;left:50%;transform:translateX(-50%);z-index:100;display:flex;flex-direction:column;gap:.5rem;align-items:center;width:min(92vw,26rem)';
    document.body.appendChild(host);
  }
  const el = document.createElement('div');
  el.setAttribute('role', 'status');
  el.style.cssText =
    'padding:.65rem 1.1rem;border-radius:.75rem;font-size:.9rem;font-weight:500;width:100%;text-align:center;' +
    'box-shadow:0 10px 30px -10px rgba(0,0,0,.8);border:1px solid;' +
    (type === 'ok'
      ? 'background:#16161f;color:#f4f4f9;border-color:#2a2a39'
      : 'background:#2a1214;color:#ffb3b3;border-color:#5c2326');
  el.textContent = message;
  host.appendChild(el);
  setTimeout(() => el.remove(), 4200);
}

/** Human-readable message out of a Supabase/Postgres error. */
export function errMsg(e: unknown): string {
  const raw =
    (e as { message?: string })?.message ?? (typeof e === 'string' ? e : 'Something went wrong');
  return raw.replace(/^.*?exception:? /i, '');
}

export const skillStatusLabels: Record<string, string> = {
  not_started: 'Not started',
  working_on: 'Working on',
  achieved: 'Achieved',
  mastered: 'Mastered',
};

export const skillStatusOrder = ['not_started', 'working_on', 'achieved', 'mastered'];
