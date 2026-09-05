/**
 * Schedule rows + their actions, shared by the club and coach portals.
 * Every button carries data-act="<verb>:<id>"; wireScheduleActions handles it.
 */
import { supabase } from './supabase';
import { esc, fmtTime, fmtDay, groupByDay, money, statusPill, toast, errMsg, type ScheduleRow } from './app';

export interface RowOpts {
  /** staff = owner/admin: see coach names, paid toggles, everyone's lessons */
  staff: boolean;
  /** the signed-in coach's id (their own slots get the wrap-up controls) */
  coachId?: string;
  currency?: string;
  showCoach?: boolean;
}

export function rowHtml(r: ScheduleRow, o: RowOpts): string {
  const cur = o.currency ?? 'GBP';
  const isMineToRun = o.staff || r.coach_id === o.coachId;
  const past = new Date(r.starts_at).getTime() < Date.now();
  const coach = o.showCoach ? `<span class="text-mist-500"> · ${esc(r.coach_name)}</span>` : '';
  let body = '';
  let actions = '';
  if (!r.lesson_id) {
    body = `<span class="text-mist-400">Open${coach}</span>`;
    if (!past) {
      actions = isMineToRun
        ? `<button class="btn btn-primary btn-sm" data-act="assign:${r.slot_id}">＋ Assign athlete</button>
           <button class="btn btn-ghost btn-sm" data-act="remove:${r.slot_id}" title="Remove this slot">✕</button>`
        : '';
    } else if (isMineToRun) actions = `<button class="btn btn-ghost btn-sm" data-act="remove:${r.slot_id}">✕</button>`;
  } else if (r.athlete_name) {
    const age = r.athlete_age != null ? ` <span class="text-xs text-mist-500">(${r.athlete_age})</span>` : '';
    body = `<b>${esc(r.athlete_name)}</b>${age}${coach} ${r.medical ? '<span class="pill pill-warn" title="Medical notes">🚑</span>' : ''} ${statusPill(r.lesson_status)}
      ${r.paid ? '<span class="pill pill-success">paid</span>' : r.lesson_status !== 'booked' ? '<span class="pill pill-danger">unpaid</span>' : ''}`;
    if (isMineToRun) {
      actions += `<button class="btn btn-ghost btn-sm" data-act="info:${r.slot_id}" title="Contact & medical">ℹ️</button>`;
      if (r.lesson_status === 'booked') {
        actions += `<button class="btn btn-primary btn-sm" data-act="wrap:${r.slot_id}">${past ? '✅ Wrap up' : '✅ Wrap up'}</button>
          <button class="btn btn-danger btn-sm" data-act="cancel:${r.lesson_id}">Cancel</button>`;
      } else {
        actions += `<button class="btn btn-ghost btn-sm" data-act="wrap:${r.slot_id}">✏️ Notes</button>`;
      }
      if (o.staff || r.coach_id === o.coachId) actions += `<button class="btn btn-ghost btn-sm" data-act="paid:${r.lesson_id}:${r.paid ? 0 : 1}">${r.paid ? 'Unmark paid' : '💷 Paid'}</button>`;
    }
  } else {
    body = `<span class="text-mist-500">Booked${coach}</span>`;
  }
  return `
    <div class="rounded-xl bg-ink-900 border border-ink-700 px-3 py-2.5" data-row="${r.slot_id}">
      <div class="flex flex-wrap items-center gap-x-3 gap-y-1.5">
        <span class="font-display font-semibold tabular-nums w-14">${fmtTime(r.starts_at)}</span>
        <span class="text-sm flex-1 min-w-40">${body}</span>
        <span class="text-xs text-mist-500">${r.minutes}m · ${money(r.price_pence, cur)}</span>
        <div class="flex flex-wrap gap-1.5 w-full sm:w-auto">${actions}</div>
      </div>
      <div class="row-panel hidden mt-2"></div>
    </div>`;
}

