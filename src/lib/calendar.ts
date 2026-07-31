import { esc } from './app';

export interface CalChip {
  id: string;
  label: string;
  tone: 'ok' | 'danger' | 'accent' | 'warn' | 'muted';
  title?: string;
}

const MONTHS = [
  'January', 'February', 'March', 'April', 'May', 'June',
  'July', 'August', 'September', 'October', 'November', 'December',
];

/** ISO date (yyyy-mm-dd) for a Date in local time. */
export function isoDate(d: Date): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

/**
 * Renders a Monday-first month grid. Chips are buttons carrying
 * data-chip="<id>" — the page wires the clicks (and data-cal-prev /
 * data-cal-next on the header arrows).
 */
export function renderMonthCalendar(
  year: number,
  month: number, // 0-based
  chipsByDate: Map<string, CalChip[]>
): string {
  const first = new Date(year, month, 1);
  const lead = (first.getDay() + 6) % 7; // Monday-first offset
  const daysInMonth = new Date(year, month + 1, 0).getDate();
  const today = isoDate(new Date());

  let cells = '';
  for (let i = 0; i < lead; i++) cells += '<div class="cal-cell cal-empty"></div>';
  for (let day = 1; day <= daysInMonth; day++) {
    const date = `${year}-${String(month + 1).padStart(2, '0')}-${String(day).padStart(2, '0')}`;
    const chips = chipsByDate.get(date) ?? [];
    const shown = chips.slice(0, 4);
    cells += `
      <div class="cal-cell ${date === today ? 'cal-today' : ''}">
        <span class="cal-daynum">${day}</span>
        ${shown
          .map(
            (c) =>
              `<button class="cal-chip cal-${c.tone}" data-chip="${c.id}" ${c.title ? `title="${esc(c.title)}"` : ''}>${esc(c.label)}</button>`
          )
          .join('')}
        ${chips.length > shown.length ? `<span class="cal-more">+${chips.length - shown.length} more</span>` : ''}
      </div>`;
  }

  return `
    <div class="surface-card p-3 sm:p-4">
      <div class="flex items-center justify-between mb-3">
        <button class="btn btn-ghost btn-sm" data-cal-prev aria-label="Previous month">←</button>
        <p class="font-display font-semibold">${MONTHS[month]} ${year}</p>
        <button class="btn btn-ghost btn-sm" data-cal-next aria-label="Next month">→</button>
      </div>
      <div class="cal-grid cal-head">
        ${['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'].map((d) => `<div>${d}</div>`).join('')}
      </div>
      <div class="cal-grid">${cells}</div>
    </div>`;
}

/** Standard "Tiles | Calendar" toggle. Pages listen on data-view buttons. */
export function renderViewToggle(view: 'tiles' | 'calendar'): string {
  return `
    <div class="inline-flex rounded-full border border-ink-600 p-0.5 text-xs font-semibold">
      <button data-view="tiles" class="px-3 py-1 rounded-full ${view === 'tiles' ? 'bg-ignite-500 text-white' : 'text-mist-300'}">Tiles</button>
      <button data-view="calendar" class="px-3 py-1 rounded-full ${view === 'calendar' ? 'bg-ignite-500 text-white' : 'text-mist-300'}">Calendar</button>
    </div>`;
}
