-- ============================================================
-- نظام إيجارات كرم — تنبيهات الإيميل اليومية (أنت تحدد متى ترسل ومتى تتوقف)
-- شغّله بعد 6_reminders.sql مرة واحدة: Supabase ← SQL Editor ← New query ← الصق ← Run
-- آمن للتشغيل أكثر من مرة. الإعدادات كلها من داخل البرنامج: الجرس ← تنبيهات الإيميل
-- ============================================================

-- 1) الإضافات المطلوبة: الإرسال للإنترنت + الجدولة
create extension if not exists pg_net;
create extension if not exists pg_cron;

-- 2) الجداول
create table if not exists public.email_settings (
  project    text primary key,
  data       jsonb not null default '{}'::jsonb,
  last_sent  date,
  updated_at timestamptz not null default now()
);
alter table public.email_settings enable row level security;
drop policy if exists email_settings_read  on public.email_settings;
drop policy if exists email_settings_admin on public.email_settings;
create policy email_settings_read  on public.email_settings for select to authenticated
  using (public.has_perm('users') and public.has_project(project));
create policy email_settings_admin on public.email_settings for all to authenticated
  using (public.has_perm('users')) with check (public.has_perm('users'));

-- مفتاح خدمة الإرسال (لا يُقرأ من البرنامج أبداً — يُكتب فقط)
create table if not exists public.app_secrets (k text primary key, v text not null);
alter table public.app_secrets enable row level security;
revoke all on public.app_secrets from anon, authenticated;

create table if not exists public.email_log (
  id         bigserial primary key,
  at         timestamptz not null default now(),
  project    text,
  kind       text,          -- auto / test / error
  recipients jsonb,
  n          int,
  request_id bigint,
  status     int,
  resp       text,
  note       text
);
alter table public.email_log enable row level security;
revoke all on public.email_log from anon, authenticated;

-- 3) أدوات مساعدة
create or replace function public.krc_d(s text) returns date
language plpgsql immutable as $$
begin
  if s is null or s !~ '^\d{4}-\d{2}-\d{2}$' then return null; end if;
  return s::date;
exception when others then return null;
end $$;

create or replace function public.krc_n(s text) returns numeric
language plpgsql immutable as $$
begin
  if s is null or btrim(s) = '' then return 0; end if;
  return s::numeric;
exception when others then return 0;
end $$;

create or replace function public.krc_fd(x date) returns text
language sql immutable as $$ select to_char(x, 'DD/MM/YYYY') $$;

create or replace function public.krc_fmt(x numeric) returns text
language sql immutable as $$
  select regexp_replace(to_char(round(coalesce(x,0), 2), 'FM999,999,999,990.00'), '\.?0+$', '')
$$;

create or replace function public.krc_esc(s text) returns text
language sql immutable as $$
  select replace(replace(replace(replace(coalesce(s,''), '&', '&amp;'), '<', '&lt;'), '>', '&gt;'), '"', '&quot;')
$$;

create or replace function public.krc_arr(j jsonb) returns jsonb
language sql immutable as $$ select case when jsonb_typeof(j) = 'array' then j else '[]'::jsonb end $$;

-- قيمة الدفعة في تاريخ معيّن بعد تطبيق تعديلات العقد (نفس منطق البرنامج)
create or replace function public.krc_inst_at(t jsonb, at_date date) returns numeric
language plpgsql immutable as $$
declare
  rent numeric := public.krc_n(t->>'rent');
  inst numeric := public.krc_n(t->>'installment');
  a jsonb; v numeric; delta numeric; nr numeric; ad date; ato date;
begin
  for a in
    select x from jsonb_array_elements(public.krc_arr(t->'amendments')) x
    order by x->>'date', coalesce(x->>'created','')
  loop
    ad := public.krc_d(a->>'date');
    if ad is null then continue; end if;
    if ad > at_date then exit; end if;
    ato := public.krc_d(a->>'to');
    if ato is not null and at_date > ato then continue; end if;
    v := public.krc_n(a->>'value');
    if a->>'kind' = 'set' then nr := v;
    else
      delta := case when a->>'mode' = 'percent' then rent * v / 100 else v end;
      nr := case when a->>'kind' = 'discount' then rent - delta else rent + delta end;
    end if;
    nr := greatest(0, round(nr, 2));
    inst := case when rent > 0 then round(inst * nr / rent, 2)
                 else round(nr * coalesce(nullif(public.krc_n(t->>'everyMonths'), 0), 12) / 12, 2) end;
    rent := nr;
  end loop;
  return inst;