export function scheduleHtml(rows: ScheduleRow[], o: RowOpts, empty = 'Nothing scheduled.'): string {
  if (!rows.length) return `<p class="text-sm text-mist-500">${empty}</p>`;
  return groupByDay(rows)
    .map(([, list]) => `
      <div class="mb-4">
        <h3 class="text-xs font-semibold uppercase tracking-widest text-mist-500 mb-1.5">${fmtDay(list[0].starts_at)}</h3>
        <div class="flex flex-col gap-1.5">${list.map((r) => rowHtml(r, o)).join('')}</div>
      </div>`)
    .join('');
}

export function infoHtml(r: ScheduleRow): string {
  return `
    <div class="rounded-lg bg-ink-850 border border-ink-700 p-3 text-xs flex flex-col gap-1">
      ${r.contact_name ? `<p><b>Contact:</b> ${esc(r.contact_name)}
        ${r.contact_phone ? ` · <a class="text-ignite-400" href="tel:${esc(r.contact_phone)}">${esc(r.contact_phone)}</a>` : ''}
        ${r.contact_email ? ` · <a class="text-ignite-400" href="mailto:${esc(r.contact_email)}">${esc(r.contact_email)}</a>` : ''}</p>` : '<p class="text-mist-500">No contact on file.</p>'}
      ${r.medical ? `<p class="text-charge-400"><b>🚑 Medical:</b> ${esc(r.medical)}</p>` : '<p class="text-mist-500">No medical notes.</p>'}
      ${r.goals ? `<p><b>🎯 Goal:</b> ${esc(r.goals)}</p>` : ''}
      ${r.athlete_id ? `<a class="text-ignite-400" href="#" data-act="journey:${r.athlete_id}">Progress & history →</a>` : ''}
    </div>`;
}

export function wrapHtml(r: ScheduleRow, skills: string[]): string {
  const chips = [...new Set([...(r.worked_on ?? []), ...skills])];
  return `
    <form class="rounded-lg bg-ink-850 border border-ink-700 p-3 flex flex-col gap-2.5 text-sm" data-wrap="${r.lesson_id}">
      <div class="flex gap-2 flex-wrap">
        <label class="pill cursor-pointer"><input type="radio" name="st" value="completed" ${r.lesson_status !== 'no_show' ? 'checked' : ''} /> Attended</label>
        <label class="pill cursor-pointer"><input type="radio" name="st" value="no_show" ${r.lesson_status === 'no_show' ? 'checked' : ''} /> No-show</label>
      </div>
      <div>
        <p class="text-xs text-mist-400 mb-1">Worked on</p>
        <div class="flex flex-wrap gap-1.5" data-chips>
          ${chips.map((s) => `<label class="pill cursor-pointer has-checked:text-ignite-400 has-checked:border-ignite-500"><input type="checkbox" class="sr-only" value="${esc(s)}" ${(r.worked_on ?? []).includes(s) ? 'checked' : ''} />${esc(s)}</label>`).join('')}
          <input class="field !w-40 !py-1 !text-xs" placeholder="+ other skill" data-newskill />
        </div>
      </div>
      <textarea class="field" rows="2" placeholder="Notes for the family — what went well, what to focus on" data-notes>${esc(r.notes ?? '')}</textarea>
      <input class="field" placeholder="Homework (optional)" data-homework value="${esc(r.homework ?? '')}" />
      <div class="flex gap-2"><button class="btn btn-primary btn-sm" type="submit">Save</button><button class="btn btn-ghost btn-sm" type="button" data-close>Close</button></div>
    </form>`;
}

export interface WireOpts extends RowOpts {
  clubId: string;
  reload: () => void;
  /** athletes available for "assign" */
  athletes: () => Promise<{ id: string; name: string }[]>;
  /** skills known for an athlete, for the wrap-up chips */
  skillsFor?: (athleteId: string) => Promise<string[]>;
  onJourney?: (athleteId: string) => void;
}

