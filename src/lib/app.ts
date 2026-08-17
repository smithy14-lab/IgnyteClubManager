import { supabase, supabaseConfigured } from './supabase';

export type Role = 'parent' | 'athlete' | 'coach' | 'admin' | 'owner';
export type ClubRole = 'parent' | 'athlete' | 'coach' | 'admin';

export interface Profile {
  id: string;
  full_name: string;
  email: string;
  phone: string | null;
  role: Role;
  last_club_id: string | null;
}

export interface Membership {
  club_id: string;
  role: ClubRole;
  status: 'active' | 'pending' | 'removed';
  clubs: {
    id: string;
    name: string;
    slug: string;
    status: string;
    plan: string;
    addons: string[] | null;
    logo_path: string | null;
    accent_color: string | null;
  };
}

export interface ActiveClub {
  id: string;
  name: string;
  slug: string;
  status: string;
  plan: string;
  addons: string[];
  role: ClubRole | 'owner';
  accent_color: string | null;
  logo_path: string | null;
}

/** The columns every club query needs so capability gating works. */
export const CLUB_COLS = 'id, name, slug, status, plan, addons, logo_path, accent_color';

/**
 * A club's package = exactly what the owner enabled. The whole app shows only
 * these. Model: club/comped plans get everything; any à-la-carte club's surface
 * IS its `addons` list (nothing baseline); a plan with no addons falls back to
 * the free/small baseline. Some features are derived (payments rides with any
 * billable module; progress/enrolments ride with lessons/classes).
 */
export type Feature =
  | 'privates' | 'classes' | 'memberships' | 'shop' | 'events'
  | 'website' | 'websitepro' | 'payments' | 'progress' | 'enrolments' | 'forms';

const ALL_FEATURES: Feature[] = [
  'privates', 'classes', 'memberships', 'shop', 'events',
  'website', 'websitepro', 'payments', 'progress', 'enrolments', 'forms',
];

export function clubFeatures(club: { plan: string; addons?: string[] | null }): Set<string> {
  if (club.plan === 'club' || club.plan === 'comped') return new Set<string>(ALL_FEATURES);
  const addons = club.addons ?? [];
  const s = new Set<string>(['forms']); // forms (waivers) are always available
  // à-la-carte club → its surface is EXACTLY its addons (fully modular: a club
  // can have just 'classes', or just 'enrolments', or just 'privates', etc.);
  // a plan with no addons falls back to the free/small baseline.
  const base = addons.length ? [...addons] : ['classes', 'enrolments', 'shop', 'events', 'website'];
  if (club.plan === 'small' && !addons.includes('privates')) base.push('privates');
  base.forEach((a) => s.add(a));
  // derived-only conveniences (never force one primary module from another)
  if (s.has('privates') || s.has('memberships') || s.has('classes') || s.has('enrolments')) s.add('payments');
  if (s.has('privates') || s.has('classes') || s.has('enrolments')) s.add('progress');
  if (s.has('websitepro')) s.add('website');
  return s;
}

export function hasFeature(club: { plan: string; addons?: string[] | null }, key: Feature): boolean {
  return clubFeatures(club).has(key);
}

export interface AuthCtx {
  profile: Profile;
  memberships: Membership[];
  club: ActiveClub | null;
}

export interface Athlete {
  id: string;
  parent_id: string | null;
  profile_id: string | null;
  name: string;
  dob: string;
  notes: string | null;
  medical_notes: string | null;
  media_consent: boolean;
}

const CLUB_KEY = 'icm-active-club';

export function storedClubId(): string | null {
  return localStorage.getItem(CLUB_KEY);
}

export async function setActiveClub(clubId: string): Promise<void> {
  localStorage.setItem(CLUB_KEY, clubId);
  const { data } = await supabase.auth.getSession();
  if (data.session) {
    await supabase.from('profiles').update({ last_club_id: clubId }).eq('id', data.session.user.id);
  }
  // Purge cached club data so nothing bleeds across the switch.
  if ('caches' in window) {
    const keys = await caches.keys();
    await Promise.all(keys.filter((k) => k.startsWith('ignyte-data')).map((k) => caches.delete(k)));
  }
}

export function applyClubBranding(club: ActiveClub | null): void {
  if (club?.accent_color && club.plan !== 'free') {
    const root = document.documentElement;
    root.style.setProperty('--color-ignite-500', club.accent_color);
    root.style.setProperty('--color-ignite-600', club.accent_color);
    root.style.setProperty('--color-ignite-400', club.accent_color);
  }
}

/**
 * Require a signed-in user, resolve their memberships and the active club.
 * clubRoles: which roles-in-club may view this page ('any' = any member).
 * The platform owner passes every check; with ?club= they can enter any club.
 */