end $$;

-- 4) حساب التنبيهات لمشروع (نفس تنبيهات الجرس داخل البرنامج)
-- sev: 0 عاجل ، 1 تنبيه ، 2 للعلم
create or replace function public.krc_alerts(p text, c jsonb, today date)
returns table(sev int, tag text, title text, sub text, at_date date, kind text)
language plpgsql stable set search_path = public as $$
#variable_conflict use_column
declare
  t record; x record; r record; a jsonb;
  n int; st text; e date; nd date; inst numeric; paid numeric; net numeric; remv numeric;
  dd date; sd date; lim int;
  cexp int := coalesce(nullif(c->>'exp','')::int, 90);
  cdue int := coalesce(nullif(c->>'due','')::int, 7);
  cdisc int := coalesce(nullif(c->>'disc','')::int, 30);
begin
  -- العقود
  for t in select id, data from public.tenants where project = p loop
    st := t.data->>'state';
    if st = 'evicted' then continue; end if;
    e := krc_d(t.data->>'end');
    if st is distinct from 'pending' then
      st := case when e is not null and e < today then 'ended' else 'active' end;
    end if;

    if e is not null and st = 'active' then
      n := e - today;
      if n between 0 and cexp then
        sev := case when n <= 30 then 0 else 1 end; tag := 'انتهاء عقد'; title := t.data->>'name';
        sub := 'ينتهي العقد ' || krc_fd(e) || ' — بعد ' || n || ' يوم'; at_date := e; kind := 'exp';
        return next;
      end if;
    end if;

    if st = 'ended' and today - e <= 60 then
      sev := 0; tag := 'عقد منتهي'; title := t.data->>'name';
      sub := 'انتهى ' || krc_fd(e) || ' ولم يُجدد'; at_date := e; kind := 'ended';
      return next;
    end if;

    nd := krc_d(t.data->>'nextDue');
    if nd is not null and not (e is not null and nd > e) then
      inst := krc_inst_at(t.data, nd);
      if inst > 0 and not exists (
        select 1 from public.dues q
        where q.project = p and q.data->>'tenantId' = t.id and q.data->>'dueDate' = t.data->>'nextDue'
      ) then
        n := nd - today;
        if n <= cdue then
          sev := case when n < 0 then 0 else 1 end;
          tag := case when n < 0 then 'دفعة لم تُصدر' else 'دفعة قادمة' end;
          title := t.data->>'name';
          sub := 'دفعة ' || krc_fmt(inst) || ' — ' ||
                 case when n < 0 then 'فات موعدها منذ ' || (-n) || ' يوم'
                      when n = 0 then 'تستحق اليوم'
                      else 'تستحق بعد ' || n || ' يوم (' || krc_fd(nd) || ')' end;
          at_date := nd; kind := 'pay';
          return next;
        end if;
      end if;
    end if;

    for a in select y from jsonb_array_elements(krc_arr(t.data->'amendments')) y loop
      dd := krc_d(a->>'to');
      if dd is not null and dd >= today and dd - today <= cdisc then
        sev := 2; tag := 'نهاية تعديل مؤقت'; title := t.data->>'name';
        sub := (case a->>'kind' when 'discount' then 'خصم' when 'increase' then 'زيادة'
                 when 'set' then 'قيمة إيجارية جديدة' else 'تعديل' end)
               || ' ينتهي ' || krc_fd(dd) || ' ويرجع الإيجار لقيمته';
        at_date := dd; kind := 'amd';
        return next;
      end if;
    end loop;
  end loop;

  -- المطالبات
  for x in select id, data from public.dues where project = p loop
    paid := coalesce((select sum(krc_n(pm->>'amount')) from jsonb_array_elements(krc_arr(x.data->'payments')) pm), 0);
    net := greatest(0, krc_n(x.data->>'amount') -
             case when jsonb_typeof(x.data->'discount') = 'object' then krc_n(x.data->'discount'->>'amount') else 0 end);
    remv := greatest(0, net - paid);
    if x.data->>'closed' = 'true' or remv <= 0.5 then continue; end if;

    dd := krc_d(x.data->>'dueDate');
    if dd is not null and dd > today then
      n := dd - today;
      if n <= cdue then
        sev := 1; tag := 'مطالبة تستحق'; title := x.data->>'tenantName';
        sub := krc_fmt(remv) || ' تستحق ' || krc_fd(dd); at_date := dd; kind := 'due';
        return next;
      end if;
    else
      sd := krc_d(x.data->>'stageDate');
      lim := case x.data->>'stage'
               when 'المطالبة' then 30 when 'التشغيل' then 7 when 'التاجير' then 7
               when 'زيارات طارئة' then 7 when 'المحصل القانوني' then 14 when 'خطاب قانوني' then 7
               when 'في مرحلة التحويل' then 7 else null end;
      if lim is not null and sd is not null and today - sd > lim then
        sev := 0; tag := 'تجاوز مرحلة'; title := x.data->>'tenantName';
        sub := (x.data->>'stage') || ' منذ ' || (today - sd) || ' يوم (المحدد ' || lim || ') — متبقي ' || krc_fmt(remv);
        at_date := sd; kind := 'stage';
        return next;
      end if;
    end if;

    if coalesce(x.data->>'billing', 'inv') = 'none' and coalesce(dd - today, 0) <= cdue then
      sev := 1; tag := 'غير مفوترة'; title := x.data->>'tenantName';
      sub := coalesce(x.data->>'period', '') || ' — لم تصدر فاتورتها'; at_date := dd; kind := 'bill';
      return next;
    end if;
  end loop;

  -- التذكيرات اليدوية
  for r in select data from public.reminders where project = p and coalesce(data->>'done','false') <> 'true' loop
    dd := krc_d(r.data->>'date');
    if dd is null then continue; end if;
    n := dd - today;
    if n > 7 then continue; end if;
    sev := case when n <= 0 then 0 else 2 end;
    tag := case when n < 0 then 'تذكير متأخر' when n = 0 then 'تذكير اليوم' else 'تذكير قادم' end;
    title := coalesce(nullif(r.data->>'title',''), 'تذكير');
    sub := coalesce(r.data->>'note', '') || ' — ' || krc_fd(dd); at_date := dd; kind := 'rem';
    return next;
  end loop;