export function wireScheduleActions(host: HTMLElement, rows: ScheduleRow[], o: WireOpts) {
  const byId = new Map(rows.map((r) => [r.slot_id, r]));
  host.addEventListener('click', async (e) => {
    const btn = (e.target as HTMLElement).closest<HTMLElement>('[data-act]');
    if (!btn || !host.contains(btn)) return;
    e.preventDefault();
    const [verb, id, extra] = btn.dataset.act!.split(':');
    const rowEl = btn.closest<HTMLElement>('[data-row]');
    const panel = rowEl?.querySelector<HTMLElement>('.row-panel');
    const r = rowEl ? byId.get(rowEl.dataset.row!) : undefined;
    const openPanel = (html: string) => {
      if (!panel) return;
      if (panel.dataset.for === verb && !panel.classList.contains('hidden')) return panel.classList.add('hidden');
      panel.dataset.for = verb;
      panel.classList.remove('hidden');
      panel.innerHTML = html;
    };
    try {
      if (verb === 'info' && r) return openPanel(infoHtml(r));
      if (verb === 'journey') return o.onJourney?.(id);
      if (verb === 'remove') {
        const booked = r?.lesson_id;
        if (!confirm(booked ? 'This slot is booked — removing it cancels the lesson. Continue?' : 'Remove this slot?')) return;
        const { error } = await supabase.rpc('remove_slot', { p_slot: id });
        if (error) throw error;
        toast(booked ? 'Slot removed and lesson cancelled' : 'Slot removed');
        return o.reload();
      }
      if (verb === 'cancel') {
        if (!confirm('Cancel this lesson? The slot goes back to open.')) return;
        const { error } = await supabase.rpc('cancel_lesson', { p_lesson: id });
        if (error) throw error;
        toast('Lesson cancelled');
        return o.reload();
      }
      if (verb === 'paid') {
        const { error } = await supabase.rpc('mark_paid', { p_lesson: id, p_paid: extra === '1' });
        if (error) throw error;
        toast(extra === '1' ? 'Marked paid' : 'Marked unpaid');
        return o.reload();
      }
      if (verb === 'assign' && r) {
        const list = await o.athletes();
        openPanel(`
          <form class="flex flex-wrap gap-2 items-center rounded-lg bg-ink-850 border border-ink-700 p-3" data-assign>
            <select class="field flex-1 min-w-40" required><option value="">Choose an athlete…</option>${list.map((a) => `<option value="${a.id}">${esc(a.name)}</option>`).join('')}</select>
            <button class="btn btn-primary btn-sm" type="submit">Book them in</button>
          </form>`);
        panel?.querySelector('form')?.addEventListener('submit', async (ev) => {
          ev.preventDefault();
          const sel = (ev.currentTarget as HTMLFormElement).querySelector('select')!;
          const { error } = await supabase.rpc('book_slot', { p_slot: id, p_athlete: sel.value });
          if (error) return toast(errMsg(error), 'err');
          toast('Booked');
          o.reload();
        });
        return;
      }
      if (verb === 'wrap' && r && r.lesson_id) {
        const skills = o.skillsFor && r.athlete_id ? await o.skillsFor(r.athlete_id) : [];
        openPanel(wrapHtml(r, skills));
        const form = panel?.querySelector<HTMLFormElement>('[data-wrap]');
        form?.querySelector('[data-close]')?.addEventListener('click', () => panel?.classList.add('hidden'));
        const newSkill = form?.querySelector<HTMLInputElement>('[data-newskill]');
        newSkill?.addEventListener('keydown', (ke) => {
          if (ke.key !== 'Enter') return;
          ke.preventDefault();
          const v = newSkill.value.trim();
          if (!v) return;
          newSkill.insertAdjacentHTML('beforebegin', `<label class="pill cursor-pointer has-checked:text-ignite-400 has-checked:border-ignite-500"><input type="checkbox" class="sr-only" value="${esc(v)}" checked />${esc(v)}</label>`);
          newSkill.value = '';
        });
        form?.addEventListener('submit', async (ev) => {
          ev.preventDefault();
          const pending = newSkill?.value.trim();
          const worked = [...form.querySelectorAll<HTMLInputElement>('[data-chips] input[type=checkbox]:checked')].map((c) => c.value);
          if (pending) worked.push(pending);
          const { error } = await supabase.rpc('complete_lesson', {
            p_lesson: r.lesson_id, p_status: (form.querySelector('input[name=st]:checked') as HTMLInputElement).value,
            p_notes: (form.querySelector('[data-notes]') as HTMLTextAreaElement).value, p_homework: (form.querySelector('[data-homework]') as HTMLInputElement).value,
            p_worked_on: worked,
          });
          if (error) return toast(errMsg(error), 'err');
          toast('Saved — the family can see your notes');
          o.reload();
        });
      }
    } catch (err) {
      toast(errMsg(err), 'err');
    }
  });
}

