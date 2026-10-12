-- ============================================================
-- نظام إيجارات كرم مول — إعداد قاعدة البيانات (Supabase)
-- شغّل هذا الملف مرة واحدة: Supabase ← SQL Editor ← New query ← الصق ← Run
-- ============================================================

-- المستخدمون والصلاحيات: admin = مدير (يدير المستخدمين) ، editor = محرر ، viewer = مشاهد
create table if not exists public.app_users (
  email      text primary key,
  role       text not null default 'editor' check (role in ('admin','editor','viewer')),
  created_at timestamptz not null default now()
);

-- العقود والمطالبات (كل سجل محفوظ كـ JSON في عمود data)
create table if not exists public.tenants (
  id         text primary key,
  data       jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
create table if not exists public.dues (
  id         text primary key,
  data       jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

-- تحديث وقت التعديل تلقائياً
create or replace function public.touch_updated_at() returns trigger
language plpgsql as $$ begin new.updated_at := now(); return new; end $$;
drop trigger if exists tenants_touch on public.tenants;
create trigger tenants_touch before update on public.tenants for each row execute function public.touch_updated_at();
drop trigger if exists dues_touch on public.dues;
create trigger dues_touch before update on public.dues for each row execute function public.touch_updated_at();

-- صلاحية المستخدم الحالي حسب بريده
create or replace function public.app_role() returns text
language sql stable security definer set search_path = public as $$
  select role from public.app_users where email = lower(coalesce(auth.jwt() ->> 'email', ''))
$$;
grant execute on function public.app_role() to authenticated;

-- حماية البيانات (Row Level Security)
alter table public.app_users enable row level security;
alter table public.tenants   enable row level security;
alter table public.dues      enable row level security;

drop policy if exists users_read  on public.app_users;
drop policy if exists users_admin on public.app_users;
create policy users_read  on public.app_users for select to authenticated using (public.app_role() is not null);
create policy users_admin on public.app_users for all    to authenticated using (public.app_role() = 'admin') with check (public.app_role() = 'admin');

drop policy if exists tenants_read  on public.tenants;
drop policy if exists tenants_write on public.tenants;
create policy tenants_read  on public.tenants for select to authenticated using (public.app_role() is not null);
create policy tenants_write on public.tenants for all    to authenticated using (public.app_role() in ('admin','editor')) with check (public.app_role() in ('admin','editor'));

drop policy if exists dues_read  on public.dues;
drop policy if exists dues_write on public.dues;
create policy dues_read  on public.dues for select to authenticated using (public.app_role() is not null);
create policy dues_write on public.dues for all    to authenticated using (public.app_role() in ('admin','editor')) with check (public.app_role() in ('admin','editor'));

-- تحديث مباشر لكل المستخدمين عند أي تعديل
do $$ begin
  begin alter publication supabase_realtime add table public.tenants; exception when others then null; end;
  begin alter publication supabase_realtime add table public.dues;    exception when others then null; end;
end $$;

-- مدير النظام الأول (غيّر البريد إذا لزم)
insert into public.app_users (email, role) values ('ai.karamholding@gmail.com', 'admin')
on conflict (email) do update set role = 'admin';