end $$;

-- 5) بناء الرسالة وإرسالها عبر Resend
create or replace function public.krc_send_alerts(p text, mode text default 'auto') returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  s record; c jsonb; pr jsonb; key text; tos jsonb; it record;
  today date := (now() at time zone 'Asia/Riyadh')::date;
  app text := 'https://karam-rent.github.io/karam-rent/';
  n int := 0; nbad int := 0; nwarn int := 0; ninfo int := 0;
  rows text := ''; html text; subj text; frm text; logo text; pname text; rid bigint;
  col text; bg text;
begin
  select * into s from public.email_settings where project = p;
  if not found then return jsonb_build_object('ok', false, 'reason', 'لا توجد إعدادات لهذا المشروع'); end if;
  c := s.data;
  select v into key from public.app_secrets where k = 'resend_key';
  if key is null then return jsonb_build_object('ok', false, 'reason', 'لم يُحفظ مفتاح Resend بعد'); end if;

  select jsonb_agg(e) into tos from (
    select distinct lower(btrim(z)) e from jsonb_array_elements_text(krc_arr(c->'to')) z
    where btrim(z) ~ '^[^@\s]+@[^@\s]+\.[^@\s]+$') q;
  if tos is null then return jsonb_build_object('ok', false, 'reason', 'لا يوجد مستلمون'); end if;

  select data into pr from public.projects where id = p;
  pname := coalesce(pr->>'name', p);
  logo := coalesce(nullif(pr->>'logo',''), 'logo.png');
  logo := case when logo like 'data:%' then null when logo ~ '^https?://' then logo else app || logo end;

  for it in
    select * from krc_alerts(p, c, today) a
    where coalesce((c->'types'->>a.kind)::boolean, true)
      and (coalesce((c->>'onlyUrgent')::boolean, false) = false or a.sev = 0)
    order by a.sev, a.at_date nulls last
  loop
    n := n + 1;
    if it.sev = 0 then nbad := nbad + 1; col := '#b42318'; bg := '#fdecea';
    elsif it.sev = 1 then nwarn := nwarn + 1; col := '#a15c07'; bg := '#fdf3e1';
    else ninfo := ninfo + 1; col := '#2a1460'; bg := '#efeaf8'; end if;
    if n <= 200 then
      rows := rows || '<tr><td width="1" style="padding:10px 12px;border-top:1px solid #eee;white-space:nowrap;vertical-align:top">'
        || '<span style="display:inline-block;padding:3px 10px;border-radius:999px;font-size:12px;background:' || bg || ';color:' || col || '">'
        || krc_esc(it.tag) || '</span></td><td style="padding:10px 12px;border-top:1px solid #eee">'
        || '<div style="font-weight:bold;color:#1d1530">' || krc_esc(it.title) || '</div>'
        || '<div style="color:#6b6480;font-size:13px;margin-top:2px">' || krc_esc(it.sub) || '</div></td></tr>';
    end if;
  end loop;

  if n = 0 and mode = 'auto' and coalesce((c->>'skipEmpty')::boolean, true) then
    update public.email_settings set last_sent = today where project = p;
    insert into public.email_log (project, kind, recipients, n, note) values (p, mode, tos, 0, 'لا توجد تنبيهات — لم تُرسل رسالة');
    return jsonb_build_object('ok', true, 'n', 0, 'skipped', true);
  end if;

  subj := 'تنبيهات ' || pname || ' — ' || krc_fd(today) ||
          case when nbad > 0 then ' (' || nbad || ' عاجل)' else '' end;

  html := '<div dir="rtl" style="background:#f4f2f8;padding:24px 12px;font-family:Tahoma,Arial,sans-serif">'
    || '<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width:680px;margin:0 auto;background:#ffffff;border-radius:14px;overflow:hidden;border-collapse:collapse">'
    || '<tr><td colspan="2" style="background:#2a1460;padding:18px 20px;color:#ffffff">'
    || case when logo is not null then '<img src="' || krc_esc(logo) || '" alt="" style="height:44px;background:#fff;border-radius:8px;padding:4px;vertical-align:middle;margin-left:10px">' else '' end
    || '<span style="font-size:18px;font-weight:bold;vertical-align:middle">' || krc_esc(pname) || '</span>'
    || '<div style="font-size:13px;opacity:.85;margin-top:6px">ملخص التنبيهات — ' || krc_fd(today) || '</div></td></tr>'
    || '<tr><td colspan="2" style="padding:16px 20px">'
    || '<span style="display:inline-block;margin:0 0 6px 8px;padding:6px 12px;border-radius:8px;background:#fdecea;color:#b42318;font-weight:bold">عاجل: ' || nbad || '</span>'
    || '<span style="display:inline-block;margin:0 0 6px 8px;padding:6px 12px;border-radius:8px;background:#fdf3e1;color:#a15c07;font-weight:bold">تنبيه: ' || nwarn || '</span>'
    || '<span style="display:inline-block;margin:0 0 6px 8px;padding:6px 12px;border-radius:8px;background:#efeaf8;color:#2a1460;font-weight:bold">للعلم: ' || ninfo || '</span>'
    || '</td></tr>'
    || case when n = 0 then '<tr><td colspan="2" style="padding:16px 20px;color:#6b6480">لا توجد تنبيهات اليوم — كل شيء تحت السيطرة.</td></tr>' else rows end
    || case when n > 200 then '<tr><td colspan="2" style="padding:10px 12px;color:#6b6480">و' || (n - 200) || ' تنبيه آخر داخل البرنامج.</td></tr>' else '' end
    || '<tr><td colspan="2" style="padding:20px;text-align:center"><a href="' || app || '" style="display:inline-block;background:#2a1460;color:#ffffff;text-decoration:none;padding:11px 26px;border-radius:10px;font-weight:bold">فتح البرنامج</a></td></tr>'
    || '<tr><td colspan="2" style="padding:12px 20px 18px;color:#9a93ad;font-size:12px;border-top:1px solid #eee">رسالة تلقائية من نظام إيجارات كرم. لإيقافها أو تغيير موعدها: الجرس ← تنبيهات الإيميل.</td></tr>'
    || '</table></div>';

  frm := coalesce(nullif(btrim(c->>'sender'), ''), 'Karam Alerts <onboarding@resend.dev>');

  rid := net.http_post(
    url := 'https://api.resend.com/emails',
    body := jsonb_build_object('from', frm, 'to', tos, 'subject', subj, 'html', html),
    headers := jsonb_build_object('Authorization', 'Bearer ' || key, 'Content-Type', 'application/json'),
    timeout_milliseconds := 15000);

  insert into public.email_log (project, kind, recipients, n, request_id) values (p, mode, tos, n, rid);
  if mode = 'auto' then update public.email_settings set last_sent = today where project = p; end if;
  return jsonb_build_object('ok', true, 'n', n, 'request', rid);
