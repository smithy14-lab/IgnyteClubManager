import { supabase, supabaseConfigured } from './supabase';

export type Role = 'owner' | 'admin' | 'coach' | 'parent' | 'athlete';

export interface Profile {
  id: string;
  full_name: string;
  email: string;
  phone: string | null;
  is_platform_owner: boolean;
}

export interface Club {
  id: string;
  name: string;
  slug: string;
  join_code: string | null;
  venue: string | null;
  timezone: string;
  lesson_minutes: number;
  lesson_price_pence: number;
  currency: string;
  cancel_hours: number;
  status: string;
  roles: Role[];
}

export interface Ctx {
  profile: Profile;
  clubs: Club[];
  /** The club this page is working in (null when the user has none yet). */
  club: Club | null;
}

export interface ScheduleRow {
  slot_id: string;
  starts_at: string;
  minutes: number;
  price_pence: number;
  slot_status: 'open' | 'booked' | 'cancelled';
  coach_id: string;
  coach_name: string;
  lesson_id: string | null;
  lesson_status: string | null;
  paid: boolean | null;
  notes: string | null;
  homework: string | null;
  worked_on: string[] | null;
  athlete_id: string | null;
  athlete_name: string | null;
  athlete_age: number | null;
  medical: string | null;
  goals: string | null;
  contact_name: string | null;
  contact_phone: string | null;
  contact_email: string | null;
  mine: boolean;
}

export interface Athlete {
  id: string;
  club_id: string;
  name: string;
  dob: string | null;
  parent_id: string | null;
  profile_id: string | null;
  medical_notes: string | null;
  notes: string | null;
  goals: string | null;
  active: boolean;
}

const CLUB_KEY = 'ignyte-club';

/** Which portals a set of roles unlocks. */
export const PORTALS: { key: string; label: string; href: string; roles: Role[] }[] = [
  { key: 'club', label: '🏛️ Club', href: '/club', roles: ['owner', 'admin'] },
  { key: 'coach', label: '📣 Coach', href: '/coach', roles: ['coach'] },
  { key: 'family', label: '👨‍👧 Family', href: '/family', roles: ['parent'] },
  { key: 'me', label: '🔥 Me', href: '/me', roles: ['athlete'] },
];

export function portalsFor(club: Club | null, isPlatformOwner: boolean) {
  const list = PORTALS.filter((p) => club && p.roles.some((r) => club.roles.includes(r)));
  return isPlatformOwner ? [{ key: 'hq', label: '👑 Ignyte HQ', href: '/hq', roles: [] as Role[] }, ...list] : list;
}

/** One round-trip: profile + clubs (+ merges any pending invites). */
export async function loadCtx(): Promise<Ctx | null> {
  const { data: session } = await supabase.auth.getSession();
  if (!session.session) return null;
  const { data, error } = await supabase.rpc('my_context');
  if (error) throw error;
  if (!data) return null;
  const raw = data as { profile: Profile; clubs: Club[] };
  const clubs = raw.clubs ?? [];
  const urlClub = new URLSearchParams(location.search).get('club');
  const stored = localStorage.getItem(CLUB_KEY);
  let club = clubs.find((c) => c.id === urlClub) ?? clubs.find((c) => c.id === stored) ?? clubs[0] ?? null;
  // Ignyte owner stepping into any club (they hold every role there).
  const wanted = urlClub ?? (club ? null : stored);
  if (!club && raw.profile.is_platform_owner && wanted) {
    const { data: c } = await supabase.from('clubs').select('*').eq('id', wanted).single();
    if (c) club = { ...(c as Club), roles: ['owner', 'admin', 'coach', 'parent', 'athlete'] };
  } else if (raw.profile.is_platform_owner && urlClub && club && club.id === urlClub) {
    club = { ...club, roles: ['owner', 'admin', 'coach', 'parent', 'athlete'] };
  }
  if (club) localStorage.setItem(CLUB_KEY, club.id);
  return { profile: raw.profile, clubs, club };
}

export function setActiveClub(id: string) {
  localStorage.setItem(CLUB_KEY, id);
}