export async function requireAuth(clubRoles?: ClubRole[] | 'any'): Promise<AuthCtx> {
  if (!supabaseConfigured) {
    document.body.innerHTML =
      '<div style="padding:4rem 1.5rem;text-align:center;font-family:system-ui">' +
      '<h1 style="font-size:1.4rem">Not configured</h1><p style="margin-top:1rem;color:#9090a8">Add Supabase env vars and rebuild.</p></div>';
    throw new Error('Supabase not configured');
  }
  const { data } = await supabase.auth.getSession();
  if (!data.session) {
    location.href = '/login?next=' + encodeURIComponent(location.pathname + location.search);
    throw new Error('redirecting');
  }
  const uid = data.session.user.id;
  const [{ data: profile }, { data: memberships }] = await Promise.all([
    supabase.from('profiles').select('*').eq('id', uid).single(),
    supabase
      .from('club_members')
      .select(`club_id, role, status, clubs(${CLUB_COLS})`)
      .eq('profile_id', uid),
  ]);
  if (!profile) {
    await supabase.auth.signOut();
    location.href = '/login';
    throw new Error('redirecting');
  }

  const all = (memberships ?? []) as unknown as Membership[];
  const usable = all.filter((m) => m.status === 'active' && m.clubs?.status === 'active');
  const isOwner = profile.role === 'owner';

  // Resolve the active club: URL ?club= → stored → last → sole → null
  let club: ActiveClub | null = null;
  const urlClub = new URLSearchParams(location.search).get('club');
  const pick = (id: string | null): Membership | undefined =>
    id ? usable.find((m) => m.club_id === id) : undefined;
  const chosen =
    pick(urlClub) ?? pick(storedClubId()) ?? pick(profile.last_club_id) ?? (usable.length === 1 ? usable[0] : undefined);

  if (chosen) {
    club = {
      id: chosen.club_id,
      name: chosen.clubs.name,
      slug: chosen.clubs.slug,
      status: chosen.clubs.status,
      plan: chosen.clubs.plan,
      addons: chosen.clubs.addons ?? [],
      role: chosen.role,
      accent_color: chosen.clubs.accent_color,
      logo_path: chosen.clubs.logo_path,
    };
  } else if (isOwner) {
    // Owner acting inside a club they're not a member of (support access).
    // The "key" is ?club= on entry, then localStorage so it survives navigation.
    const supportId = urlClub ?? storedClubId();
    if (supportId) {
      const { data: c } = await supabase.from('clubs').select('*').eq('id', supportId).single();
      if (c) {
        club = { id: c.id, name: c.name, slug: c.slug, status: c.status, plan: c.plan, addons: c.addons ?? [], role: 'owner', accent_color: c.accent_color, logo_path: c.logo_path };
      } else {
        localStorage.removeItem(CLUB_KEY);
      }
    }
  }

  if (club) localStorage.setItem(CLUB_KEY, club.id);
  applyClubBranding(club);

  if (clubRoles) {
    if (!club) {
      if (isOwner) {
        // owner without a club context heads to their console
        if (!location.pathname.startsWith('/owner')) {
          location.href = '/owner';
          throw new Error('redirecting');
        }
      } else {
        location.href = '/clubs';
        throw new Error('redirecting');
      }
    } else if (clubRoles !== 'any' && club.role !== 'owner' && !clubRoles.includes(club.role as ClubRole)) {
      location.href = '/dashboard';
      throw new Error('redirecting');
    }
  }

  return { profile: profile as Profile, memberships: all, club };
}

/** Guard for the owner console. */
export async function requireOwner(): Promise<AuthCtx> {
  const ctx = await requireAuth();
  if (ctx.profile.role !== 'owner') {
    location.href = '/dashboard';
    throw new Error('redirecting');
  }
  return ctx;
}

/** Athletes the current user can book for, with enrolment state for a club. */
export async function myAthletes(clubId?: string): Promise<(Athlete & { enrolled: boolean })[]> {
  const { data: session } = await supabase.auth.getSession();
  const uid = session.session?.user.id;
  if (!uid) return [];
  const { data } = await supabase
    .from('athletes')
    .select('*')
    .or(`parent_id.eq.${uid},profile_id.eq.${uid}`)
    .order('name');
  const athletes = (data ?? []) as Athlete[];
  if (!clubId || !athletes.length) return athletes.map((a) => ({ ...a, enrolled: true }));
  const { data: enr } = await supabase
    .from('athlete_enrolments')
    .select('athlete_id')
    .eq('club_id', clubId)
    .in('athlete_id', athletes.map((a) => a.id));
  const set = new Set((enr ?? []).map((e) => e.athlete_id));
  return athletes.map((a) => ({ ...a, enrolled: set.has(a.id) }));
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

/** Today as YYYY-MM-DD in the user's own timezone (toISOString is UTC — wrong late at night in BST). */
export function todayISO(): string {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

export function errMsg(e: unknown): string {
  const raw =
    (e as { message?: string })?.message ?? (typeof e === 'string' ? e : 'Something went wrong');
  const msg = raw.replace(/^.*?exception:? /i, '');
  // Postgres/PostgREST internals nobody should read — translate the common ones.
  if (/^JWT expired/i.test(msg)) return 'Your session expired — refresh the page and sign in again.';
  if (/Failed to fetch|NetworkError|Load failed/i.test(msg)) return "Can't reach the server — check your connection and try again.";
  if (/duplicate key value/i.test(msg)) return 'That already exists — no need to add it twice.';
  if (/violates foreign key/i.test(msg)) return "That can't be removed while other records still use it.";
  if (/violates row-level security|permission denied/i.test(msg)) return "You don't have permission to do that in this club.";
  if (/invalid input syntax/i.test(msg)) return 'One of the values doesn’t look right — check the form and try again.';
  return msg;
}

export const skillStatusLabels: Record<string, string> = {
  not_started: 'Not started',
  working_on: 'Working on',
  achieved: 'Achieved',
  mastered: 'Mastered',
};

export const skillStatusOrder = ['not_started', 'working_on', 'achieved', 'mastered'];
