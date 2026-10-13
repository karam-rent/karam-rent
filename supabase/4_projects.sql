-- ============================================================
-- نظام إيجارات كرم — تعدد المشاريع (كرم مول / كرم فيلج / كرم العقارية ...)
-- شغّله بعد 3_permissions.sql مرة واحدة: Supabase ← SQL Editor ← New query ← الصق ← Run
-- آمن للتشغيل أكثر من مرة. البيانات الحالية كلها تصير تحت مشروع "إيجارات كرم مول".
-- ============================================================

-- 1) جدول المشاريع
create table if not exists public.projects (
  id         text primary key,
  data       jsonb not null default '{}'::jsonb,
  sort       int not null default 0,
  created_at timestamptz not null default now()
);

insert into public.projects (id, sort, data) values
 ('mall', 1, '{"name":"إيجارات كرم مول","company":"شركة مجمع كرم مول التجاري","cr":"1122005677","vat":"310154341300003","addr":"المجمعة - حي المستقبل - طريق الملك خالد","prefix":"KM"}'),
 ('village', 2, '{"name":"إيجارات كرم فيلج","company":"","cr":"","vat":"","addr":"","prefix":"KV"}'),
 ('realestate', 3, '{"name":"إيجارات كرم العقارية","company":"","cr":"","vat":"","addr":"","prefix":"KR"}')
on conflict (id) do nothing;

-- 2) ربط العقود والمطالبات بالمشروع (الحالي كله = المول)
alter table public.tenants add column if not exists project text not null default 'mall';
alter table public.dues    add column if not exists project text not null default 'mall';
create index if not exists tenants_project on public.tenants (project);
create index if not exists dues_project    on public.dues (project);

-- 3) المشاريع المسموحة لكل مستخدم (فارغ = كل المشاريع)
alter table public.app_users add column if not exists projects jsonb;

create or replace function public.has_project(p text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((
    select u.role = 'admin' or u.projects is null or u.projects ? p
    from public.app_users u
    where u.email = lower(coalesce(auth.jwt() ->> 'email',''))), false)
$$;
grant execute on function public.has_project(text) to authenticated;

-- 4) سياسات الوصول = الصلاحية + المشروع
drop policy if exists tenants_read   on public.tenants;
drop policy if exists tenants_insert on public.tenants;
drop policy if exists tenants_update on public.tenants;
drop policy if exists tenants_delete on public.tenants;
create policy tenants_read   on public.tenants for select to authenticated using (public.app_role() is not null and public.has_project(project));
create policy tenants_insert on public.tenants for insert to authenticated with check (public.has_perm('edit_contracts') and public.has_project(project));
create policy tenants_update on public.tenants for update to authenticated using ((public.has_perm('edit_contracts') or public.has_perm('edit_dues')) and public.has_project(project)) with check ((public.has_perm('edit_contracts') or public.has_perm('edit_dues')) and public.has_project(project));
create policy tenants_delete on public.tenants for delete to authenticated using (public.has_perm('delete') and public.has_project(project));

drop policy if exists dues_read   on public.dues;
drop policy if exists dues_insert on public.dues;
drop policy if exists dues_update on public.dues;
drop policy if exists dues_delete on public.dues;
create policy dues_read   on public.dues for select to authenticated using (public.app_role() is not null and public.has_project(project));
create policy dues_insert on public.dues for insert to authenticated with check (public.has_perm('edit_dues') and public.has_project(project));
create policy dues_update on public.dues for update to authenticated using (public.has_perm('edit_dues') and public.has_project(project)) with check (public.has_perm('edit_dues') and public.has_project(project));
create policy dues_delete on public.dues for delete to authenticated using (public.has_perm('delete') and public.has_project(project));

alter table public.projects enable row level security;
drop policy if exists projects_read  on public.projects;
drop policy if exists projects_admin on public.projects;
create policy projects_read  on public.projects for select to authenticated using (public.app_role() is not null and public.has_project(id));
create policy projects_admin on public.projects for all    to authenticated using (public.has_perm('users')) with check (public.has_perm('users'));

-- 5) سجل التعديلات يحفظ المشروع
alter table public.audit_log add column if not exists project text;
create or replace function public.audit_row() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.audit_log (email, tbl, row_id, action, before, after, project)
  values (lower(coalesce(auth.jwt() ->> 'email','system')), tg_table_name,
          coalesce(new.id, old.id), lower(tg_op),
          case when tg_op <> 'INSERT' then old.data end,
          case when tg_op <> 'DELETE' then new.data end,
          coalesce(new.project, old.project));
  return coalesce(new, old);
end $$;

do $$ begin
  begin alter publication supabase_realtime add table public.projects; exception when others then null; end;
end $$;

select id, data->>'name' as name from public.projects order by sort;