end $$;

-- تحديث حالة الرسائل المرسلة من رد الخادم
create or replace function public.krc_sync_email_status() returns void
language sql security definer set search_path = public as $$
  update public.email_log l
     set status = coalesce(r.status_code, 0), resp = left(coalesce(r.content, r.error_msg, ''), 300)
    from net._http_response r
   where r.id = l.request_id and l.status is null;
$$;

-- 6) المُجدوِل: يفحص كل 15 دقيقة ويرسل حسب إعدادات كل مشروع (بتوقيت الرياض)
create or replace function public.krc_run_alert_emails() returns int
language plpgsql security definer set search_path = public as $$
declare
  s record; k int := 0;
  now_l timestamp := now() at time zone 'Asia/Riyadh';
  today date := (now() at time zone 'Asia/Riyadh')::date;
  tm time; since interval;
begin
  perform public.krc_sync_email_status();
  for s in select * from public.email_settings loop
    if coalesce((s.data->>'enabled')::boolean, false) is not true then continue; end if;
    if s.last_sent is not null and s.last_sent >= today then continue; end if;
    if krc_d(s.data->>'from') is not null and today < krc_d(s.data->>'from') then continue; end if;
    if krc_d(s.data->>'until') is not null and today > krc_d(s.data->>'until') then continue; end if;
    if jsonb_typeof(s.data->'days') = 'array'
       and not (s.data->'days' @> to_jsonb(extract(dow from today)::int)) then continue; end if;
    begin tm := coalesce(nullif(s.data->>'time','')::time, '08:00'); exception when others then tm := '08:00'; end;
    since := now_l - (today + tm);
    if since < interval '0' or since > interval '3 hours' then continue; end if;
    begin
      perform public.krc_send_alerts(s.project, 'auto');
      k := k + 1;
    exception when others then
      insert into public.email_log (project, kind, note) values (s.project, 'error', sqlerrm);
    end;
  end loop;
  return k;