/** "Add slots" form used by club (any coach) and coach (self). */
export function addSlotsFormHtml(coaches: { id: string; name: string }[] | null, defaults: { minutes: number; price_pence: number }): string {
  const today = new Date();
  const d = `${today.getFullYear()}-${String(today.getMonth() + 1).padStart(2, '0')}-${String(today.getDate()).padStart(2, '0')}`;
  return `
    <form class="grid grid-cols-2 sm:grid-cols-3 gap-2.5 items-end" data-add-slots>
      ${coaches ? `<div class="col-span-2 sm:col-span-3"><label class="form-label">Coach</label><select class="field" name="coach" required>${coaches.map((c) => `<option value="${c.id}">${esc(c.name)}</option>`).join('')}</select></div>` : ''}
      <div><label class="form-label">First date</label><input class="field" type="date" name="date" value="${d}" min="${d}" required /></div>
      <div><label class="form-label">Start time</label><input class="field" type="time" name="time" value="16:00" step="300" required /></div>
      <div><label class="form-label">Lesson length</label><select class="field" name="minutes">${[15, 20, 30, 45, 60].map((m) => `<option value="${m}" ${m === defaults.minutes ? 'selected' : ''}>${m} min</option>`).join('')}</select></div>
      <div><label class="form-label">Slots in a row</label><input class="field" type="number" name="count" min="1" max="24" value="4" /></div>
      <div><label class="form-label">Repeat weekly for</label><select class="field" name="weeks">${[1, 2, 4, 6, 8, 12].map((w) => `<option value="${w}" ${w === 4 ? 'selected' : ''}>${w === 1 ? 'Just this week' : w + ' weeks'}</option>`).join('')}</select></div>
      <div><label class="form-label">Price (£)</label><input class="field" type="number" name="price" min="0" step="0.5" value="${(defaults.price_pence / 100).toFixed(2)}" /></div>
      <button class="btn btn-primary col-span-2 sm:col-span-3" type="submit">Add slots</button>
    </form>`;
}

export function wireAddSlots(form: HTMLFormElement, clubId: string, coachId: string | null, reload: () => void) {
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const f = new FormData(form);
    const start = new Date(`${f.get('date')}T${f.get('time')}:00`);
    if (isNaN(start.getTime())) return toast('Pick a date and time.', 'err');
    if (start.getTime() < Date.now()) return toast('That first time is in the past.', 'err');
    const { data, error } = await supabase.rpc('add_slots', {
      p_club: clubId, p_coach: coachId ?? f.get('coach'), p_start: start.toISOString(),
      p_minutes: Number(f.get('minutes')), p_count: Number(f.get('count')), p_weeks: Number(f.get('weeks')),
      p_price_pence: Math.round(Number(f.get('price')) * 100),
    });
    if (error) return toast(errMsg(error), 'err');
    toast(`${data} slot${data === 1 ? '' : 's'} added`);
    reload();
  });
}
