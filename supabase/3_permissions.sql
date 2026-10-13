-- ============================================================
-- نظام إيجارات كرم مول — الصلاحيات التفصيلية + سجل التعديلات (نسخة من كل تغيير)
-- شغّله مرة واحدة: Supabase ← SQL Editor ← New query ← الصق ← Run
-- آمن للتشغيل أكثر من مرة.
-- ============================================================

-- 1) صلاحيات مخصصة لكل مستخدم (فارغة = حسب الدور)
alter table public.app_users add column if not exists perms jsonb;

-- الصلاحيات: edit_dues (المطالبات والدفعات) ، edit_contracts (العقود) ، discount (الخصومات وتعديلات العقد) ، delete (الحذف) ، users (إدارة المستخدمين)
create or replace function public.has_perm(p text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((
    select case
      when u.role = 'admin' then true
      when u.perms is not null then coalesce((u.perms ->> p)::boolean, false)
      when u.role = 'editor' then p in ('edit_dues','edit_contracts')
      else false end
    from public.app_users u
    where u.email = lower(coalesce(auth.jwt() ->> 'email',''))), false)
$$;
grant execute on function public.has_perm(text) to authenticated;

-- 2) سياسات الوصول حسب الصلاحية
drop policy if exists tenants_write  on public.tenants;
drop policy if exists tenants_insert on public.tenants;
drop policy if exists tenants_update on public.tenants;
drop policy if exists tenants_delete on public.tenants;
create policy tenants_insert on public.tenants for insert to authenticated with check (public.has_perm('edit_contracts'));
create policy tenants_update on public.tenants for update to authenticated using (public.has_perm('edit_contracts') or public.has_perm('edit_dues')) with check (public.has_perm('edit_contracts') or public.has_perm('edit_dues'));
create policy tenants_delete on public.tenants for delete to authenticated using (public.has_perm('delete'));

drop policy if exists dues_write  on public.dues;
drop policy if exists dues_insert on public.dues;
drop policy if exists dues_update on public.dues;
drop policy if exists dues_delete on public.dues;
create policy dues_insert on public.dues for insert to authenticated with check (public.has_perm('edit_dues'));
create policy dues_update on public.dues for update to authenticated using (public.has_perm('edit_dues')) with check (public.has_perm('edit_dues'));
create policy dues_delete on public.dues for delete to authenticated using (public.has_perm('delete'));

drop policy if exists users_admin on public.app_users;
create policy users_admin on public.app_users for all to authenticated using (public.has_perm('users')) with check (public.has_perm('users'));

-- 3) حماية الحقول الحساسة داخل السجل
create or replace function public.guard_tenant() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  -- من عنده صلاحية المطالبات فقط يقدر يحرّك "الاستحقاق القادم" عند إصدار مطالبة، ولا شيء غيره
  if not public.has_perm('edit_contracts') and (new.data - 'nextDue') is distinct from (old.data - 'nextDue') then
    raise exception 'لا تملك صلاحية تعديل بيانات العقد';
  end if;
  if not public.has_perm('discount') and (new.data -> 'amendments') is distinct from (old.data -> 'amendments') then
    raise exception 'لا تملك صلاحية الخصم أو تعديل القيمة الإيجارية';
  end if;
  return new;
end $$;
drop trigger if exists tenants_guard on public.tenants;
create trigger tenants_guard before update on public.tenants for each row execute function public.guard_tenant();

create or replace function public.guard_due() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.has_perm('discount') and (new.data -> 'discount') is distinct from (case when tg_op='UPDATE' then old.data -> 'discount' else null end) then
    raise exception 'لا تملك صلاحية الخصم';
  end if;
  return new;
end $$;
drop trigger if exists dues_guard on public.dues;
create trigger dues_guard before insert or update on public.dues for each row execute function public.guard_due();

-- 4) سجل التعديلات: نسخة قبل/بعد لكل إضافة وتعديل وحذف
create table if not exists public.audit_log (
  id         bigint generated always as identity primary key,
  at         timestamptz not null default now(),
  email      text,
  tbl        text not null,
  row_id     text not null,
  action     text not null,
  before     jsonb,
  after      jsonb
);
create index if not exists audit_log_at on public.audit_log (at desc);
alter table public.audit_log enable row level security;
drop policy if exists audit_read on public.audit_log;
create policy audit_read on public.audit_log for select to authenticated using (public.has_perm('users'));

create or replace function public.audit_row() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.audit_log (email, tbl, row_id, action, before, after)
  values (lower(coalesce(auth.jwt() ->> 'email','system')), tg_table_name,
          coalesce(new.id, old.id), lower(tg_op),
          case when tg_op <> 'INSERT' then old.data end,
          case when tg_op <> 'DELETE' then new.data end);
  return coalesce(new, old);
end $$;
drop trigger if exists tenants_audit on public.tenants;
create trigger tenants_audit after insert or update or delete on public.tenants for each row execute function public.audit_row();
drop trigger if exists dues_audit on public.dues;
create trigger dues_audit after insert or update or delete on public.dues for each row execute function public.audit_row();

select 'تم تفعيل الصلاحيات وسجل التعديلات' as result;