end $$;

-- 7) وظائف يستدعيها البرنامج (للمدير فقط)
create or replace function public.email_key_status() returns boolean
language sql stable security definer set search_path = public as $$
  select public.has_perm('users') and exists (select 1 from public.app_secrets where k = 'resend_key')
$$;

create or replace function public.set_email_key(newkey text) returns boolean
language plpgsql security definer set search_path = public as $$
begin
  if not public.has_perm('users') then raise exception 'غير مصرح'; end if;
  if coalesce(btrim(newkey), '') = '' then delete from public.app_secrets where k = 'resend_key'; return false; end if;
  insert into public.app_secrets (k, v) values ('resend_key', btrim(newkey))
  on conflict (k) do update set v = excluded.v;
  return true;
end $$;

create or replace function public.send_alert_email_test(p text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not (public.has_perm('users') and public.has_project(p)) then raise exception 'غير مصرح'; end if;
  return public.krc_send_alerts(p, 'test');
end $$;

create or replace function public.email_log_list(p text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if not (public.has_perm('users') and public.has_project(p)) then raise exception 'غير مصرح'; end if;
  perform public.krc_sync_email_status();
  return coalesce((select jsonb_agg(to_jsonb(l) order by l.id desc) from (
    select id, at, kind, recipients, n, status, resp, note from public.email_log
    where project = p order by id desc limit 20) l), '[]'::jsonb);
end $$;

revoke execute on function public.krc_send_alerts(text, text)  from public, anon, authenticated;
revoke execute on function public.krc_run_alert_emails()        from public, anon, authenticated;
revoke execute on function public.krc_sync_email_status()       from public, anon, authenticated;
revoke execute on function public.email_key_status()            from public, anon;
revoke execute on function public.set_email_key(text)           from public, anon;
revoke execute on function public.send_alert_email_test(text)   from public, anon;
revoke execute on function public.email_log_list(text)          from public, anon;
grant  execute on function public.email_key_status()            to authenticated;
grant  execute on function public.set_email_key(text)           to authenticated;
grant  execute on function public.send_alert_email_test(text)   to authenticated;
grant  execute on function public.email_log_list(text)          to authenticated;

-- 8) تشغيل الفحص كل 15 دقيقة
select cron.schedule('karam-alert-emails', '*/15 * * * *', 'select public.krc_run_alert_emails()');

select 'تم تفعيل تنبيهات الإيميل' as result;