/** Signed-in guard. With roles, the active club must grant one of them. */
export async function requireAuth(roles?: Role[]): Promise<Ctx> {
  if (!supabaseConfigured) {
    document.body.innerHTML =
      '<div style="padding:4rem 1.5rem;text-align:center;font-family:system-ui"><h1>Not configured</h1><p>Add Supabase env vars and rebuild.</p></div>';
    throw new Error('Supabase not configured');
  }
  let ctx: Ctx | null = null;
  try {
    ctx = await loadCtx();
  } catch (e) {
    // Signed in but the app can't load its data — say so rather than bouncing
    // the person back to the sign-in page with no explanation.
    document.body.innerHTML =
      '<div style="padding:4rem 1.5rem;text-align:center;font-family:system-ui;max-width:28rem;margin:auto"><h1 style="font-size:1.3rem">Something went wrong loading your account</h1>' +
      `<p style="margin-top:1rem;color:#9090a8">${esc(errMsg(e))}</p>` +
      '<p style="margin-top:1.5rem"><a href="/dashboard" style="color:#ff9248">Try again</a> · <a href="/" id="so" style="color:#ff9248">Sign out</a></p></div>';
    document.getElementById('so')?.addEventListener('click', () => supabase.auth.signOut());
    throw new Error('redirecting');
  }
  if (!ctx) {
    const { data } = await supabase.auth.getSession();
    if (data.session) await supabase.auth.signOut();
    location.href = '/?next=' + encodeURIComponent(location.pathname + location.search);
    throw new Error('redirecting');
  }
  if (roles) {
    if (!ctx.club || !roles.some((r) => ctx.club!.roles.includes(r))) {
      location.href = '/dashboard';
      throw new Error('redirecting');
    }
  }
  return ctx;
}

export async function requirePlatformOwner(): Promise<Ctx> {
  const ctx = await requireAuth();
  if (!ctx.profile.is_platform_owner) {
    location.href = '/dashboard';
    throw new Error('redirecting');
  }
  return ctx;
}

export async function schedule(clubId: string, from: Date, to: Date): Promise<ScheduleRow[]> {
  const { data, error } = await supabase.rpc('club_schedule', { p_club: clubId, p_from: from.toISOString(), p_to: to.toISOString() });
  if (error) throw error;
  return (data ?? []) as ScheduleRow[];
}

/** Athletes the signed-in user looks after (children + themselves) in a club. */
export async function myAthletes(clubId: string): Promise<Athlete[]> {
  const { data: session } = await supabase.auth.getSession();
  const uid = session.session?.user.id;
  if (!uid) return [];
  const { data } = await supabase
    .from('athletes')
    .select('*')
    .eq('club_id', clubId)
    .or(`parent_id.eq.${uid},profile_id.eq.${uid}`)
    .order('name');
  return (data ?? []) as Athlete[];
}

