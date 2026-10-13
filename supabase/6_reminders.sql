-- ============================================================
-- نظام إيجارات كرم — التذكيرات اليدوية (على العقود والمطالبات)
-- شغّله بعد 4_projects.sql مرة واحدة: Supabase ← SQL Editor ← New query ← الصق ← Run
-- ============================================================
create table if not exists public.reminders (
  id         text primary key,
  project    text not null default 'mall',
  data       jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
create index if not exists reminders_project on public.reminders (project);
alter table public.reminders enable row level security;

drop policy if exists reminders_read  on public.reminders;
drop policy if exists reminders_write on public.reminders;
create policy reminders_read  on public.reminders for select to authenticated
  using (public.app_role() is not null and public.has_project(project));
create policy reminders_write on public.reminders for all to authenticated
  using ((public.has_perm('edit_dues') or public.has_perm('edit_contracts')) and public.has_project(project))
  with check ((public.has_perm('edit_dues') or public.has_perm('edit_contracts')) and public.has_project(project));

do $$ begin
  begin alter publication supabase_realtime add table public.reminders; exception when others then null; end;
end $$;

select 'تم تفعيل التذكيرات' as result;
