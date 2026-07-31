import { createClient, type SupabaseClient } from '@supabase/supabase-js';

const url = import.meta.env.PUBLIC_SUPABASE_URL as string | undefined;
const anonKey = import.meta.env.PUBLIC_SUPABASE_ANON_KEY as string | undefined;

export const supabaseConfigured = Boolean(url && anonKey);

// A single browser client for the whole app. Sessions persist in localStorage
// so the installed PWA stays signed in between visits (and offline).
export const supabase: SupabaseClient = createClient(
  url ?? 'https://not-configured.supabase.co',
  anonKey ?? 'not-configured',
  { auth: { persistSession: true, autoRefreshToken: true } }
);