// ---------- formatting ----------
export function money(pence: number, currency = 'GBP'): string {
  return new Intl.NumberFormat(undefined, { style: 'currency', currency, minimumFractionDigits: pence % 100 ? 2 : 0 }).format(pence / 100);
}
export function fmtWhen(iso: string): string {
  return new Date(iso).toLocaleString(undefined, { weekday: 'short', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
}
export function fmtTime(iso: string): string {
  return new Date(iso).toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' });
}
export function fmtDay(iso: string): string {
  return new Date(iso).toLocaleDateString(undefined, { weekday: 'long', day: 'numeric', month: 'short' });
}
export function fmtDate(isoDate: string): string {
  return new Date(isoDate + 'T00:00:00').toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' });
}
/** Local calendar day (yyyy-mm-dd) of a timestamp. */
export function dayKey(iso: string | Date): string {
  const d = typeof iso === 'string' ? new Date(iso) : iso;
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}
export function todayISO(): string {
  return dayKey(new Date());
}
export function startOfDay(d = new Date()): Date {
  const x = new Date(d);
  x.setHours(0, 0, 0, 0);
  return x;
}
export function addDays(d: Date, n: number): Date {
  const x = new Date(d);
  x.setDate(x.getDate() + n);
  return x;
}
export function ageFromDob(dob: string | null): number | null {
  if (!dob) return null;
  const d = new Date(dob + 'T00:00:00');
  const now = new Date();
  let age = now.getFullYear() - d.getFullYear();
  const m = now.getMonth() - d.getMonth();
  if (m < 0 || (m === 0 && now.getDate() < d.getDate())) age--;
  return age;
}
export function groupByDay<T extends { starts_at: string }>(rows: T[]): [string, T[]][] {
  const map = new Map<string, T[]>();
  for (const r of rows) {
    const k = dayKey(r.starts_at);
    if (!map.has(k)) map.set(k, []);
    map.get(k)!.push(r);
  }
  return [...map.entries()];
}

export function esc(s: unknown): string {
  return String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' })[c] as string);
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
    'padding:.65rem 1.1rem;border-radius:.75rem;font-size:.9rem;font-weight:500;width:100%;text-align:center;box-shadow:0 10px 30px -10px rgba(0,0,0,.8);border:1px solid;' +
    (type === 'ok' ? 'background:#16161f;color:#f4f4f9;border-color:#2a2a39' : 'background:#2a1214;color:#ffb3b3;border-color:#5c2326');
  el.textContent = message;
  host.appendChild(el);
  setTimeout(() => el.remove(), 4500);
}

export function errMsg(e: unknown): string {
  const raw = (e as { message?: string })?.message ?? (typeof e === 'string' ? e : 'Something went wrong');
  const msg = raw.replace(/^.*?exception:? /i, '');
  if (/^JWT expired/i.test(msg)) return 'Your session expired — refresh the page and sign in again.';
  if (/Failed to fetch|NetworkError|Load failed/i.test(msg)) return "Can't reach the server — check your connection and try again.";
  if (/duplicate key value/i.test(msg)) return 'That already exists.';
  if (/violates row-level security|permission denied/i.test(msg)) return "You don't have permission to do that.";
  if (/Invalid login credentials/i.test(msg)) return 'Wrong email or password.';
  return msg;
}

export const STATUS_LABEL: Record<string, string> = {
  booked: 'Booked',
  completed: 'Attended',
  no_show: 'No-show',
  cancelled: 'Cancelled',
  working_on: 'Working on',
  achieved: 'Achieved',
  mastered: 'Mastered',
};

export function statusPill(status: string | null): string {
  if (!status) return '';
  const tone =
    status === 'completed' || status === 'achieved' ? 'pill-success'
    : status === 'mastered' ? 'pill-accent'
    : status === 'no_show' || status === 'cancelled' ? 'pill-danger'
    : status === 'working_on' ? 'pill-warn'
    : '';
  return `<span class="pill ${tone}">${STATUS_LABEL[status] ?? status}</span>`;
}

/** Shared "athlete journey" card: stats, progress, lesson history with coach notes. */
export function journeyHtml(j: JourneyData, opts: { editable?: boolean } = {}): string {
  const a = j.athlete;
  const prog = j.progress ?? [];
  const lessons = j.lessons ?? [];
  return `
    <div class="grid grid-cols-3 gap-2 text-center">
      <div class="rounded-xl bg-ink-900 border border-ink-700 p-3"><p class="text-2xl font-display font-semibold text-ignite-400">${j.stats.completed}</p><p class="text-[0.65rem] uppercase tracking-widest text-mist-500">lessons</p></div>
      <div class="rounded-xl bg-ink-900 border border-ink-700 p-3"><p class="text-2xl font-display font-semibold text-charge-400">${j.stats.working_on}</p><p class="text-[0.65rem] uppercase tracking-widest text-mist-500">working on</p></div>
      <div class="rounded-xl bg-ink-900 border border-ink-700 p-3"><p class="text-2xl font-display font-semibold" style="color:#7ee2a8">${j.stats.achieved}</p><p class="text-[0.65rem] uppercase tracking-widest text-mist-500">achieved</p></div>
    </div>
    ${a.goals ? `<p class="text-sm mt-3"><span class="text-mist-500">🎯 Goal:</span> ${esc(a.goals)}</p>` : ''}
    <h3 class="text-sm font-semibold mt-4 mb-1.5">Skills</h3>
    <div class="flex flex-col gap-1.5" data-progress-list>
      ${prog.map((p) => `
        <div class="flex flex-wrap items-center gap-2 text-sm rounded-lg bg-ink-900 border border-ink-700 px-3 py-2">
          <span class="flex-1 min-w-32">${esc(p.skill)}${p.note ? `<span class="block text-xs text-mist-500">${esc(p.note)}</span>` : ''}</span>
          ${opts.editable ? `<select class="field !w-auto !py-1 !text-xs" data-skill-status="${esc(p.skill)}">
              ${['working_on', 'achieved', 'mastered'].map((s) => `<option value="${s}" ${s === p.status ? 'selected' : ''}>${STATUS_LABEL[s]}</option>`).join('')}
              <option value="">Remove</option></select>` : statusPill(p.status)}
        </div>`).join('') || '<p class="text-sm text-mist-500">No skills tracked yet.</p>'}
    </div>
    ${opts.editable ? `<form class="flex gap-2 mt-2" data-add-skill>
        <input class="field flex-1" placeholder="Add a skill, e.g. Back handspring" maxlength="60" required />
        <button class="btn btn-ghost btn-sm" type="submit">Add</button></form>` : ''}
    <h3 class="text-sm font-semibold mt-4 mb-1.5">Lesson history</h3>
    <div class="flex flex-col gap-1.5">
      ${lessons.filter((l) => l.status !== 'booked').slice(0, 20).map((l) => `
        <div class="rounded-lg bg-ink-900 border border-ink-700 px-3 py-2 text-sm">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <span>${fmtWhen(l.starts_at)} <span class="text-mist-500">· ${esc(l.coach_name)}</span></span>
            ${statusPill(l.status)}
          </div>
          ${l.worked_on?.length ? `<p class="text-xs text-mist-400 mt-1">Worked on: ${l.worked_on.map(esc).join(', ')}</p>` : ''}
          ${l.notes ? `<p class="text-xs mt-1">📝 ${esc(l.notes)}</p>` : ''}
          ${l.homework ? `<p class="text-xs mt-1 text-charge-400">🏠 Homework: ${esc(l.homework)}</p>` : ''}
        </div>`).join('') || '<p class="text-sm text-mist-500">No lessons yet.</p>'}
    </div>`;
}

export interface JourneyData {
  athlete: { id: string; name: string; dob: string | null; goals: string | null; notes: string | null; medical: string | null; club_id: string; age: number | null };
  progress: { skill: string; status: string; note: string | null; updated_at: string }[];
  lessons: { lesson_id: string; status: string; starts_at: string; coach_name: string; notes: string | null; homework: string | null; worked_on: string[]; paid: boolean; price_pence: number }[];
  stats: { completed: number; achieved: number; working_on: number };
}

/** Wire the editable journey controls (coach/admin). */
export function wireJourneyEditing(host: HTMLElement, athleteId: string, reload: () => void) {
  host.querySelectorAll<HTMLSelectElement>('[data-skill-status]').forEach((sel) =>
    sel.addEventListener('change', async () => {
      const { error } = await supabase.rpc('set_progress', { p_athlete: athleteId, p_skill: sel.dataset.skillStatus, p_status: sel.value || null });
      if (error) return toast(errMsg(error), 'err');
      toast(sel.value ? 'Progress updated' : 'Skill removed');
      reload();
    })
  );
  host.querySelector<HTMLFormElement>('[data-add-skill]')?.addEventListener('submit', async (e) => {
    e.preventDefault();
    const input = (e.currentTarget as HTMLFormElement).querySelector('input')!;
    const { error } = await supabase.rpc('set_progress', { p_athlete: athleteId, p_skill: input.value.trim(), p_status: 'working_on' });
    if (error) return toast(errMsg(error), 'err');
    reload();
  });
}
